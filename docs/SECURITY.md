# Security

## Status

**This software is unaudited and is not mainnet-ready.**

Do not use it to secure real funds, production price feeds, or institutional
custody workflows until independent audits, formal verification of critical
paths, and a public bug-bounty programme are in place.

## Threat model (summary)

| Asset | Threat | Mitigation (current / planned) |
| --- | --- | --- |
| Oracle price integrity | Byzantine operators, poisoned sources | `n=3f+1` quorum, stake-weighted median, MAD outlier rejection, source signature verification |
| Operator keys | Theft from disk | `Signer`/`KeyProvider` abstraction; **PKCS#11 HSM stub** behind `pkcs11` feature — production must use HSM/remote signer |
| Equivocation | Double-signed conflicting reports | `SlashingManager.slashEquivocation` with evidence replay protection |
| Contract upgrade / param risk | Malicious admin | Multisig + `TimelockController`; progressive decentralization (see GOVERNANCE.md) |
| Bitcoin anchor integrity | Fake commitments | Tagged `BSYN` payload + FROST `t-of-n` co-sign (off-chain) of commitment digest |
| Supply integrity | Inflation | Fixed 42M mint-once BSY; no mint path; fuzz invariant `totalSupply ≤ MAX_SUPPLY` |

## Cryptography

- **Reports (EVM):** EIP-712 + ECDSA secp256k1, low-S, `v ∈ {27,28}` — matches
  OpenZeppelin `ECDSA.recover`.
- **Threshold (Bitcoin anchors):** FROST(secp256k1, Taproot) via
  `frost-secp256k1-tr`. Trusted-dealer keygen is for tests; production should
  run DKG.
- **Sources:** Ed25519 or ECDSA-over-keccak signed payloads; mock fixture
  included for offline operation.
- **HSM:** Interface only (`bitsync-crypto` feature `pkcs11`). Not a working
  PKCS#11 backend.

## Disclosure

Please responsibly disclose issues to the maintainers via GitHub Security
Advisories on this repository. Do not open public issues for exploitable
vulnerabilities before a fix is available.


## Remediation status (internal audit, 2026-10-05)

Fixes landed for all **Critical** and **High** findings from the independent
audit of commit `f5b66549` (report: internal `/workspace/audit/BitSync-Audit-Report.md`):

| ID | Status | Notes |
| --- | --- | --- |
| BSY-C1 | **Fixed** | Per-asset soft-cap refunds (`ethRefunded` + per-stable `stablePaid`); allocation voided once |
| BSY-C2 | **Fixed** | No Anvil default key; `COMPLIANCE_SIGNER_KEY` server-only; country from headers; KYC provider fail-closed; on-chain KYC nonce |
| BSY-C3 | **Fixed** | Deploy grants `COMPLIANCE_ROLE` to designated signer; deployer renounces |
| BSY-H1 | **Fixed** | Canonical feed id = UTF-8 label in `bytes32` (Solidity / Rust / TS + vectors) |
| BSY-H2 | **Fixed** | `setConfig` reverts with `ConfigLocked` once `block.timestamp >= config.start` |
| BSY-H3 | **Fixed** | MAD rejection band `max(ceil(k*MAD), 1)` so even honest committees finalise |
| BSY-H4 | **Fixed** | Report timestamp = median of accepted observation timestamps |
| BSY-H5 | **Fixed** | Persist last-signed observation digest per (feed, round); refuse equivocation |
| BSY-H6 | **Fixed** | Larger gossip buffer, Lagged warnings, per-peer rate limit + dedupe gate |
| BSY-H7 | **Fixed** | `operator_key_path` required at binary start; ephemeral keys tests-only |
| BSY-H8 | **Fixed** | TS `verifyQuorum` requires trusted stake map and strict `>2/3` |

Medium / Low items (sequencer checks, Next.js upgrades, metrics bind address, etc.)
remain open — see the audit report.
