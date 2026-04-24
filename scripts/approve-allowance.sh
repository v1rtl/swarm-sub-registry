#!/usr/bin/env bash
# Propose a single Safe transaction: BZZ.approve(REGISTRY, APPROVE_AMOUNT).
# Same proposer flow as scripts/create-volumes.sh. No on-chain writes —
# only signs the Safe tx hash off-chain and POSTs it to the Safe
# Transaction Service for later owner confirmation and execution.
#
# Reads PRIVATE_KEY from ./.env.
set -euo pipefail

# --- Config ------------------------------------------------------------------

SAFE="0x10D9aBA7E0F5534757E85d1E35C46F170E8821e1"
REGISTRY="0x9639Ae4C7A8Fa9efE585738d516a3915DdD02aAD"
BZZ="0xdBF3Ea6F5beE45c02255B2c26a16F300502F68da"
RPC="wss://gnosis-rpc.publicnode.com"
TX_SERVICE="https://api.safe.global/tx-service/gno"

# Allowance amount. type(uint256).max — unlimited. Prefer a bounded figure
# (§12 of notes/usage.md) in production.
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

NONCE_RAW="$(cast call "$SAFE" "nonce()(uint256)" --rpc-url "$RPC")"
NONCE="${NONCE_RAW%% *}"

ALLOWANCE_RAW="$(cast call "$BZZ" "allowance(address,address)(uint256)" "$SAFE" "$REGISTRY" --rpc-url "$RPC")"
ALLOWANCE="${ALLOWANCE_RAW%% *}"

echo "Safe:           $SAFE"
echo "Registry:       $REGISTRY"
echo "BZZ:            $BZZ"
echo "RPC:            $RPC"
echo "Proposer EOA:   $SENDER"
echo "Safe nonce:     $NONCE"
echo "Current allowance: $ALLOWANCE"
echo "New allowance:     $APPROVE_AMOUNT"
echo

# --- Build and submit --------------------------------------------------------

DATA="$(cast calldata "approve(address,uint256)" "$REGISTRY" "$APPROVE_AMOUNT")"

SAFE_TX_HASH_RAW="$(cast call "$SAFE" \
  "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" \
  "$BZZ" 0 "$DATA" 0 0 0 0 "$ZERO" "$ZERO" "$NONCE" \
  --rpc-url "$RPC")"
SAFE_TX_HASH="${SAFE_TX_HASH_RAW%% *}"

SIG="$(cast wallet sign --no-hash "$SAFE_TX_HASH" --private-key "$PRIVATE_KEY")"

BODY=$(cat <<JSON
{"to":"$BZZ","value":"0","data":"$DATA","operation":0,"safeTxGas":"0","baseGas":"0","gasPrice":"0","gasToken":"$ZERO","refundReceiver":"$ZERO","nonce":$NONCE,"contractTransactionHash":"$SAFE_TX_HASH","sender":"$SENDER","signature":"$SIG"}
JSON
)

RESP_FILE="$(mktemp)"
CODE="$(curl -sS -o "$RESP_FILE" -w "%{http_code}" \
  -X POST "$TX_SERVICE/api/v1/safes/$SAFE/multisig-transactions/" \
  -H 'Content-Type: application/json' \
  -d "$BODY")"

echo "proposal  nonce=$NONCE  safeTxHash=$SAFE_TX_HASH  HTTP=$CODE"
if [[ "$CODE" != "201" && "$CODE" != "200" && "$CODE" != "202" ]]; then
  echo "  body:" >&2
  sed 's/^/    /' "$RESP_FILE" >&2
  rm -f "$RESP_FILE"
  exit 1
fi
rm -f "$RESP_FILE"

echo
echo "Queue: https://app.safe.global/transactions/queue?safe=gno:$SAFE"
