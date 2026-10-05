//! Ethereum-compatible recoverable ECDSA over secp256k1.

use crate::{error::CryptoError, hash::keccak256};
use k256::ecdsa::{RecoveryId, Signature, SigningKey, VerifyingKey};
use serde::{Deserialize, Serialize};
use std::{fmt, str::FromStr};

/// A 20-byte Ethereum-style address.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default, Serialize, Deserialize)]
#[serde(into = "String", try_from = "String")]
pub struct Address(pub [u8; 20]);

impl Address {
    /// Derive an address from a verifying key: `keccak256(uncompressed[1..])[12..]`.
    pub fn from_verifying_key(vk: &VerifyingKey) -> Self {
        let point = vk.to_encoded_point(false);
        let hash = keccak256(&point.as_bytes()[1..]);
        let mut out = [0u8; 20];
        out.copy_from_slice(&hash[12..]);
        Address(out)
    }

    /// Raw bytes.
    pub fn as_bytes(&self) -> &[u8; 20] {
        &self.0
    }

    /// Left-pad to a 32-byte ABI word.
    pub fn to_word(&self) -> [u8; 32] {
        let mut w = [0u8; 32];
        w[12..].copy_from_slice(&self.0);
        w
    }
}

impl fmt::Display for Address {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "0x{}", hex::encode(self.0))
    }
}

impl fmt::Debug for Address {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, f)
    }
}

impl FromStr for Address {
    type Err = CryptoError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let raw = hex::decode(s.trim_start_matches("0x"))?;
        let arr: [u8; 20] = raw
            .try_into()
            .map_err(|_| CryptoError::Hex("address must be 20 bytes".into()))?;
        Ok(Address(arr))
    }
}

impl From<Address> for String {
    fn from(a: Address) -> Self {
        a.to_string()
    }
}

impl TryFrom<String> for Address {
    type Error = CryptoError;
    fn try_from(s: String) -> Result<Self, Self::Error> {
        s.parse()
    }
}

/// A 65-byte `r || s || v` signature with `v ∈ {27, 28}` and low-S, as
/// accepted by OpenZeppelin's `ECDSA.recover`.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct EthSignature(pub [u8; 65]);

impl EthSignature {
    /// Sign a 32-byte prehash with a secp256k1 key. Output is always low-S.
    pub fn sign_prehash(key: &SigningKey, digest: &[u8; 32]) -> Result<Self, CryptoError> {
        let (sig, recid) = key
            .sign_prehash_recoverable(digest)
            .map_err(|e| CryptoError::SigningFailed(e.to_string()))?;
        // k256 already normalises to low-S, but enforce defensively.
        let (sig, recid) = match sig.normalize_s() {
            Some(n) => (n, RecoveryId::new(!recid.is_y_odd(), recid.is_x_reduced())),
            None => (sig, recid),
        };
        let mut out = [0u8; 65];
        out[..64].copy_from_slice(&sig.to_bytes());
        out[64] = 27 + recid.to_byte();
        Ok(EthSignature(out))
    }

    /// Recover the signer address. Rejects high-S and invalid `v`, mirroring
    /// OpenZeppelin `ECDSA.tryRecover` semantics.
    pub fn recover(&self, digest: &[u8; 32]) -> Result<Address, CryptoError> {
        let v = self.0[64];
        let recid = match v {
            27 | 28 => RecoveryId::from_byte(v - 27).ok_or(CryptoError::MalformedSignature("v"))?,
            _ => return Err(CryptoError::MalformedSignature("v must be 27 or 28")),
        };
        let sig = Signature::from_slice(&self.0[..64])
            .map_err(|_| CryptoError::MalformedSignature("r/s out of range"))?;
        if sig.normalize_s().is_some() {
            return Err(CryptoError::MalformedSignature("high-S signature"));
        }
        let vk = VerifyingKey::recover_from_prehash(digest, &sig, recid)
            .map_err(|_| CryptoError::RecoveryFailed)?;
        Ok(Address::from_verifying_key(&vk))
    }

    /// Hex encoding with `0x` prefix.
    pub fn to_hex(&self) -> String {
        format!("0x{}", hex::encode(self.0))
    }

    /// Parse from (optionally `0x`-prefixed) hex.
    pub fn from_hex(s: &str) -> Result<Self, CryptoError> {
        let raw = hex::decode(s.trim_start_matches("0x"))?;
        let arr: [u8; 65] = raw
            .try_into()
            .map_err(|_| CryptoError::MalformedSignature("length must be 65"))?;
        Ok(EthSignature(arr))
    }
}

impl fmt::Debug for EthSignature {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "EthSignature({})", self.to_hex())
    }
}

impl Serialize for EthSignature {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.to_hex())
    }
}

impl<'de> Deserialize<'de> for EthSignature {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        EthSignature::from_hex(&s).map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::rngs::OsRng;

    #[test]
    fn known_address_for_secret_one() {
        // Private key 0x…01 is the well-known secp256k1 generator; its address
        // is a public test vector, not a secret.
        let mut sk = [0u8; 32];
        sk[31] = 1;
        let key = SigningKey::from_slice(&sk).unwrap();
        let addr = Address::from_verifying_key(key.verifying_key());
        assert_eq!(
            addr.to_string(),
            "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf"
        );
    }

    #[test]
    fn sign_and_recover_roundtrip() {
        let key = SigningKey::random(&mut OsRng);
        let addr = Address::from_verifying_key(key.verifying_key());
        let digest = keccak256(b"bitsync");
        let sig = EthSignature::sign_prehash(&key, &digest).unwrap();
        assert!(sig.0[64] == 27 || sig.0[64] == 28);
        assert_eq!(sig.recover(&digest).unwrap(), addr);
        assert_ne!(sig.recover(&keccak256(b"other")).unwrap(), addr);
    }

    #[test]
    fn rejects_bad_v_and_high_s() {
        let key = SigningKey::random(&mut OsRng);
        let digest = keccak256(b"x");
        let mut sig = EthSignature::sign_prehash(&key, &digest).unwrap();
        let mut bad_v = sig;
        bad_v.0[64] = 29;
        assert!(bad_v.recover(&digest).is_err());

        // Flip s to n - s (high-S) and ensure rejection.
        let parsed = Signature::from_slice(&sig.0[..64]).unwrap();
        let (r, s) = parsed.split_scalars();
        let high = Signature::from_scalars(r.to_bytes(), (-*s).to_bytes()).unwrap();
        sig.0[..64].copy_from_slice(&high.to_bytes());
        assert_eq!(
            sig.recover(&digest),
            Err(CryptoError::MalformedSignature("high-S signature"))
        );
    }

    #[test]
    fn serde_roundtrip() {
        let key = SigningKey::random(&mut OsRng);
        let sig = EthSignature::sign_prehash(&key, &keccak256(b"y")).unwrap();
        let json = serde_json_like(&sig);
        assert!(json.starts_with("0x"));
        assert_eq!(EthSignature::from_hex(&json).unwrap(), sig);
        let addr = Address::from_verifying_key(key.verifying_key());
        assert_eq!(addr.to_string().parse::<Address>().unwrap(), addr);
    }

    fn serde_json_like(sig: &EthSignature) -> String {
        sig.to_hex()
    }
}
