#!/usr/bin/env bash
# Live tail: render two unicode charts of VolumeRegistry state in the
# terminal, refreshed every new block.
#
#   1. Per-volume postage batch remaining balance (one subplot per
#      active volume, rolling history window).
#   2. Safe BZZ balance over the same history window.
#
# Rendering is done with `plotext` (braille-dot terminal plots, built-in
# subplots, `plt.build()` for string output). The output is written
# inside the terminal's alternate screen buffer (vim/less pattern) so
# the repaint stays in place and the pre-run terminal scrollback is
# restored on exit. The registry is the source of truth: retired /
# pruned volumes vanish from the chart on the next tick; newly created
# volumes appear as new rows.
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
#   --poll-interval SECS  (default 2)
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
SAFE="${SAFE-0x10D9aBA7E0F5534757E85d1E35C46F170E8821e1}"
POLL_INTERVAL=2
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
  --with "plotext" \
  python3 - <<'PY'
import hashlib
import json
import os
import re
import shutil
import signal
import sys
import time
from collections import OrderedDict, deque
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

import plotext as plt

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
    return max(60, cols), max(20, rows)


# Fixed budgets, in terminal rows, for the non-chart chrome we print each
# frame: header lines, divider, padding. Everything else goes to the two
# chart regions.
HEADER_ROWS = 2  # one header line per chart + blank
DIVIDER_ROWS = 1
SAFE_ROWS_MIN = 10  # minimum rows for the Safe chart to be legible


def _step_points(xs, ys):
    """Convert (x,y) point list into step-post representation by doubling
    each transition. plotext has no built-in step plotting, so we
    pre-process the data to draw horizontal-then-vertical line segments."""
    if not xs:
        return [], []
    sx, sy = [], []
    for i in range(len(xs) - 1):
        sx.append(xs[i])
        sy.append(ys[i])
        sx.append(xs[i + 1])
        sy.append(ys[i])  # hold value until next x
    sx.append(xs[-1])
    sy.append(ys[-1])
    return sx, sy


def _integer_xticks(xs, count=5):
    """Evenly sample `count` integer tick positions spanning xs, returned
    as (positions, string-labels). Prevents plotext from rendering block
    numbers as floats like 10716637.50."""
    if not xs:
        return [], []
    lo, hi = int(min(xs)), int(max(xs))
    if hi == lo:
        return [lo], [str(lo)]
    step = max(1, (hi - lo) // max(1, count - 1))
    ticks = list(range(lo, hi + 1, step))
    # Always pin the last tick exactly on `hi` for endpoint clarity.
    if ticks[-1] != hi:
        ticks.append(hi)
    return ticks, [str(t) for t in ticks]


_ANSI_RE = re.compile(r"\033\[[^m]*m")


def _visual_len(s: str) -> int:
    """Length of string as it appears on screen (ignoring ANSI escapes)."""
    return len(_ANSI_RE.sub("", s))


def _hstack_charts(parts: list[str], gap: int = 2) -> str:
    """Place independently-rendered chart strings side by side.

    Uses visual width (stripping ANSI codes) for alignment so colour
    escapes don't misalign columns."""
    if len(parts) == 1:
        return parts[0]
    split = [p.split("\n") for p in parts]
    max_lines = max(len(s) for s in split)
    for s in split:
        while len(s) < max_lines:
            s.append("")
    # Measure widest visual line per column.
    col_widths = [max((_visual_len(ln) for ln in s), default=0) for s in split]
    spacer = " " * gap
    rows = []
    for row_cells in zip(*split):
        padded = []
        for cell, w in zip(row_cells, col_widths):
            pad = w - _visual_len(cell)
            padded.append(cell + "\033[0m" + " " * max(0, pad))
        rows.append(spacer.join(padded))
    return "\n".join(rows)


def render_batch_figure(block_number: int, utc_iso: str, budget_rows: int) -> str:
    series = [(vid, list(batch_hist[vid])) for vid in batch_hist if batch_hist[vid]]
    header = (
        f"Postage batch balances — block {block_number} @ {utc_iso} | "
        f"{len(series)} active"
    )
    if not series:
        return header + "\n  (no active volumes)\n"

    # Union of all x ranges so every chart shares a common tick set.
    all_xs = [p[0] for _, pts in series for p in pts]
    xticks_pos, xticks_lab = _integer_xticks(all_xs)

    n = len(series)
    cols, _ = term_size()
    GAP = 2
    col_width = max(20, (cols - GAP * (n - 1)) // n)

    # Render each batch as a fully independent figure to avoid plotext
    # global-state leakage between plt.build() calls.
    parts = []
    for vid, points in series:
        plt.clear_figure()
        plt.canvas_color("default")
        plt.axes_color("default")
        plt.ticks_color("default")
        xs = [p[0] for p in points]
        ys = [p[1] for p in points]
        sx, sy = _step_points(xs, ys)
        color = "#" + hashlib.md5(vid.encode()).hexdigest()[:6]
        plt.plot(sx, sy, marker="braille", color=color)
        plt.title(f"{vid[:18]}...")
        plt.ylabel("remaining")
        plt.ylim(0)
        if xticks_pos:
            plt.xticks(xticks_pos, xticks_lab)
        plt.plotsize(col_width, budget_rows)
        parts.append(plt.build())

    body = _hstack_charts(parts, gap=GAP)
    return header + "\n" + body


def render_safe_figure(block_number: int, utc_iso: str, safe_bal: int, rows: int) -> str:
    header = (
        f"BZZ balance {SAFE[:8]}...{SAFE[-6:]} — block {block_number} @ {utc_iso} | "
        f"{safe_bal / 1e16:.6f} BZZ"
    )
    if not safe_hist:
        return header + "\n  (no samples yet)\n"
    cols, _ = term_size()
    plt.clear_figure()
    plt.canvas_color("default")
    plt.axes_color("default")
    plt.ticks_color("default")
    xs = [p[0] for p in safe_hist]
    ys = [p[1] / 1e16 for p in safe_hist]
    sx, sy = _step_points(xs, ys)
    plt.plot(sx, sy, marker="braille", color="orange")
    plt.ylabel("BZZ")
    plt.xlabel("block")
    xticks_pos, xticks_lab = _integer_xticks(xs)
    if xticks_pos:
        plt.xticks(xticks_pos, xticks_lab)
    plt.plotsize(cols, rows)
    body = plt.build()
    return header + "\n" + body


# Alternate-screen buffer: switches the terminal to a blank canvas on
# entry and restores the pre-run scrollback on exit. vim/less/htop use
# this. Critical for "repaint in place" — without it, content from each
# frame can end up accumulating in scrollback despite screen-clears.
ALT_SCREEN_ENTER = "\033[?1049h"
ALT_SCREEN_EXIT = "\033[?1049l"
CURSOR_HIDE = "\033[?25l"
CURSOR_SHOW = "\033[?25h"
# Home cursor + clear from cursor to end of screen. Order matters:
# going H first then J means J wipes from (1,1) downward — always
# clears the whole visible area regardless of where the cursor was.
CLEAR_FRAME = "\033[H\033[J"


def repaint(block_number: int, utc_iso: str, safe_bal: int):
    cols, rows = term_size()
    # Allocate vertical space: fixed safe region, remainder for batch.
    safe_rows = SAFE_ROWS_MIN
    batch_rows = max(6, rows - safe_rows - HEADER_ROWS * 2 - DIVIDER_ROWS)

    batch_txt = render_batch_figure(block_number, utc_iso, batch_rows)
    safe_txt = render_safe_figure(block_number, utc_iso, safe_bal, safe_rows)
    divider = "─" * cols

    out = []
    if IS_TTY:
        out.append(CLEAR_FRAME)
    out.append(batch_txt.rstrip("\n"))
    out.append("\n")
    out.append(divider)
    out.append("\n")
    out.append(safe_txt.rstrip("\n"))
    sys.stdout.write("".join(out))
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

# Enter the alternate screen BEFORE the first frame so the user's
# pre-run terminal content is preserved. Exit in finally — even on
# uncaught exception the terminal must be restored.
if IS_TTY:
    sys.stdout.write(ALT_SCREEN_ENTER + CURSOR_HIDE)
    sys.stdout.write(CLEAR_FRAME + "Fetching initial state…\n")
    sys.stdout.flush()

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
            with ThreadPoolExecutor() as pool:
                f_cto = pool.submit(read_cto)
                f_vols = pool.submit(read_active_volumes)
                f_safe = pool.submit(read_safe_balance)
                cto = f_cto.result()
                vols = f_vols.result()
                safe_bal = f_safe.result()
        except RuntimeError as e:
            print(f"[plot] state read failed: {e}", file=sys.stderr)
            time.sleep(POLL_INTERVAL)
            continue

        # Fetch all batch balances in parallel.
        vids = [vid for vid, _depth in vols]
        with ThreadPoolExecutor() as pool:
            batch_results = list(pool.map(read_batch_nb, vids))

        # Update batch history. Drop pruned / dead / absent.
        active_vids = set()
        for (vid, _depth), (owner, nb) in zip(vols, batch_results):
            active_vids.add(vid)
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
        # Restore cursor + leave alternate screen so the user's terminal
        # looks exactly like it did before the run.
        sys.stdout.write(CURSOR_SHOW + ALT_SCREEN_EXIT)
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
