# BitSync Presale Web

Next.js (App Router) + Tailwind + wagmi/viem + RainbowKit site for the BSY token presale.

## Quick start (local demo)

From the repo root:

```bash
# Terminal 1 — Anvil + deploy mocks + write apps/presale-web/.env.local + start Next
./scripts/local-presale-demo.sh

# Or split:
./scripts/local-presale-demo.sh contracts
cd apps/presale-web && npm install && npm run dev
```

Open http://127.0.0.1:3001 — connect MetaMask (or RainbowKit) to Anvil `31337`, import Anvil account #0.

## Scripts

- `npm run dev` — Next on port 3001
- `npm run build` / `npm run lint` / `npm test`
- `npm run demo` — full local stack via root script

## Env

See `.env.example`. Defaults target Anvil. Set a real `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` for WalletConnect.

## Compliance

- `/legal` — terms & risk disclosure stub
- `/api/compliance/check` — geo block list (default US/UK)
- `/api/compliance/kyc` — EIP-712 signer stub for local demos only

**Do not deploy this app or contracts to a public chain without audit, legal review, and a licensed KYC provider.**
