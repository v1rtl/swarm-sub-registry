#!/usr/bin/env bash
# Render a chart of postage batch remaining balance over time, for every
# volume registered in a VolumeRegistry.
#
# Two acquisition modes:
#
#   --mode analytical (default)
#     Event-driven reconstruction via eth_getLogs (bloom-filter-friendly).
#     Each batch's per-chunk remaining balance is computed analytically:
#
#       remaining(b) = last_seen_normalisedBalance − currentTotalOutPayment(b)
#
#     where `currentTotalOutPayment(b)` comes from the `PriceUpdate` event
#     trajectory (piecewise-linear between price knots) and
#     `last_seen_normalisedBalance` is the latest `Toppedup`/`BatchCreated`
#     event. RPC cost is O(log_chunks) — independent of chart resolution.
#     Reflects the protocol-level virtual-time accounting.
#
#   --mode actual
#     Per-sample `eth_call` to `PostageStamp.batches(id)` and
#     `PostageStamp.currentTotalOutPayment()` at each chart sample block.
#     Reflects the on-chain READ of those view functions, so a batch
#     that has been pruned (owner=0) reports 0 — whereas analytical
#     mode would still compute a positive pre-prune remaining until
#     cto catches up. Useful for visual parity with the chain's own
#     view. RPC cost is O(N_volumes × N_samples) — expensive.
#
# Between topups the curve drains linearly at `lastPrice` per block; at each
# `Toppedup` log the line jumps up. Retirement (`VolumeRetired`) cuts the
# series to NaN; matplotlib breaks the line there, matching TEST-PLAN §6.4.
#
# Usage:
#   ./scripts/plot-batch-balances.sh [flags] FROM_BLOCK [TO_BLOCK]
#
# Connection to the chain is supplied in one of three ways (flags win over
# env, env wins over implicit defaults):
#
#   a) flags:  --rpc-url URL --registry ADDR --postage ADDR
#   b) env:    RPC_URL, REGISTRY, POSTAGE
#
# Both forms work under bash/zsh/fish. The flag form is the fish-friendly
# path because fish does not accept inline `VAR=val command` syntax.
#
# Flags:
#   --rpc-url URL       chain RPC (archive needed for eth_call on FROM_BLOCK)
#   --registry ADDR     VolumeRegistry address
#   --postage ADDR      PostageStamp address
#   --mode M            analytical | actual                (default analytical)
#   --step N            chart resolution in blocks between samples (default 50)
#   --metric M          remaining | total | normalised    (default remaining)
#   --render R          png | svg | ascii                 (default png)
#   --out FILE          chart output path   (default batch-balances.png)
#   --tsv FILE          data file path      (default batch-balances.tsv)
#   --log-chunk N       eth_getLogs block span per request (default 5000)
#
# Examples (all three shells):
#
#   # bash/zsh, env form:
#   RPC_URL=$RPC_URL REGISTRY=$REG POSTAGE=$PS \
#     ./scripts/plot-batch-balances.sh 10715650
#
#   # fish, flag form:
#   ./scripts/plot-batch-balances.sh \
#     --rpc-url https://… --registry 0x3a99… --postage 0xcdfd… 10715650
set -euo pipefail

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------

STEP=50
METRIC="remaining"
RENDER="png"
OUTFILE="batch-balances.png"
TSV="batch-balances.tsv"
LOG_CHUNK=5000
MODE="analytical"

# Connection params: flags override env; env provides defaults.
RPC_URL="${RPC_URL-}"
REGISTRY="${REGISTRY-}"
POSTAGE="${POSTAGE-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rpc-url) RPC_URL="$2"; shift 2;;
    --registry) REGISTRY="$2"; shift 2;;
    --postage) POSTAGE="$2"; shift 2;;
    --mode) MODE="$2"; shift 2;;
    --step) STEP="$2"; shift 2;;
    --metric) METRIC="$2"; shift 2;;
    --render) RENDER="$2"; shift 2;;
    --out) OUTFILE="$2"; shift 2;;
    --tsv) TSV="$2"; shift 2;;
    --log-chunk) LOG_CHUNK="$2"; shift 2;;
    -h|--help) sed -n '2,60p' "$0"; exit 0;;
    --) shift; break;;
    -*) echo "unknown flag: $1" >&2; exit 2;;
    *) break;;
  esac
done

FROM_BLOCK="${1:?FROM_BLOCK required (positional arg 1)}"
TO_BLOCK="${2:-latest}"

case "$METRIC" in remaining|total|normalised) ;;
  *) echo "invalid --metric: $METRIC" >&2; exit 2;; esac
case "$RENDER" in png|svg|ascii) ;;
  *) echo "invalid --render: $RENDER" >&2; exit 2;; esac
case "$MODE" in analytical|actual) ;;
  *) echo "invalid --mode: $MODE (want analytical|actual)" >&2; exit 2;; esac

if [[ -z "$RPC_URL" ]]; then
  echo "missing RPC_URL (--rpc-url flag or env var)" >&2; exit 2;
fi
if [[ -z "$REGISTRY" ]]; then
  echo "missing REGISTRY (--registry flag or env var)" >&2; exit 2;
fi
if [[ -z "$POSTAGE" ]]; then
  echo "missing POSTAGE (--postage flag or env var)" >&2; exit 2;
fi

# Catch copy-paste mishaps early — urllib rejects non-ASCII URLs with an
# ugly 30-line traceback otherwise.
if ! printf '%s' "$RPC_URL" | LC_ALL=C grep -q '^[[:print:]]*$'; then
  echo "RPC_URL contains non-ASCII characters (likely a copy-paste artifact " \
       "such as '…' from an example). Use the full literal URL." >&2
  echo "  got: $RPC_URL" >&2
  exit 2
fi
if [[ ! "$RPC_URL" =~ ^https?:// ]]; then
  echo "RPC_URL must start with http:// or https://  (got: $RPC_URL)" >&2
  exit 2
fi
for v in "$REGISTRY" "$POSTAGE"; do
  if [[ ! "$v" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "invalid address: $v (expected 0x-prefixed 20-byte hex)" >&2
    exit 2
  fi
done

for bin in uv python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "missing tool: $bin" >&2; exit 1; }
done

export RPC_URL REGISTRY POSTAGE FROM_BLOCK TO_BLOCK STEP METRIC RENDER OUTFILE TSV LOG_CHUNK MODE

# ---------------------------------------------------------------------------
# Work lives in Python — matplotlib for rendering, pycryptodome for keccak
# (EVM topic hashes), stdlib urllib for JSON-RPC.
# ---------------------------------------------------------------------------

exec uv run --quiet \
  --with "matplotlib" --with "numpy" --with "pycryptodome" \
  python3 - <<'PY'
import bisect
import json
import os
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from Crypto.Hash import keccak

# --------------------------- config -----------------------------------------

RPC = os.environ["RPC_URL"]
REGISTRY = os.environ["REGISTRY"].lower()
POSTAGE = os.environ["POSTAGE"].lower()
FROM_BLOCK = int(os.environ["FROM_BLOCK"])
TO_BLOCK_ARG = os.environ["TO_BLOCK"]
STEP = int(os.environ["STEP"])
METRIC = os.environ["METRIC"]
RENDER = os.environ["RENDER"]
OUTFILE = os.environ["OUTFILE"]
TSV = os.environ["TSV"]
LOG_CHUNK = int(os.environ["LOG_CHUNK"])
MODE = os.environ["MODE"]  # "analytical" or "actual"

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
        with urlopen(req, timeout=60) as r:
            resp = json.loads(r.read().decode())
    except (HTTPError, URLError) as e:
        raise RuntimeError(f"{method} HTTP error: {e}") from e
    if "error" in resp:
        raise RuntimeError(f"{method} error: {resp['error']}")
    return resp["result"]


def hex_int(s):
    # "0x" (empty returndata from a call to a non-contract address) is not a
    # number. Callers decide whether that's an error or a "treat as missing".
    if s in ("0x", "0x0", ""):
        return 0
    return int(s, 16)


def kec256(s):
    return "0x" + keccak.new(digest_bits=256, data=s.encode()).hexdigest()


def selector(sig):
    return "0x" + keccak.new(digest_bits=256, data=sig.encode()).hexdigest()[:8]


# --------------------------- topic hashes -----------------------------------

TOPIC_PRICE_UPDATE = kec256("PriceUpdate(uint256)")
TOPIC_BATCH_CREATED = kec256(
    "BatchCreated(bytes32,uint256,uint256,address,uint8,uint8,bool)"
)
TOPIC_VOLUME_CREATED = kec256("VolumeCreated(bytes32,address,address,uint8,uint64)")
TOPIC_TOPPEDUP = kec256("Toppedup(bytes32,uint256,uint256)")
TOPIC_VOLUME_RETIRED = kec256("VolumeRetired(bytes32,uint8)")

SEL_CTO = selector("currentTotalOutPayment()")
SEL_LAST_PRICE = selector("lastPrice()")
SEL_GET_ACTIVE_COUNT = selector("getActiveVolumeCount()")
SEL_GET_ACTIVE_VOLUMES = selector("getActiveVolumes(uint256,uint256)")
SEL_BATCHES = selector("batches(bytes32)")

# --------------------------- helpers ----------------------------------------


def eth_call(to, data, block):
    block_tag = hex(block) if isinstance(block, int) else block
    return rpc("eth_call", [{"to": to, "data": data}, block_tag])


def get_logs_paged(address, topics, from_b, to_b):
    """Page eth_getLogs in LOG_CHUNK-sized block windows. Topics are passed
    as-is; caller is responsible for AND/OR structure.
    """
    out = []
    b = from_b
    while b <= to_b:
        end = min(b + LOG_CHUNK - 1, to_b)
        chunk = rpc(
            "eth_getLogs",
            [
                {
                    "address": address,
                    "fromBlock": hex(b),
                    "toBlock": hex(end),
                    "topics": topics,
                }
            ],
        )
        out.extend(chunk)
        b = end + 1
    return out


def encode_uint256(n: int) -> str:
    return f"{n:064x}"


def encode_bytes32(b: str) -> str:
    # strip 0x, left-pad to 64 hex chars (bytes32 is already 32 bytes though)
    s = b.lower()
    if s.startswith("0x"):
        s = s[2:]
    return s.rjust(64, "0")


# --------------------------- resolve TO_BLOCK -------------------------------

if TO_BLOCK_ARG == "latest":
    TO_BLOCK = hex_int(rpc("eth_blockNumber", []))
else:
    TO_BLOCK = int(TO_BLOCK_ARG)

if FROM_BLOCK >= TO_BLOCK:
    print(
        f"FROM_BLOCK ({FROM_BLOCK}) must be < TO_BLOCK ({TO_BLOCK})",
        file=sys.stderr,
    )
    sys.exit(2)

print(
    f"[plot] RPC={RPC}\n"
    f"[plot] range={FROM_BLOCK}..{TO_BLOCK}  step={STEP}  "
    f"metric={METRIC}  render={RENDER}  mode={MODE}",
    file=sys.stderr,
)

# --------------------------- phase 1: discover volumes ----------------------

# Volumes to chart = (created in window) ∪ (active at FROM_BLOCK).
# The union covers both "show me what happened this week" and
# "include long-running volumes that started before the window".

volumes = {}  # volume_id (str, 0x-prefixed) -> state dict


def register_volume(vid, depth, create_block):
    if vid in volumes:
        return
    volumes[vid] = {
        "depth": int(depth),
        "create_block": int(create_block),
        # nb_events sorted by (block, log_index): list[(block, nb)]
        "nb_events": [],
        "retire_block": None,
    }


# (a) Volumes created in [FROM_BLOCK, TO_BLOCK]: VolumeCreated events on registry.
print("[plot] fetching VolumeCreated logs...", file=sys.stderr)
vc_logs = get_logs_paged(REGISTRY, [TOPIC_VOLUME_CREATED], FROM_BLOCK, TO_BLOCK)
for log in vc_logs:
    vid = log["topics"][1]
    block = hex_int(log["blockNumber"])
    # data: address chunkSigner (32) + uint8 depth (padded 32) + uint64 ttlExpiry (padded 32)
    data = bytes.fromhex(log["data"][2:])
    depth = data[63]  # second 32-byte word, last byte
    register_volume(vid, depth, block)
print(f"[plot]   volumes created in window: {len(vc_logs)}", file=sys.stderr)

# (b) Volumes already Active at FROM_BLOCK.
print("[plot] reading getActiveVolumes at FROM_BLOCK...", file=sys.stderr)
active_count = 0
try:
    count_hex = eth_call(REGISTRY, SEL_GET_ACTIVE_COUNT, FROM_BLOCK)
    # A call to a non-contract address returns "0x" (empty). Treat as
    # "registry not deployed yet" rather than an error.
    if count_hex in ("0x", "0x0"):
        print(
            "[plot]   no code / empty return at REGISTRY for FROM_BLOCK; "
            "skipping pre-existing volumes",
            file=sys.stderr,
        )
    else:
        active_count = hex_int(count_hex)
except RuntimeError as e:
    # Registry not deployed at FROM_BLOCK, or RPC lacks archive state there.
    print(
        f"[plot]   getActiveVolumeCount at FROM_BLOCK failed: {e}\n"
        f"[plot]   skipping pre-existing volumes; window-created only",
        file=sys.stderr,
    )

PAGE = 100
pre_existing = []  # list[(volume_id, depth)]
offset = 0
while offset < active_count:
    limit = min(PAGE, active_count - offset)
    call_data = SEL_GET_ACTIVE_VOLUMES + encode_uint256(offset) + encode_uint256(limit)
    raw = eth_call(REGISTRY, call_data, FROM_BLOCK)
    # Decode: dynamic array of tuples.
    # ABI layout of the return: head [offset], then the array: length, then
    # `length` tuples of 9 words each (all 9 fields are statically-sized).
    buf = bytes.fromhex(raw[2:])
    # First word points to the start of the array; usually 0x20.
    array_offset = int.from_bytes(buf[0:32], "big")
    array_start = array_offset
    array_len = int.from_bytes(buf[array_start : array_start + 32], "big")
    p = array_start + 32
    TUPLE_WORDS = 9  # volumeId, owner, payer, chunkSigner, createdAt, ttlExpiry, depth, status, accountActive
    for _ in range(array_len):
        words = buf[p : p + 32 * TUPLE_WORDS]
        volume_id_bytes = words[0:32]
        # depth is at word index 6 (0-based), last byte of that 32-byte word.
        depth = words[32 * 6 + 31]
        vid = "0x" + volume_id_bytes.hex()
        pre_existing.append((vid, depth))
        p += 32 * TUPLE_WORDS
    offset += limit

pre_existing_new = 0
for vid, depth in pre_existing:
    if vid in volumes:
        continue
    # Seed create_block to FROM_BLOCK (we don't know the real creation — it's
    # pre-window). The chart starts at FROM_BLOCK for this volume.
    register_volume(vid, depth, FROM_BLOCK)
    pre_existing_new += 1
print(
    f"[plot]   pre-existing volumes at FROM_BLOCK: {pre_existing_new} new "
    f"({len(pre_existing)} total in active set)",
    file=sys.stderr,
)

if not volumes:
    print("[plot] no volumes to chart — done", file=sys.stderr)
    sys.exit(0)

# --------------------------- phase 2: seed initial nb (analytical only) -----

vids = sorted(volumes.keys())

if MODE == "analytical":
    # (a) For window-created volumes: read their initial nb from BatchCreated
    #     logs on PostageStamp. Filter by topic1 ∈ {vid, …} in chunks.
    print(
        "[plot] fetching BatchCreated logs for window-created volumes...",
        file=sys.stderr,
    )
    CREATED_IN_WINDOW = [vid for vid in vids if vid in {l["topics"][1] for l in vc_logs}]
    BATCH_CHUNK = 100
    for i in range(0, len(CREATED_IN_WINDOW), BATCH_CHUNK):
        chunk_ids = CREATED_IN_WINDOW[i : i + BATCH_CHUNK]
        bc_logs = get_logs_paged(
            POSTAGE, [TOPIC_BATCH_CREATED, chunk_ids], FROM_BLOCK, TO_BLOCK
        )
        for log in bc_logs:
            vid = log["topics"][1]
            if vid not in volumes:
                continue
            block = hex_int(log["blockNumber"])
            # data: totalAmount(32) + normalisedBalance(32) + owner(32) + depth(32) + bucketDepth(32) + immutableFlag(32)
            data = bytes.fromhex(log["data"][2:])
            nb = int.from_bytes(data[32:64], "big")
            volumes[vid]["nb_events"].append((block, nb))

    # (b) For pre-existing volumes: one eth_call batches(id) at FROM_BLOCK.
    PRE_EXISTING_IDS = [vid for vid, _ in pre_existing]
    if PRE_EXISTING_IDS:
        print(
            f"[plot] seeding {len(PRE_EXISTING_IDS)} pre-existing nb via eth_call...",
            file=sys.stderr,
        )
    for vid in PRE_EXISTING_IDS:
        if vid not in volumes:
            continue
        # batches(bytes32) returns (address, uint8, uint8, bool, uint256, uint256)
        # packed into 6 * 32-byte words.
        data = SEL_BATCHES + encode_bytes32(vid)
        try:
            raw = eth_call(POSTAGE, data, FROM_BLOCK)
        except RuntimeError:
            continue
        buf = bytes.fromhex(raw[2:])
        if len(buf) < 5 * 32:
            continue
        nb = int.from_bytes(buf[4 * 32 : 5 * 32], "big")
        if nb > 0:
            volumes[vid]["nb_events"].append((FROM_BLOCK, nb))

# --------------------------- phase 3: retirement + (analytical-only) topups -

if MODE == "analytical":
    print("[plot] fetching Toppedup logs...", file=sys.stderr)
    tu_logs = get_logs_paged(REGISTRY, [TOPIC_TOPPEDUP], FROM_BLOCK, TO_BLOCK)
    for log in tu_logs:
        vid = log["topics"][1]
        if vid not in volumes:
            continue
        block = hex_int(log["blockNumber"])
        # data: amount(32) + newNormalisedBalance(32)
        data = bytes.fromhex(log["data"][2:])
        new_nb = int.from_bytes(data[32:64], "big")
        volumes[vid]["nb_events"].append((block, new_nb))
    print(f"[plot]   Toppedup events: {len(tu_logs)}", file=sys.stderr)

# VolumeRetired is needed in both modes — it cuts the chart series to NaN.
print("[plot] fetching VolumeRetired logs...", file=sys.stderr)
vr_logs = get_logs_paged(REGISTRY, [TOPIC_VOLUME_RETIRED], FROM_BLOCK, TO_BLOCK)
for log in vr_logs:
    vid = log["topics"][1]
    if vid not in volumes:
        continue
    block = hex_int(log["blockNumber"])
    volumes[vid]["retire_block"] = block
print(f"[plot]   VolumeRetired events: {len(vr_logs)}", file=sys.stderr)

if MODE == "analytical":
    # Sort nb_events per volume.
    for v in volumes.values():
        v["nb_events"].sort()

# --------------------------- phase 4: price trajectory (analytical only) ----

if MODE == "analytical":
    print("[plot] fetching PriceUpdate logs + initial cto/lastPrice...", file=sys.stderr)
    pu_logs = get_logs_paged(POSTAGE, [TOPIC_PRICE_UPDATE], FROM_BLOCK, TO_BLOCK)
    cto_0 = hex_int(eth_call(POSTAGE, SEL_CTO, FROM_BLOCK))
    last_price_0 = hex_int(eth_call(POSTAGE, SEL_LAST_PRICE, FROM_BLOCK))

    # Piecewise-linear cto(b): list of (knot_block, cto_at_knot, price_from_here).
    # At FROM_BLOCK the price-in-force is last_price_0. PriceUpdate events turn
    # the piecewise function into a new segment.
    knots = [(FROM_BLOCK, cto_0, last_price_0)]
    for log in sorted(
        pu_logs, key=lambda l: (hex_int(l["blockNumber"]), hex_int(l["logIndex"]))
    ):
        block = hex_int(log["blockNumber"])
        if block < FROM_BLOCK:
            continue
        # PriceUpdate(uint256) — data is a single uint256 word.
        new_price = hex_int(log["data"])
        prev_block, prev_cto, prev_price = knots[-1]
        cto_at_knot = prev_cto + prev_price * (block - prev_block)
        # If this is the same block as the last knot (edge case: anvil mining
        # multiple setPrices in one block), overwrite rather than append.
        if prev_block == block:
            knots[-1] = (block, cto_at_knot, new_price)
        else:
            knots.append((block, cto_at_knot, new_price))
    print(
        f"[plot]   PriceUpdate events: {len(pu_logs)}  knots: {len(knots)}",
        file=sys.stderr,
    )

    def cto_at(b: int) -> int:
        ks = [k[0] for k in knots]
        i = bisect.bisect_right(ks, b) - 1
        if i < 0:
            i = 0
        kb, kcto, kprice = knots[i]
        return kcto + kprice * (b - kb)

    def last_nb_at(vid: str, b: int):
        events = volumes[vid]["nb_events"]
        if not events:
            return None
        ks = [e[0] for e in events]
        i = bisect.bisect_right(ks, b) - 1
        if i < 0:
            return None
        return events[i][1]


# --------------------------- phase 5: sample + write TSV --------------------

sample_blocks = list(range(FROM_BLOCK, TO_BLOCK + 1, STEP))
if sample_blocks[-1] != TO_BLOCK:
    sample_blocks.append(TO_BLOCK)


def value_analytical(vid: str, b: int):
    v = volumes[vid]
    if b < v["create_block"]:
        return None
    if v["retire_block"] is not None and b >= v["retire_block"]:
        return None
    last_nb = last_nb_at(vid, b)
    if last_nb is None:
        return None
    rem = last_nb - cto_at(b)
    if rem <= 0:
        return None
    if METRIC == "remaining":
        return rem
    if METRIC == "total":
        return rem << v["depth"]
    if METRIC == "normalised":
        return last_nb
    return None


def value_actual(vid: str, b: int, cto_b: int):
    """Read the batch struct live from PostageStamp at block b. Returns
    None if the batch doesn't exist (pruned), is dead, or the volume is
    outside its active window.
    """
    v = volumes[vid]
    if b < v["create_block"]:
        return None
    if v["retire_block"] is not None and b >= v["retire_block"]:
        return None
    try:
        raw = eth_call(POSTAGE, SEL_BATCHES + encode_bytes32(vid), b)
    except RuntimeError:
        return None
    buf = bytes.fromhex(raw[2:])
    if len(buf) < 5 * 32:
        return None
    # slot 0: packed [owner(20), depth(1), bucketDepth(1), immutable(1), padding].
    # ABI-encodes as word 0 = address (right-padded? actually left-padded to 32).
    # On return the struct is 6 * 32-byte words, one field per word.
    owner_word = buf[0:32]
    # address padded to 32 bytes, left-zeroed.
    if owner_word == b"\x00" * 32:
        return None  # pruned
    nb = int.from_bytes(buf[4 * 32 : 5 * 32], "big")
    rem = nb - cto_b
    if rem <= 0:
        return None
    if METRIC == "remaining":
        return rem
    if METRIC == "total":
        return rem << v["depth"]
    if METRIC == "normalised":
        return nb
    return None


print(
    f"[plot] writing {len(sample_blocks)} samples to {TSV} (mode={MODE})...",
    file=sys.stderr,
)
with open(TSV, "w") as f:
    header = ["block", "cto"] + vids
    f.write("\t".join(header) + "\n")
    for sample_i, b in enumerate(sample_blocks):
        if MODE == "analytical":
            cto_b = cto_at(b)
            row = [str(b), str(cto_b)]
            for vid in vids:
                val = value_analytical(vid, b)
                row.append("NaN" if val is None else str(val))
        else:  # actual
            # Progress ticker for the expensive path.
            if sample_i % 25 == 0 or sample_i == len(sample_blocks) - 1:
                print(
                    f"[plot]   actual sample {sample_i + 1}/{len(sample_blocks)}  block={b}",
                    file=sys.stderr,
                )
            try:
                cto_b = hex_int(eth_call(POSTAGE, SEL_CTO, b))
            except RuntimeError:
                cto_b = 0
            row = [str(b), str(cto_b)]
            for vid in vids:
                val = value_actual(vid, b, cto_b)
                row.append("NaN" if val is None else str(val))
        f.write("\t".join(row) + "\n")

# --------------------------- phase 6: render --------------------------------


def load_tsv():
    with open(TSV) as f:
        hdr = f.readline().rstrip("\n").split("\t")
        rows = [line.rstrip("\n").split("\t") for line in f]
    ids_ = hdr[2:]
    blocks = np.array([int(r[0]) for r in rows])

    def parse(col_idx):
        out = np.empty(len(rows))
        for k, r in enumerate(rows):
            s = r[col_idx]
            try:
                out[k] = float(s) if s != "NaN" else np.nan
            except ValueError:
                out[k] = np.nan
        return out

    series = {vid: parse(2 + i) for i, vid in enumerate(ids_)}
    return blocks, series


if RENDER == "ascii":
    blocks, series = load_tsv()
    print(
        f"\n{METRIC} over blocks {int(blocks[0])}..{int(blocks[-1])}  "
        f"({len(blocks)} samples)"
    )
    print("-" * 80)
    BARS = " ▁▂▃▄▅▆▇█"
    for vid, vals in series.items():
        finite = vals[np.isfinite(vals)]
        if finite.size == 0:
            print(f"  {vid[:12]}…  (all NaN)")
            continue
        lo, hi = float(finite.min()), float(finite.max())
        span = hi - lo if hi > lo else 1.0
        spark = "".join(
            " "
            if not np.isfinite(v)
            else BARS[
                min(len(BARS) - 1, max(0, int((float(v) - lo) / span * (len(BARS) - 1))))
            ]
            for v in vals
        )
        print(f"  {vid[:12]}…  [{lo:.2e}..{hi:.2e}]  {spark}")
    print()
    sys.exit(0)

blocks, series = load_tsv()

# Unit scaling based on max finite across all series.
max_finite = max(
    (float(np.nanmax(s)) for s in series.values() if np.any(np.isfinite(s))),
    default=1.0,
)
if max_finite <= 0 or max_finite < 1e6:
    scale, unit = 1.0, "raw"
elif max_finite < 1e12:
    scale, unit = 1e6, "×10⁶"
elif max_finite < 1e18:
    scale, unit = 1e12, "×10¹²"
else:
    scale, unit = 1e18, "×10¹⁸ (≈BZZ)"

fig, ax = plt.subplots(figsize=(14, 7))
cmap = plt.get_cmap("tab20" if len(series) > 10 else "tab10")
for i, (vid, vals) in enumerate(series.items()):
    ax.step(
        blocks,
        vals / scale,
        where="post",
        label=vid[:12] + "…",
        linewidth=1.6,
        color=cmap(i % cmap.N),
    )

metric_label = {
    "remaining": "per-chunk remaining",
    "total": "total remaining (remaining × 2^depth)",
    "normalised": "cumulative normalisedBalance",
}.get(METRIC, METRIC)

ax.set_title(
    f"Postage batch balances — {metric_label}\n"
    f"blocks {int(blocks[0])}..{int(blocks[-1])} ({len(blocks)} samples, "
    f"{len(series)} volumes)"
)
ax.set_xlabel("block number")
ax.set_ylabel(f"balance ({unit})")
ax.grid(True, alpha=0.3)
ax.legend(loc="center left", bbox_to_anchor=(1.01, 0.5), fontsize=8, frameon=False)
fig.tight_layout()
fig.savefig(OUTFILE, dpi=120 if RENDER == "png" else None, bbox_inches="tight")
print(f"[plot] wrote {OUTFILE}", file=sys.stderr)
PY
