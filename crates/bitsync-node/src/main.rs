//! BitSync oracle node entrypoint.

use anyhow::{Context, Result};
use bitsync_crypto::{Amount, Signer, SoftwareSigner, BSY_SYMBOL, MAX_SUPPLY_BASE};
use bitsync_node::config::NodeConfig;
use bitsync_node::engine::{default_source, NodeEngine};
use bitsync_node::keystore;
use bitsync_node::libp2p_driver;
use bitsync_node::metrics::NodeMetrics;
use bitsync_node::network::{InMemoryMesh, Libp2pNetwork, Network};
use bitsync_p2p::Identity;
use bitsync_storage::{Archive, MemoryArchive};
use clap::Parser;
use prometheus::{Encoder, Registry, TextEncoder};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tracing::{info, warn};

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
    /// Run a single round and exit.
    #[arg(long)]
    once: bool,
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
        peers = cfg.bootstrap_peers.len(),
        listen = ?cfg.listen,
        "starting BitSync oracle node (unaudited / not mainnet-ready)"
    );

    let registry = Registry::new();
    let metrics = Arc::new(NodeMetrics::register(&registry)?);
    let archive: Arc<dyn Archive> = Arc::new(MemoryArchive::new());
    let source = default_source(&cfg.node_id);
    let key_path = cfg.operator_key_path.as_ref().ok_or_else(|| {
        anyhow::anyhow!(
            "operator_key_path is required (set in config TOML).              Refusing to generate an ephemeral key (BSY-H7)."
        )
    })?;
    let signer = Arc::new(keystore::load_signer(std::path::Path::new(key_path))?);
    info!(address = %signer.address(), "loaded persistent operator key");

    let metrics_addr: SocketAddr = cfg.metrics_listen.parse()?;
    let reg = registry.clone();
    tokio::spawn(async move {
        if let Err(e) = serve_metrics(metrics_addr, reg).await {
            warn!(error = %e, "metrics server exited");
        }
    });

    // Prefer libp2p when a listen address is configured (devnet / multi-node).
    // Otherwise fall back to a solo in-memory mesh so `--once` works offline.
    if let Some(listen) = cfg.listen.clone() {
        let (net, outbound_rx, _inbound_tx) = Libp2pNetwork::new(cfg.node_id.clone());
        let net = Arc::new(net);
        let identity = Identity::generate();
        let net_driver = Arc::clone(&net);
        let bootstrap = cfg.bootstrap_peers.clone();
        tokio::spawn(async move {
            if let Err(e) =
                libp2p_driver::run_libp2p(identity, &listen, &bootstrap, net_driver, outbound_rx)
                    .await
            {
                warn!(error = %e, "libp2p driver exited");
            }
        });
        // Give the swarm a moment to listen / dial before the first round.
        tokio::time::sleep(Duration::from_millis(500)).await;
        run_engine(cfg, net, signer, source, archive, metrics, cli.once).await?;
    } else {
        let mesh = InMemoryMesh::new();
        let net = Arc::new(mesh.join(cfg.node_id.clone()));
        run_engine(cfg, net, signer, source, archive, metrics, cli.once).await?;
    }
    Ok(())
}

async fn run_engine<N: Network + 'static>(
    cfg: NodeConfig,
    network: Arc<N>,
    signer: Arc<SoftwareSigner>,
    source: Arc<bitsync_sources::MockSignedSource>,
    archive: Arc<dyn Archive>,
    metrics: Arc<NodeMetrics>,
    once: bool,
) -> Result<()> {
    let mut engine = NodeEngine::new(cfg.clone(), network, signer, source, archive);
    engine.metrics = Some(metrics.clone());
    let mut round = 0u64;
    loop {
        round += 1;
        match engine.run_round(round).await {
            Ok(outcomes) => {
                for o in outcomes {
                    info!(?o, "round outcome");
                }
            }
            Err(e) => {
                warn!(round, error = %e, "round failed");
                metrics.rounds_failed.inc();
            }
        }
        if once {
            std::process::exit(0);
        }
        tokio::time::sleep(Duration::from_secs(cfg.round_interval_secs)).await;
    }
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
