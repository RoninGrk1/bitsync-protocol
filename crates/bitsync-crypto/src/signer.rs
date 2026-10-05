//! Key-provider / signer abstraction.
//!
//! Production nodes should load operator keys from an HSM (PKCS#11). The
//! `pkcs11` feature exposes an interface stub; the software backend is for
//! local development and tests only.

use crate::{
    ecdsa::{Address, EthSignature},
    error::CryptoError,
};
use async_trait::async_trait;
use k256::ecdsa::SigningKey;
use parking_lot::RwLock;
use std::collections::HashMap;
use zeroize::{Zeroize, ZeroizeOnDrop};

/// Identifies a key managed by a [`KeyProvider`].
pub type KeyId = String;

/// Capability to produce Ethereum-compatible ECDSA signatures over a 32-byte
/// digest.
#[async_trait]
pub trait Signer: Send + Sync {
    /// Sign `digest` and return a 65-byte recoverable signature.
    async fn sign_digest(&self, digest: &[u8; 32]) -> Result<EthSignature, CryptoError>;
    /// Ethereum address corresponding to this signer.
    fn address(&self) -> Address;
}

/// A store of named signing keys.
#[async_trait]
pub trait KeyProvider: Send + Sync {
    /// Resolve a named key to a [`Signer`].
    async fn get(&self, id: &str) -> Result<Box<dyn Signer>, CryptoError>;
    /// List known key identifiers.
    async fn list(&self) -> Result<Vec<KeyId>, CryptoError>;
}

/// In-memory software key (ZEROIZE on drop). **Not for production.**
#[derive(Zeroize, ZeroizeOnDrop)]
pub struct SoftwareSigner {
    #[zeroize(skip)]
    address: Address,
    secret: [u8; 32],
}

impl SoftwareSigner {
    /// Construct from a 32-byte secp256k1 secret.
    pub fn from_secret(secret: [u8; 32]) -> Result<Self, CryptoError> {
        let key = SigningKey::from_slice(&secret).map_err(|_| CryptoError::InvalidSecretKey)?;
        let address = Address::from_verifying_key(key.verifying_key());
        Ok(Self { address, secret })
    }

    /// Generate a fresh random key.
    pub fn random() -> Self {
        use rand::rngs::OsRng;
        let key = SigningKey::random(&mut OsRng);
        let mut secret = [0u8; 32];
        secret.copy_from_slice(&key.to_bytes());
        let address = Address::from_verifying_key(key.verifying_key());
        Self { address, secret }
    }
}

#[async_trait]
impl Signer for SoftwareSigner {
    async fn sign_digest(&self, digest: &[u8; 32]) -> Result<EthSignature, CryptoError> {
        let key =
            SigningKey::from_slice(&self.secret).map_err(|_| CryptoError::InvalidSecretKey)?;
        EthSignature::sign_prehash(&key, digest)
    }

    fn address(&self) -> Address {
        self.address
    }
}

/// In-process key provider. Suitable for tests and local nets only.
pub struct SoftwareKeyProvider {
    keys: RwLock<HashMap<KeyId, [u8; 32]>>,
}

impl SoftwareKeyProvider {
    /// Empty provider.
    pub fn new() -> Self {
        Self {
            keys: RwLock::new(HashMap::new()),
        }
    }

    /// Insert / replace a named key. Returns its address.
    pub fn insert(&self, id: impl Into<KeyId>, secret: [u8; 32]) -> Result<Address, CryptoError> {
        let signer = SoftwareSigner::from_secret(secret)?;
        let addr = signer.address();
        self.keys.write().insert(id.into(), secret);
        Ok(addr)
    }

    /// Generate and insert a fresh key.
    pub fn generate(&self, id: impl Into<KeyId>) -> Address {
        let s = SoftwareSigner::random();
        let addr = s.address;
        self.keys.write().insert(id.into(), s.secret);
        addr
    }
}

impl Default for SoftwareKeyProvider {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl KeyProvider for SoftwareKeyProvider {
    async fn get(&self, id: &str) -> Result<Box<dyn Signer>, CryptoError> {
        let secret = self
            .keys
            .read()
            .get(id)
            .copied()
            .ok_or_else(|| CryptoError::UnknownKey(id.into()))?;
        Ok(Box::new(SoftwareSigner::from_secret(secret)?))
    }

    async fn list(&self) -> Result<Vec<KeyId>, CryptoError> {
        Ok(self.keys.read().keys().cloned().collect())
    }
}

/// PKCS#11 / HSM signer interface.
///
/// Enabled with `--features pkcs11`. The current build ships an interface
/// stub only — see `docs/SECURITY.md` for the production integration plan.
#[cfg(feature = "pkcs11")]
pub mod pkcs11 {
    use super::*;

    /// Configuration for a PKCS#11 token.
    #[derive(Clone, Debug)]
    pub struct Pkcs11Config {
        /// Path to the PKCS#11 shared library (e.g. `/usr/lib/softhsm/libsofthsm2.so`).
        pub library_path: String,
        /// Token slot index.
        pub slot: u64,
        /// Key label inside the token.
        pub key_label: String,
        /// Optional PIN (prefer prompting / env injection at runtime).
        pub pin: Option<String>,
    }

    /// HSM-backed signer. **Stub** — returns [`CryptoError::Unsupported`] until
    /// a PKCS#11 backend is wired in a follow-up release.
    pub struct Pkcs11Signer {
        cfg: Pkcs11Config,
        address: Address,
    }

    impl Pkcs11Signer {
        /// Construct a stub signer. Does not open the HSM.
        pub fn new(cfg: Pkcs11Config, address: Address) -> Self {
            Self { cfg, address }
        }

        /// Access the underlying config (for diagnostics).
        pub fn config(&self) -> &Pkcs11Config {
            &self.cfg
        }
    }

    #[async_trait]
    impl Signer for Pkcs11Signer {
        async fn sign_digest(&self, _digest: &[u8; 32]) -> Result<EthSignature, CryptoError> {
            Err(CryptoError::Unsupported(
                "PKCS#11 backend not yet implemented; see docs/SECURITY.md",
            ))
        }

        fn address(&self) -> Address {
            self.address
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hash::keccak256;

    #[tokio::test]
    async fn software_provider_signs() {
        let provider = SoftwareKeyProvider::new();
        let addr = provider.generate("op-0");
        let signer = provider.get("op-0").await.unwrap();
        assert_eq!(signer.address(), addr);
        let dig = keccak256(b"hello");
        let sig = signer.sign_digest(&dig).await.unwrap();
        assert_eq!(sig.recover(&dig).unwrap(), addr);
    }
}
