//! Persist last-signed observation digests per (feed, round) to prevent
//! restart equivocation (BSY-H5).

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct StateFile {
    /// key = "{feed_hex}:{round}" -> digest hex
    observations: HashMap<String, String>,
}

/// Persistent store of last-signed observation digests per (feed, round).
pub struct SignedStateStore {
    path: Option<PathBuf>,
    inner: Mutex<StateFile>,
}

impl SignedStateStore {
    /// Open (or create) a store under `dir/signed_state.json`, or in-memory if `None`.
    pub fn open(dir: Option<&str>) -> Result<Self> {
        let path = dir.map(|d| Path::new(d).join("signed_state.json"));
        let inner = if let Some(ref p) = path {
            if p.exists() {
                let raw =
                    std::fs::read_to_string(p).with_context(|| format!("read {}", p.display()))?;
                serde_json::from_str(&raw).unwrap_or_default()
            } else {
                if let Some(parent) = p.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                StateFile::default()
            }
        } else {
            StateFile::default()
        };
        Ok(Self {
            path,
            inner: Mutex::new(inner),
        })
    }

    fn key(feed_id: &[u8; 32], round: u64) -> String {
        format!("{}:{round}", hex::encode(feed_id))
    }

    /// Returns Ok(true) if this digest is new or matches the stored one.
    /// Returns Ok(false) if a *different* digest was already signed for this feed/round.
    pub fn check_and_record_observation(
        &self,
        feed_id: &[u8; 32],
        round: u64,
        digest: &[u8; 32],
    ) -> Result<bool> {
        let k = Self::key(feed_id, round);
        let dig = hex::encode(digest);
        let mut g = self.inner.lock().unwrap();
        if let Some(prev) = g.observations.get(&k) {
            return Ok(prev == &dig);
        }
        g.observations.insert(k, dig);
        if let Some(ref p) = self.path {
            let json = serde_json::to_string_pretty(&*g)?;
            std::fs::write(p, json).with_context(|| format!("write {}", p.display()))?;
        }
        Ok(true)
    }
}
