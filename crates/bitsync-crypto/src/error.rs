//! Error types.

use thiserror::Error;

/// Errors produced by cryptographic operations.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum CryptoError {
    /// A signature was malformed (wrong length, invalid `v`, high-S, …).
    #[error("malformed signature: {0}")]
    MalformedSignature(&'static str),
    /// Public-key recovery failed.
    #[error("signature recovery failed")]
    RecoveryFailed,
    /// A secret key was invalid (zero or ≥ curve order).
    #[error("invalid secret key")]
    InvalidSecretKey,
    /// The requested key is unknown to the key provider.
    #[error("unknown key: {0}")]
    UnknownKey(String),
    /// Signing failed inside a backend.
    #[error("signing failed: {0}")]
    SigningFailed(String),
    /// Feature is not available in this build / backend.
    #[error("unsupported: {0}")]
    Unsupported(&'static str),
    /// Threshold (FROST) protocol error.
    #[error("threshold protocol error: {0}")]
    Threshold(String),
    /// Hex decoding error.
    #[error("invalid hex: {0}")]
    Hex(String),
    /// Invalid BSY amount.
    #[error("invalid amount: {0}")]
    InvalidAmount(String),
}

impl From<hex::FromHexError> for CryptoError {
    fn from(e: hex::FromHexError) -> Self {
        CryptoError::Hex(e.to_string())
    }
}
