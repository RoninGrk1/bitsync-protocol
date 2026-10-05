//! # bitsync-sources
//!
//! Trait-based adapters for institutional market-data APIs. Every payload
//! consumed by a BitSync node is expected to carry a cryptographic signature
//! (Ed25519 or ECDSA) so that oracle operators can prove provenance.
//!
//! The [`mock`] module ships a fully offline signed fixture source so the
//! node can run without network access (CI, local nets).

#![forbid(unsafe_code)]
#![warn(missing_docs)]

use async_trait::async_trait;
use bitsync_crypto::hash::keccak256;
use bitsync_crypto::{Address, CryptoError};
use ed25519_dalek::{
    Signature as EdSig, Signer, SigningKey as EdSigningKey, Verifier,
    VerifyingKey as EdVerifyingKey,
};
use k256::ecdsa::signature::Signer as EcdsaSigner;
use k256::ecdsa::{Signature as KSig, SigningKey as KSigningKey, VerifyingKey as KVerifyingKey};
use serde::{Deserialize, Serialize};
use thiserror::Error;

pub mod mock;

/// Source errors.
#[derive(Debug, Error)]
pub enum SourceError {
    /// Transport / HTTP failure.
    #[error("transport: {0}")]
    Transport(String),
    /// Signature verification failed.
    #[error("bad signature: {0}")]
    BadSignature(String),
    /// Payload schema / parse error.
    #[error("invalid payload: {0}")]
    InvalidPayload(String),
    /// Crypto helper error.
    #[error(transparent)]
    Crypto(#[from] CryptoError),
}

/// A signed price observation from an upstream source.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignedTick {
    /// Feed label, e.g. `"BTC/USD"`.
    pub feed: String,
    /// Price in 8-decimal fixed point (matching BSY-style sats scale for USD).
    pub price: i128,
    /// Confidence / spread.
    pub confidence: u128,
    /// Unix timestamp of the observation.
    pub timestamp: u64,
    /// Source identifier.
    pub source_id: String,
    /// Signature scheme used.
    pub scheme: SigScheme,
    /// Hex-encoded signature bytes.
    pub signature: String,
    /// Hex-encoded verifying key / address material.
    pub public_key: String,
}

/// Supported signature schemes for source authenticity.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SigScheme {
    /// Ed25519 over the canonical payload bytes.
    Ed25519,
    /// secp256k1 ECDSA over `keccak256(payload)` (Ethereum-style).
    EcdsaKeccak,
}

impl SignedTick {
    /// Canonical bytes that are signed: `feed|price|confidence|timestamp|source_id`.
    pub fn payload_bytes(&self) -> Vec<u8> {
        format!(
            "{}|{}|{}|{}|{}",
            self.feed, self.price, self.confidence, self.timestamp, self.source_id
        )
        .into_bytes()
    }

    /// Verify the embedded signature.
    pub fn verify(&self) -> Result<(), SourceError> {
        let payload = self.payload_bytes();
        match self.scheme {
            SigScheme::Ed25519 => {
                let pk_bytes = hex::decode(self.public_key.trim_start_matches("0x"))
                    .map_err(|e| SourceError::InvalidPayload(e.to_string()))?;
                let pk: [u8; 32] = pk_bytes
                    .try_into()
                    .map_err(|_| SourceError::InvalidPayload("ed25519 pk len".into()))?;
                let vk = EdVerifyingKey::from_bytes(&pk)
                    .map_err(|e| SourceError::BadSignature(e.to_string()))?;
                let sig_bytes = hex::decode(self.signature.trim_start_matches("0x"))
                    .map_err(|e| SourceError::InvalidPayload(e.to_string()))?;
                let sig = EdSig::from_slice(&sig_bytes)
                    .map_err(|e| SourceError::BadSignature(e.to_string()))?;
                vk.verify(&payload, &sig)
                    .map_err(|e| SourceError::BadSignature(e.to_string()))
            }
            SigScheme::EcdsaKeccak => {
                let pk_bytes = hex::decode(self.public_key.trim_start_matches("0x"))
                    .map_err(|e| SourceError::InvalidPayload(e.to_string()))?;
                let vk = KVerifyingKey::from_sec1_bytes(&pk_bytes)
                    .map_err(|e| SourceError::BadSignature(e.to_string()))?;
                let sig_bytes = hex::decode(self.signature.trim_start_matches("0x"))
                    .map_err(|e| SourceError::InvalidPayload(e.to_string()))?;
                let sig = KSig::from_slice(&sig_bytes)
                    .map_err(|e| SourceError::BadSignature(e.to_string()))?;
                use k256::ecdsa::signature::Verifier;
                let digest = keccak256(&payload);
                vk.verify(&digest, &sig)
                    .map_err(|e| SourceError::BadSignature(e.to_string()))
            }
        }
    }
}

/// A market-data source.
#[async_trait]
pub trait PriceSource: Send + Sync {
    /// Stable identifier.
    fn id(&self) -> &str;
    /// Fetch a signed tick for `feed`.
    async fn fetch(&self, feed: &str) -> Result<SignedTick, SourceError>;
}

/// Helper: sign a tick with Ed25519 (used by the mock source and tests).
pub fn sign_ed25519(tick: &mut SignedTick, sk: &EdSigningKey) {
    let sig = Signer::sign(sk, &tick.payload_bytes());
    tick.scheme = SigScheme::Ed25519;
    tick.signature = hex::encode(sig.to_bytes());
    tick.public_key = hex::encode(sk.verifying_key().as_bytes());
}

/// Helper: sign a tick with ECDSA/keccak.
pub fn sign_ecdsa(tick: &mut SignedTick, sk: &KSigningKey) {
    let digest = keccak256(tick.payload_bytes());
    let sig: KSig = EcdsaSigner::sign(sk, &digest);
    tick.scheme = SigScheme::EcdsaKeccak;
    tick.signature = hex::encode(sig.to_bytes());
    tick.public_key = hex::encode(sk.verifying_key().to_encoded_point(true).as_bytes());
}

/// Derive an Ethereum address for diagnostics (ECDSA sources).
pub fn ecdsa_address(sk: &KSigningKey) -> Address {
    Address::from_verifying_key(sk.verifying_key())
}

pub use mock::MockSignedSource;
