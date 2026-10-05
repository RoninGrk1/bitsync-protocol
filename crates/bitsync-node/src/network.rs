//! Transport abstraction: in-memory bus (tests) and a thin libp2p facade.

use crate::protocol::GossipMessage;
use async_trait::async_trait;
use dashmap::DashMap;
use futures::Stream;
use parking_lot::Mutex;
use std::pin::Pin;
use std::sync::Arc;
use tokio::sync::broadcast;
use tokio::sync::mpsc;
use tokio_stream::wrappers::BroadcastStream;
use tokio_stream::StreamExt;

/// Opaque peer identifier (node_id string in the in-memory bus).
pub type PeerId = String;

/// Event delivered to a node from the network.
#[derive(Clone, Debug)]
pub struct NetworkEvent {
    /// Sender peer.
    pub from: PeerId,
    /// Gossip payload.
    pub message: GossipMessage,
}

/// Minimal gossip transport used by the round engine.
#[async_trait]
pub trait Network: Send + Sync {
    /// Local peer id.
    fn local_id(&self) -> &str;
    /// Publish a message to all peers (including self, for uniform handling).
    async fn publish(&self, message: GossipMessage) -> anyhow::Result<()>;
    /// Subscribe to inbound messages.
    fn subscribe(&self) -> Pin<Box<dyn Stream<Item = NetworkEvent> + Send>>;
}

/// Shared in-memory mesh. Each `join` returns a handle that broadcasts to all members.
pub struct InMemoryMesh {
    peers: DashMap<PeerId, broadcast::Sender<NetworkEvent>>,
}

impl InMemoryMesh {
    /// Empty mesh.
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            peers: DashMap::new(),
        })
    }

    /// Register a peer and return its network handle.
    pub fn join(self: &Arc<Self>, id: impl Into<PeerId>) -> InMemoryNetwork {
        let id = id.into();
        let (tx, _rx) = broadcast::channel(4096);
        self.peers.insert(id.clone(), tx);
        InMemoryNetwork {
            id,
            mesh: Arc::clone(self),
        }
    }
}

impl Default for InMemoryMesh {
    fn default() -> Self {
        Self {
            peers: DashMap::new(),
        }
    }
}

/// Per-peer handle onto an [`InMemoryMesh`].
pub struct InMemoryNetwork {
    id: PeerId,
    mesh: Arc<InMemoryMesh>,
}

#[async_trait]
impl Network for InMemoryNetwork {
    fn local_id(&self) -> &str {
        &self.id
    }

    async fn publish(&self, message: GossipMessage) -> anyhow::Result<()> {
        let event = NetworkEvent {
            from: self.id.clone(),
            message,
        };
        for entry in self.mesh.peers.iter() {
            // Ignore lagging receivers; tests drive the loop promptly.
            let _ = entry.value().send(event.clone());
        }
        Ok(())
    }

    fn subscribe(&self) -> Pin<Box<dyn Stream<Item = NetworkEvent> + Send>> {
        let tx = self
            .mesh
            .peers
            .get(&self.id)
            .expect("peer registered")
            .clone();
        let rx = tx.subscribe();
        Box::pin(BroadcastStream::new(rx).filter_map(|r| match r {
            Ok(ev) => Some(ev),
            Err(tokio_stream::wrappers::errors::BroadcastStreamRecvError::Lagged(n)) => {
                tracing::warn!(
                    skipped = n,
                    "gossip subscriber lagged; applying backpressure"
                );
                None
            }
        }))
    }
}

/// Drain helper: collect events for up to `timeout` from a subscribe stream.
pub async fn collect_for(
    stream: &mut Pin<Box<dyn Stream<Item = NetworkEvent> + Send>>,
    timeout: std::time::Duration,
) -> Vec<NetworkEvent> {
    let mut out = Vec::new();
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        match tokio::time::timeout(remaining, stream.next()).await {
            Ok(Some(ev)) => out.push(ev),
            Ok(None) | Err(_) => break,
        }
    }
    out
}

/// Build a libp2p-backed network (best-effort publish; used by the binary).
///
/// The full swarm event loop is driven by [`Libp2pNetwork::drive`]. Incoming
/// gossipsub messages are forwarded onto an internal broadcast channel that
/// implements [`Network`].
pub struct Libp2pNetwork {
    id: PeerId,
    inbound_tx: broadcast::Sender<NetworkEvent>,
    outbound_tx: Mutex<Option<mpsc::UnboundedSender<GossipMessage>>>,
}

impl Libp2pNetwork {
    /// Construct a handle; call [`Self::drive`] from a spawned task.
    pub fn new(
        id: impl Into<PeerId>,
    ) -> (
        Self,
        mpsc::UnboundedReceiver<GossipMessage>,
        broadcast::Sender<NetworkEvent>,
    ) {
        let (inbound_tx, _) = broadcast::channel(4096);
        let (outbound_tx, outbound_rx) = mpsc::unbounded_channel();
        (
            Self {
                id: id.into(),
                inbound_tx: inbound_tx.clone(),
                outbound_tx: Mutex::new(Some(outbound_tx)),
            },
            outbound_rx,
            inbound_tx,
        )
    }

    /// Push an inbound gossip message (called by the swarm driver).
    pub fn push_inbound(&self, from: PeerId, message: GossipMessage) {
        let _ = self.inbound_tx.send(NetworkEvent { from, message });
    }
}

#[async_trait]
impl Network for Libp2pNetwork {
    fn local_id(&self) -> &str {
        &self.id
    }

    async fn publish(&self, message: GossipMessage) -> anyhow::Result<()> {
        if let Some(tx) = self.outbound_tx.lock().as_ref() {
            tx.send(message)
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        }
        Ok(())
    }

    fn subscribe(&self) -> Pin<Box<dyn Stream<Item = NetworkEvent> + Send>> {
        Box::pin(
            BroadcastStream::new(self.inbound_tx.subscribe()).filter_map(|r| match r {
                Ok(ev) => Some(ev),
                Err(tokio_stream::wrappers::errors::BroadcastStreamRecvError::Lagged(n)) => {
                    tracing::warn!(skipped = n, "libp2p inbound lagged; applying backpressure");
                    None
                }
            }),
        )
    }
}

/// Per-peer rate limiter + content dedupe for inbound gossip (BSY-H6).
#[derive(Default)]
pub struct InboundGate {
    /// peer -> (window_start_ms, count)
    peers: dashmap::DashMap<PeerId, (u64, u32)>,
    /// recent message fingerprints
    seen: dashmap::DashMap<u64, ()>,
}

impl InboundGate {
    /// Max messages accepted per peer per second.
    pub const PER_PEER_PER_SEC: u32 = 32;

    /// Returns true if the message should be processed.
    pub fn admit(&self, peer: &str, fingerprint: u64) -> bool {
        if self.seen.insert(fingerprint, ()).is_some() {
            return false; // duplicate
        }
        // Cap seen map growth.
        if self.seen.len() > 10_000 {
            self.seen.clear();
            self.seen.insert(fingerprint, ());
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let mut entry = self.peers.entry(peer.to_string()).or_insert((now, 0));
        if entry.0 != now {
            *entry = (now, 1);
            return true;
        }
        if entry.1 >= Self::PER_PEER_PER_SEC {
            return false;
        }
        entry.1 += 1;
        true
    }
}
