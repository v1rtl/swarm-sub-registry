#!/usr/bin/env bash
# Demo flow continuation (steps 2-4 of the registry demo). Each subcommand
# queues a single Safe transaction proposal via the Safe Transaction Service.
#
# Subcommands:
#   list                 — list volumes owned by the Safe
#   delete <volumeId>    — propose deleteVolume(volumeId) on the registry
#   revoke               — propose BZZ.approve(registry, 0)
#   restore              — propose BZZ.approve(registry, uint256.max)
#
# Typical demo sequence (after the initial create-volumes batch has executed):
#   1. ./scripts/demo-flow.sh list                  # find volume A's id
#   2. ./scripts/demo-flow.sh delete <A>            # watch A's batch die down
#   3. ./scripts/demo-flow.sh revoke                # gas-boy triggers will TopupSkipped(PaymentFailed)
#   4. ./scripts/demo-flow.sh restore               # before B and C die, restore allowance
#
# Reads PRIVATE_KEY from ./.env.
set -euo pipefail

# --- Config ------------------------------------------------------------------

SAFE="0x10D9aBA7E0F5534757E85d1E35C46F170E8821e1"
REGISTRY="0x9639Ae4C7A8Fa9efE585738d516a3915DdD02aAD"
BZZ="0xdBF3Ea6F5beE45c02255B2c26a16F300502F68da"
RPC="wss://gnosis-rpc.publicnode.com"
TX_SERVICE="https://api.safe.global/tx-service/gno"

APPROVE_AMOUNT_MAX="115792089237316195423570985008687907853269984665640564039457584007913129639935"

ZERO="0x0000000000000000000000000000000000000000"

# --- Usage -------------------------------------------------------------------

usage() {
  cat <<EOF
usage: $0 <subcommand> [args]

subcommands:
  list                  list volumes owned by the Safe
  delete <volumeId>     propose deleteVolume(volumeId)
  revoke                propose BZZ.approve(registry, 0)
  restore               propose BZZ.approve(registry, uint256.max)
EOF
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }
SUBCMD="$1"; shift

# --- Locate and load .env (except for 'list') --------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

load_env() {
  local ENV_FILE=""
  local candidate
  for candidate in "$PWD/.env" "$REPO_ROOT/.env" "$SCRIPT_DIR/.env"; do
    if [[ -f "$candidate" ]]; then ENV_FILE="$candidate"; break; fi
  done
  [[ -n "$ENV_FILE" ]] || { echo "error: .env not found" >&2; exit 1; }
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
  [[ -n "${PRIVATE_KEY:-}" ]] || { echo "error: PRIVATE_KEY not set in $ENV_FILE" >&2; exit 1; }
}

command -v cast >/dev/null || { echo "error: cast not found in PATH" >&2; exit 1; }
command -v curl >/dev/null || { echo "error: curl not found in PATH" >&2; exit 1; }

# --- Proposal helper ---------------------------------------------------------

# propose_call <to> <data> — sign and submit a single Safe tx with operation=0.
propose_call() {
  local TO="$1" DATA="$2"
  local SENDER NONCE_RAW NONCE H_RAW H SIG BODY CODE RESP_FILE

  SENDER="$(cast wallet address --private-key "$PRIVATE_KEY")"
  NONCE_RAW="$(cast call "$SAFE" "nonce()(uint256)" --rpc-url "$RPC")"
  NONCE="${NONCE_RAW%% *}"

  H_RAW="$(cast call "$SAFE" \
    "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" \
    "$TO" 0 "$DATA" 0 0 0 0 "$ZERO" "$ZERO" "$NONCE" \
    --rpc-url "$RPC")"
  H="${H_RAW%% *}"

  SIG="$(cast wallet sign --no-hash "$H" --private-key "$PRIVATE_KEY")"

  BODY=$(cat <<JSON
{"to":"$TO","value":"0","data":"$DATA","operation":0,"safeTxGas":"0","baseGas":"0","gasPrice":"0","gasToken":"$ZERO","refundReceiver":"$ZERO","nonce":$NONCE,"contractTransactionHash":"$H","sender":"$SENDER","signature":"$SIG"}
JSON
)

  RESP_FILE="$(mktemp)"
  CODE="$(curl -sS -o "$RESP_FILE" -w "%{http_code}" \
    -X POST "$TX_SERVICE/api/v1/safes/$SAFE/multisig-transactions/" \
    -H 'Content-Type: application/json' \
    -d "$BODY")"

  echo "proposal  nonce=$NONCE  safeTxHash=$H  HTTP=$CODE"
  if [[ "$CODE" != "201" && "$CODE" != "200" && "$CODE" != "202" ]]; then
    echo "  body:" >&2
    sed 's/^/    /' "$RESP_FILE" >&2
    rm -f "$RESP_FILE"
    exit 1
  fi
  rm -f "$RESP_FILE"

  echo "Queue: https://app.safe.global/transactions/queue?safe=gno:$SAFE"
}

# --- Subcommands -------------------------------------------------------------

case "$SUBCMD" in
  list)
    COUNT_RAW="$(cast call "$REGISTRY" "getActiveVolumeCount()(uint256)" --rpc-url "$RPC")"
    COUNT="${COUNT_RAW%% *}"
    echo "Active volumes in registry: $COUNT"
    [[ "$COUNT" == "0" ]] && exit 0

    # Pull all pages up to COUNT. Paginate in chunks of 50 to be safe.
    LIMIT=50
    OFFSET=0
    echo
    echo "Volumes owned by $SAFE:"
    echo "  idx  volumeId                                                            depth  ttlExpiry    active"
    while (( OFFSET < COUNT )); do
      # Each tuple prints as "(volumeId, owner, payer, chunkSigner, createdAt, ttlExpiry, depth, status, accountActive)".
      RAW_OUT="$(cast call "$REGISTRY" \
        "getActiveVolumes(uint256,uint256)((bytes32,address,address,address,uint64,uint64,uint8,uint8,bool)[])" \
        "$OFFSET" "$LIMIT" --rpc-url "$RPC")"
      # Each tuple is printed as "(volumeId, owner, payer, chunkSigner, createdAt, ttlExpiry, depth, status, accountActive)".
      # Strip the outer brackets then split.
      STRIPPED="${RAW_OUT#[}"; STRIPPED="${STRIPPED%]}"
      # Split on "), (" — keep parentheses, then process.
      python3 - "$STRIPPED" "$SAFE" "$OFFSET" <<'PY'
import sys, re
raw, safe, off = sys.argv[1], sys.argv[2].lower(), int(sys.argv[3])
# Extract tuples: top-level parens only.
tuples = re.findall(r"\(([^()]*)\)", raw)
for i, t in enumerate(tuples):
    parts = [p.strip() for p in t.split(",")]
    if len(parts) < 9:
        continue
    volumeId, owner, payer, chunkSigner, createdAt, ttlExpiry, depth, status, active = parts[:9]
    if owner.lower() != safe:
        continue
    print(f"  {off+i:3d}  {volumeId}  {depth:>5}  {ttlExpiry:>10}  {active}")
PY
      OFFSET=$((OFFSET + LIMIT))
      # If fewer than LIMIT returned, done.
      # Approximate by counting '(' in raw output.
      RET_COUNT=$(grep -o '(' <<< "$RAW_OUT" | wc -l | tr -d ' ')
      (( RET_COUNT < LIMIT )) && break
    done
    ;;

  delete)
    [[ $# -ge 1 ]] || { echo "error: delete requires a volumeId" >&2; usage >&2; exit 2; }
    VOLUME_ID="$1"
    [[ "$VOLUME_ID" =~ ^0x[0-9a-fA-F]{64}$ ]] || { echo "error: volumeId must be 0x + 64 hex chars" >&2; exit 2; }
    load_env
    echo "Proposing deleteVolume($VOLUME_ID) on $REGISTRY"
    DATA="$(cast calldata "deleteVolume(bytes32)" "$VOLUME_ID")"
    propose_call "$REGISTRY" "$DATA"
    ;;

  revoke)
    load_env
    echo "Proposing BZZ.approve($REGISTRY, 0)"
    DATA="$(cast calldata "approve(address,uint256)" "$REGISTRY" 0)"
    propose_call "$BZZ" "$DATA"
    ;;

  restore)
    load_env
    echo "Proposing BZZ.approve($REGISTRY, uint256.max)"
    DATA="$(cast calldata "approve(address,uint256)" "$REGISTRY" "$APPROVE_AMOUNT_MAX")"
    propose_call "$BZZ" "$DATA"
    ;;

  *)
    usage >&2
    exit 2
    ;;
esac
