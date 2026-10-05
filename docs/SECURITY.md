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
