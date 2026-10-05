//! # bitsync-sdk
//!
//! Typed client helpers for reading BitSync feeds, verifying operator /
//! quorum report signatures, and working with BSY amounts (8 decimals,
//! 42,000,000 fixed supply).

#![forbid(unsafe_code)]
#![warn(missing_docs)]

use bitsync_crypto::{Address, CryptoError, Domain, EthSignature, Report};
use serde::{Deserialize, Serialize};
use thiserror::Error;

pub use bitsync_crypto::{
    Amount as BsyAmount, Amount, BSY_DECIMALS, BSY_NAME, BSY_SCALE, BSY_SYMBOL, MAX_SUPPLY_BASE,
    MAX_SUPPLY_WHOLE,
};

/// SDK errors.
#[derive(Debug, Error)]
pub enum SdkError {
    /// Cryptographic failure.
    #[error(transparent)]
    Crypto(#[from] CryptoError),
    /// HTTP / transport.
    #[error("transport: {0}")]
    Transport(String),
    /// Quorum / verification failure.
    #[error("verification: {0}")]
    Verification(String),
}

/// A report together with operator signatures.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SignedReport {
    /// Canonical report.
    pub report: Report,
    /// Parallel arrays: operator address ↔ signature over `report.digest(domain)`.
    pub operators: Vec<Address>,
    /// Signatures (65-byte hex).
    pub signatures: Vec<EthSignature>,
}

impl SignedReport {
    /// Verify every signature recovers to the claimed operator, and that at
    /// least `quorum` distinct operators signed.
    pub fn verify(&self, domain: &Domain, quorum: usize) -> Result<(), SdkError> {
        if self.operators.len() != self.signatures.len() {
            return Err(SdkError::Verification(
                "operators/signatures length mismatch".into(),
            ));
        }
        let digest = self.report.digest(domain);
        let mut seen = Vec::new();
        for (op, sig) in self.operators.iter().zip(self.signatures.iter()) {
            let recovered = sig.recover(&digest)?;
            if &recovered != op {
                return Err(SdkError::Verification(format!(
                    "signature recovers to {recovered}, expected {op}"
                )));
            }
            if seen.contains(op) {
                return Err(SdkError::Verification(format!("duplicate operator {op}")));
            }
            seen.push(*op);
        }
        if seen.len() < quorum {
            return Err(SdkError::Verification(format!(
                "quorum not met: {} < {quorum}",
                seen.len()
            )));
        }
        Ok(())
    }
}

/// Lightweight HTTP client against a BitSync gateway / node API.
pub struct FeedClient {
    /// Base URL, e.g. `http://127.0.0.1:8080`.
    pub base_url: String,
    client: reqwest::Client,
}

impl FeedClient {
    /// Construct.
    pub fn new(base_url: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into(),
            client: reqwest::Client::new(),
        }
    }

    /// `GET {base}/feeds/{feed}` → [`SignedReport`].
    pub async fn get_feed(&self, feed: &str) -> Result<SignedReport, SdkError> {
        let url = format!("{}/feeds/{}", self.base_url.trim_end_matches('/'), feed);
        let resp = self
            .client
            .get(&url)
            .send()
            .await
            .map_err(|e| SdkError::Transport(e.to_string()))?;
        if !resp.status().is_success() {
            return Err(SdkError::Transport(format!("status {}", resp.status())));
        }
        resp.json()
            .await
            .map_err(|e| SdkError::Transport(e.to_string()))
    }
}

/// Re-export BSY helpers as a module for ergonomics.
pub mod bsy {
    pub use bitsync_crypto::{
        Amount, BSY_DECIMALS, BSY_NAME, BSY_SCALE, BSY_SYMBOL, MAX_SUPPLY_BASE, MAX_SUPPLY_WHOLE,
    };
}

#[cfg(test)]
mod tests {
    use super::*;
    use bitsync_crypto::ecdsa::EthSignature;
    use bitsync_crypto::Address;
    use k256::ecdsa::SigningKey;
    use rand::rngs::OsRng;

    #[tokio::test]
    async fn verify_quorum_report() {
        let domain = Domain::bitsync_oracle(1, Address([0x11; 20]));
        let report = Report {
            feed_id: Report::feed_id_from_label("BTC/USD").unwrap(),
            price: 6_400_000_000_000,
            confidence: 1_000_000_000,
            timestamp: 1_700_000_000,
            round: 1,
        };
        let digest = report.digest(&domain);
        let mut operators = Vec::new();
        let mut signatures = Vec::new();
        for _ in 0..3 {
            let sk = SigningKey::random(&mut OsRng);
            let addr = Address::from_verifying_key(sk.verifying_key());
            let sig = EthSignature::sign_prehash(&sk, &digest).unwrap();
            operators.push(addr);
            signatures.push(sig);
        }
        let signed = SignedReport {
            report,
            operators,
            signatures,
        };
        signed.verify(&domain, 3).unwrap();
        assert!(signed.verify(&domain, 4).is_err());
    }

    #[test]
    fn bsy_constants_match_spec() {
        assert_eq!(BSY_DECIMALS, 8);
        assert_eq!(BSY_SYMBOL, "BSY");
        assert_eq!(BSY_NAME, "BitSync");
        assert_eq!(MAX_SUPPLY_WHOLE, 42_000_000);
        assert_eq!(MAX_SUPPLY_BASE, 42_000_000 * BSY_SCALE);
        assert_eq!(Amount::parse("42000000 BSY").unwrap(), Amount::MAX_SUPPLY);
    }
}
