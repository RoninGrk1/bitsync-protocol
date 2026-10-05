//! # bitsync-p2p
//!
//! Thin wrapper around libp2p with the BitSync defaults:
//! TCP + Noise + Yamux, Gossipsub for report dissemination, Identify and Kademlia
//! for peer discovery.
//!
//! The event loop is intentionally small; the node binary drives it.

#![allow(missing_docs)]

use futures::StreamExt;
use libp2p::gossipsub::{self, IdentTopic, MessageAuthenticity, ValidationMode};
use libp2p::identity::Keypair;
use libp2p::swarm::{NetworkBehaviour, SwarmEvent};
use libp2p::{identify, kad, noise, tcp, yamux, Multiaddr, PeerId, Swarm, SwarmBuilder};
use serde::{Deserialize, Serialize};
use std::time::Duration;
use thiserror::Error;

/// P2P errors.
#[derive(Debug, Error)]
pub enum P2pError {
    /// Transport / swarm build failure.
    #[error("swarm: {0}")]
    Swarm(String),
    /// Gossipsub publish failure.
    #[error("publish: {0}")]
    Publish(String),
    /// Invalid multiaddr.
    #[error("multiaddr: {0}")]
    Multiaddr(String),
}

/// Gossip topics used by BitSync.
pub mod topics {
    use libp2p::gossipsub::IdentTopic;
    /// Observations for the current round.
    pub fn observations() -> IdentTopic {
        IdentTopic::new("bitsync/observations/1")
    }
    /// Finalised aggregate reports.
    pub fn reports() -> IdentTopic {
        IdentTopic::new("bitsync/reports/1")
    }
}

/// Node identity.
#[derive(Clone)]
pub struct Identity {
    /// libp2p keypair.
    pub keypair: Keypair,
    /// Derived peer id.
    pub peer_id: PeerId,
}

impl Identity {
    /// Generate an ephemeral identity (local nets / tests).
    pub fn generate() -> Self {
        let keypair = Keypair::generate_ed25519();
        let peer_id = keypair.public().to_peer_id();
        Self { keypair, peer_id }
    }
}

/// Composite behaviour.
#[derive(NetworkBehaviour)]
pub struct BitSyncBehaviour {
    /// Gossipsub.
    pub gossipsub: gossipsub::Behaviour,
    /// Identify.
    pub identify: identify::Behaviour,
    /// Kademlia DHT (optional; memory store).
    pub kad: kad::Behaviour<kad::store::MemoryStore>,
}

/// Build a swarm listening on `listen` (e.g. `/ip4/0.0.0.0/tcp/0`).
pub async fn build_swarm(
    identity: Identity,
    listen: Multiaddr,
) -> Result<Swarm<BitSyncBehaviour>, P2pError> {
    let peer_id = identity.peer_id;
    let mut gossipsub = gossipsub::Behaviour::new(
        MessageAuthenticity::Signed(identity.keypair.clone()),
        gossipsub::ConfigBuilder::default()
            .validation_mode(ValidationMode::Strict)
            .heartbeat_interval(Duration::from_secs(1))
            .build()
            .map_err(|e| P2pError::Swarm(e.to_string()))?,
    )
    .map_err(|e| P2pError::Swarm(e.to_string()))?;

    gossipsub
        .subscribe(&topics::observations())
        .map_err(|e| P2pError::Swarm(e.to_string()))?;
    gossipsub
        .subscribe(&topics::reports())
        .map_err(|e| P2pError::Swarm(e.to_string()))?;

    let identify = identify::Behaviour::new(identify::Config::new(
        "bitsync/1.0.0".into(),
        identity.keypair.public(),
    ));
    let store = kad::store::MemoryStore::new(peer_id);
    let kad = kad::Behaviour::new(peer_id, store);

    let behaviour = BitSyncBehaviour {
        gossipsub,
        identify,
        kad,
    };

    let mut swarm = SwarmBuilder::with_existing_identity(identity.keypair)
        .with_tokio()
        .with_tcp(
            tcp::Config::default(),
            noise::Config::new,
            yamux::Config::default,
        )
        .map_err(|e| P2pError::Swarm(e.to_string()))?
        .with_behaviour(|_| behaviour)
        .map_err(|e| P2pError::Swarm(e.to_string()))?
        .with_swarm_config(|c| c.with_idle_connection_timeout(Duration::from_secs(60)))
        .build();

    swarm
        .listen_on(listen)
        .map_err(|e| P2pError::Swarm(e.to_string()))?;
    Ok(swarm)
}

/// Publish raw bytes on a topic.
pub fn publish(
    swarm: &mut Swarm<BitSyncBehaviour>,
    topic: IdentTopic,
    data: Vec<u8>,
) -> Result<gossipsub::MessageId, P2pError> {
    swarm
        .behaviour_mut()
        .gossipsub
        .publish(topic, data)
        .map_err(|e| P2pError::Publish(e.to_string()))
}

/// Dial a peer multiaddr.
pub fn dial(swarm: &mut Swarm<BitSyncBehaviour>, addr: Multiaddr) -> Result<(), P2pError> {
    swarm.dial(addr).map_err(|e| P2pError::Swarm(e.to_string()))
}

/// Parse a multiaddr.
pub fn parse_multiaddr(s: &str) -> Result<Multiaddr, P2pError> {
    s.parse()
        .map_err(|e: libp2p::multiaddr::Error| P2pError::Multiaddr(e.to_string()))
}

/// A single poll of the swarm; useful for tests.
pub async fn next_event(swarm: &mut Swarm<BitSyncBehaviour>) -> SwarmEvent<BitSyncBehaviourEvent> {
    loop {
        if let Some(ev) = swarm.next().await {
            return ev;
        }
    }
}

/// Envelope for gossip payloads (extensible).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct GossipEnvelope {
    /// Schema version.
    pub version: u32,
    /// Kind: `"observation"` | `"report"`.
    pub kind: String,
    /// Opaque JSON payload.
    pub payload: serde_json::Value,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn swarm_listens() {
        let id = Identity::generate();
        let addr = parse_multiaddr("/ip4/127.0.0.1/tcp/0").unwrap();
        let mut swarm = build_swarm(id, addr).await.unwrap();
        // Wait for listening address.
        let ev = next_event(&mut swarm).await;
        match ev {
            SwarmEvent::NewListenAddr { address, .. } => {
                assert!(address.to_string().contains("/tcp/"));
            }
            other => panic!("unexpected event: {other:?}"),
        }
    }
}
