//! # bitsync-crypto
//!
//! Cryptographic building blocks shared by BitSync oracle nodes, SDKs and
//! tooling.
//!
//! * [`report`] – the canonical oracle [`Report`](report::Report) and its
//!   EIP-712 digest. The digest is byte-for-byte identical to the one computed
//!   by `OracleAggregator.reportDigest` on-chain and by the TypeScript SDK.
//! * [`ecdsa`] – Ethereum-style recoverable secp256k1 signatures (65 bytes,
//!   low-S normalised, `v ∈ {27, 28}`) and address derivation.
//! * [`signer`] – the [`Signer`](signer::Signer) / [`KeyProvider`](signer::KeyProvider)
//!   abstraction with an in-process software implementation and a PKCS#11
//!   (HSM) interface behind the `pkcs11` feature.
//! * [`threshold`] – FROST(secp256k1, Taproot) threshold Schnorr signatures
//!   used to co-sign Bitcoin anchor commitments with a `t-of-n` operator key.
//!
//! This crate is **unaudited**. See `docs/SECURITY.md`.

#![forbid(unsafe_code)]
#![warn(missing_docs)]

pub mod bsy;
pub mod ecdsa;
pub mod error;
pub mod hash;
pub mod observation;
pub mod report;
pub mod signer;
pub mod threshold;

pub use bsy::{
    Amount, BSY_DECIMALS, BSY_NAME, BSY_SCALE, BSY_SYMBOL, MAX_SUPPLY_BASE, MAX_SUPPLY_WHOLE,
};
pub use ecdsa::{Address, EthSignature};
pub use error::CryptoError;
pub use observation::Observation;
pub use report::{Domain, Report};
pub use signer::{KeyProvider, Signer, SoftwareKeyProvider, SoftwareSigner};
