#!/usr/bin/env bash
# Launch `wrangler dev` for local orion testing.
#
# Reads orion/state/registry.json and injects REGISTRY_ADDRESS as an env
# override so the Worker picks up the freshly-deployed address without
# needing to edit wrangler.jsonc.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REGISTRY_JSON="$REPO_ROOT/orion/state/registry.json"

[[ -f "$REGISTRY_JSON" ]] || {
  echo "missing $REGISTRY_JSON — run gas-boy/scripts/deploy-to-orion.sh first" >&2
  exit 1
}

REGISTRY_ADDRESS="$(jq -r .address "$REGISTRY_JSON")"
POSTAGE_ADDRESS="$(jq -r .postage_stamp "$REGISTRY_JSON")"
RPC_URL="$(jq -r .rpc "$REGISTRY_JSON")"
CHAIN_ID="$(jq -r .chain_id "$REGISTRY_JSON")"

cd "$REPO_ROOT/gas-boy"

[[ -f .dev.vars ]] || cp .dev.vars.example .dev.vars

echo "gas-boy dev:"
echo "  REGISTRY_ADDRESS=$REGISTRY_ADDRESS"
echo "  POSTAGE_ADDRESS=$POSTAGE_ADDRESS"
echo "  RPC_URL=$RPC_URL  CHAIN_ID=$CHAIN_ID"
echo

exec wrangler dev \
  --var "REGISTRY_ADDRESS:$REGISTRY_ADDRESS" \
  --var "POSTAGE_ADDRESS:$POSTAGE_ADDRESS" \
  --var "RPC_URL:$RPC_URL" \
  --var "CHAIN_ID:$CHAIN_ID" \
  "$@"
