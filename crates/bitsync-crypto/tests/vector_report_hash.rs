//! Cross-language EIP-712 vector: must match Solidity + TypeScript.

use bitsync_crypto::ecdsa::{Address, EthSignature};
use bitsync_crypto::{Domain, Observation, Report};
use serde::Deserialize;
use std::fs;
use std::path::PathBuf;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Vector {
    chain_id: u64,
    verifying_contract: String,
    feed_id: String,
    report_price: i128,
    report_confidence: u128,
    observation_price: i128,
    observation_confidence: u128,
    timestamp: u64,
    round: u64,
    report_digest: String,
    observation_digest: String,
    signer: String,
    report_signature: String,
    observation_signature: String,
    report_typehash: String,
    observation_typehash: String,
}

fn load() -> Vector {
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.pop();
    path.pop();
    path.push("test-vectors/report_hash.json");
    serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
}

fn parse_hex32(s: &str) -> [u8; 32] {
    let raw = hex::decode(s.trim_start_matches("0x")).unwrap();
    raw.try_into().unwrap()
}

#[test]
fn report_and_observation_match_shared_vector() {
    let v = load();
    let verifying: Address = v.verifying_contract.parse().unwrap();
    let domain = Domain::bitsync_oracle(v.chain_id, verifying);
    let feed_id = parse_hex32(&v.feed_id);

    let report = Report {
        feed_id,
        price: v.report_price,
        confidence: v.report_confidence,
        timestamp: v.timestamp,
        round: v.round,
    };
    let obs = Observation {
        feed_id,
        price: v.observation_price,
        confidence: v.observation_confidence,
        timestamp: v.timestamp,
        round: v.round,
    };

    assert_eq!(
        format!("0x{}", hex::encode(Report::type_hash())),
        v.report_typehash
    );
    assert_eq!(
        format!("0x{}", hex::encode(Observation::type_hash())),
        v.observation_typehash
    );

    let rd = report.digest(&domain);
    let od = obs.digest(&domain);
    assert_eq!(format!("0x{}", hex::encode(rd)), v.report_digest);
    assert_eq!(format!("0x{}", hex::encode(od)), v.observation_digest);

    let signer: Address = v.signer.parse().unwrap();
    let rsig = EthSignature::from_hex(&v.report_signature).unwrap();
    let osig = EthSignature::from_hex(&v.observation_signature).unwrap();
    assert_eq!(rsig.recover(&rd).unwrap(), signer);
    assert_eq!(osig.recover(&od).unwrap(), signer);
}
