//! BitSync oracle node entrypoint.

use anyhow::{Context, Result};
use bitsync_consensus::{
    aggregate, report_from_aggregate, AggregationConfig, Committee, Observation,
};
use bitsync_crypto::bsy::{Amount, BSY_SYMBOL, MAX_SUPPLY_BASE};
use bitsync_crypto::{Domain, Report, Signer, SoftwareSigner};
use bitsync_sources::{MockSignedSource, PriceSource};
use bitsync_storage::{Archive, MemoryArchive};
use clap::Parser;
use parking_lot::RwLock;
use prometheus::{Encoder, Registry, TextEncoder};
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tracing::{info, warn};

mod metrics;

/// BitSync oracle node.
#[derive(Debug, Parser)]
#[command(
    name = "bitsync-node",
    version,
    about = "The institutional oracle layer for Bitcoin."
)]
struct Cli {
    /// Path to TOML config.
    #[arg(short, long, default_value = "config/node.toml")]
    config: PathBuf,
    /// Run a single offline aggregation round against the mock source and exit.
    #[arg(long)]
    once: bool,
}

#[derive(Debug, Clone, Deserialize)]
struct NodeConfig {
    node_id: String,
    #[serde(default = "default_feeds")]
    feeds: Vec<String>,
    #[serde(default = "default_metrics")]
    metrics_listen: String,
    #[serde(default)]
    committee_n: usize,
    #[serde(default = "default_round_secs")]
    round_interval_secs: u64,
    #[serde(default)]
    chain_id: u64,
    #[serde(default)]
    verifying_contract: String,
}

fn default_feeds() -> Vec<String> {
    vec!["BTC/USD".into(), "ETH/USD".into()]
}
fn default_metrics() -> String {
    "0.0.0.0:9100".into()
}
fn default_round_secs() -> u64 {
    5
}

impl Default for NodeConfig {
    fn default() -> Self {
        Self {
            node_id: "node-0".into(),
            feeds: default_feeds(),
            metrics_listen: default_metrics(),
            committee_n: 4,
            round_interval_secs: default_round_secs(),
            chain_id: 31337,
            verifying_contract: "0x1111111111111111111111111111111111111111".into(),
        }
    }
}

#[derive(Clone, Serialize)]
struct FinalisedReport {
    report: Report,
    aggregate_price: i128,
    accepted: usize,
    cid: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "bitsync_node=info,bitsync=info".into()),
        )
        .init();

    let cli = Cli::parse();
    let cfg = if cli.config.exists() {
        let raw = std::fs::read_to_string(&cli.config)
            .with_context(|| format!("read {}", cli.config.display()))?;
        toml::from_str::<NodeConfig>(&raw)?
    } else {
        warn!(path = %cli.config.display(), "config not found; using defaults");
        NodeConfig::default()
    };

    info!(
        node = %cfg.node_id,
        supply = %Amount::MAX_SUPPLY,
        symbol = BSY_SYMBOL,
        max_base = MAX_SUPPLY_BASE,
        "starting BitSync oracle node (unaudited / not mainnet-ready)"
    );

    let registry = Registry::new();
    let metrics = metrics::NodeMetrics::register(&registry)?;
    let archive: Arc<dyn Archive> = Arc::new(MemoryArchive::new());
    let source = Arc::new(MockSignedSource::new(format!("{}-fixture", cfg.node_id)));
    let signer = Arc::new(SoftwareSigner::random());
    let state = Arc::new(RwLock::new(Vec::<FinalisedReport>::new()));

    let metrics_addr: SocketAddr = cfg.metrics_listen.parse()?;
    let reg = registry.clone();
    tokio::spawn(async move {
        if let Err(e) = serve_metrics(metrics_addr, reg).await {
            warn!(error = %e, "metrics server exited");
        }
    });

    if cli.once {
        run_round(
            &cfg,
            &source,
            archive.as_ref(),
            signer.as_ref(),
            &metrics,
            &state,
        )
        .await?;
        return Ok(());
    }

    let mut round = 0u64;
    loop {
        round += 1;
        if let Err(e) = run_round(
            &cfg,
            &source,
            archive.as_ref(),
            signer.as_ref(),
            &metrics,
            &state,
        )
        .await
        {
            warn!(round, error = %e, "round failed");
            metrics.rounds_failed.inc();
        } else {
            metrics.rounds_ok.inc();
            metrics.last_round.set(round as i64);
        }
        tokio::time::sleep(Duration::from_secs(cfg.round_interval_secs)).await;
    }
}

async fn run_round(
    cfg: &NodeConfig,
    source: &MockSignedSource,
    archive: &dyn Archive,
    signer: &SoftwareSigner,
    metrics: &metrics::NodeMetrics,
    state: &RwLock<Vec<FinalisedReport>>,
) -> Result<()> {
    let committee = Committee::from_n(if cfg.committee_n == 0 {
        4
    } else {
        cfg.committee_n
    });
    let agg_cfg = AggregationConfig::default();

    for feed in &cfg.feeds {
        let tick = source.fetch(feed).await?;
        tick.verify()?;
        metrics.ticks_verified.inc();

        // Simulate a 4-operator committee around the tick (offline / once mode).
        let base = tick.price;
        let observations = vec![
            Observation {
                operator: bitsync_crypto::Address([1u8; 20]),
                stake: 1_000 * bitsync_crypto::BSY_SCALE as u128,
                price: base,
                confidence: tick.confidence,
            },
            Observation {
                operator: bitsync_crypto::Address([2u8; 20]),
                stake: 1_000 * bitsync_crypto::BSY_SCALE as u128,
                price: base + 100_000_000,
                confidence: tick.confidence,
            },
            Observation {
                operator: bitsync_crypto::Address([3u8; 20]),
                stake: 1_000 * bitsync_crypto::BSY_SCALE as u128,
                price: base - 100_000_000,
                confidence: tick.confidence,
            },
            Observation {
                operator: bitsync_crypto::Address([4u8; 20]),
                stake: 1_000 * bitsync_crypto::BSY_SCALE as u128,
                price: base + 200_000_000,
                confidence: tick.confidence,
            },
        ];
        let agg = aggregate(&committee, &agg_cfg, &observations)?;
        let feed_id = Report::feed_id_from_label(feed)?;
        let report = report_from_aggregate(
            feed_id,
            metrics.last_round.get() as u64 + 1,
            tick.timestamp,
            &agg,
        );
        let domain = Domain::bitsync_oracle(cfg.chain_id, cfg.verifying_contract.parse()?);
        let digest = report.digest(&domain);
        let _sig = signer.sign_digest(&digest).await?;

        let encoded = serde_json::to_vec(&report)?;
        let cid = archive.put(&encoded).await?;
        info!(
            feed = %feed,
            price = agg.price,
            cid = %cid,
            accepted = agg.accepted.len(),
            "finalised report"
        );
        state.write().push(FinalisedReport {
            report,
            aggregate_price: agg.price,
            accepted: agg.accepted.len(),
            cid,
        });
        metrics.reports_finalised.inc();
    }
    Ok(())
}

async fn serve_metrics(addr: SocketAddr, registry: Registry) -> Result<()> {
    use axum::{routing::get, Router};
    let app = Router::new().route(
        "/metrics",
        get(move || {
            let registry = registry.clone();
            async move {
                let encoder = TextEncoder::new();
                let metric_families = registry.gather();
                let mut buf = Vec::new();
                encoder.encode(&metric_families, &mut buf).unwrap();
                (
                    [(
                        axum::http::header::CONTENT_TYPE,
                        encoder.format_type().to_string(),
                    )],
                    buf,
                )
            }
        }),
    );
    info!(%addr, "prometheus metrics listening");
    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}
