//! Operator observation (pre-aggregation) and its EIP-712 digest.
//!
//! Distinct from [`crate::report::Report`] so that an honest operator signing both an
//! observation and a report for the same feed/round is never framed as equivocation.

use crate::hash::keccak256;
use crate::report::Domain;
use serde::{Deserialize, Serialize};

/// A single operator's signed price observation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Observation {
    /// Feed identifier (bytes32).
    pub feed_id: [u8; 32],
    /// Observed price.
    pub price: i128,
    /// Confidence (±).
    pub confidence: u128,
    /// Observation timestamp (unix seconds).
    pub timestamp: u64,
    /// Round / epoch number.
    pub round: u64,
}

impl Observation {
    /// EIP-712 type hash.
    pub fn type_hash() -> [u8; 32] {
        keccak256(
            b"Observation(bytes32 feedId,int256 price,uint256 confidence,uint64 timestamp,uint64 round)",
        )
    }

    /// Struct hash.
    pub fn struct_hash(&self) -> [u8; 32] {
        let mut enc = Vec::with_capacity(32 * 6);
        enc.extend_from_slice(&Self::type_hash());
        enc.extend_from_slice(&self.feed_id);
        enc.extend_from_slice(&i256_be(self.price));
        enc.extend_from_slice(&u256_be(self.confidence));
        enc.extend_from_slice(&u256_be(self.timestamp as u128));
        enc.extend_from_slice(&u256_be(self.round as u128));
        keccak256(enc)
    }

    /// Full EIP-712 digest.
    pub fn digest(&self, domain: &Domain) -> [u8; 32] {
        let mut buf = [0u8; 66];
        buf[0] = 0x19;
        buf[1] = 0x01;
        buf[2..34].copy_from_slice(&domain.separator());
        buf[34..66].copy_from_slice(&self.struct_hash());
        keccak256(buf)
    }
}

fn u256_be(v: u128) -> [u8; 32] {
    let mut out = [0u8; 32];
    out[16..].copy_from_slice(&v.to_be_bytes());
    out
}

fn i256_be(v: i128) -> [u8; 32] {
    let mut out = [0u8; 32];
    if v >= 0 {
        out[16..].copy_from_slice(&(v as u128).to_be_bytes());
    } else {
        out.fill(0xff);
        out[16..].copy_from_slice(&(v as u128).to_be_bytes());
    }
    out
}
