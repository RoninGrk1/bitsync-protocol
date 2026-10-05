//! Hash helpers.

use sha2::{Digest as _, Sha256};
use sha3::Keccak256;

/// A 32-byte hash value.
pub type H256 = [u8; 32];

/// Keccak-256 (the Ethereum variant, *not* NIST SHA3-256).
pub fn keccak256(data: impl AsRef<[u8]>) -> H256 {
    let mut h = Keccak256::new();
    h.update(data.as_ref());
    h.finalize().into()
}

/// SHA-256.
pub fn sha256(data: impl AsRef<[u8]>) -> H256 {
    Sha256::digest(data.as_ref()).into()
}

/// Double SHA-256 as used throughout Bitcoin.
pub fn sha256d(data: impl AsRef<[u8]>) -> H256 {
    sha256(sha256(data))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keccak_empty_vector() {
        assert_eq!(
            hex::encode(keccak256([])),
            "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
        );
    }

    #[test]
    fn sha256_abc_vector() {
        assert_eq!(
            hex::encode(sha256(b"abc")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
