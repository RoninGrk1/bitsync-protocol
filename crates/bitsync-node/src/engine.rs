//! Round engine: observe → gossip → aggregate → co-sign report → archive.

use crate::config::NodeConfig;
use crate::metrics::NodeMetrics;
use crate::network::InboundGate;
use crate::network::{Network, NetworkEvent};
use crate::protocol::{GossipMessage, SignedObservation, SignedReportShare};
use crate::signed_state::SignedStateStore;
use anyhow::{bail, Result};
use bitsync_consensus::{
    aggregate, report_from_aggregate, stake_quorum_met, AggregationConfig, Committee,
    Observation as ConsObs,
};
use bitsync_crypto::{Address, Domain, Observation, Report, Signer, SoftwareSigner};
use bitsync_sources::{MockSignedSource, PriceSource};
use bitsync_storage::Archive;
use futures::StreamExt;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tracing::{info, warn};

/// How a node behaves in a round (tests inject faults here).
#[derive(Clone, Debug, Default)]
pub enum Behaviour {
    /// Honest: report the source price (± tiny noise).
    #[default]
    Honest,
    /// Byzantine outlier: report `price_override` regardless of the source.
    Outlier {
        /// Fake price.
        price_override: i128,
    },
    /// Equivocate: publish two conflicting observations (detected off-chain / slashable).
    Equivocate {
        /// Second conflicting price.
        alt_price: i128,
    },
    /// Silence: publish nothing.
    Silent,
}

/// Outcome of a single feed round.
#[derive(Clone, Debug)]
pub enum RoundOutcome {
    /// Aggregate finalised with a stake quorum of report signatures.
    Finalised {
        /// Feed label.
        feed: String,
        /// Aggregate price.
        price: i128,
        /// Content id of the archived report.
        cid: String,
        /// Number of observation contributors accepted.
        accepted: usize,
        /// Number of report co-signers.
        cosigners: usize,
    },
    /// Not enough honest observations / signatures — progress halted safely.
    Halted {
        /// Feed label.
        feed: String,
        /// Why.
        reason: String,
    },
}

/// Oracle node engine over an abstract [`Network`].
pub struct NodeEngine<N: Network> {
    /// Config.
    pub cfg: NodeConfig,
    /// Network handle.
    pub network: Arc<N>,
    /// Local signer.
    pub signer: Arc<SoftwareSigner>,
    /// Price source.
    pub source: Arc<dyn PriceSource>,
    /// Archive backend.
    pub archive: Arc<dyn Archive>,
    /// Optional metrics.
    pub metrics: Option<Arc<NodeMetrics>>,
    /// Behaviour (fault injection).
    pub behaviour: Behaviour,
    /// Known committee operators → stake. Must include self.
    pub committee_stakes: HashMap<Address, u128>,
    /// Inbound gossip rate-limit + dedupe (BSY-H6).
    pub inbound_gate: InboundGate,
    /// Persist last-signed observation digests (BSY-H5).
    pub signed_state: SignedStateStore,
}

impl<N: Network> NodeEngine<N> {
    /// Construct.
    pub fn new(
        cfg: NodeConfig,
        network: Arc<N>,
        signer: Arc<SoftwareSigner>,
        source: Arc<dyn PriceSource>,
        archive: Arc<dyn Archive>,
    ) -> Self {
        let mut committee_stakes = HashMap::new();
        committee_stakes.insert(signer.address(), cfg.operator_stake as u128);
        let signed_state =
            SignedStateStore::open(cfg.signed_state_dir.as_deref()).expect("signed state store");
        Self {
            cfg,
            network,
            signer,
            source,
            archive,
            metrics: None,
            behaviour: Behaviour::Honest,
            committee_stakes,
            inbound_gate: InboundGate::default(),
            signed_state,
        }
    }

    /// Register peer operators (address → stake).
    pub fn set_committee(&mut self, stakes: HashMap<Address, u128>) {
        self.committee_stakes = stakes;
    }

    /// EIP-712 domain.
    pub fn domain(&self) -> Result<Domain> {
        Ok(Domain::bitsync_oracle(
            self.cfg.chain_id,
            self.cfg.verifying_contract.parse()?,
        ))
    }

    /// Run one round for every configured feed.
    pub async fn run_round(&self, round: u64) -> Result<Vec<RoundOutcome>> {
        let mut out = Vec::new();
        for feed in &self.cfg.feeds {
            out.push(self.run_feed_round(feed, round).await?);
        }
        Ok(out)
    }

    /// Run a single feed round.
    pub async fn run_feed_round(&self, feed: &str, round: u64) -> Result<RoundOutcome> {
        let domain = self.domain()?;
        let feed_id = Report::feed_id_from_label(feed)?;
        let timestamp = now_secs();
        // Committee size is the number of known operators. Solo/--once has only
        // the local signer registered, so n=1 and rounds still finalise offline.
        let committee = Committee::from_n(self.committee_stakes.len().max(1));
        let collect = Duration::from_millis(self.cfg.collect_timeout_ms);

        // Subscribe BEFORE publishing so we do not miss our own gossip (broadcast
        // receivers only see messages sent after they subscribe).
        let mut inbound = self.network.subscribe();
        let mut observations: HashMap<Address, SignedObservation> = HashMap::new();

        // --- Phase 1: publish own observation(s) ---------------------------------
        match &self.behaviour {
            Behaviour::Silent => {}
            Behaviour::Honest => {
                let tick = self.source.fetch(feed).await?;
                tick.verify()?;
                let so = self
                    .build_observation(
                        feed_id,
                        tick.price,
                        tick.confidence,
                        timestamp,
                        round,
                        &domain,
                    )
                    .await?;
                observations.insert(so.operator, so.clone());
                self.network.publish(GossipMessage::Observation(so)).await?;
            }
            Behaviour::Outlier { price_override } => {
                let so = self
                    .build_observation(feed_id, *price_override, 1, timestamp, round, &domain)
                    .await?;
                observations.insert(so.operator, so.clone());
                self.network.publish(GossipMessage::Observation(so)).await?;
            }
            Behaviour::Equivocate { alt_price } => {
                let tick = self.source.fetch(feed).await?;
                let so1 = self
                    .build_observation(
                        feed_id,
                        tick.price,
                        tick.confidence,
                        timestamp,
                        round,
                        &domain,
                    )
                    .await?;
                let so2 = self
                    .build_observation(feed_id, *alt_price, 1, timestamp, round, &domain)
                    .await?;
                // Keep only the last locally; both go on the wire (slashable).
                observations.insert(so1.operator, so2.clone());
                self.network
                    .publish(GossipMessage::Observation(so1))
                    .await?;
                self.network
                    .publish(GossipMessage::Observation(so2))
                    .await?;
            }
        }

        // --- Phase 2: collect observations ---------------------------------------
        let deadline = tokio::time::Instant::now() + collect;
        while tokio::time::Instant::now() < deadline {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            match tokio::time::timeout(remaining, inbound.next()).await {
                Ok(Some(NetworkEvent { message, .. })) => {
                    if let GossipMessage::Observation(so) = message {
                        let fp = {
                            use std::hash::{Hash, Hasher};
                            let mut h = std::collections::hash_map::DefaultHasher::new();
                            so.operator.0.hash(&mut h);
                            so.observation.round.hash(&mut h);
                            so.observation.price.hash(&mut h);
                            h.finish()
                        };
                        if !self.inbound_gate.admit("gossip", fp) {
                            continue;
                        }
                        if so.observation.feed_id == feed_id
                            && so.observation.round == round
                            && self.verify_observation(&so, &domain).is_ok()
                        {
                            observations.insert(so.operator, so);
                        }
                    }
                }
                Ok(None) | Err(_) => break,
            }
            if observations.len() >= self.cfg.committee_n {
                break;
            }
        }

        let cons: Vec<ConsObs> = observations
            .values()
            .map(|so| ConsObs {
                operator: so.operator,
                stake: *self.committee_stakes.get(&so.operator).unwrap_or(&so.stake),
                price: so.observation.price,
                confidence: so.observation.confidence,
            })
            .collect();

        let agg = match aggregate(&committee, &AggregationConfig::default(), &cons) {
            Ok(a) => a,
            Err(e) => {
                warn!(feed, round, error = %e, "aggregation halted");
                if let Some(m) = &self.metrics {
                    m.rounds_failed.inc();
                }
                return Ok(RoundOutcome::Halted {
                    feed: feed.into(),
                    reason: e.to_string(),
                });
            }
        };

        // BSY-H4: report timestamp is the median of accepted observation timestamps
        // (deterministic across honest nodes), not each node's wall clock.
        let mut ts: Vec<u64> = agg
            .accepted
            .iter()
            .filter_map(|op| observations.get(op).map(|so| so.observation.timestamp))
            .collect();
        ts.sort_unstable();
        let report_ts = if ts.is_empty() {
            timestamp
        } else if ts.len() % 2 == 0 {
            ts[ts.len() / 2 - 1]
        } else {
            ts[ts.len() / 2]
        };
        let report = report_from_aggregate(feed_id, round, report_ts, &agg);

        // --- Phase 3: co-sign the aggregate report --------------------------------
        let mut shares: HashMap<Address, SignedReportShare> = HashMap::new();
        if !matches!(self.behaviour, Behaviour::Silent) {
            let digest = report.digest(&domain);
            let signature = self.signer.sign_digest(&digest).await?;
            let share = SignedReportShare {
                operator: self.signer.address(),
                stake: self.cfg.operator_stake as u128,
                report: report.clone(),
                signature,
            };
            shares.insert(share.operator, share.clone());
            self.network
                .publish(GossipMessage::ReportShare(share))
                .await?;
        }

        // --- Phase 4: collect report shares ---------------------------------------
        let deadline = tokio::time::Instant::now() + collect;
        while tokio::time::Instant::now() < deadline {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            match tokio::time::timeout(remaining, inbound.next()).await {
                Ok(Some(NetworkEvent { message, .. })) => {
                    if let GossipMessage::ReportShare(sr) = message {
                        if sr.report == report && self.verify_report_share(&sr, &domain).is_ok() {
                            shares.insert(sr.operator, sr);
                        }
                    }
                }
                Ok(None) | Err(_) => break,
            }
            let signed_stake: u128 = shares
                .keys()
                .map(|op| *self.committee_stakes.get(op).unwrap_or(&0))
                .sum();
            let total: u128 = self.committee_stakes.values().sum();
            if stake_quorum_met(signed_stake, total) && shares.len() >= committee.quorum_size() {
                break;
            }
        }

        let signed_stake: u128 = shares
            .keys()
            .map(|op| *self.committee_stakes.get(op).unwrap_or(&0))
            .sum();
        let total: u128 = self.committee_stakes.values().sum();
        if !stake_quorum_met(signed_stake, total) || shares.len() < committee.quorum_size() {
            warn!(
                feed,
                round,
                signed_stake,
                total,
                cosigners = shares.len(),
                "report quorum not reached"
            );
            if let Some(m) = &self.metrics {
                m.rounds_failed.inc();
            }
            return Ok(RoundOutcome::Halted {
                feed: feed.into(),
                reason: format!(
                    "report quorum not reached: stake {signed_stake}/{total}, signers {}",
                    shares.len()
                ),
            });
        }

        let encoded = serde_json::to_vec(&report)?;
        let cid = self.archive.put(&encoded).await?;
        info!(
            feed,
            round,
            price = agg.price,
            cid = %cid,
            accepted = agg.accepted.len(),
            cosigners = shares.len(),
            "finalised networked report"
        );
        if let Some(m) = &self.metrics {
            m.rounds_ok.inc();
            m.reports_finalised.inc();
            m.last_round.set(round as i64);
        }
        Ok(RoundOutcome::Finalised {
            feed: feed.into(),
            price: agg.price,
            cid,
            accepted: agg.accepted.len(),
            cosigners: shares.len(),
        })
    }

    async fn build_observation(
        &self,
        feed_id: [u8; 32],
        price: i128,
        confidence: u128,
        timestamp: u64,
        round: u64,
        domain: &Domain,
    ) -> Result<SignedObservation> {
        let observation = Observation {
            feed_id,
            price,
            confidence,
            timestamp,
            round,
        };
        let digest = observation.digest(domain);
        // BSY-H5: never sign a different observation for the same (feed, round).
        if !self
            .signed_state
            .check_and_record_observation(&feed_id, round, &digest)?
        {
            bail!("refusing to equivocate: already signed a different observation for feed/round");
        }
        let signature = self.signer.sign_digest(&digest).await?;
        Ok(SignedObservation {
            operator: self.signer.address(),
            stake: self.cfg.operator_stake as u128,
            observation,
            signature,
        })
    }

    fn verify_observation(&self, so: &SignedObservation, domain: &Domain) -> Result<()> {
        if !self.committee_stakes.contains_key(&so.operator) {
            bail!("unknown operator {}", so.operator);
        }
        let digest = so.observation.digest(domain);
        let recovered = so.signature.recover(&digest)?;
        if recovered != so.operator {
            bail!("observation signature mismatch");
        }
        Ok(())
    }

    fn verify_report_share(&self, sr: &SignedReportShare, domain: &Domain) -> Result<()> {
        if !self.committee_stakes.contains_key(&sr.operator) {
            bail!("unknown operator {}", sr.operator);
        }
        let digest = sr.report.digest(domain);
        let recovered = sr.signature.recover(&digest)?;
        if recovered != sr.operator {
            bail!("report share signature mismatch");
        }
        Ok(())
    }
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// Build a default offline source bound to a node id.
pub fn default_source(node_id: &str) -> Arc<MockSignedSource> {
    Arc::new(MockSignedSource::new(format!("{node_id}-fixture")))
}

/// Convenience: equal-stake committee map from a list of signers.
pub fn equal_committee(signers: &[Arc<SoftwareSigner>], stake: u128) -> HashMap<Address, u128> {
    signers.iter().map(|s| (s.address(), stake)).collect()
}
