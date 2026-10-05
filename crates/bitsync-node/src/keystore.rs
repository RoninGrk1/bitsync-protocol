//! Persistent operator key loading (BSY-H7).
//!
//! Production nodes MUST set `operator_key_path` to a file containing a 32-byte
//! hex secp256k1 secret (optionally `0x`-prefixed). Random keys are only for tests.

use anyhow::{bail, Context, Result};
use bitsync_crypto::SoftwareSigner;
use std::path::Path;

/// Load a [`SoftwareSigner`] from a hex secret file.
pub fn load_signer(path: &Path) -> Result<SoftwareSigner> {
    let raw = std::fs::read_to_string(path)
        .with_context(|| format!("read operator key {}", path.display()))?;
    let hex = raw.trim().trim_start_matches("0x");
    let bytes = hex::decode(hex).context("operator key must be hex")?;
    if bytes.len() != 32 {
        bail!("operator key must be 32 bytes, got {}", bytes.len());
    }
    let mut secret = [0u8; 32];
    secret.copy_from_slice(&bytes);
    SoftwareSigner::from_secret(secret).map_err(|e| anyhow::anyhow!(e.to_string()))
}
