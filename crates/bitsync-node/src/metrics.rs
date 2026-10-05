//! Prometheus metrics.

use anyhow::Result;
use prometheus::{IntCounter, IntGauge, Opts, Registry};

/// Process-level metrics.
pub struct NodeMetrics {
    /// Successful rounds.
    pub rounds_ok: IntCounter,
    /// Failed / halted rounds.
    pub rounds_failed: IntCounter,
    /// Last successful round number.
    pub last_round: IntGauge,
    /// Source ticks that verified.
    pub ticks_verified: IntCounter,
    /// Reports finalised and archived.
    pub reports_finalised: IntCounter,
}

impl NodeMetrics {
    /// Register on `registry`.
    pub fn register(registry: &Registry) -> Result<Self> {
        let rounds_ok = IntCounter::with_opts(Opts::new(
            "bitsync_rounds_ok",
            "Successful aggregation rounds",
        ))?;
        let rounds_failed = IntCounter::with_opts(Opts::new(
            "bitsync_rounds_failed",
            "Failed / halted aggregation rounds",
        ))?;
        let last_round =
            IntGauge::with_opts(Opts::new("bitsync_last_round", "Last successful round"))?;
        let ticks_verified = IntCounter::with_opts(Opts::new(
            "bitsync_ticks_verified",
            "Source ticks with valid signatures",
        ))?;
        let reports_finalised = IntCounter::with_opts(Opts::new(
            "bitsync_reports_finalised",
            "Reports finalised and archived",
        ))?;
        registry.register(Box::new(rounds_ok.clone()))?;
        registry.register(Box::new(rounds_failed.clone()))?;
        registry.register(Box::new(last_round.clone()))?;
        registry.register(Box::new(ticks_verified.clone()))?;
        registry.register(Box::new(reports_finalised.clone()))?;
        Ok(Self {
            rounds_ok,
            rounds_failed,
            last_round,
            ticks_verified,
            reports_finalised,
        })
    }
}
