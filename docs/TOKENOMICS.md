# Tokenomics — BitSync (BSY)

> **Utility only.** No market-cap, FDV, listing-price, or fundraising figures
> are claimed here. Allocations below are **proposed / example** and subject to
> governance.

## Token summary

| Field | Value |
| --- | --- |
| Name | **BitSync** |
| Ticker | **BSY** |
| Decimals | **8** (1 BSY = 10⁸ base units; sat-style) |
| Max / total supply | **42,000,000 BSY** = `42_000_000 * 10**8` base units |
| Inflation | **0%** — full supply minted once at deployment; **no mint function** thereafter |
| Standard (EVM / Bitcoin L2) | ERC-20 + EIP-2612 Permit + ERC-20 Burnable |
| Burn | Holders may burn; supply can only decrease |

Constants are shared across Solidity (`BSY.MAX_SUPPLY`), Rust
(`bitsync_crypto::{MAX_SUPPLY_BASE, BSY_DECIMALS, Amount}`), and TypeScript
(`@bitsync/sdk` `MAX_SUPPLY_BASE`).

## Utility

BSY is an **institutional-grade utility token**:

1. **Staking / oracle security** — operators bond BSY in `StakingManager`; stake
   weights consensus and is at risk of slashing for equivocation.
2. **Fees** — consumers pay feed fees in BSY via `FeeManager`; fees accrue to
   stakers.
3. **Governance (roadmap)** — progressive decentralization may add BSY-weighted
   voting (see [GOVERNANCE.md](./GOVERNANCE.md)).

## Proposed genesis allocation (example)

These percentages are **illustrative** and must be finalised by the deploying
multisig / timelock before any public distribution:

| Bucket | Example % | Notes |
| --- | --- | --- |
| Ecosystem / rewards | 40% | Operator incentives, grants — vesting TBD |
| Treasury / runway | 25% | Controlled by BitSync timelock |
| Early contributors | 20% | Vesting TBD |
| Community / liquidity | 15% | Programs TBD |

All 42M BSY are minted to the treasury/genesis address in the ERC-20
constructor; subsequent distribution is ordinary ERC-20 transfer.

## Bitcoin-native representation (roadmap)

The EVM ERC-20 on Bitcoin L2s is the **canonical execution-layer** form of BSY
today. A Bitcoin-native representation (e.g. Runes, BRC-20-style, or a
dedicated bridge with a **cross-chain supply invariant of 42M total across all
chains**) is **design / roadmap only** and is **not implemented** in this
repository.

Design constraints when that path is built:

- Global circulating supply across all representations ≤ 42,000,000 BSY.
- Bridge mints on one chain must lock/burn on another (no net inflation).
- 8-decimal base units preserved end-to-end.
- Proofs of lock/burn attested by the BitSync oracle set or an equivalent
  light-client bridge.

## Fee units

All staking, fee, and slashing amounts in contracts and node software use
**8-decimal base units** consistently (e.g. `10_000 * 10**8` = 10,000 BSY
minimum stake in the deploy script).
