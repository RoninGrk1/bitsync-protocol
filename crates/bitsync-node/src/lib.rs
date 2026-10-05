//! BitSync oracle node library.
//!
//! The binary (`main.rs`) loads config and drives [`engine::NodeEngine`].
//! Integration tests build several engines over an [`network::InMemoryMesh`].

#![forbid(unsafe_code)]
#![warn(missing_docs)]

pub mod config;
pub mod engine;
pub mod keystore;
pub mod libp2p_driver;
pub mod metrics;
pub mod network;
pub mod protocol;
pub mod signed_state;

pub use config::NodeConfig;
pub use engine::{Behaviour, NodeEngine, RoundOutcome};
pub use network::{InMemoryMesh, InMemoryNetwork, Network, NetworkEvent, PeerId};
pub use protocol::{GossipMessage, OperatorId, SignedObservation, SignedReportShare};
