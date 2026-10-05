//! Canonical oracle report and EIP-712 digest.
//!
//! The digest is wired to match the Solidity implementation in
//! `OracleAggregator.reportDigest` (EIP-712 typed data with the BitSync domain).

use crate::{error::CryptoError, hash::keccak256, Address};
use serde::{Deserialize, Serialize};

/// EIP-712 domain parameters. Must match on-chain `EIP712("BitSync Oracle", "1")`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Domain {
    /// EIP-712 name.
    pub name: String,
    /// EIP-712 version.
    pub version: String,
    /// Chain id.
    pub chain_id: u64,
    /// Verifying contract address.
    pub verifying_contract: Address,
}

impl Domain {
    /// Construct the BitSync Oracle domain used by production contracts.
    pub fn bitsync_oracle(chain_id: u64, verifying_contract: Address) -> Self {
        Self {
            name: "BitSync Oracle".into(),
            version: "1".into(),
            chain_id,
            verifying_contract,
        }
    }

    /// EIP-712 domain separator.
    pub fn separator(&self) -> [u8; 32] {
        // keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
        let type_hash = keccak256(
            b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
        );
        let mut enc = Vec::with_capacity(32 * 5);
        enc.extend_from_slice(&type_hash);
        enc.extend_from_slice(&keccak256(self.name.as_bytes()));
        enc.extend_from_slice(&keccak256(self.version.as_bytes()));
        enc.extend_from_slice(&u256_be(self.chain_id as u128));
        enc.extend_from_slice(&self.verifying_contract.to_word());
        keccak256(enc)
    }
}

/// A signed price report submitted by an operator (or by the quorum aggregator).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Report {
    /// Feed identifier (bytes32 on-chain).
    pub feed_id: [u8; 32],
    /// Price in the feed's native decimal scale (e.g. 8 for BTC/USD).
    pub price: i128,
    /// Confidence interval (±) in the same scale.
    pub confidence: u128,
    /// Observation timestamp (unix seconds).
    pub timestamp: u64,
    /// Round / epoch number.
    pub round: u64,
}

impl Report {
    /// EIP-712 type hash for `Report(...)`.
    pub fn type_hash() -> [u8; 32] {
        keccak256(
            b"Report(bytes32 feedId,int256 price,uint256 confidence,uint64 timestamp,uint64 round)",
        )
    }

    /// Struct hash of this report.
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

    /// Full EIP-712 digest `\x19\x01 || domainSeparator || structHash`.
    pub fn digest(&self, domain: &Domain) -> [u8; 32] {
        let mut buf = [0u8; 66];
        buf[0] = 0x19;
        buf[1] = 0x01;
        buf[2..34].copy_from_slice(&domain.separator());
        buf[34..66].copy_from_slice(&self.struct_hash());
        keccak256(buf)
    }

    /// Encode as a compact ABI tuple matching the Solidity `Report` struct.
    pub fn abi_encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(32 * 5);
        out.extend_from_slice(&self.feed_id);
        out.extend_from_slice(&i256_be(self.price));
        out.extend_from_slice(&u256_be(self.confidence));
        out.extend_from_slice(&u256_be(self.timestamp as u128));
        out.extend_from_slice(&u256_be(self.round as u128));
        out
    }

    /// Parse a 32-byte feed id from a UTF-8 label (right-padded with zeros).
    pub fn feed_id_from_label(label: &str) -> Result<[u8; 32], CryptoError> {
        let b = label.as_bytes();
        if b.len() > 32 {
            return Err(CryptoError::Hex("feed label longer than 32 bytes".into()));
        }
        let mut id = [0u8; 32];
        id[..b.len()].copy_from_slice(b);
        Ok(id)
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
        // Two's complement sign-extend across 256 bits.
        out.fill(0xff);
        out[16..].copy_from_slice(&(v as u128).to_be_bytes());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ecdsa::{Address, EthSignature};
    use k256::ecdsa::SigningKey;
    use rand::rngs::OsRng;

    #[test]
    fn digest_is_deterministic_and_recoverable() {
        let domain = Domain::bitsync_oracle(
            1,
            "0x1111111111111111111111111111111111111111"
                .parse()
                .unwrap(),
        );
        let report = Report {
            feed_id: Report::feed_id_from_label("BTC/USD").unwrap(),
            price: 6_425_000_000_000, // $64,250.00 with 8 decimals
            confidence: 1_000_000_000,
            timestamp: 1_700_000_000,
            round: 42,
        };
        let d1 = report.digest(&domain);
        let d2 = report.digest(&domain);
        assert_eq!(d1, d2);

        let key = SigningKey::random(&mut OsRng);
        let addr = Address::from_verifying_key(key.verifying_key());
        let sig = EthSignature::sign_prehash(&key, &d1).unwrap();
        assert_eq!(sig.recover(&d1).unwrap(), addr);
    }
}
