//! FROST(secp256k1, Taproot) threshold signatures for Bitcoin anchor co-signing.
//!
//! Operators hold FROST key shares. A `t-of-n` quorum produces a single Schnorr
//! signature that verifies against the group's Taproot-tweaked public key —
//! the key that appears in Bitcoin OP_RETURN commitments / Taproot spends.
//!
//! On-chain EVM report verification currently uses an ECDSA quorum (see
//! `OracleAggregator`). The documented upgrade path to BLS / FROST-verified
//! reports is described in `docs/ARCHITECTURE.md`.

use crate::error::CryptoError;
use frost_secp256k1_tr as frost;
use frost_secp256k1_tr::keys::{KeyPackage, PublicKeyPackage};
use frost_secp256k1_tr::round1::{SigningCommitments, SigningNonces};
use frost_secp256k1_tr::round2::SignatureShare;
use frost_secp256k1_tr::{Identifier, Signature};
use rand::rngs::OsRng;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// A distributed key-generation ceremony result.
#[derive(Clone)]
pub struct ThresholdKeygen {
    /// Per-participant key packages (secret shares). Persist securely / in HSM.
    pub key_packages: BTreeMap<Identifier, KeyPackage>,
    /// Public key package shared with all participants and verifiers.
    pub pubkey_package: PublicKeyPackage,
    /// Threshold `t`.
    pub min_signers: u16,
    /// Total participants `n`.
    pub max_signers: u16,
}

impl ThresholdKeygen {
    /// Trusted dealer keygen (suitable for tests and bootstrap). Production
    /// deployments should use DKG (`frost::keys::dkg`).
    pub fn dealer(max_signers: u16, min_signers: u16) -> Result<Self, CryptoError> {
        if min_signers == 0 || min_signers > max_signers {
            return Err(CryptoError::Threshold(
                "invalid threshold parameters".into(),
            ));
        }
        let (shares, pubkey_package) = frost::keys::generate_with_dealer(
            max_signers,
            min_signers,
            frost::keys::IdentifierList::Default,
            OsRng,
        )
        .map_err(|e| CryptoError::Threshold(e.to_string()))?;
        let mut key_packages = BTreeMap::new();
        for (id, secret_share) in shares {
            let kp = KeyPackage::try_from(secret_share)
                .map_err(|e| CryptoError::Threshold(e.to_string()))?;
            key_packages.insert(id, kp);
        }
        Ok(Self {
            key_packages,
            pubkey_package,
            min_signers,
            max_signers,
        })
    }

    /// Group verifying key bytes (compressed).
    pub fn group_verifying_key(&self) -> Vec<u8> {
        self.pubkey_package
            .verifying_key()
            .serialize()
            .expect("serialize")
    }
}

/// Serializable commitment produced in FROST round 1.
#[derive(Clone, Serialize, Deserialize)]
pub struct Round1Output {
    /// Participant identifier (big-endian u16 encoded as hex for JSON).
    pub identifier: String,
    /// Serialized signing commitments.
    pub commitments: Vec<u8>,
}

/// Drive a FROST signing session for `message` with a subset of participants.
pub fn sign(
    keygen: &ThresholdKeygen,
    participant_ids: &[Identifier],
    message: &[u8],
) -> Result<Signature, CryptoError> {
    if participant_ids.len() < keygen.min_signers as usize {
        return Err(CryptoError::Threshold("not enough signers".into()));
    }

    // Round 1: each participant produces nonces + commitments.
    let mut nonces_map: BTreeMap<Identifier, SigningNonces> = BTreeMap::new();
    let mut commitments_map: BTreeMap<Identifier, SigningCommitments> = BTreeMap::new();
    for id in participant_ids {
        let kp = keygen
            .key_packages
            .get(id)
            .ok_or_else(|| CryptoError::Threshold(format!("unknown id {id:?}")))?;
        let (nonces, commitments) = frost::round1::commit(kp.signing_share(), &mut OsRng);
        nonces_map.insert(*id, nonces);
        commitments_map.insert(*id, commitments);
    }

    let signing_package = frost::SigningPackage::new(commitments_map, message);

    // Round 2: signature shares.
    let mut signature_shares: BTreeMap<Identifier, SignatureShare> = BTreeMap::new();
    for id in participant_ids {
        let kp = &keygen.key_packages[id];
        let share = frost::round2::sign(&signing_package, &nonces_map[id], kp)
            .map_err(|e| CryptoError::Threshold(e.to_string()))?;
        signature_shares.insert(*id, share);
    }

    frost::aggregate(&signing_package, &signature_shares, &keygen.pubkey_package)
        .map_err(|e| CryptoError::Threshold(e.to_string()))
}

/// Verify a FROST signature against the group public key.
pub fn verify(
    pubkey_package: &PublicKeyPackage,
    message: &[u8],
    signature: &Signature,
) -> Result<(), CryptoError> {
    pubkey_package
        .verifying_key()
        .verify(message, signature)
        .map_err(|e| CryptoError::Threshold(e.to_string()))
}

/// Convenience: identifier from a 1-indexed participant number.
pub fn id_from_u16(n: u16) -> Result<Identifier, CryptoError> {
    Identifier::try_from(n).map_err(|e| CryptoError::Threshold(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frost_2_of_3_signs_and_verifies() {
        let kg = ThresholdKeygen::dealer(3, 2).unwrap();
        let ids = vec![id_from_u16(1).unwrap(), id_from_u16(3).unwrap()];
        let msg = b"bitsync bitcoin anchor commitment";
        let sig = sign(&kg, &ids, msg).unwrap();
        verify(&kg.pubkey_package, msg, &sig).unwrap();
        assert!(verify(&kg.pubkey_package, b"tampered", &sig).is_err());
    }

    #[test]
    fn rejects_below_threshold() {
        let kg = ThresholdKeygen::dealer(3, 2).unwrap();
        let ids = vec![id_from_u16(1).unwrap()];
        assert!(sign(&kg, &ids, b"x").is_err());
    }
}
