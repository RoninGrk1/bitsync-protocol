//! Four-node in-process networked rounds over the in-memory gossip mesh.

use bitsync_crypto::SoftwareSigner;
use bitsync_node::config::NodeConfig;
use bitsync_node::engine::{equal_committee, Behaviour, NodeEngine, RoundOutcome};
use bitsync_node::network::InMemoryMesh;
use bitsync_sources::MockSignedSource;
use bitsync_storage::MemoryArchive;
use std::sync::Arc;
use std::time::Duration;

fn cfg(id: &str) -> NodeConfig {
    NodeConfig {
        node_id: id.into(),
        feeds: vec!["BTC/USD".into()],
        committee_n: 4,
        collect_timeout_ms: 800,
        round_interval_secs: 1,
        operator_stake: 10_000 * 100_000_000,
        ..NodeConfig::default()
    }
}

async fn spawn_committee(
    behaviours: [Behaviour; 4],
) -> Vec<Arc<NodeEngine<bitsync_node::network::InMemoryNetwork>>> {
    let mesh = InMemoryMesh::new();
    let mut signers = Vec::new();
    let mut nets = Vec::new();
    for i in 0..4 {
        let id = format!("node-{i}");
        signers.push(Arc::new(SoftwareSigner::random()));
        nets.push(Arc::new(mesh.join(id)));
    }
    let committee = equal_committee(&signers, 10_000 * 100_000_000);
    // Shared mid price so honest nodes agree.
    let price = 6_425_000_000_000i128;
    let mut engines = Vec::new();
    for i in 0..4 {
        let source = Arc::new(MockSignedSource::new(format!("src-{i}")));
        source.set_price("BTC/USD", price).await;
        let archive = Arc::new(MemoryArchive::new());
        let mut engine = NodeEngine::new(
            cfg(&format!("node-{i}")),
            Arc::clone(&nets[i]),
            Arc::clone(&signers[i]),
            source,
            archive,
        );
        engine.set_committee(committee.clone());
        engine.behaviour = behaviours[i].clone();
        engines.push(Arc::new(engine));
    }
    engines
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn three_honest_one_outlier_finalises() {
    let engines = spawn_committee([
        Behaviour::Honest,
        Behaviour::Honest,
        Behaviour::Honest,
        Behaviour::Outlier {
            price_override: 1_000_000_000_000_000,
        },
    ])
    .await;

    let mut handles = Vec::new();
    for eng in &engines {
        let eng = Arc::clone(eng);
        handles.push(tokio::spawn(async move {
            eng.run_feed_round("BTC/USD", 1).await
        }));
    }
    let mut outcomes = Vec::new();
    for h in handles {
        outcomes.push(h.await.unwrap().unwrap());
    }

    let finalised: Vec<_> = outcomes
        .iter()
        .filter_map(|o| match o {
            RoundOutcome::Finalised {
                price,
                accepted,
                cosigners,
                ..
            } => Some((*price, *accepted, *cosigners)),
            _ => None,
        })
        .collect();
    // At least the three honest nodes must finalise; the outlier also aggregates the
    // same honest majority so it finalises too (its own outlier obs is rejected).
    assert!(finalised.len() >= 3, "outcomes={outcomes:?}");
    for (price, accepted, cosigners) in &finalised {
        assert!(
            (*price - 6_425_000_000_000i128).abs() < 100_000_000,
            "price={price}"
        );
        assert_eq!(*accepted, 3, "outlier must be rejected");
        assert!(*cosigners >= 3);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn two_faulty_of_four_halts_safely() {
    let engines = spawn_committee([
        Behaviour::Honest,
        Behaviour::Honest,
        Behaviour::Outlier {
            price_override: 9_000_000_000_000_000,
        },
        Behaviour::Silent,
    ])
    .await;

    let mut handles = Vec::new();
    for eng in &engines {
        let eng = Arc::clone(eng);
        handles.push(tokio::spawn(async move {
            // Give silent/outlier peers a moment so collect windows overlap.
            tokio::time::sleep(Duration::from_millis(20)).await;
            eng.run_feed_round("BTC/USD", 7).await
        }));
    }
    let mut halted = 0;
    let mut finalised = 0;
    for h in handles {
        match h.await.unwrap().unwrap() {
            RoundOutcome::Halted { .. } => halted += 1,
            RoundOutcome::Finalised { .. } => finalised += 1,
        }
    }
    // With only 2 honest observations, quorum size 3 cannot be met → everyone halts.
    assert_eq!(finalised, 0, "must not finalise with 2 faulty of 4");
    assert_eq!(halted, 4);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn four_honest_agree_on_price() {
    let engines = spawn_committee([
        Behaviour::Honest,
        Behaviour::Honest,
        Behaviour::Honest,
        Behaviour::Honest,
    ])
    .await;
    let mut handles = Vec::new();
    for eng in &engines {
        let eng = Arc::clone(eng);
        handles.push(tokio::spawn(async move {
            eng.run_feed_round("BTC/USD", 3).await
        }));
    }
    let mut prices = Vec::new();
    for h in handles {
        match h.await.unwrap().unwrap() {
            RoundOutcome::Finalised {
                price, accepted, ..
            } => {
                assert_eq!(accepted, 4);
                prices.push(price);
            }
            other => panic!("expected finalised, got {other:?}"),
        }
    }
    assert!(prices.iter().all(|p| *p == prices[0]));
}
