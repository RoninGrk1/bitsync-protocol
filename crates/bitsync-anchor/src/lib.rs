//! # bitsync-anchor
//!
//! Builds Bitcoin transactions that commit BitSync oracle-state Merkle roots
//! into an `OP_RETURN` output. No wallet / fund handling is performed — callers
//! supply a funded input and change address; this crate only constructs the
//! commitment payload and a skeleton transaction for signing elsewhere.
//!
//! Commitment layout (pushdata of the `OP_RETURN`):
//! ```text
//! magic[4] = b"BSYN"
//! version[1] = 0x01
//! round[8]   = u64 BE
//! root[32]   = Merkle root of signed reports for the round
//! ```
//! Total: 45 bytes (well under the 80-byte standard relay limit).

#![forbid(unsafe_code)]
#![warn(missing_docs)]

use bitcoin::absolute::LockTime;
use bitcoin::blockdata::script::{PushBytesBuf, ScriptBuf};
use bitcoin::hashes::Hash;
use bitcoin::transaction::{OutPoint, Sequence, TxIn, TxOut, Version};
use bitcoin::{Address, Amount, Network, Transaction, Txid};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;

/// Tag that identifies a BitSync commitment in an OP_RETURN.
pub const MAGIC: &[u8; 4] = b"BSYN";
/// Commitment format version.
pub const VERSION: u8 = 1;
/// Maximum OP_RETURN payload we emit.
pub const PAYLOAD_LEN: usize = 45;

/// Errors from the commitment builder.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum AnchorError {
    /// Payload would exceed Bitcoin relay policy.
    #[error("payload too large: {0} bytes")]
    PayloadTooLarge(usize),
    /// Invalid Merkle root length.
    #[error("merkle root must be 32 bytes")]
    BadRoot,
    /// Script / address error.
    #[error("script error: {0}")]
    Script(String),
}

/// A BitSync oracle-state commitment.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Commitment {
    /// Protocol version byte.
    pub version: u8,
    /// Oracle round number being anchored.
    pub round: u64,
    /// 32-byte Merkle root over the round's signed reports.
    pub merkle_root: [u8; 32],
}

impl Commitment {
    /// Construct a v1 commitment.
    pub fn new(round: u64, merkle_root: [u8; 32]) -> Self {
        Self {
            version: VERSION,
            round,
            merkle_root,
        }
    }

    /// Encode to the OP_RETURN payload bytes.
    pub fn encode(&self) -> [u8; PAYLOAD_LEN] {
        let mut out = [0u8; PAYLOAD_LEN];
        out[0..4].copy_from_slice(MAGIC);
        out[4] = self.version;
        out[5..13].copy_from_slice(&self.round.to_be_bytes());
        out[13..45].copy_from_slice(&self.merkle_root);
        out
    }

    /// Decode from payload bytes. Returns `None` if magic / length mismatch.
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        if bytes.len() != PAYLOAD_LEN || &bytes[0..4] != MAGIC {
            return None;
        }
        let version = bytes[4];
        if version != VERSION {
            return None;
        }
        let mut round_bytes = [0u8; 8];
        round_bytes.copy_from_slice(&bytes[5..13]);
        let mut root = [0u8; 32];
        root.copy_from_slice(&bytes[13..45]);
        Some(Self {
            version,
            round: u64::from_be_bytes(round_bytes),
            merkle_root: root,
        })
    }

    /// Build the `OP_RETURN <payload>` script.
    pub fn op_return_script(&self) -> Result<ScriptBuf, AnchorError> {
        let payload = self.encode();
        let push = PushBytesBuf::try_from(payload.to_vec())
            .map_err(|e| AnchorError::Script(e.to_string()))?;
        Ok(ScriptBuf::new_op_return(push))
    }
}

/// Compute a binary Merkle root over a list of 32-byte leaves.
/// Empty list → `[0; 32]`. Odd nodes are duplicated (Bitcoin-style).
pub fn merkle_root(leaves: &[[u8; 32]]) -> [u8; 32] {
    if leaves.is_empty() {
        return [0u8; 32];
    }
    let mut layer: Vec<[u8; 32]> = leaves.to_vec();
    while layer.len() > 1 {
        if layer.len() % 2 == 1 {
            if let Some(last) = layer.last().copied() {
                layer.push(last);
            }
        }
        let mut next = Vec::with_capacity(layer.len() / 2);
        for pair in layer.chunks(2) {
            let mut h = Sha256::new();
            h.update(pair[0]);
            h.update(pair[1]);
            let first: [u8; 32] = h.finalize().into();
            next.push(Sha256::digest(first).into());
        }
        layer = next;
    }
    layer[0]
}

/// Parameters for building an unsigned commitment transaction.
#[derive(Clone, Debug)]
pub struct AnchorTxParams {
    /// Outpoint to spend (must be funded by the caller).
    pub funding_outpoint: OutPoint,
    /// Value of the funding outpoint, in sats.
    pub funding_value: Amount,
    /// Fee to pay, in sats.
    pub fee: Amount,
    /// Change address.
    pub change_address: Address,
    /// The commitment to embed.
    pub commitment: Commitment,
}

/// Build an unsigned 1-in / 2-out transaction: OP_RETURN + change.
pub fn build_anchor_tx(params: &AnchorTxParams) -> Result<Transaction, AnchorError> {
    if params.fee > params.funding_value {
        return Err(AnchorError::Script("fee exceeds funding".into()));
    }
    let change = params
        .funding_value
        .checked_sub(params.fee)
        .ok_or_else(|| AnchorError::Script("underflow".into()))?;

    let op_return = TxOut {
        value: Amount::ZERO,
        script_pubkey: params.commitment.op_return_script()?,
    };
    let change_out = TxOut {
        value: change,
        script_pubkey: params.change_address.script_pubkey(),
    };

    let txid = params.funding_outpoint.txid;
    let _ = txid; // silence
    Ok(Transaction {
        version: Version::TWO,
        lock_time: LockTime::ZERO,
        input: vec![TxIn {
            previous_output: params.funding_outpoint,
            script_sig: ScriptBuf::new(),
            sequence: Sequence::ENABLE_RBF_NO_LOCKTIME,
            witness: bitcoin::Witness::new(),
        }],
        output: vec![op_return, change_out],
    })
}

/// Helper: parse a txid from hex.
pub fn txid_from_hex(s: &str) -> Result<Txid, AnchorError> {
    Txid::from_slice(&hex::decode(s).map_err(|e| AnchorError::Script(e.to_string()))?)
        .map_err(|e| AnchorError::Script(e.to_string()))
}

/// Network helper for tests / examples.
pub fn regtest_address_from_script(script: ScriptBuf) -> Result<Address, AnchorError> {
    Address::from_script(&script, Network::Regtest).map_err(|e| AnchorError::Script(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use bitcoin::hashes::Hash;
    use bitcoin::PubkeyHash;
    #[test]
    fn encode_decode_roundtrip() {
        let c = Commitment::new(7, [0xAB; 32]);
        let bytes = c.encode();
        assert_eq!(bytes.len(), PAYLOAD_LEN);
        assert_eq!(&bytes[0..4], MAGIC);
        assert_eq!(Commitment::decode(&bytes), Some(c));
        assert!(Commitment::decode(&bytes[..44]).is_none());
    }

    #[test]
    fn merkle_empty_and_single() {
        assert_eq!(merkle_root(&[]), [0u8; 32]);
        let leaf = [1u8; 32];
        assert_eq!(merkle_root(&[leaf]), leaf);
    }

    #[test]
    fn merkle_two_leaves_deterministic() {
        let a = [1u8; 32];
        let b = [2u8; 32];
        let r1 = merkle_root(&[a, b]);
        let r2 = merkle_root(&[a, b]);
        assert_eq!(r1, r2);
        assert_ne!(r1, merkle_root(&[b, a]));
    }

    #[test]
    fn builds_op_return_tx() {
        // Anyone-can-spend P2PKH dust script for change (test only).
        let h160 = PubkeyHash::from_slice(&[0u8; 20]).unwrap();
        let change = Address::p2pkh(h160, Network::Regtest);
        let params = AnchorTxParams {
            funding_outpoint: OutPoint {
                txid: Txid::from_byte_array([9u8; 32]),
                vout: 0,
            },
            funding_value: Amount::from_sat(50_000),
            fee: Amount::from_sat(1_000),
            change_address: change,
            commitment: Commitment::new(99, [0xCD; 32]),
        };
        let tx = build_anchor_tx(&params).unwrap();
        assert_eq!(tx.output.len(), 2);
        assert!(tx.output[0].script_pubkey.is_op_return());
        assert_eq!(tx.output[0].value, Amount::ZERO);
        assert_eq!(tx.output[1].value, Amount::from_sat(49_000));
        let payload = &tx.output[0].script_pubkey.as_bytes()[2..]; // OP_RETURN + pushlen
        assert_eq!(Commitment::decode(payload).unwrap().round, 99);
    }

    proptest::proptest! {
        #[test]
        fn encode_never_exceeds_45(round: u64, root: [u8; 32]) {
            let c = Commitment::new(round, root);
            assert_eq!(c.encode().len(), 45);
            assert_eq!(Commitment::decode(&c.encode()).unwrap(), c);
        }
    }
}
