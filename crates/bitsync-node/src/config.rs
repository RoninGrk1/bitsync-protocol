//! Node configuration (TOML).

use serde::{Deserialize, Serialize};

/// Top-level node config.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NodeConfig {
    /// Human-readable node id (also used as gossip identity label).
    pub node_id: String,
    /// Feeds to produce each round.
    #[serde(default = "default_feeds")]
    pub feeds: Vec<String>,
    /// Prometheus listen address.
    #[serde(default = "default_metrics")]
    pub metrics_listen: String,
    /// Expected committee size `n = 3f+1`.
    #[serde(default = "default_committee")]
    pub committee_n: usize,
    /// Seconds between rounds.
    #[serde(default = "default_round_secs")]
    pub round_interval_secs: u64,
    /// How long to wait for peer observations within a round.
    #[serde(default = "default_collect_ms")]
    pub collect_timeout_ms: u64,
    /// EIP-712 chain id.
    #[serde(default = "default_chain")]
    pub chain_id: u64,
    /// Verifying contract for the EIP-712 domain.
    #[serde(default = "default_contract")]
    pub verifying_contract: String,
    /// Equal per-operator stake used for aggregation weight (BSY base units).
    /// Stored as u64 because `toml` cannot deserialize `u128`.
    #[serde(default = "default_stake")]
    pub operator_stake: u64,
    /// Optional libp2p listen multiaddr (e.g. `/ip4/0.0.0.0/tcp/4001`).
    #[serde(default)]
    pub listen: Option<String>,
    /// Bootstrap peer multiaddrs for the libp2p swarm.
    #[serde(default)]
    pub bootstrap_peers: Vec<String>,
    /// Path to a 32-byte hex secp256k1 operator secret (file). Required for non-test runs.
    /// When unset, the binary refuses to start (BSY-H7); tests use SoftwareSigner::random().
    #[serde(default)]
    pub operator_key_path: Option<String>,
    /// Directory used to persist last-signed (feed, round) digests across restarts (BSY-H5).
    #[serde(default)]
    pub signed_state_dir: Option<String>,
}

fn default_feeds() -> Vec<String> {
    vec!["BTC/USD".into(), "ETH/USD".into()]
}
fn default_metrics() -> String {
    "0.0.0.0:9100".into()
}
fn default_committee() -> usize {
    4
}
fn default_round_secs() -> u64 {
    5
}
fn default_collect_ms() -> u64 {
    1500
}
fn default_chain() -> u64 {
    31337
}
fn default_contract() -> String {
    "0x1111111111111111111111111111111111111111".into()
}
fn default_stake() -> u64 {
    10_000 * 100_000_000
}

impl Default for NodeConfig {
    fn default() -> Self {
        Self {
            node_id: "node-0".into(),
            feeds: default_feeds(),
            metrics_listen: default_metrics(),
            committee_n: default_committee(),
            round_interval_secs: default_round_secs(),
            collect_timeout_ms: default_collect_ms(),
            chain_id: default_chain(),
            verifying_contract: default_contract(),
            operator_stake: default_stake(),
            listen: None,
            bootstrap_peers: Vec::new(),
            operator_key_path: None,
            signed_state_dir: None,
        }
    }
}
