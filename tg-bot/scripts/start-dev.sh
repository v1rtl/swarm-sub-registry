#!/usr/bin/env bash
set -euo pipefail

# Read addresses from orion state (same pattern as gas-boy/scripts/start-dev.sh)
STATE_DIR="${ORION_STATE:-../orion/state}"
REGISTRY_JSON="$STATE_DIR/registry.json"

if [[ ! -f "$REGISTRY_JSON" ]]; then
  echo "Error: $REGISTRY_JSON not found. Run orion deploy first." >&2
  exit 1
fi

REGISTRY_ADDRESS=$(jq -r '.registry' "$REGISTRY_JSON")
POSTAGE_ADDRESS=$(jq -r '.postage' "$REGISTRY_JSON")
BZZ_ADDRESS=$(jq -r '.bzz // .token' "$REGISTRY_JSON")

export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
export CHAIN_ID="${CHAIN_ID:-31337}"
export REGISTRY_ADDRESS
export POSTAGE_ADDRESS
export BZZ_ADDRESS
export POLL_INTERVAL_MS="${POLL_INTERVAL_MS:-10000}"
export DB_PATH="${DB_PATH:-./data/tg-bot.db}"

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  echo "Error: TELEGRAM_BOT_TOKEN not set" >&2
  exit 1
fi

exec bun run src/index.ts
