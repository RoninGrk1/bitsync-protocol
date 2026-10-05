//! Wire types for gossiped observations and report shares.

use bitsync_crypto::{Address, EthSignature, Observation, Report};
use serde::{Deserialize, Serialize};

/// Stable operator identity (ECDSA address).
pub type OperatorId = Address;

/// A gossip envelope.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum GossipMessage {
    /// Signed observation for a feed/round.
    Observation(SignedObservation),
    /// Partial signature over the aggregate report.
    ReportShare(SignedReportShare),
}

/// Observation + operator ECDSA signature over its EIP-712 digest.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SignedObservation {
    /// Operator address.
    pub operator: OperatorId,
    /// Stake weight claimed for aggregation (trusted via committee config in v0).
    pub stake: u128,
    /// Observation payload.
    pub observation: Observation,
    /// Signature.
    pub signature: EthSignature,
}

/// Aggregate report + one operator's signature share.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SignedReportShare {
    /// Operator address.
    pub operator: OperatorId,
    /// Stake weight.
    pub stake: u128,
    /// Canonical aggregate report.
    pub report: Report,
    /// Signature over `report.digest(domain)`.
    pub signature: EthSignature,
}
