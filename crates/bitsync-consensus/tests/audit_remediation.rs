//! Regression tests for BSY-H3 / quorum (formerly audit PoCs).

use bitsync_consensus::{aggregate, stake_quorum_met, AggregationConfig, Committee, Observation};
use bitsync_crypto::Address;

fn obs(op: u8, stake: u128, price: i128) -> Observation {
    Observation {
        operator: Address([op; 20]),
        stake,
        price,
        confidence: 1,
    }
}

#[test]
fn remediated_mad_even_committee_finalises() {
    let c = Committee::from_n(4);
    let v = vec![
        obs(1, 1, 100),
        obs(2, 1, 100),
        obs(3, 1, 101),
        obs(4, 1, 102),
    ];
    let agg = aggregate(&c, &AggregationConfig::default(), &v).expect("H3: must finalise");
    assert!(agg.accepted.len() >= 3);
}

#[test]
fn remediated_quorum_matches_onchain_strict_gt() {
    assert!(!stake_quorum_met(2, 3)); // exact 2/3 rejected
    assert!(stake_quorum_met(67, 100));
}
