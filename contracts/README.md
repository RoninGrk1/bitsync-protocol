# BitSync contracts (Foundry)

- `BSY` — BitSync ERC-20, 8 decimals, 42M fixed supply, Permit, Burnable
- `StakingManager` — stake / unbond / operator registry
- `SlashingManager` — equivocation slashing
- `OracleAggregator` / `FeedRegistry` — ECDSA quorum reports
- `FeeManager` — BSY fee collection
- `BitSyncTimelock` — OpenZeppelin TimelockController

```bash
forge test
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
```
