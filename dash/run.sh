#!/usr/bin/env bash
# Generate config.js from $RPC_URL (Gnosis Chain) and serve the dashboard on :8080.
# Usage: ./run.sh [port]
set -euo pipefail

cd "$(dirname "$0")"

# Back-compat: accept legacy SEP_RPC_URL too.
: "${RPC_URL:=${SEP_RPC_URL:-}}"

if [[ -z "$RPC_URL" ]]; then
  echo "error: RPC_URL not set in environment (Gnosis Chain RPC, e.g. wss://gnosis-rpc.publicnode.com)" >&2
  exit 1
fi

# Embed the RPC URL as a window global. config.js is gitignored.
printf 'window.RPC_URL = %s;\n' "$(printf '%s' "$RPC_URL" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" > config.js

PORT="${1:-8080}"
echo "open http://localhost:${PORT}/"
echo "  (defaults: account=0x10D9aBA7…21e1 Safe, no batches)"
echo "  add batches with ?batches=0xAAA…,0xBBB…"
exec python3 -m http.server "$PORT"
