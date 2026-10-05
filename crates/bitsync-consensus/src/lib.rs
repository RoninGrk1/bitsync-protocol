//! # bitsync-consensus
//!
//! Byzantine-fault-tolerant, stake-weighted price aggregation.
//!
//! For `n = 3f + 1` operators the protocol tolerates up to `f` Byzantine
//! faults. Each round:
//!
//! 1. Operators publish signed observations for a feed.
//! 2. Observations outside a robust MAD (median absolute deviation) band
//!    around the stake-weighted median are rejected as outliers.
//! 3. The stake-weighted median of the remaining set becomes the round's
//!    aggregate price; a quorum of `2f + 1` distinct operator signatures on
//!    the EIP-712 report digest is required before the round is final.
//!
//! This crate is pure logic — networking lives in `bitsync-p2p` and the node
//! binary.

#![forbid(unsafe_code)]
#![warn(missing_docs)]

use bitsync_crypto::{Address, Report};
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Consensus errors.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum ConsensusError {
    /// Not enough honest stake / signatures to finalise.
    #[error("quorum not reached: have {have}, need {need}")]
    QuorumNotReached {
        /// Accumulated weight.
        have: u128,
        /// Required weight.
        need: u128,
    },
    /// Operator set size is not of the form `3f+1` (warn-only in permissive mode).
    #[error("operator set size {0} cannot tolerate the configured f")]
    InvalidCommittee(usize),
    /// Duplicate vote from the same operator.
    #[error("duplicate vote from {0}")]
    Duplicate(Address),
    /// Empty observation set.
    #[error("no observations")]
    Empty,
}

/// An operator's observation for a single round.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Observation {
    /// Operator address (ECDSA identity used on-chain).
    pub operator: Address,
    /// Stake weight (BSY base units bonded).
    pub stake: u128,
    /// Observed price (feed decimals).
    pub price: i128,
    /// Self-reported confidence (±).
    pub confidence: u128,
}

/// Committee parameters. `n` should equal `3f + 1`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Committee {
    /// Maximum Byzantine faults tolerated.
    pub f: usize,
}

impl Committee {
    /// Derive `f` from `n` using `f = (n - 1) / 3`.
    pub fn from_n(n: usize) -> Self {
        Self {
            f: n.saturating_sub(1) / 3,
        }
    }

    /// Quorum size in operators: `2f + 1`.
    pub fn quorum_size(&self) -> usize {
        2 * self.f + 1
    }

    /// Expected committee size `3f + 1`.
    pub fn expected_n(&self) -> usize {
        3 * self.f + 1
    }
}

/// Tunables for outlier rejection.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AggregationConfig {
    /// MAD multiplier. Observations with `|x - median| > k * MAD` are dropped.
    /// `k = 3.0` is a common robust default.
    pub mad_k: f64,
    /// If `true`, require the operator set size to equal `3f+1`.
    pub strict_committee: bool,
}

impl Default for AggregationConfig {
    fn default() -> Self {
        Self {
            mad_k: 3.0,
            strict_committee: false,
        }
    }
}

/// Result of a successful aggregation round.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Aggregate {
    /// Stake-weighted median price after outlier rejection.
    pub price: i128,
    /// Aggregated confidence (stake-weighted median of remaining).
    pub confidence: u128,
    /// Operators whose observations were accepted.
    pub accepted: Vec<Address>,
    /// Operators rejected as outliers.
    pub rejected: Vec<Address>,
    /// Total accepted stake.
    pub accepted_stake: u128,
}

/// Compute the (unweighted) median of a non-empty slice. Panics if empty —
/// callers must guard.
fn median_i128(values: &mut [i128]) -> i128 {
    values.sort_unstable();
    let mid = values.len() / 2;
    if values.len() % 2 == 0 {
        // Bias toward lower for determinism with even counts.
        values[mid - 1]
    } else {
        values[mid]
    }
}

/// Stake-weighted median: sort by price ascending; walk until cumulative
/// stake reaches half of total.
pub fn stake_weighted_median(obs: &[Observation]) -> Result<i128, ConsensusError> {
    if obs.is_empty() {
        return Err(ConsensusError::Empty);
    }
    let total: u128 = obs.iter().map(|o| o.stake).sum();
    if total == 0 {
        return Err(ConsensusError::Empty);
    }
    let mut sorted = obs.to_vec();
    sorted.sort_by_key(|o| o.price);
    let mut acc = 0u128;
    for o in &sorted {
        acc = acc.saturating_add(o.stake);
        if acc * 2 >= total {
            return Ok(o.price);
        }
    }
    Ok(sorted.last().unwrap().price)
}

/// Median absolute deviation around `center`.
fn mad(values: &[i128], center: i128) -> i128 {
    if values.is_empty() {
        return 0;
    }
    let mut devs: Vec<i128> = values.iter().map(|v| (v - center).abs()).collect();
    median_i128(&mut devs)
}

/// Aggregate observations for a round.
pub fn aggregate(
    committee: &Committee,
    cfg: &AggregationConfig,
    observations: &[Observation],
) -> Result<Aggregate, ConsensusError> {
    if observations.is_empty() {
        return Err(ConsensusError::Empty);
    }
    if cfg.strict_committee && observations.len() != committee.expected_n() {
        return Err(ConsensusError::InvalidCommittee(observations.len()));
    }

    // Dedup by operator (last write wins, but flag duplicates as hard error).
    let mut seen = Vec::new();
    for o in observations {
        if seen.contains(&o.operator) {
            return Err(ConsensusError::Duplicate(o.operator));
        }
        seen.push(o.operator);
    }

    let median = stake_weighted_median(observations)?;
    let prices: Vec<i128> = observations.iter().map(|o| o.price).collect();
    let mad_v = mad(&prices, median);
    // MAD == 0 means a strict majority sits on the exact median. Keep only that
    // median value (band 0) so a lone Byzantine outlier is rejected. When all
    // observations already equal the median they remain accepted.
    // Never collapse the band to 0: with an even observation count the lower
    // median of absolute deviations can be 0 even when honest prices differ by
    // a tick (BSY-H3). A minimum band of 1 keeps near-median honest values.
    let band = ((cfg.mad_k * mad_v as f64).ceil() as i128).max(1);

    let mut accepted = Vec::new();
    let mut rejected = Vec::new();
    for o in observations {
        if (o.price - median).abs() <= band {
            accepted.push(o.clone());
        } else {
            rejected.push(o.operator);
        }
    }

    if accepted.len() < committee.quorum_size() {
        return Err(ConsensusError::QuorumNotReached {
            have: accepted.len() as u128,
            need: committee.quorum_size() as u128,
        });
    }

    let price = stake_weighted_median(&accepted)?;
    let conf_obs: Vec<Observation> = accepted
        .iter()
        .map(|o| Observation {
            price: o.confidence as i128,
            ..o.clone()
        })
        .collect();
    let confidence = stake_weighted_median(&conf_obs)? as u128;
    let accepted_stake = accepted.iter().map(|o| o.stake).sum();

    Ok(Aggregate {
        price,
        confidence,
        accepted: accepted.iter().map(|o| o.operator).collect(),
        rejected,
        accepted_stake,
    })
}

/// Build the canonical [`Report`] from an aggregate + round metadata.
pub fn report_from_aggregate(
    feed_id: [u8; 32],
    round: u64,
    timestamp: u64,
    agg: &Aggregate,
) -> Report {
    Report {
        feed_id,
        price: agg.price,
        confidence: agg.confidence,
        timestamp,
        round,
    }
}

/// Does `weight` meet a stake quorum of `2/3` of `total`?
pub fn stake_quorum_met(weight: u128, total: u128) -> bool {
    // Strictly greater than 2/3 — matches OracleAggregator (signed*3 > total*2).
    total > 0 && weight.saturating_mul(3) > total.saturating_mul(2)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn addr(b: u8) -> Address {
        Address([b; 20])
    }

    fn obs(op: u8, stake: u128, price: i128) -> Observation {
        Observation {
            operator: addr(op),
            stake,
            price,
            confidence: 1,
        }
    }

    #[test]
    fn committee_3f1() {
        let c = Committee::from_n(4);
        assert_eq!(c.f, 1);
        assert_eq!(c.quorum_size(), 3);
        assert_eq!(c.expected_n(), 4);
    }

    #[test]
    fn weighted_median_basic() {
        let v = vec![obs(1, 10, 100), obs(2, 50, 200), obs(3, 10, 300)];
        // Cumulative: 10@100, 60@200 → half of 70 is 35 → 200.
        assert_eq!(stake_weighted_median(&v).unwrap(), 200);
    }

    #[test]
    fn rejects_outlier_and_requires_quorum() {
        let c = Committee::from_n(4);
        let cfg = AggregationConfig::default();
        // Three honest ~100, one Byzantine at 1_000_000.
        let v = vec![
            obs(1, 100, 100),
            obs(2, 100, 101),
            obs(3, 100, 99),
            obs(4, 100, 1_000_000),
        ];
        let agg = aggregate(&c, &cfg, &v).unwrap();
        assert!(agg.rejected.contains(&addr(4)));
        assert_eq!(agg.accepted.len(), 3);
        assert!(agg.price >= 99 && agg.price <= 101);
    }

    #[test]
    fn quorum_not_reached() {
        let c = Committee { f: 1 }; // need 3
        let cfg = AggregationConfig::default();
        let v = vec![obs(1, 1, 10), obs(2, 1, 10)];
        assert!(matches!(
            aggregate(&c, &cfg, &v),
            Err(ConsensusError::QuorumNotReached { .. })
        ));
    }

    #[test]
    fn duplicate_rejected() {
        let c = Committee::from_n(4);
        let v = vec![obs(1, 1, 1), obs(1, 1, 2), obs(2, 1, 1), obs(3, 1, 1)];
        assert!(matches!(
            aggregate(&c, &AggregationConfig::default(), &v),
            Err(ConsensusError::Duplicate(_))
        ));
    }

    #[test]
    fn stake_quorum() {
        // Strict > 2/3: 2/3 exact fails; just above passes.
        assert!(stake_quorum_met(67, 100));
        assert!(!stake_quorum_met(66, 100));
        assert!(!stake_quorum_met(2, 3)); // exact 2/3 rejected (matches on-chain)
    }

    #[test]
    fn honest_even_committee_with_tick_noise_finalises() {
        // BSY-H3 regression: four honest equal-stake prices that differ by a tick.
        let c = Committee::from_n(4);
        let v = vec![
            obs(1, 1, 100),
            obs(2, 1, 100),
            obs(3, 1, 101),
            obs(4, 1, 102),
        ];
        let agg = aggregate(&c, &AggregationConfig::default(), &v).expect("must finalise");
        assert!(agg.accepted.len() >= 3);
        assert!(agg.price >= 100 && agg.price <= 102);
    }
}
