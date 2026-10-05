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

## Genesis allocation

All **42,000,000 BSY** are minted once to the treasury/timelock in the ERC-20
constructor. Subsequent distribution is ordinary ERC-20 transfer (**no mint**).

| Bucket | % | Amount (BSY) | Status |
| --- | --- | --- | --- |
| **Presale** | **15%** | **6,300,000** | **Fixed** — funded into `BSYPresale` at deploy |
| Ecosystem / rewards | 40% | 16,800,000 | Proposed / example |
| Treasury / runway | 25% | 10,500,000 | Proposed / example |
| Early contributors | 20% | 8,400,000 | Proposed / example |

Non-presale rows remain **proposed / example** pending governance finalisation.

## Presale parameters (suggested / governance-configurable)

Defaults below are **suggestions** for the web UI and local demo. On-chain values
are whatever governance sets via `BSYPresale.setConfig` **before** `start`.

| Parameter | Suggested default | Notes |
| --- | --- | --- |
| Allocation | 6,300,000 BSY | Fixed hard cap (= 15%) |
| Price | **$0.20 / BSY** | `priceUsdPerBsy` in 8-dec USD units |
| Hard-cap USD | ~**$1.26M** | 6.3M × $0.20 |
| Implied FDV at sale price | ~**$8.4M** | 42M × $0.20 (illustrative only) |
| Listing reference | **$0.30** | Marketing reference only — not on-chain |
| Payment | ETH (via ETH/USD feed) + USDC/USDT | Stables allowlisted |
| Soft cap | Configurable (e.g. 1M BSY) | Miss → refunds |
| Vesting | e.g. 25% TGE + 90d linear | Configurable bps / duration |
| KYC | EIP-712 compliance signatures | Optional gate |

None of the USD price / FDV / listing figures are financial advice or a
guarantee of secondary-market price.

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
