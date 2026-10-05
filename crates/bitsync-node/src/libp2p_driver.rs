//! Drive a libp2p swarm and bridge it to [`crate::network::Libp2pNetwork`].

use crate::network::Libp2pNetwork;
use crate::protocol::GossipMessage;
use bitsync_p2p::{
    build_swarm, dial, parse_multiaddr, publish, topics, BitSyncBehaviourEvent, Identity,
};
use futures::StreamExt;
use libp2p::gossipsub;
use libp2p::swarm::SwarmEvent;
use std::sync::Arc;
use tokio::sync::mpsc;
use tracing::{info, warn};

/// Spawn the swarm event loop. Returns when the process exits.
pub async fn run_libp2p(
    identity: Identity,
    listen: &str,
    bootstrap: &[String],
    network: Arc<Libp2pNetwork>,
    mut outbound_rx: mpsc::UnboundedReceiver<GossipMessage>,
) -> anyhow::Result<()> {
    let listen_addr = parse_multiaddr(listen)?;
    let mut swarm = build_swarm(identity, listen_addr).await?;
    for peer in bootstrap {
        match parse_multiaddr(peer) {
            Ok(addr) => {
                if let Err(e) = dial(&mut swarm, addr) {
                    warn!(peer, error = %e, "bootstrap dial failed");
                }
            }
            Err(e) => warn!(peer, error = %e, "bad bootstrap multiaddr"),
        }
    }
    info!(peers = bootstrap.len(), "libp2p swarm driving");

    loop {
        tokio::select! {
            event = swarm.select_next_some() => {
                match event {
                    SwarmEvent::Behaviour(BitSyncBehaviourEvent::Gossipsub(
                        gossipsub::Event::Message { propagation_source, message, .. }
                    )) => {
                        match serde_json::from_slice::<GossipMessage>(&message.data) {
                            Ok(msg) => {
                                network.push_inbound(propagation_source.to_string(), msg);
                            }
                            Err(e) => warn!(error = %e, "bad gossip payload"),
                        }
                    }
                    SwarmEvent::NewListenAddr { address, .. } => {
                        info!(%address, "libp2p listening");
                    }
                    SwarmEvent::ConnectionEstablished { peer_id, .. } => {
                        info!(%peer_id, "peer connected");
                    }
                    _ => {}
                }
            }
            maybe_out = outbound_rx.recv() => {
                match maybe_out {
                    Some(msg) => {
                        let bytes = serde_json::to_vec(&msg)?;
                        let topic = match &msg {
                            GossipMessage::Observation(_) => topics::observations(),
                            GossipMessage::ReportShare(_) => topics::reports(),
                        };
                        if let Err(e) = publish(&mut swarm, topic, bytes) {
                            warn!(error = %e, "gossip publish failed");
                        }
                    }
                    None => break,
                }
            }
        }
    }
    Ok(())
}
