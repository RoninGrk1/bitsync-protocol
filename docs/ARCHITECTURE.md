# Architecture

BitSync is an **institutional oracle layer for Bitcoin**. Operators pull
cryptographically signed market data, reach BFT consensus on a stake-weighted
median, publish the aggregate to a Bitcoin L2 / EVM execution environment, and
periodically anchor the round's Merkle root to Bitcoin via `OP_RETURN`.

```mermaid
flowchart LR
  subgraph Sources
    S1[Signed API A]
    S2[Signed API B]
    S3[Mock Fixture]
  end
  subgraph Operators
    N1[Node 1]
    N2[Node 2]
    N3[Node 3]
    N4[Node 4]
  end
  subgraph Settlement
    BTC[Bitcoin OP_RETURN]
  end
  subgraph Execution
    ORA[OracleAggregator]
    STK[StakingManager]
    SLH[SlashingManager]
    FEE[FeeManager]
    BSY[BSY ERC-20]
    GOV[Timelock / Multisig]
  end
  S1 --> N1 & N2 & N3 & N4
  S2 --> N1 & N2 & N3 & N4
  S3 --> N1 & N2 & N3 & N4
  N1 & N2 & N3 & N4 -->|gossipsub| N1
  N1 & N2 & N3 & N4 -->|ECDSA quorum report| ORA
  N1 -->|Merkle root| BTC
  STK --> ORA
  SLH --> STK
  FEE --> STK
  BSY --> STK & FEE
  GOV --> ORA & STK & SLH & FEE
```

## Components

| Layer | Crate / package | Role |
| --- | --- | --- |
| Crypto | `bitsync-crypto` | EIP-712 digests, ECDSA, FROST threshold Schnorr, BSY `Amount`, `Signer`/`KeyProvider` (+ PKCS#11 stub) |
| Consensus | `bitsync-consensus` | `n=3f+1` BFT, stake-weighted median, MAD outlier rejection |
| Sources | `bitsync-sources` | Signed institutional adapters + offline mock |
| Storage | `bitsync-storage` | IPFS HTTP + Arweave traits, in-memory impl |
| P2P | `bitsync-p2p` | libp2p gossipsub / noise / yamux / identify / kad |
| Anchor | `bitsync-anchor` | Bitcoin `OP_RETURN` commitment builder (`BSYN` magic) |
| Node | `bitsync-node` | Binary: rounds, archive, Prometheus `/metrics` |
| Contracts | `contracts/` | BSY, staking, slashing, fees, oracle, registry, timelock |
| SDKs | `sdk/rust`, `sdk/typescript` | Typed clients + report verification + BSY helpers |

## On-chain report verification

`OracleAggregator` verifies an **ECDSA quorum** of registered operators over an
EIP-712 digest (`"BitSync Oracle" / "1"`). The Rust and TypeScript SDKs compute
the **same digest**.

**Upgrade path to BLS / FROST-verified reports:** keep the `Report` struct and
feed storage identical; replace the per-operator ECDSA loop with a single
pairing check (BLS12-381) or a FROST-aggregated Schnorr once operator keys are
re-registered under the new scheme. `StakingManager` already stores a `blsPubkey`
field as a reserved slot for that migration. Until then, FROST is used off-chain
to co-sign **Bitcoin anchor commitments**.

## Bitcoin settlement

Each finalised round's signed reports are Merkle-ized (`bitsync-anchor::merkle_root`).
The commitment payload is:

```
magic[4]="BSYN" | version[1]=0x01 | round[8 BE] | root[32]
```

embedded in an `OP_RETURN` output. No custody of BTC is required by the
protocol software in this repository.

## Security status

**Unaudited. Not mainnet-ready.** See [SECURITY.md](./SECURITY.md).


## Networked rounds (live)

Oracle nodes gossip **signed observations** on `bitsync/observations/1` and
**report signature shares** on `bitsync/reports/1` (libp2p gossipsub). Each round:

1. Fetch a signed source tick (or inject a fault in tests).
2. Publish an EIP-712-signed [`Observation`](../crates/bitsync-crypto/src/observation.rs).
3. Collect peer observations for `collect_timeout_ms`, run stake-weighted median
   aggregation with MAD outlier rejection (`bitsync-consensus`).
4. Co-sign the aggregate [`Report`](../crates/bitsync-crypto/src/report.rs) and
   collect a stake quorum (`> 2/3` of known committee stake and `≥ 2f+1` signers).
5. Archive the report (IPFS/Arweave traits) and expose Prometheus metrics.

Solo / `--once` runs on an in-memory mesh with a one-operator committee so
offline smoke tests still finalise. Devnet configs under `deploy/devnet/` set
`listen` + `bootstrap_peers` so compose nodes dial each other over libp2p TCP.

Integration tests in `crates/bitsync-node/tests/networked_rounds.rs` spin up
four in-process nodes on the in-memory mesh: 3 honest + 1 outlier still
finalise; 2 faulty of 4 halt safely without a finalised report.
