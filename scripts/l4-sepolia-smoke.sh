#!/usr/bin/env bash
# L4 Sepolia smoke — one-shot runbook.
#
# Phases:
#   0. Env + sanity: validate tools, RPC, Safe threshold/owners.
#   1. Deploy VolumeRegistry to Sepolia via forge script.
#   2. Owner (deployer EOA) calls designateFundingWallet(SAFE).
#   3. Redeploy gas-boy Worker with new REGISTRY_ADDRESS via wrangler --var.
#   4. Propose batched MultiSendCallOnly tx to Safe Transaction Service:
#        - BZZ.approve(registry, max)
#        - registry.confirmAuth(ownerA)
#      Outer Safe -> MultiSendCallOnly is DELEGATECALL (operation=1).
#      Inner entries are plain CALLs (operation=0 each).
#
# Steps 5-8 of TEST-PLAN §6.1 (createVolume for V1/V2/V3, cron warmup,
# dashboard smoke, end-state assertions) are deferred per user instruction.
#
# Required env:
#   DEPLOYER_PK          — private key of the deployer/proposer. Must be a
#                          Safe owner OR a registered delegate.
#
# Optional env (sane Sepolia defaults):
#   SEPOLIA_RPC
#   SAFE                 (Safe A address; payer)
#   BZZ                  (Sepolia BZZ token)
#   POSTAGE              (Sepolia PostageStamp)
#   MULTISEND_CALL_ONLY  (canonical Safe v1.4.1 deployment)
#   TX_SERVICE           (Safe Transaction Service base URL)
#   GRACE_BLOCKS         (VolumeRegistry constructor arg)
set -euo pipefail

# ---------------------------------------------------------------------------
# Phase 0: env + sanity
# ---------------------------------------------------------------------------
: "${DEPLOYER_PK:?DEPLOYER_PK env var required (deployer/proposer private key)}"

SEPOLIA_RPC="${SEPOLIA_RPC:-https://lb.drpc.live/sepolia/AnmpasF2C0JBqeAEzxVO8aRo7Ju0xlER8JS4QmlfqV1j}"
SAFE="${SAFE:-0x1b5BB8C4Ea0E9B8a9BCd91Cc3B81513dB0bA8766}"
BZZ="${BZZ:-0x543dDb01Ba47acB11de34891cD86B675F04840db}"
POSTAGE="${POSTAGE:-0xcdfdC3752caaA826fE62531E0000C40546eC56A6}"
MULTISEND_CALL_ONLY="${MULTISEND_CALL_ONLY:-0x9641d764fc13c8B624c04430C7356C1C7C8102e2}"
TX_SERVICE="${TX_SERVICE:-https://api.safe.global/tx-service/sep}"
GRACE_BLOCKS="${GRACE_BLOCKS:-12}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACTS_DIR="$REPO_ROOT/contracts"
GAS_BOY_DIR="$REPO_ROOT/gas-boy"
BROADCAST_FILE="$CONTRACTS_DIR/broadcast/DeployVolumeRegistry.s.sol/11155111/run-latest.json"

for bin in forge cast curl jq bun wrangler; do
  command -v "$bin" >/dev/null 2>&1 || { echo "missing tool: $bin" >&2; exit 1; }
done

DEPLOYER_ADDR="$(cast wallet address --private-key "$DEPLOYER_PK")"

echo "==========================================================="
echo "  L4 Sepolia smoke"
echo "-----------------------------------------------------------"
echo "  RPC:              $SEPOLIA_RPC"
echo "  Deployer:         $DEPLOYER_ADDR"
echo "  Safe A:           $SAFE"
echo "  BZZ:              $BZZ"
echo "  PostageStamp:     $POSTAGE"
echo "  MultiSendCallOnly:$MULTISEND_CALL_ONLY"
echo "  Tx service:       $TX_SERVICE"
echo "  graceBlocks:      $GRACE_BLOCKS"
echo "==========================================================="
echo

# --- Code presence at every contract we'll interact with ---
for addr_name in SAFE BZZ POSTAGE MULTISEND_CALL_ONLY; do
  addr="${!addr_name}"
  code="$(cast code "$addr" --rpc-url "$SEPOLIA_RPC")"
  if [[ -z "$code" || "$code" == "0x" ]]; then
    echo "no code at $addr_name=$addr on Sepolia — abort" >&2
    exit 1
  fi
done
echo "[phase 0] code present at all four known contracts"

# --- Safe introspection ---
SAFE_VERSION="$(cast call "$SAFE" "VERSION()(string)" --rpc-url "$SEPOLIA_RPC" | tr -d '"')"
SAFE_THRESHOLD="$(cast call "$SAFE" "getThreshold()(uint256)" --rpc-url "$SEPOLIA_RPC")"
SAFE_OWNERS_RAW="$(cast call "$SAFE" "getOwners()(address[])" --rpc-url "$SEPOLIA_RPC")"
echo "[phase 0] Safe VERSION=$SAFE_VERSION threshold=$SAFE_THRESHOLD"
echo "[phase 0] Safe owners: $SAFE_OWNERS_RAW"

if [[ "$SAFE_VERSION" != "1.4.1" ]]; then
  echo "[phase 0] WARNING: Safe version $SAFE_VERSION is not 1.4.1; MULTISEND_CALL_ONLY=$MULTISEND_CALL_ONLY may not be the canonical deployment for this Safe version. Override MULTISEND_CALL_ONLY env if the proposal fails." >&2
fi

# Is the deployer an owner? cast renders addresses as checksummed; compare
# case-insensitively against the owners array.
deployer_lc="$(echo "$DEPLOYER_ADDR" | tr '[:upper:]' '[:lower:]')"
owners_lc="$(echo "$SAFE_OWNERS_RAW" | tr '[:upper:]' '[:lower:]')"
IS_OWNER=0
if [[ "$owners_lc" == *"$deployer_lc"* ]]; then IS_OWNER=1; fi

IS_DELEGATE=0
if (( IS_OWNER == 0 )); then
  # Delegate check via Safe TX Service.
  delegates_json="$(curl -sS "$TX_SERVICE/api/v1/delegates/?safe=$SAFE" || true)"
  if echo "$delegates_json" | jq -e --arg a "$deployer_lc" \
       '.results // [] | map(.delegate|ascii_downcase) | index($a)' >/dev/null 2>&1; then
    IS_DELEGATE=1
  fi
fi

echo "[phase 0] deployer is_owner=$IS_OWNER is_delegate=$IS_DELEGATE"

if (( IS_OWNER == 0 && IS_DELEGATE == 0 )); then
  echo >&2
  echo "ABORT: $DEPLOYER_ADDR is neither a Safe owner nor a registered delegate for $SAFE." >&2
  echo "The Safe Transaction Service will reject the proposal with HTTP 422." >&2
  echo "Register the deployer as a delegate (requires an existing owner's signature)" >&2
  echo "or run this script with a key that IS an owner." >&2
  exit 1
fi

if (( SAFE_THRESHOLD > 1 )); then
  echo "[phase 0] threshold=$SAFE_THRESHOLD > 1 — proposal will queue pending; co-signer(s) must confirm in Safe{Wallet}"
fi

echo

# ---------------------------------------------------------------------------
# Phase 1: deploy VolumeRegistry
# ---------------------------------------------------------------------------
echo "[phase 1] deploying VolumeRegistry to Sepolia..."

cd "$CONTRACTS_DIR"
BZZ="$BZZ" POSTAGE_STAMP="$POSTAGE" PRIVATE_KEY="$DEPLOYER_PK" \
  GRACE_BLOCKS="$GRACE_BLOCKS" \
  forge script script/DeployVolumeRegistry.s.sol:DeployVolumeRegistry \
    --rpc-url "$SEPOLIA_RPC" \
    --broadcast \
    --silent

[[ -f "$BROADCAST_FILE" ]] || {
  echo "broadcast file not found: $BROADCAST_FILE" >&2; exit 1;
}

REGISTRY="$(jq -r '[.transactions[]|select(.transactionType=="CREATE")][-1].contractAddress' "$BROADCAST_FILE")"
if [[ -z "$REGISTRY" || "$REGISTRY" == "null" ]]; then
  echo "could not extract registry address from $BROADCAST_FILE" >&2; exit 1;
fi
REGISTRY="$(cast --to-checksum-address "$REGISTRY")"

REG_CODE="$(cast code "$REGISTRY" --rpc-url "$SEPOLIA_RPC")"
[[ -n "$REG_CODE" && "$REG_CODE" != "0x" ]] || { echo "no code at registry $REGISTRY" >&2; exit 1; }

REG_GRACE="$(cast call "$REGISTRY" "graceBlocks()(uint64)" --rpc-url "$SEPOLIA_RPC")"
REG_POSTAGE="$(cast call "$REGISTRY" "postage()(address)" --rpc-url "$SEPOLIA_RPC")"
echo "[phase 1] VolumeRegistry = $REGISTRY"
echo "[phase 1]   graceBlocks = $REG_GRACE"
echo "[phase 1]   postage     = $REG_POSTAGE"

# Sanity: constructor wired correctly.
if [[ "$REG_GRACE" != "$GRACE_BLOCKS" ]]; then
  echo "graceBlocks mismatch: on-chain=$REG_GRACE expected=$GRACE_BLOCKS" >&2; exit 1;
fi
# cast returns checksummed; compare case-insensitively.
if [[ "$(echo "$REG_POSTAGE" | tr '[:upper:]' '[:lower:]')" != "$(echo "$POSTAGE" | tr '[:upper:]' '[:lower:]')" ]]; then
  echo "postage address mismatch: on-chain=$REG_POSTAGE expected=$POSTAGE" >&2; exit 1;
fi

cd "$REPO_ROOT"
echo

# ---------------------------------------------------------------------------
# Phase 2: owner designates Safe (plain EOA tx, not a Safe tx)
# ---------------------------------------------------------------------------
echo "[phase 2] owner $DEPLOYER_ADDR designates Safe $SAFE as payer..."

cast send "$REGISTRY" "designateFundingWallet(address)" "$SAFE" \
  --private-key "$DEPLOYER_PK" \
  --rpc-url "$SEPOLIA_RPC" \
  >/dev/null

DESIGNATED="$(cast call "$REGISTRY" "designated(address)(address)" "$DEPLOYER_ADDR" --rpc-url "$SEPOLIA_RPC")"
DESIGNATED_LC="$(echo "$DESIGNATED" | tr '[:upper:]' '[:lower:]')"
SAFE_LC="$(echo "$SAFE" | tr '[:upper:]' '[:lower:]')"
if [[ "$DESIGNATED_LC" != "$SAFE_LC" ]]; then
  echo "designated(owner) = $DESIGNATED, expected $SAFE — abort" >&2; exit 1;
fi
echo "[phase 2] designated[$DEPLOYER_ADDR] = $DESIGNATED — OK"
echo

# ---------------------------------------------------------------------------
# Phase 3: redeploy gas-boy Worker with new REGISTRY_ADDRESS via --var
# ---------------------------------------------------------------------------
echo "[phase 3] redeploying gas-boy production Worker with REGISTRY_ADDRESS=$REGISTRY..."

cd "$GAS_BOY_DIR"
bun install --silent

# wrangler's --var overrides wrangler.jsonc's vars for this deploy without
# mutating the committed config. POSTAGE_ADDRESS is already Sepolia's in
# wrangler.jsonc but we override it anyway for idempotence.
wrangler deploy --env production \
  --var "REGISTRY_ADDRESS:$REGISTRY" \
  --var "POSTAGE_ADDRESS:$POSTAGE"

cd "$REPO_ROOT"
echo "[phase 3] gas-boy Worker redeployed"
echo

# ---------------------------------------------------------------------------
# Phase 4: propose batched MultiSendCallOnly tx to Safe TX Service
# ---------------------------------------------------------------------------
echo "[phase 4] preparing Safe proposal (approve + confirmAuth via MultiSendCallOnly)..."

SAFE_NONCE="$(cast call "$SAFE" "nonce()(uint256)" --rpc-url "$SEPOLIA_RPC")"
echo "[phase 4] Safe nonce = $SAFE_NONCE"

# Max uint256 as 0x-prefixed hex string.
MAX_UINT=0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff

# Inner calldatas.
APPROVE_DATA="$(cast calldata "approve(address,uint256)" "$REGISTRY" "$MAX_UINT")"
CONFIRM_DATA="$(cast calldata "confirmAuth(address)" "$DEPLOYER_ADDR")"

# Pack a single MultiSend entry: operation(1) ∥ to(20) ∥ value(32) ∥ dataLen(32) ∥ data.
# MultiSendCallOnly requires operation=0 for every inner entry (rejects DELEGATECALL).
pack_entry() {
  local to="$1" data="$2"
  local to_nox="${to#0x}"
  local data_nox="${data#0x}"
  local data_bytelen=$(( ${#data_nox} / 2 ))
  printf '00%s%064x%064x%s' "$to_nox" 0 "$data_bytelen" "$data_nox"
}

MULTISEND_PAYLOAD="0x$(pack_entry "$BZZ" "$APPROVE_DATA")$(pack_entry "$REGISTRY" "$CONFIRM_DATA")"
OUTER_DATA="$(cast calldata "multiSend(bytes)" "$MULTISEND_PAYLOAD")"

# Compute Safe transaction hash. operation=1 (DELEGATECALL) because the
# MultiSend library reverts on direct CALL.
ZERO_ADDR=0x0000000000000000000000000000000000000000
SAFE_TX_HASH="$(cast call "$SAFE" \
  "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" \
  "$MULTISEND_CALL_ONLY" 0 "$OUTER_DATA" 1 0 0 0 \
  "$ZERO_ADDR" "$ZERO_ADDR" "$SAFE_NONCE" \
  --rpc-url "$SEPOLIA_RPC")"
echo "[phase 4] safeTxHash = $SAFE_TX_HASH"

SIG="$(cast wallet sign --no-hash "$SAFE_TX_HASH" --private-key "$DEPLOYER_PK")"

echo "[phase 4] POSTing proposal (operation=1, DELEGATECALL)..."

# Build the JSON body via jq so strings with embedded hex don't break quoting.
BODY="$(jq -n \
  --arg to "$MULTISEND_CALL_ONLY" \
  --arg data "$OUTER_DATA" \
  --arg nonce "$SAFE_NONCE" \
  --arg hash "$SAFE_TX_HASH" \
  --arg sender "$DEPLOYER_ADDR" \
  --arg sig "$SIG" \
  --arg zero "$ZERO_ADDR" \
  '{to:$to, value:"0", data:$data, operation:1,
    safeTxGas:"0", baseGas:"0", gasPrice:"0",
    gasToken:$zero, refundReceiver:$zero,
    nonce:($nonce|tonumber),
    contractTransactionHash:$hash, sender:$sender, signature:$sig}')"

RESP_FILE="$(mktemp)"
HTTP_CODE="$(curl -sS -o "$RESP_FILE" -w '%{http_code}' -X POST \
  "$TX_SERVICE/api/v1/safes/$SAFE/multisig-transactions/" \
  -H "Content-Type: application/json" \
  --data "$BODY")"
RESP_BODY="$(cat "$RESP_FILE")"
rm -f "$RESP_FILE"

echo "[phase 4] HTTP $HTTP_CODE"
if [[ "$HTTP_CODE" != "201" && "$HTTP_CODE" != "200" && "$HTTP_CODE" != "202" ]]; then
  echo "[phase 4] proposal REJECTED:" >&2
  echo "$RESP_BODY" | jq . 2>/dev/null || echo "$RESP_BODY" >&2
  exit 1
fi

# Fetch canonical record.
sleep 2
TX_RECORD="$(curl -sS "$TX_SERVICE/api/v1/multisig-transactions/$SAFE_TX_HASH/" || true)"
N_CONF="$(echo "$TX_RECORD" | jq -r '.confirmations | length' 2>/dev/null || echo "?")"
N_REQ="$(echo "$TX_RECORD" | jq -r '.confirmationsRequired // empty' 2>/dev/null)"
[[ -z "$N_REQ" ]] && N_REQ="$SAFE_THRESHOLD"

echo
echo "==========================================================="
echo "  L4 smoke complete (phases 1-4)"
echo "-----------------------------------------------------------"
echo "  VolumeRegistry:      $REGISTRY"
echo "  gas-boy redeployed:  wrangler production (REGISTRY_ADDRESS overridden)"
echo "  Safe proposal:"
echo "    safeTxHash:        $SAFE_TX_HASH"
echo "    nonce:             $SAFE_NONCE"
echo "    confirmations:     $N_CONF / $N_REQ"
echo "    Safe{Wallet} UI:   https://app.safe.global/transactions/queue?safe=sep:$SAFE"
echo "-----------------------------------------------------------"
echo "  Remaining (deferred per TEST-PLAN §6.1 steps 5-8):"
echo "    - createVolume for V1/V2/V3"
echo "    - gas-boy cron warmup (≥2 cycles)"
echo "    - dashboard smoke"
echo "    - end-state assertions"
echo "==========================================================="
