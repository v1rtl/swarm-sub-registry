#!/usr/bin/env bash
# Propose a single Safe transaction that batches (via MultiSendCallOnly):
#   - optionally: BZZ.approve(REGISTRY, APPROVE_AMOUNT)  [only if current allowance is 0]
#   - createVolume × 3
#
# The Safe transaction itself is a DELEGATECALL to MultiSendCallOnly, which
# executes each inner call with CALL semantics from the Safe. No on-chain
# writes happen from this script — it only signs the Safe tx hash off-chain
# and POSTs it to the Safe Transaction Service for later owner confirmation
# and execution.
#
# Reads PRIVATE_KEY from ./.env.
set -euo pipefail

# --- Config ------------------------------------------------------------------

SAFE="0x10D9aBA7E0F5534757E85d1E35C46F170E8821e1"
REGISTRY="0x9639Ae4C7A8Fa9efE585738d516a3915DdD02aAD"        # Gnosis mainnet, per contracts/broadcast
BZZ="0xdBF3Ea6F5beE45c02255B2c26a16F300502F68da"             # Gnosis mainnet BZZ
MULTISEND="0x40A2aCCbd92BCA938b02010E17A5b8929b49130D"       # MultiSendCallOnly v1.3.0, canonical
RPC="wss://gnosis-rpc.publicnode.com"
TX_SERVICE="https://api.safe.global/tx-service/gno"

DEPTH=22
BUCKET_DEPTH=16
IMMUTABLE=false
TTL_DAYS=30
# Allowance to set if current allowance is zero. type(uint256).max — unlimited.
# Prefer a bounded figure (§12 of notes/usage.md) in production.
APPROVE_AMOUNT="115792089237316195423570985008687907853269984665640564039457584007913129639935"

ZERO="0x0000000000000000000000000000000000000000"

# --- Locate and load .env ----------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_FILE=""
for candidate in "$PWD/.env" "$REPO_ROOT/.env" "$SCRIPT_DIR/.env"; do
  if [[ -f "$candidate" ]]; then ENV_FILE="$candidate"; break; fi
done
[[ -n "$ENV_FILE" ]] || { echo "error: .env not found" >&2; exit 1; }

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a
[[ -n "${PRIVATE_KEY:-}" ]] || { echo "error: PRIVATE_KEY not set in $ENV_FILE" >&2; exit 1; }

command -v cast >/dev/null || { echo "error: cast not found in PATH" >&2; exit 1; }
command -v curl >/dev/null || { echo "error: curl not found in PATH" >&2; exit 1; }

# --- Derived values ----------------------------------------------------------

SENDER="$(cast wallet address --private-key "$PRIVATE_KEY")"
CHUNK_SIGNER="$SENDER"
TTL_EXPIRY=$(( $(date +%s) + TTL_DAYS * 86400 ))

NONCE_RAW="$(cast call "$SAFE" "nonce()(uint256)" --rpc-url "$RPC")"
NONCE="${NONCE_RAW%% *}"

ALLOWANCE_RAW="$(cast call "$BZZ" "allowance(address,address)(uint256)" "$SAFE" "$REGISTRY" --rpc-url "$RPC")"
ALLOWANCE="${ALLOWANCE_RAW%% *}"

echo "Safe:           $SAFE"
echo "Registry:       $REGISTRY"
echo "BZZ:            $BZZ"
echo "MultiSend:      $MULTISEND"
echo "RPC:            $RPC"
echo "Proposer EOA:   $SENDER"
echo "Chunk signer:   $CHUNK_SIGNER"
echo "Depth:          $DEPTH  (bucketDepth=$BUCKET_DEPTH, immutable=$IMMUTABLE)"
echo "TTL expiry:     $TTL_EXPIRY  (now + ${TTL_DAYS}d)"
echo "Safe nonce:     $NONCE"
echo "BZZ allowance:  $ALLOWANCE"
echo

# --- Helpers -----------------------------------------------------------------

# Pack one inner transaction for MultiSend(CallOnly):
#   operation(1) | to(20) | value(32) | dataLen(32) | data(dataLen)
# All hex, no 0x prefix. Only CALL (op=0) is allowed by MultiSendCallOnly.
pack_tx() {
  local to=$1 data=$2
  local to_hex=${to#0x}
  local data_hex=${data#0x}
  # to_hex must be 40 hex chars; guard against anything weird.
  if [[ ${#to_hex} -ne 40 ]]; then
    echo "pack_tx: bad address length for $to" >&2; return 1
  fi
  # dataLength in bytes = data_hex length / 2
  local data_len=$(( ${#data_hex} / 2 ))
  # op=00, value=0 (64 hex zeros), dataLen (64 hex), data
  printf "00%s%064x%064x%s" "$to_hex" 0 "$data_len" "$data_hex"
}

# --- Build inner calls -------------------------------------------------------

PACKED=""

if [[ "$ALLOWANCE" == "0" ]]; then
  echo "allowance is zero → including approve in the batch"
  APPROVE_DATA="$(cast calldata "approve(address,uint256)" "$REGISTRY" "$APPROVE_AMOUNT")"
  PACKED+="$(pack_tx "$BZZ" "$APPROVE_DATA")"
else
  echo "allowance > 0 → skipping approve"
fi

CREATE_DATA="$(cast calldata \
  "createVolume(address,uint8,uint8,uint64,bool)" \
  "$CHUNK_SIGNER" "$DEPTH" "$BUCKET_DEPTH" "$TTL_EXPIRY" "$IMMUTABLE")"

for _ in 1 2 3; do
  PACKED+="$(pack_tx "$REGISTRY" "$CREATE_DATA")"
done

# --- Wrap in multiSend(bytes) and propose -----------------------------------

MULTISEND_DATA="$(cast calldata "multiSend(bytes)" "0x$PACKED")"

SAFE_TX_HASH_RAW="$(cast call "$SAFE" \
  "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" \
  "$MULTISEND" 0 "$MULTISEND_DATA" 1 0 0 0 "$ZERO" "$ZERO" "$NONCE" \
  --rpc-url "$RPC")"
SAFE_TX_HASH="${SAFE_TX_HASH_RAW%% *}"

SIG="$(cast wallet sign --no-hash "$SAFE_TX_HASH" --private-key "$PRIVATE_KEY")"

BODY=$(cat <<JSON
{"to":"$MULTISEND","value":"0","data":"$MULTISEND_DATA","operation":1,"safeTxGas":"0","baseGas":"0","gasPrice":"0","gasToken":"$ZERO","refundReceiver":"$ZERO","nonce":$NONCE,"contractTransactionHash":"$SAFE_TX_HASH","sender":"$SENDER","signature":"$SIG"}
JSON
)

RESP_FILE="$(mktemp)"
CODE="$(curl -sS -o "$RESP_FILE" -w "%{http_code}" \
  -X POST "$TX_SERVICE/api/v1/safes/$SAFE/multisig-transactions/" \
  -H 'Content-Type: application/json' \
  -d "$BODY")"

echo
echo "proposal  nonce=$NONCE  safeTxHash=$SAFE_TX_HASH  HTTP=$CODE"
if [[ "$CODE" != "201" && "$CODE" != "200" && "$CODE" != "202" ]]; then
  echo "  body:" >&2
  sed 's/^/    /' "$RESP_FILE" >&2
  rm -f "$RESP_FILE"
  exit 1
fi
rm -f "$RESP_FILE"

echo
echo "Queued one MultiSend proposal bundling $([[ "$ALLOWANCE" == "0" ]] && echo "approve + ")3× createVolume."
echo "Queue: https://app.safe.global/transactions/queue?safe=gno:$SAFE"
