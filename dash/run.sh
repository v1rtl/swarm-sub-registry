#!/usr/bin/env bash
# Generate config.js from $SEP_RPC_URL and serve the dashboard on :8080.
# Usage: ./run.sh [port]
set -euo pipefail

cd "$(dirname "$0")"

if [[ -z "${SEP_RPC_URL:-}" ]]; then
  echo "error: SEP_RPC_URL not set in environment" >&2
  exit 1
fi

# Embed the RPC URL as a window global. config.js is gitignored.
printf 'window.SEP_RPC_URL = %s;\n' "$(printf '%s' "$SEP_RPC_URL" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" > config.js

PORT="${1:-8080}"
echo "open http://localhost:${PORT}/"
echo "  (defaults: account=0x1b5BB8C4…8766, no batches)"
echo "  add batches with ?batches=0xAAA…,0xBBB…"
exec python3 -m http.server "$PORT"
