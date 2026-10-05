#!/usr/bin/env bash
# Local BitSync BSY presale demo: Anvil + DeployLocalPresale + Next.js web.
# Usage:
#   ./scripts/local-presale-demo.sh           # anvil (bg) + deploy + write .env.local + start web
#   ./scripts/local-presale-demo.sh contracts # anvil (bg) + deploy + write .env.local only
#   ./scripts/local-presale-demo.sh web       # start Next only (expects .env.local)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB="$ROOT/apps/presale-web"
CONTRACTS="$ROOT/contracts"
MODE="${1:-all}"
ANVIL_PORT="${ANVIL_PORT:-8545}"
RPC="http://127.0.0.1:${ANVIL_PORT}"
# Anvil default account #0
PK="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

ensure_anvil() {
  if curl -sf -X POST "$RPC" -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' >/dev/null 2>&1; then
    echo "Anvil already running on :${ANVIL_PORT}"
    return
  fi
  echo "Starting Anvil on :${ANVIL_PORT}…"
  anvil --port "$ANVIL_PORT" --chain-id 31337 --block-time 1 >"$ROOT/.anvil-presale.log" 2>&1 &
  echo $! >"$ROOT/.anvil-presale.pid"
  for i in $(seq 1 30); do
    if curl -sf -X POST "$RPC" -H 'content-type: application/json' \
      --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' >/dev/null 2>&1; then
      echo "Anvil ready (pid $(cat "$ROOT/.anvil-presale.pid"))"
      return
    fi
    sleep 0.3
  done
  echo "Anvil failed to start; see $ROOT/.anvil-presale.log" >&2
  exit 1
}

deploy_contracts() {
  echo "Deploying local presale stack…"
  cd "$CONTRACTS"
  OUT=$(PRIVATE_KEY="$PK" forge script script/DeployLocalPresale.s.sol:DeployLocalPresale \
    --rpc-url "$RPC" --broadcast -vv 2>&1)
  echo "$OUT" | tee "$ROOT/.deploy-presale.log" | tail -40

  # Parse console2.log lines from forge output
  BSY=$(echo "$OUT" | grep -E '^\s*BSY\s' | awk '{print $NF}' | tail -1)
  PRESALE=$(echo "$OUT" | grep -E '^\s*Presale\s' | awk '{print $NF}' | tail -1)
  USDC=$(echo "$OUT" | grep -E '^\s*USDC\s' | awk '{print $NF}' | tail -1)
  USDT=$(echo "$OUT" | grep -E '^\s*USDT\s' | awk '{print $NF}' | tail -1)

  if [[ -z "${BSY:-}" || -z "${PRESALE:-}" ]]; then
    # Fallback: parse broadcast JSON
    BROADCAST=$(ls -t "$CONTRACTS/broadcast/DeployLocalPresale.s.sol/31337/"*.json 2>/dev/null | head -1 || true)
    if [[ -n "${BROADCAST:-}" ]]; then
      BSY=$(python3 - << PY
import json
d=json.load(open("$BROADCAST"))
txs=d.get("transactions",[])
# first CREATE is BSY typically
for t in txs:
  if t.get("contractName")=="BSY":
    print(t["contractAddress"]); break
else:
  print(txs[0]["contractAddress"] if txs else "")
PY
)
      PRESALE=$(python3 - << PY
import json
d=json.load(open("$BROADCAST"))
for t in d.get("transactions",[]):
  if t.get("contractName")=="BSYPresale":
    print(t["contractAddress"]); break
PY
)
      USDC=$(python3 - << PY
import json
d=json.load(open("$BROADCAST"))
for t in d.get("transactions",[]):
  if t.get("contractName")=="MockERC20" and "USDC" in str(t.get("arguments",[])):
    print(t["contractAddress"]); break
else:
  names=[t for t in d.get("transactions",[]) if t.get("contractName")=="MockERC20"]
  print(names[0]["contractAddress"] if names else "")
PY
)
      USDT=$(python3 - << PY
import json
d=json.load(open("$BROADCAST"))
names=[t for t in d.get("transactions",[]) if t.get("contractName")=="MockERC20"]
print(names[1]["contractAddress"] if len(names)>1 else "")
PY
)
    fi
  fi

  if [[ -z "${BSY:-}" || -z "${PRESALE:-}" || -z "${USDC:-}" || -z "${USDT:-}" ]]; then
    echo "Failed to parse deploy addresses. See $ROOT/.deploy-presale.log" >&2
    exit 1
  fi

  mkdir -p "$WEB"
  cat > "$WEB/.env.local" << ENV
NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=bitsync_placeholder_project_id
NEXT_PUBLIC_CHAIN_ID=31337
NEXT_PUBLIC_RPC_URL=${RPC}
NEXT_PUBLIC_BSY_ADDRESS=${BSY}
NEXT_PUBLIC_PRESALE_ADDRESS=${PRESALE}
NEXT_PUBLIC_USDC_ADDRESS=${USDC}
NEXT_PUBLIC_USDT_ADDRESS=${USDT}
BLOCKED_COUNTRIES=US,GB,UK
KYC_REQUIRED=false
ANVIL_COMPLIANCE_KEY=${PK}
ENV
  echo "Wrote $WEB/.env.local"
  echo "  BSY=$BSY"
  echo "  Presale=$PRESALE"
  echo "  USDC=$USDC"
  echo "  USDT=$USDT"
}

start_web() {
  cd "$WEB"
  if [[ ! -d node_modules ]]; then
    echo "Installing web dependencies…"
    npm install
  fi
  echo "Starting Next.js on http://127.0.0.1:3001 …"
  npm run dev
}

case "$MODE" in
  contracts)
    ensure_anvil
    deploy_contracts
    ;;
  web)
    start_web
    ;;
  all|"")
    ensure_anvil
    deploy_contracts
    start_web
    ;;
  *)
    echo "Unknown mode: $MODE (use all|contracts|web)" >&2
    exit 1
    ;;
esac
