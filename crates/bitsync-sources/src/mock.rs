//! Offline signed fixture source.

use super::*;
use rand::rngs::OsRng;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

/// Deterministic offline source that signs ticks with a held Ed25519 key.
pub struct MockSignedSource {
    id: String,
    sk: EdSigningKey,
    /// feed → last price (mutated slightly each fetch for realism).
    prices: Arc<RwLock<HashMap<String, i128>>>,
}

impl MockSignedSource {
    /// Construct with a random Ed25519 key and default BTC/USD / ETH/USD fixtures.
    pub fn new(id: impl Into<String>) -> Self {
        let mut prices = HashMap::new();
        prices.insert("BTC/USD".into(), 6_425_000_000_000i128); // $64,250.00 @ 8dp
        prices.insert("ETH/USD".into(), 345_000_000_000i128);
        Self {
            id: id.into(),
            sk: EdSigningKey::generate(&mut OsRng),
            prices: Arc::new(RwLock::new(prices)),
        }
    }

    /// Verifying key hex (for allow-listing in node config).
    pub fn public_key_hex(&self) -> String {
        hex::encode(self.sk.verifying_key().as_bytes())
    }

    /// Override a feed's mid price.
    pub async fn set_price(&self, feed: &str, price: i128) {
        self.prices.write().await.insert(feed.into(), price);
    }
}

#[async_trait]
impl PriceSource for MockSignedSource {
    fn id(&self) -> &str {
        &self.id
    }

    async fn fetch(&self, feed: &str) -> Result<SignedTick, SourceError> {
        let price = {
            let guard = self.prices.read().await;
            *guard
                .get(feed)
                .ok_or_else(|| SourceError::InvalidPayload(format!("unknown feed {feed}")))?
        };
        let mut tick = SignedTick {
            feed: feed.into(),
            price,
            confidence: 5_000_000_000, // $50
            timestamp: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
            source_id: self.id.clone(),
            scheme: SigScheme::Ed25519,
            signature: String::new(),
            public_key: String::new(),
        };
        sign_ed25519(&mut tick, &self.sk);
        Ok(tick)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn mock_tick_verifies() {
        let src = MockSignedSource::new("fixture-1");
        let tick = src.fetch("BTC/USD").await.unwrap();
        tick.verify().unwrap();
        assert_eq!(tick.source_id, "fixture-1");
        assert!(tick.price > 0);
    }

    #[tokio::test]
    async fn tampered_tick_fails() {
        let src = MockSignedSource::new("fixture-2");
        let mut tick = src.fetch("ETH/USD").await.unwrap();
        tick.price += 1;
        assert!(tick.verify().is_err());
    }
}
