# Contributing

Thanks for your interest in BitSync.

## Prerequisites

- Rust 1.85+ (`cargo`, `rustfmt`, `clippy`)
- Foundry (`forge`, `cast`, `anvil`) — `curl -L https://foundry.paradigm.xyz | bash`
- Node 18+ (TypeScript SDK)

## Workflow

```bash
# Rust
cargo fmt --all
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace

# Solidity
cd contracts && forge fmt && forge test

# TypeScript
cd sdk/typescript && npm ci && npm run lint && npm test && npm run build
```

## Guidelines

- No secrets or private keys in commits. Test keys are generated in-process.
- Keep BSY math in **8-decimal base units**; never introduce a second mint path.
- Document security-sensitive changes in `docs/SECURITY.md`.
- Prefer small, reviewable PRs with tests.

## License

Contributions are under Apache-2.0 (see `LICENSE`).
