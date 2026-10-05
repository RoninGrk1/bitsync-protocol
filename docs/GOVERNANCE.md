# Governance

BitSync uses a **multisig-controlled OpenZeppelin `TimelockController`**
(`BitSyncTimelock`) as the root of on-chain authority. Roles on
`StakingManager`, `SlashingManager`, `FeeManager`, `OracleAggregator`, and
`FeedRegistry` are granted to the timelock in production deployments.

## Progressive decentralization roadmap

| Phase | Proposer | Executor | Notes |
| --- | --- | --- | --- |
| 0 — Bootstrap | Deployer EOA | Deployer EOA | Local / testnets only |
| 1 — Multisig | 3-of-5 (or similar) institutional multisig | Same multisig (+ optionally `address(0)` for open execution) | **Current production target** |
| 2 — Hybrid | Multisig **and** on-chain Governor (BSY voting) | Timelock | Add Governor as proposer; keep multisig as safety valve |
| 3 — Community | Governor only | Timelock | Revoke multisig proposer role after sustained stability |

Parameters under governance include: unbonding period, minimum stake, slash
bps, fee per read, feed allow-list, and (eventually) BLS/FROST migration
switches.

## Off-chain process

- RFC → public discussion → multisig ceremony → timelock queue → execute after
  `minDelay`.
- Emergency pause (if added in a future release) should still flow through the
  timelock unless a narrowly scoped guardian is introduced with a published
  sunset schedule.
