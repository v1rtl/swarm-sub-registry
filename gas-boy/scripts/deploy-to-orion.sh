#!/usr/bin/env bash
# Deploy VolumeRegistry to the orion anvil devnet.
#
# Reads:
#   orion/state/chain.json       (rpc, deployer_key)
#   orion/state/deployment.json  (Token, PostageStamp addresses)
#
# Writes:
#   orion/state/registry.json    ({address, chain_id, rpc, deployer, bzz, postage_stamp})
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHAIN_JSON="$REPO_ROOT/orion/state/chain.json"
DEPLOY_JSON="$REPO_ROOT/orion/state/deployment.json"
REGISTRY_JSON="$REPO_ROOT/orion/state/registry.json"

command -v jq    >/dev/null || { echo "jq required" >&2; exit 1; }
command -v forge >/dev/null || { echo "forge required" >&2; exit 1; }
command -v cast  >/dev/null || { echo "cast required"  >&2; exit 1; }

[[ -f "$CHAIN_JSON"  ]] || { echo "missing $CHAIN_JSON — run 'uv run orion up --profile swarm' first" >&2; exit 1; }
[[ -f "$DEPLOY_JSON" ]] || { echo "missing $DEPLOY_JSON — run 'uv run orion deploy --profile swarm' first" >&2; exit 1; }

RPC="$(jq -r .rpc "$CHAIN_JSON")"
CHAIN_ID="$(jq -r .chain_id "$CHAIN_JSON")"
DEPLOYER_KEY="0x$(jq -r .deployer_key "$CHAIN_JSON")"
DEPLOYER_ADDR="$(jq -r .deployer_addr "$CHAIN_JSON")"
BZZ="$(jq -r .contracts.Token "$DEPLOY_JSON")"
POSTAGE_STAMP="$(jq -r .contracts.PostageStamp "$DEPLOY_JSON")"

echo "orion rpc:         $RPC"
echo "orion chain_id:    $CHAIN_ID"
echo "BZZ token:         $BZZ"
echo "PostageStamp:      $POSTAGE_STAMP"
echo "Deployer:          $DEPLOYER_ADDR"
echo

cd "$REPO_ROOT/contracts"

# `forge script --broadcast` + `--json` emits the run metadata we need.
# We capture the returns by parsing broadcast/run-latest.json.
BZZ="$BZZ" POSTAGE_STAMP="$POSTAGE_STAMP" PRIVATE_KEY="$DEPLOYER_KEY" \
  forge script script/DeployVolumeRegistry.s.sol:DeployVolumeRegistry \
    --rpc-url "$RPC" \
    --broadcast \
    --silent

# The registry is the single CREATE tx in the latest broadcast for this chain.
BROADCAST="$REPO_ROOT/contracts/broadcast/DeployVolumeRegistry.s.sol/$CHAIN_ID/run-latest.json"
[[ -f "$BROADCAST" ]] || { echo "broadcast file not found at $BROADCAST" >&2; exit 1; }

REGISTRY_ADDR="$(jq -r '[.transactions[] | select(.transactionType=="CREATE")][0].contractAddress' "$BROADCAST")"
if [[ -z "$REGISTRY_ADDR" || "$REGISTRY_ADDR" == "null" ]]; then
  echo "could not extract registry address from $BROADCAST" >&2
  exit 1
fi

# Sanity: contract has code at that address.
CODE="$(cast code "$REGISTRY_ADDR" --rpc-url "$RPC")"
[[ ${#CODE} -gt 2 ]] || { echo "no code at $REGISTRY_ADDR" >&2; exit 1; }

mkdir -p "$(dirname "$REGISTRY_JSON")"
jq -n \
  --arg address "$REGISTRY_ADDR" \
  --arg chain_id "$CHAIN_ID" \
  --arg rpc "$RPC" \
  --arg deployer "$DEPLOYER_ADDR" \
  --arg bzz "$BZZ" \
  --arg postage_stamp "$POSTAGE_STAMP" \
  '{address:$address, chain_id:($chain_id|tonumber), rpc:$rpc, deployer:$deployer, bzz:$bzz, postage_stamp:$postage_stamp}' \
  > "$REGISTRY_JSON"

echo
echo "VolumeRegistry deployed at: $REGISTRY_ADDR"
echo "State written to: $REGISTRY_JSON"
