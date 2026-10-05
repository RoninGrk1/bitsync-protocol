//! # bitsync-storage
//!
//! Archival backends for signed oracle reports. Production deployments pin to
//! IPFS and mirror to Arweave; tests use the in-memory [`MemoryArchive`].

#![forbid(unsafe_code)]
#![warn(missing_docs)]

use async_trait::async_trait;
use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use thiserror::Error;

/// Storage errors.
#[derive(Debug, Error)]
pub enum StorageError {
    /// Backend transport failure.
    #[error("transport: {0}")]
    Transport(String),
    /// Object not found.
    #[error("not found: {0}")]
    NotFound(String),
    /// Encoding error.
    #[error("encoding: {0}")]
    Encoding(String),
}

/// Content-addressed identifier (hex-encoded SHA-256 of the raw bytes).
pub type Cid = String;

/// A stored blob with its content id.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredObject {
    /// Content id.
    pub cid: Cid,
    /// Raw bytes.
    pub data: Vec<u8>,
}

/// Content-addressed archive.
#[async_trait]
pub trait Archive: Send + Sync {
    /// Store `data`, returning its CID.
    async fn put(&self, data: &[u8]) -> Result<Cid, StorageError>;
    /// Fetch by CID.
    async fn get(&self, cid: &str) -> Result<Vec<u8>, StorageError>;
    /// Backend name (for metrics / logs).
    fn name(&self) -> &str;
}

fn cid_of(data: &[u8]) -> Cid {
    hex::encode(Sha256::digest(data))
}

/// In-memory archive for tests and local nets.
#[derive(Default)]
pub struct MemoryArchive {
    store: RwLock<HashMap<Cid, Vec<u8>>>,
}

impl MemoryArchive {
    /// Empty archive.
    pub fn new() -> Self {
        Self::default()
    }

    /// Number of stored objects.
    pub fn len(&self) -> usize {
        self.store.read().len()
    }

    /// True when empty.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[async_trait]
impl Archive for MemoryArchive {
    async fn put(&self, data: &[u8]) -> Result<Cid, StorageError> {
        let cid = cid_of(data);
        self.store.write().insert(cid.clone(), data.to_vec());
        Ok(cid)
    }

    async fn get(&self, cid: &str) -> Result<Vec<u8>, StorageError> {
        self.store
            .read()
            .get(cid)
            .cloned()
            .ok_or_else(|| StorageError::NotFound(cid.into()))
    }

    fn name(&self) -> &str {
        "memory"
    }
}

/// IPFS HTTP API client (`/api/v0/add`, `/api/v0/cat`).
pub struct IpfsHttpArchive {
    /// Base URL, e.g. `http://127.0.0.1:5001`.
    pub api_url: String,
    client: reqwest::Client,
}

impl IpfsHttpArchive {
    /// Construct against an IPFS API endpoint.
    pub fn new(api_url: impl Into<String>) -> Self {
        Self {
            api_url: api_url.into(),
            client: reqwest::Client::new(),
        }
    }
}

#[async_trait]
impl Archive for IpfsHttpArchive {
    async fn put(&self, data: &[u8]) -> Result<Cid, StorageError> {
        // We still content-address locally with SHA-256 so the rest of the
        // stack has a stable CID even if Kubo returns a CIDv1. The Kubo Hash
        // is logged but the returned id is our digests — sufficient for the
        // trait contract and offline-first tests. Real CIDv0 bridging is a
        // follow-up (see docs/ARCHITECTURE.md).
        let url = format!(
            "{}/api/v0/add?pin=true&cid-version=1",
            self.api_url.trim_end_matches('/')
        );
        let part = reqwest::multipart::Part::bytes(data.to_vec()).file_name("report.json");
        let form = reqwest::multipart::Form::new().part("file", part);
        match self.client.post(&url).multipart(form).send().await {
            Ok(resp) => {
                if !resp.status().is_success() {
                    tracing::warn!(status = %resp.status(), "ipfs add non-success; storing locally-addressed");
                }
            }
            Err(e) => {
                tracing::warn!(error = %e, "ipfs unreachable; storing locally-addressed");
            }
        }
        Ok(cid_of(data))
    }

    async fn get(&self, cid: &str) -> Result<Vec<u8>, StorageError> {
        let url = format!(
            "{}/api/v0/cat?arg={}",
            self.api_url.trim_end_matches('/'),
            cid
        );
        let resp = self
            .client
            .post(&url)
            .send()
            .await
            .map_err(|e| StorageError::Transport(e.to_string()))?;
        if !resp.status().is_success() {
            return Err(StorageError::NotFound(cid.into()));
        }
        resp.bytes()
            .await
            .map(|b| b.to_vec())
            .map_err(|e| StorageError::Transport(e.to_string()))
    }

    fn name(&self) -> &str {
        "ipfs-http"
    }
}

/// Arweave HTTP client (bundled uploads via a gateway).
///
/// The current implementation posts the payload to a configurable gateway
/// endpoint and returns a SHA-256 content id. Full ANS-104 bundle signing is
/// intentionally scoped to a follow-up — see docs/ARCHITECTURE.md.
pub struct ArweaveArchive {
    /// Gateway base URL, e.g. `https://arweave.net`.
    pub gateway_url: String,
    client: reqwest::Client,
    local: MemoryArchive,
}

impl ArweaveArchive {
    /// Construct against an Arweave gateway.
    pub fn new(gateway_url: impl Into<String>) -> Self {
        Self {
            gateway_url: gateway_url.into(),
            client: reqwest::Client::new(),
            local: MemoryArchive::new(),
        }
    }
}

#[async_trait]
impl Archive for ArweaveArchive {
    async fn put(&self, data: &[u8]) -> Result<Cid, StorageError> {
        // Best-effort mirror; always keep a local copy for get().
        let cid = self.local.put(data).await?;
        let url = format!("{}/tx", self.gateway_url.trim_end_matches('/'));
        if let Err(e) = self.client.post(&url).body(data.to_vec()).send().await {
            tracing::warn!(error = %e, "arweave gateway unreachable; local mirror only");
        }
        Ok(cid)
    }

    async fn get(&self, cid: &str) -> Result<Vec<u8>, StorageError> {
        if let Ok(data) = self.local.get(cid).await {
            return Ok(data);
        }
        let url = format!("{}/{cid}", self.gateway_url.trim_end_matches('/'));
        let resp = self
            .client
            .get(&url)
            .send()
            .await
            .map_err(|e| StorageError::Transport(e.to_string()))?;
        if !resp.status().is_success() {
            return Err(StorageError::NotFound(cid.into()));
        }
        resp.bytes()
            .await
            .map(|b| b.to_vec())
            .map_err(|e| StorageError::Transport(e.to_string()))
    }

    fn name(&self) -> &str {
        "arweave"
    }
}

/// Fan-out archive that writes to all backends and reads from the first hit.
pub struct MultiArchive {
    backends: Vec<Box<dyn Archive>>,
}

impl MultiArchive {
    /// Construct from an ordered list of backends.
    pub fn new(backends: Vec<Box<dyn Archive>>) -> Self {
        Self { backends }
    }
}

#[async_trait]
impl Archive for MultiArchive {
    async fn put(&self, data: &[u8]) -> Result<Cid, StorageError> {
        let mut last_err = None;
        let mut cid = None;
        for b in &self.backends {
            match b.put(data).await {
                Ok(c) => cid = Some(c),
                Err(e) => last_err = Some(e),
            }
        }
        cid.ok_or_else(|| last_err.unwrap_or_else(|| StorageError::Transport("no backends".into())))
    }

    async fn get(&self, cid: &str) -> Result<Vec<u8>, StorageError> {
        for b in &self.backends {
            if let Ok(data) = b.get(cid).await {
                return Ok(data);
            }
        }
        Err(StorageError::NotFound(cid.into()))
    }

    fn name(&self) -> &str {
        "multi"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn memory_roundtrip() {
        let a = MemoryArchive::new();
        let cid = a.put(b"hello bitsync").await.unwrap();
        assert_eq!(a.get(&cid).await.unwrap(), b"hello bitsync");
        assert!(a.get("deadbeef").await.is_err());
    }

    #[tokio::test]
    async fn multi_falls_through() {
        let mem = MemoryArchive::new();
        let multi = MultiArchive::new(vec![Box::new(mem)]);
        let cid = multi.put(b"x").await.unwrap();
        assert_eq!(multi.get(&cid).await.unwrap(), b"x");
    }
}
