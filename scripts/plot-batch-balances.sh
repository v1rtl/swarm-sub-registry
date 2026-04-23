#!/usr/bin/env bash
# Live tail: render two ASCII charts of VolumeRegistry state in the
# terminal, refreshed every new block.
#
#   1. Per-volume postage batch remaining balance (one subplot per
#      active volume, rolling history window).
#   2. Safe BZZ balance over the same history window.
#
# Both figures are produced via matplotlib with the `mpl_ascii` backend
# and repainted over the same terminal area on each tick. The registry
# is the source of truth: retired / pruned volumes vanish from the
# chart on the next tick; newly created volumes appear as new rows.
#
# No persistence. No event indexing. No archive requirements. Every
# datapoint is a live `eth_call` at the current tip.
#
# Usage:
#   ./scripts/plot-batch-balances.sh [flags]
#
# Connection:
#   --rpc-url URL    chain RPC   (or $RPC_URL)
#   --registry ADDR  VolumeRegistry address   (or $REGISTRY)
#   --safe ADDR      Safe to track BZZ balance for
#                    (default 0x1b5BB8C4Ea0E9B8a9BCd91Cc3B81513dB0bA8766)
#
# Runtime:
#   --poll-interval SECS  (default 12, ~1 Sepolia block)
#   --history N           rolling samples per series (default 200)
#   --duration SECS       auto-exit after N seconds (default: run forever)
#
# Both forms work under bash/zsh/fish. Flag form is fish-friendly.
#
# When stdout is piped (not a tty), ANSI redraws are suppressed; the
# script emits one JSON line per tick instead, for tee / jq pipelines.
set -euo pipefail

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------

RPC_URL="${RPC_URL-}"
REGISTRY="${REGISTRY-}"
SAFE="${SAFE-0x1b5BB8C4Ea0E9B8a9BCd91Cc3B81513dB0bA8766}"
POLL_INTERVAL=12
HISTORY_N=200
DURATION=0  # 0 = unbounded

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rpc-url) RPC_URL="$2"; shift 2;;
    --registry) REGISTRY="$2"; shift 2;;
    --safe) SAFE="$2"; shift 2;;
    --poll-interval) POLL_INTERVAL="$2"; shift 2;;
    --history) HISTORY_N="$2"; shift 2;;
    --duration) DURATION="$2"; shift 2;;
    -h|--help) sed -n '2,35p' "$0"; exit 0;;
    --) shift; break;;
    -*) echo "unknown flag: $1" >&2; exit 2;;
    *) echo "unexpected positional arg: $1" >&2; exit 2;;
  esac
done

if [[ -z "$RPC_URL" ]]; then
  echo "missing RPC_URL (--rpc-url flag or env var)" >&2; exit 2;
fi
if [[ -z "$REGISTRY" ]]; then
  echo "missing REGISTRY (--registry flag or env var)" >&2; exit 2;
fi

# ASCII URL check (catches '…' copy-paste artifacts).
if ! printf '%s' "$RPC_URL" | LC_ALL=C grep -q '^[[:print:]]*$'; then
  echo "RPC_URL contains non-ASCII characters. Use the full literal URL." >&2
  echo "  got: $RPC_URL" >&2
  exit 2
fi
if [[ ! "$RPC_URL" =~ ^https?:// ]]; then
  echo "RPC_URL must start with http:// or https://  (got: $RPC_URL)" >&2
  exit 2
fi
for v in "$REGISTRY" "$SAFE"; do
  if [[ ! "$v" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "invalid address: $v (expected 0x-prefixed 20-byte hex)" >&2
    exit 2
  fi
done

for bin in uv python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "missing tool: $bin" >&2; exit 1; }
done

export RPC_URL REGISTRY SAFE POLL_INTERVAL HISTORY_N DURATION

# ---------------------------------------------------------------------------
# The Python driver — lives in an embedded heredoc, runs under `uv run`
# with matplotlib + mpl_ascii pulled into a transient cache.
# ---------------------------------------------------------------------------

exec uv run --quiet \
  --with "matplotlib" --with "numpy" --with "mpl_ascii" \
  python3 - <<'PY'
import io
import json
import os
import shutil
import signal
import sys
import time
from collections import OrderedDict, deque
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

import matplotlib
matplotlib.use("module://mpl_ascii")
import matplotlib.pyplot as plt

# --------------------------- config -----------------------------------------

RPC = os.environ["RPC_URL"]
REGISTRY = os.environ["REGISTRY"].lower()
SAFE = os.environ["SAFE"].lower()
POLL_INTERVAL = int(os.environ["POLL_INTERVAL"])
HISTORY_N = int(os.environ["HISTORY_N"])
DURATION = int(os.environ["DURATION"])

IS_TTY = sys.stdout.isatty()

# --------------------------- JSON-RPC ---------------------------------------

_rpc_id = 0


def rpc(method, params):
    global _rpc_id
    _rpc_id += 1
    body = json.dumps(
        {"jsonrpc": "2.0", "id": _rpc_id, "method": method, "params": params}
    ).encode()
    req = Request(RPC, data=body, headers={"Content-Type": "application/json"})
    try:
        with urlopen(req, timeout=30) as r:
            resp = json.loads(r.read().decode())
    except (HTTPError, URLError) as e:
        raise RuntimeError(f"{method} HTTP error: {e}") from e
    if "error" in resp:
        raise RuntimeError(f"{method} error: {resp['error']}")
    return resp["result"]


def hex_int(s):
    if s in ("0x", "0x0", ""):
        return 0
    return int(s, 16)


def encode_uint256(n: int) -> str:
    return f"{n:064x}"


def encode_bytes32(b: str) -> str:
    s = b.lower()
    if s.startswith("0x"):
        s = s[2:]
    return s.rjust(64, "0")


def encode_address(a: str) -> str:
    s = a.lower()
    if s.startswith("0x"):
        s = s[2:]
    return s.rjust(64, "0")


# Function selectors (precomputed; keccak256("sig")[0:4]).
# Verified against `cast keccak` at authoring time.
SEL_POSTAGE = "0x6af20da1"  # postage() on VolumeRegistry
SEL_BZZ = "0x474a2f80"  # bzz() on VolumeRegistry
SEL_GET_ACTIVE_COUNT = "0xe7b4ed6a"  # getActiveVolumeCount()
SEL_GET_ACTIVE_VOLUMES = "0x68abda20"  # getActiveVolumes(uint256,uint256)
SEL_CURRENT_TOTAL_OUTPAYMENT = "0x51b17cd0"  # currentTotalOutPayment()
SEL_BATCHES = "0xc81e25ab"  # batches(bytes32)
SEL_BALANCE_OF = "0x70a08231"  # balanceOf(address)


def eth_call_latest(to, data):
    return rpc("eth_call", [{"to": to, "data": data}, "latest"])


def eth_block_number():
    return hex_int(rpc("eth_blockNumber", []))


# --------------------------- discovery --------------------------------------

# Read POSTAGE + BZZ addresses from the registry once; they are immutable.
try:
    postage_raw = eth_call_latest(REGISTRY, SEL_POSTAGE)
    bzz_raw = eth_call_latest(REGISTRY, SEL_BZZ)
except RuntimeError as e:
    print(f"failed to read registry.postage()/bzz(): {e}", file=sys.stderr)
    sys.exit(1)

POSTAGE = "0x" + postage_raw[-40:]
BZZ = "0x" + bzz_raw[-40:]

if POSTAGE == "0x" + "0" * 40 or BZZ == "0x" + "0" * 40:
    print(
        f"registry returned zero postage / bzz address (POSTAGE={POSTAGE}, BZZ={BZZ})",
        file=sys.stderr,
    )
    sys.exit(1)


print(
    f"[plot] RPC={RPC}",
    file=sys.stderr,
)
print(
    f"[plot] REGISTRY={REGISTRY}  POSTAGE={POSTAGE}  BZZ={BZZ}  SAFE={SAFE}",
    file=sys.stderr,
)
print(
    f"[plot] poll_interval={POLL_INTERVAL}s  history={HISTORY_N} samples  "
    f"duration={'∞' if DURATION == 0 else f'{DURATION}s'}  tty={IS_TTY}",
    file=sys.stderr,
)

# --------------------------- state reads ------------------------------------


def read_active_volumes():
    """Page getActiveVolumes into a list of (vid, owner, payer, chunkSigner,
    depth) tuples."""
    count_hex = eth_call_latest(REGISTRY, SEL_GET_ACTIVE_COUNT)
    count = hex_int(count_hex)
    out = []
    PAGE = 100
    offset = 0
    while offset < count:
        limit = min(PAGE, count - offset)
        data = SEL_GET_ACTIVE_VOLUMES + encode_uint256(offset) + encode_uint256(limit)
        raw = eth_call_latest(REGISTRY, data)
        buf = bytes.fromhex(raw[2:])
        array_offset = int.from_bytes(buf[0:32], "big")
        array_len = int.from_bytes(buf[array_offset : array_offset + 32], "big")
        p = array_offset + 32
        TUPLE_WORDS = 9  # vid, owner, payer, chunkSigner, createdAt, ttlExpiry, depth, status, accountActive
        for _ in range(array_len):
            words = buf[p : p + 32 * TUPLE_WORDS]
            vid = "0x" + words[0:32].hex()
            depth = words[32 * 6 + 31]
            out.append((vid, int(depth)))
            p += 32 * TUPLE_WORDS
        offset += limit
    return out


def read_batch_nb(vid: str):
    """Return (owner_bytes32, normalisedBalance) for a batch, or (None, 0)
    on RPC failure."""
    data = SEL_BATCHES + encode_bytes32(vid)
    try:
        raw = eth_call_latest(POSTAGE, data)
    except RuntimeError:
        return None, 0
    buf = bytes.fromhex(raw[2:])
    if len(buf) < 5 * 32:
        return None, 0
    owner_word = buf[0:32]
    nb = int.from_bytes(buf[4 * 32 : 5 * 32], "big")
    return owner_word, nb


def read_cto():
    return hex_int(eth_call_latest(POSTAGE, SEL_CURRENT_TOTAL_OUTPAYMENT))


def read_safe_balance():
    data = SEL_BALANCE_OF + encode_address(SAFE)
    return hex_int(eth_call_latest(BZZ, data))


# --------------------------- rendering --------------------------------------

# vid -> deque[(block, remaining_per_chunk)], most recent last
batch_hist: "OrderedDict[str, deque]" = OrderedDict()
safe_hist: deque = deque(maxlen=HISTORY_N)


def term_size():
    cols, rows = shutil.get_terminal_size(fallback=(140, 40))
    return max(80, cols), max(20, rows)


def figsize_for_rows(n_rows: int):
    cols, rows = term_size()
    # mpl_ascii maps ~10 chars/inch horizontally and ~5 rows/inch
    # vertically. Reserve a few rows for the Safe chart + divider.
    chart_budget_rows = max(8, rows - 14)
    per_row = max(3, chart_budget_rows // max(1, n_rows))
    return (cols / 10.0, (per_row * max(1, n_rows)) / 5.0)


def figsize_safe():
    cols, _ = term_size()
    return (cols / 10.0, 8 / 5.0)


def render_batch_figure(block_number: int, utc_iso: str) -> str:
    series = [(vid, list(batch_hist[vid])) for vid in batch_hist if batch_hist[vid]]
    if not series:
        return (
            f"Postage batch balances — block {block_number} @ {utc_iso}\n"
            "  (no active volumes)\n"
        )
    n = len(series)
    fig, axes = plt.subplots(
        nrows=n, ncols=1, figsize=figsize_for_rows(n), sharex=True, squeeze=False
    )
    axes = axes[:, 0]
    for i, (vid, points) in enumerate(series):
        ax = axes[i]
        xs = [p[0] for p in points]
        ys = [p[1] for p in points]
        ax.step(xs, ys, where="post")
        ax.set_title(f"{vid[:18]}...", loc="left")
        ax.set_ylabel("rem/chunk")
    axes[-1].set_xlabel("block")
    fig.suptitle(
        f"Postage batches — block {block_number} @ {utc_iso} | {n} active"
    )
    fig.tight_layout()
    # mpl_ascii's print_txt writes bytes, so we need BytesIO.
    buf = io.BytesIO()
    fig.savefig(buf, format="txt")
    plt.close(fig)
    return buf.getvalue().decode("utf-8")


def render_safe_figure(block_number: int, utc_iso: str, safe_bal: int) -> str:
    if not safe_hist:
        return (
            f"Safe BZZ balance — block {block_number} @ {utc_iso}\n"
            "  (no samples yet)\n"
        )
    fig, ax = plt.subplots(figsize=figsize_safe())
    xs = [p[0] for p in safe_hist]
    ys = [p[1] / 1e16 for p in safe_hist]  # 16-decimal BZZ → whole-BZZ units
    ax.step(xs, ys, where="post")
    ax.set_xlabel("block")
    ax.set_ylabel("BZZ")
    fig.suptitle(
        f"Safe {SAFE[:8]}...{SAFE[-6:]} — block {block_number} @ {utc_iso} | "
        f"{safe_bal / 1e16:.6f} BZZ"
    )
    fig.tight_layout()
    buf = io.BytesIO()
    fig.savefig(buf, format="txt")
    plt.close(fig)
    return buf.getvalue().decode("utf-8")


def repaint(block_number: int, utc_iso: str, safe_bal: int):
    if IS_TTY:
        # Clear + home cursor.
        sys.stdout.write("\033[2J\033[H")
    batch_txt = render_batch_figure(block_number, utc_iso)
    safe_txt = render_safe_figure(block_number, utc_iso, safe_bal)
    cols, _ = term_size()
    divider = "─" * cols + "\n"
    sys.stdout.write(batch_txt)
    sys.stdout.write("\n")
    sys.stdout.write(divider)
    sys.stdout.write(safe_txt)
    sys.stdout.flush()


def emit_json_tick(block_number: int, utc_iso: str, safe_bal: int):
    rec = {
        "kind": "plot-tick",
        "block": block_number,
        "ts": utc_iso,
        "safe_bal": str(safe_bal),  # bigint as string
        "volumes": {
            vid: str(batch_hist[vid][-1][1]) for vid in batch_hist if batch_hist[vid]
        },
    }
    print(json.dumps(rec), flush=True)


# --------------------------- signal handling --------------------------------

_running = True


def _stop(signum, _frame):
    global _running
    _running = False


signal.signal(signal.SIGINT, _stop)
signal.signal(signal.SIGTERM, _stop)

# --------------------------- main loop --------------------------------------

started = time.time()
last_block = -1
last_safe_bal = None

try:
    while _running:
        if DURATION and (time.time() - started) >= DURATION:
            break

        try:
            block = eth_block_number()
        except RuntimeError as e:
            print(f"[plot] eth_blockNumber failed: {e}", file=sys.stderr)
            time.sleep(POLL_INTERVAL)
            continue

        if block == last_block:
            time.sleep(1)
            continue
        last_block = block

        try:
            cto = read_cto()
            vols = read_active_volumes()
            safe_bal = read_safe_balance()
        except RuntimeError as e:
            print(f"[plot] state read failed: {e}", file=sys.stderr)
            time.sleep(POLL_INTERVAL)
            continue

        # Update batch history. Drop pruned / dead / absent.
        active_vids = set()
        for vid, _depth in vols:
            active_vids.add(vid)
            owner, nb = read_batch_nb(vid)
            if owner is None or owner == b"\x00" * 32:
                # Pruned on PostageStamp — drop from chart.
                batch_hist.pop(vid, None)
                continue
            rem = nb - cto
            if rem <= 0:
                # Batch dead — drop this frame.
                batch_hist.pop(vid, None)
                continue
            dq = batch_hist.setdefault(vid, deque(maxlen=HISTORY_N))
            dq.append((block, rem))

        # Drop volumes that have disappeared from the registry's active set
        # (retired since last poll).
        for vid in list(batch_hist):
            if vid not in active_vids:
                batch_hist.pop(vid, None)

        safe_hist.append((block, safe_bal))
        last_safe_bal = safe_bal

        utc_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        if IS_TTY:
            repaint(block, utc_iso, safe_bal)
        else:
            emit_json_tick(block, utc_iso, safe_bal)

        # Sleep until the next poll slot. Use a shorter sleep when we just
        # ticked so a fast block cadence doesn't oversleep a full interval.
        time.sleep(POLL_INTERVAL)
finally:
    if IS_TTY:
        sys.stdout.write("\033[2J\033[H")
        sys.stdout.flush()
    msg_block = last_block if last_block >= 0 else "<none>"
    msg_safe = (
        f"{last_safe_bal / 1e16:.6f} BZZ"
        if last_safe_bal is not None
        else "unknown"
    )
    print(
        f"[plot] stopped at block {msg_block}, Safe BZZ balance: {msg_safe}",
        file=sys.stderr,
    )
PY
