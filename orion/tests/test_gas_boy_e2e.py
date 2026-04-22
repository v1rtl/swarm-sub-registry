"""End-to-end integration test for the gas-boy Cloudflare Worker.

Prerequisites (run these manually before invoking pytest):

    uv run orion up --profile swarm
    uv run orion prime set-postage-price --wei-per-chunkblock 44445
    uv run orion participants provision --label op-1 --overlays 1 \
        --balance-per-chunk 2000000000
    ../gas-boy/scripts/deploy-to-orion.sh

The `--balance-per-chunk 2000000000` is important: the default picked by
orion on a freshly-primed chain can be as low as 34560 (= minimum), which
leaves the batch already "due" or even expired before gas-boy runs.
2e9 gives the batch a healthy buffer so the `not-due` case in test_20
holds initially.

The test uses anvil_setStorageAt to lower PostageStamp.minimumValidityBlocks
from 17280 → 100, allowing a small EXTENSION_BLOCKS (200) and fast mining.

Then:

    uv run pytest tests/test_gas_boy_e2e.py -s

What this exercises:
  - Deploy + subscribe flow works against a live anvil + PostageStamp.
  - Worker's /trigger endpoint correctly no-ops when nothing is due.
  - When blocks are mined past the due threshold, the Worker calls
    `keepalive()` exactly once, emits `KeptAlive`, and advances the
    batch's normalisedBalance by `threshold` (= price * extensionBlocks).
  - Hysteresis: a second /trigger with no block progression is a no-op.
  - Cycle: mining another extension's worth of blocks makes the batch
    due again and the Worker tops it up a second time.
  - A payer that revokes their allowance yields `KeepaliveSkipped` and
    does NOT crash the Worker (scheduled() still returns 200).

The test spawns `wrangler dev` as a subprocess and drives it over HTTP.
"""
from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import time
import urllib.request
from pathlib import Path
from typing import Any, Iterator

import pytest
from eth_account import Account
from web3 import Web3
from web3.types import EventData

REPO_ROOT = Path(__file__).resolve().parents[2]
STATE_DIR = REPO_ROOT / "orion" / "state"
GAS_BOY_DIR = REPO_ROOT / "gas-boy"

WRANGLER_PORT = 8787
WRANGLER_URL = f"http://127.0.0.1:{WRANGLER_PORT}"

# Anvil prefunded account #1 — gas-boy's caller (distinct from op-0 payer).
GAS_BOY_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
GAS_BOY_ADDR = Account.from_key(GAS_BOY_KEY).address

# We lower PostageStamp.minimumValidityBlocks from 17280 → 100 via
# anvil_setStorageAt (see `lowered_min_validity` fixture), so
# EXTENSION_BLOCKS can be small and `anvil_mine` calls finish instantly.
EXTENSION_BLOCKS = 200

# ---------------------------------------------------------------------------
# ABIs (minimal surfaces)
# ---------------------------------------------------------------------------

REGISTRY_ABI = [
    {"type": "function", "name": "subscribe", "stateMutability": "nonpayable",
     "inputs": [{"type": "bytes32"}, {"type": "uint32"}], "outputs": []},
    {"type": "function", "name": "updateExtension", "stateMutability": "nonpayable",
     "inputs": [{"type": "bytes32"}, {"type": "uint32"}], "outputs": []},
    {"type": "function", "name": "unsubscribe", "stateMutability": "nonpayable",
     "inputs": [{"type": "bytes32"}], "outputs": []},
    {"type": "function", "name": "subs", "stateMutability": "view",
     "inputs": [{"type": "bytes32"}],
     "outputs": [{"type": "address", "name": "payer"},
                 {"type": "uint32", "name": "extensionBlocks"}]},
    {"type": "function", "name": "isDue", "stateMutability": "view",
     "inputs": [{"type": "bytes32"}], "outputs": [{"type": "bool"}]},
    {"type": "function", "name": "subscriptionCount", "stateMutability": "view",
     "inputs": [], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "estimatedTopUp", "stateMutability": "view",
     "inputs": [{"type": "bytes32"}],
     "outputs": [{"type": "uint256", "name": "perChunk"},
                 {"type": "uint256", "name": "total"}]},
    {"type": "event", "name": "KeptAlive", "anonymous": False,
     "inputs": [
         {"indexed": True, "name": "caller", "type": "address"},
         {"indexed": True, "name": "batchId", "type": "bytes32"},
         {"indexed": True, "name": "payer", "type": "address"},
         {"indexed": False, "name": "topUpPerChunk", "type": "uint256"},
         {"indexed": False, "name": "totalAmount", "type": "uint256"}]},
    {"type": "event", "name": "KeepaliveSkipped", "anonymous": False,
     "inputs": [
         {"indexed": True, "name": "batchId", "type": "bytes32"},
         {"indexed": False, "name": "reason", "type": "bytes"}]},
    {"type": "event", "name": "Subscribed", "anonymous": False,
     "inputs": [
         {"indexed": True, "name": "batchId", "type": "bytes32"},
         {"indexed": True, "name": "payer", "type": "address"},
         {"indexed": False, "name": "extensionBlocks", "type": "uint32"}]},
]

ERC20_ABI = [
    {"type": "function", "name": "approve", "stateMutability": "nonpayable",
     "inputs": [{"type": "address"}, {"type": "uint256"}],
     "outputs": [{"type": "bool"}]},
    {"type": "function", "name": "balanceOf", "stateMutability": "view",
     "inputs": [{"type": "address"}], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "allowance", "stateMutability": "view",
     "inputs": [{"type": "address"}, {"type": "address"}],
     "outputs": [{"type": "uint256"}]},
]

STAMP_ABI = [
    {"type": "function", "name": "batches", "stateMutability": "view",
     "inputs": [{"type": "bytes32"}],
     "outputs": [{"type": "address"}, {"type": "uint8"}, {"type": "uint8"},
                 {"type": "bool"}, {"type": "uint256"}, {"type": "uint256"}]},
    {"type": "function", "name": "lastPrice", "stateMutability": "view",
     "inputs": [], "outputs": [{"type": "uint64"}]},
    {"type": "function", "name": "currentTotalOutPayment", "stateMutability": "view",
     "inputs": [], "outputs": [{"type": "uint256"}]},
]


# ---------------------------------------------------------------------------
# State loading
# ---------------------------------------------------------------------------

def _load_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        pytest.skip(f"prerequisite missing: {path} (see test docstring)")
    return json.loads(path.read_text())


@pytest.fixture(scope="module")
def chain_state() -> dict[str, Any]:
    return _load_json(STATE_DIR / "chain.json")


@pytest.fixture(scope="module")
def deployment_state() -> dict[str, Any]:
    return _load_json(STATE_DIR / "deployment.json")


@pytest.fixture(scope="module")
def registry_state() -> dict[str, Any]:
    return _load_json(STATE_DIR / "registry.json")


@pytest.fixture(scope="module")
def participants_state() -> dict[str, Any]:
    return _load_json(STATE_DIR / "participants.json")


@pytest.fixture(scope="module")
def w3(chain_state: dict[str, Any]) -> Web3:
    # Fail fast on stale state/chain.json rather than hanging on a dead anvil.
    # See ISSUES.md "Stale anvil / wrong chain".
    pid = chain_state.get("pid")
    if pid:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pytest.fail(
                f"anvil pid {pid} from state/chain.json is dead — "
                f"state is stale, re-run `uv run orion up --profile swarm` "
                f"and the other prerequisites (see test docstring)"
            )
    # Large anvil_mine calls can take several seconds; default 10s is tight.
    w = Web3(Web3.HTTPProvider(chain_state["rpc"], request_kwargs={"timeout": 120}))
    if not w.is_connected():
        pytest.fail(
            f"anvil not reachable at {chain_state['rpc']} "
            f"(pid={pid}) — state/chain.json may be stale"
        )
    actual_chain_id = w.eth.chain_id
    expected_chain_id = chain_state["chain_id"]
    if actual_chain_id != expected_chain_id:
        pytest.fail(
            f"chain_id mismatch: rpc reports {actual_chain_id}, "
            f"state/chain.json says {expected_chain_id} — wrong anvil?"
        )
    return w


PAYER_LABEL = "op-1"

@pytest.fixture(scope="module")
def payer(participants_state: dict[str, Any]) -> dict[str, Any]:
    p = participants_state["participants"].get(PAYER_LABEL)
    assert p is not None, f"{PAYER_LABEL} not provisioned — see test docstring"
    assert p["batches"], f"{PAYER_LABEL} has no batch"
    return p


@pytest.fixture(scope="module")
def batch_id(payer: dict[str, Any]) -> bytes:
    return bytes.fromhex(payer["batches"][0]["batch_id"][2:])


@pytest.fixture(scope="module")
def contracts(w3: Web3, deployment_state: dict[str, Any], registry_state: dict[str, Any]):
    addr = lambda a: Web3.to_checksum_address(a)
    return {
        "registry": w3.eth.contract(address=addr(registry_state["address"]), abi=REGISTRY_ABI),
        "bzz": w3.eth.contract(address=addr(deployment_state["contracts"]["Token"]), abi=ERC20_ABI),
        "stamp": w3.eth.contract(address=addr(deployment_state["contracts"]["PostageStamp"]), abi=STAMP_ABI),
    }


# ---------------------------------------------------------------------------
# Chain helpers
# ---------------------------------------------------------------------------

def _send(w3: Web3, key: str, tx: dict[str, Any]) -> dict[str, Any]:
    signed = w3.eth.account.sign_transaction(tx, key)
    h = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(h, timeout=30, poll_latency=0.2)
    assert receipt.status == 1, f"tx failed: {receipt}"
    return receipt


def _tx_defaults(w3: Web3, sender: str) -> dict[str, Any]:
    return {
        "from": sender,
        "nonce": w3.eth.get_transaction_count(sender),
        "chainId": w3.eth.chain_id,
        "gas": 2_000_000,
        "gasPrice": w3.eth.gas_price,
    }


def _anvil_mine(w3: Web3, n: int) -> None:
    # anvil supports an optional count parameter on evm_mine (hex string).
    w3.provider.make_request("anvil_mine", [hex(n)])


def _fast_forward_to_near_due(w3: Web3, stamp, batch_id: bytes,
                              extension_blocks: int, margin: int = 10) -> None:
    """If the gap between remaining balance and threshold is large, poke
    PostageStamp.totalOutPayment (slot 5) so only `margin` blocks of real
    mining are needed.  This avoids mining tens of thousands of empty blocks.
    """
    price = stamp.functions.lastPrice().call()
    if price == 0:
        return
    norm_bal = stamp.functions.batches(batch_id).call()[4]
    cto = stamp.functions.currentTotalOutPayment().call()
    remaining = norm_bal - cto
    threshold = price * extension_blocks
    gap = remaining - threshold
    if gap <= price * margin:
        return  # already close enough
    # We want: normBal - newCto = threshold + margin * price
    # newCto = normBal - threshold - margin * price
    # cto = totalOutPayment + (block.number - lastUpdatedBlock) * price
    # So new totalOutPayment = newCto - (block.number - lastUpdatedBlock) * price
    # Easier: read current totalOutPayment, add the delta.
    current_top = int.from_bytes(
        w3.eth.get_storage_at(stamp.address, _SLOT_TOTAL_OUT_PAYMENT), "big")
    # We want to increase cto by (gap - margin * price).
    bump = gap - margin * price
    new_top = current_top + bump
    w3.provider.make_request("anvil_setStorageAt", [
        stamp.address,
        hex(_SLOT_TOTAL_OUT_PAYMENT),
        "0x" + new_top.to_bytes(32, "big").hex(),
    ])


def _mine_until_due(w3: Web3, registry, stamp, batch_id: bytes,
                    extension_blocks: int) -> int:
    """Make `batch_id` due by fast-forwarding totalOutPayment then mining
    the last few blocks.  Returns the number of blocks actually mined.
    """
    if registry.functions.isDue(batch_id).call():
        return 0
    price = stamp.functions.lastPrice().call()
    assert price > 0, "lastPrice is 0 — run `uv run orion prime set-postage-price --price 44445`"

    # Fast-forward so only ~10 blocks of real mining remain.
    _fast_forward_to_near_due(w3, stamp, batch_id, extension_blocks)

    norm_bal = stamp.functions.batches(batch_id).call()[4]
    cto = stamp.functions.currentTotalOutPayment().call()
    remaining = norm_bal - cto
    threshold = price * extension_blocks
    gap = remaining - threshold
    if gap < 0:
        return 0
    blocks = (gap // price) + 1
    _anvil_mine(w3, int(blocks))
    assert registry.functions.isDue(batch_id).call(), (
        f"still not due after mining {blocks} (price={price} ext={extension_blocks} "
        f"remaining={remaining} threshold={threshold})"
    )
    return int(blocks)


# ---------------------------------------------------------------------------
# Anvil storage pokes — speed up mining by lowering minimumValidityBlocks
# ---------------------------------------------------------------------------

# PostageStamp storage layout (from compiled artifact):
#   slot 5: totalOutPayment (uint256)
#   slot 9: lastPrice(uint64, offset 0) | minimumValidityBlocks(uint64, offset 8)
#           | lastUpdatedBlock(uint64, offset 16)
_SLOT_TOTAL_OUT_PAYMENT = 5
_SLOT_PRICE_PACKED = 9
_MIN_VALIDITY_BLOCKS = 100


def _poke_slot9(w3: Web3, stamp_addr: str, *,
                last_price: int | None = None,
                min_validity: int | None = None,
                last_updated: int | None = None) -> None:
    """Read-modify-write the packed slot 9 of PostageStamp."""
    raw = w3.eth.get_storage_at(Web3.to_checksum_address(stamp_addr), _SLOT_PRICE_PACKED)
    val = int.from_bytes(raw, "big")
    mask64 = (1 << 64) - 1
    if last_price is not None:
        val = (val & ~mask64) | last_price
    if min_validity is not None:
        val = (val & ~(mask64 << 64)) | (min_validity << 64)
    if last_updated is not None:
        val = (val & ~(mask64 << 128)) | (last_updated << 128)
    w3.provider.make_request("anvil_setStorageAt", [
        Web3.to_checksum_address(stamp_addr),
        hex(_SLOT_PRICE_PACKED),
        "0x" + val.to_bytes(32, "big").hex(),
    ])


@pytest.fixture(scope="module")
def lowered_min_validity(w3: Web3, contracts):
    """Lower PostageStamp.minimumValidityBlocks so EXTENSION_BLOCKS can be small."""
    _poke_slot9(w3, contracts["stamp"].address, min_validity=_MIN_VALIDITY_BLOCKS)
    return True


# ---------------------------------------------------------------------------
# Subscribe op-0 payer to the registry (module-scoped, runs once).
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def subscribed(w3: Web3, contracts, payer, batch_id, registry_state, lowered_min_validity):
    print("\n[subscribed] starting")
    payer_key = "0x" + payer["signing_key"]
    payer_addr = Web3.to_checksum_address(payer["address"])
    registry_addr = Web3.to_checksum_address(registry_state["address"])

    # Approve BZZ (max) from payer → registry, if not already.
    cur = contracts["bzz"].functions.allowance(payer_addr, registry_addr).call()
    print(f"[subscribed] allowance={cur}")
    if cur < 2**255:
        tx = contracts["bzz"].functions.approve(registry_addr, 2**256 - 1).build_transaction(
            _tx_defaults(w3, payer_addr))
        _send(w3, payer_key, tx)
        print("[subscribed] approved")

    # Subscribe if not already — or update ext if already there with a stale value.
    existing = contracts["registry"].functions.subs(batch_id).call()
    print(f"[subscribed] existing sub: {existing}")
    if existing[0] == "0x0000000000000000000000000000000000000000":
        tx = contracts["registry"].functions.subscribe(batch_id, EXTENSION_BLOCKS).build_transaction(
            _tx_defaults(w3, payer_addr))
        _send(w3, payer_key, tx)
        print("[subscribed] subscribed")
    elif existing[1] != EXTENSION_BLOCKS:
        tx = contracts["registry"].functions.updateExtension(batch_id, EXTENSION_BLOCKS).build_transaction(
            _tx_defaults(w3, payer_addr))
        _send(w3, payer_key, tx)
        print("[subscribed] ext updated")

    assert contracts["registry"].functions.subscriptionCount().call() == 1
    assert contracts["registry"].functions.subs(batch_id).call()[1] == EXTENSION_BLOCKS
    print("[subscribed] done")
    return True


# ---------------------------------------------------------------------------
# Wrangler dev subprocess
# ---------------------------------------------------------------------------

WRANGLER_LOG = GAS_BOY_DIR / ".wrangler-dev.log"


def _wait_for_health(port: int, log_path: Path, proc: subprocess.Popen,
                     timeout: float = 60.0) -> None:
    deadline = time.time() + timeout
    last_err: Exception | None = None
    while time.time() < deadline:
        if proc.poll() is not None:
            tail = log_path.read_text() if log_path.exists() else ""
            raise RuntimeError(
                f"wrangler dev exited with code {proc.returncode} before opening port.\n"
                f"--- log ---\n{tail}"
            )
        try:
            with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/health", timeout=2
            ) as r:
                r.read()
                return
        except Exception as e:
            last_err = e
        time.sleep(0.5)
    tail = log_path.read_text() if log_path.exists() else ""
    raise RuntimeError(
        f"wrangler dev did not respond on /health within {timeout}s "
        f"(last error: {last_err})\n--- log ---\n{tail}"
    )


@pytest.fixture(scope="module")
def wrangler_dev(registry_state, subscribed) -> Iterator[None]:
    # Write .dev.vars with the gas-boy caller's key.
    (GAS_BOY_DIR / ".dev.vars").write_text(f'PRIVATE_KEY="{GAS_BOY_KEY}"\n')

    # Route stdout/stderr to a log file so the subprocess never blocks on
    # a full pipe buffer (which was hanging the test).
    log_file = WRANGLER_LOG.open("w")

    cmd = [
        "wrangler", "dev",
        "--port", str(WRANGLER_PORT),
        "--ip", "127.0.0.1",
        "--var", f"REGISTRY_ADDRESS:{registry_state['address']}",
        "--var", f"RPC_URL:{registry_state['rpc']}",
        "--var", f"CHAIN_ID:{registry_state['chain_id']}",
    ]
    print(f"\n[wrangler] launching: {' '.join(cmd)}  (log: {WRANGLER_LOG})")
    proc = subprocess.Popen(
        cmd,
        cwd=GAS_BOY_DIR,
        stdout=log_file,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        _wait_for_health(WRANGLER_PORT, WRANGLER_LOG, proc)
        print("[wrangler] /health ok")
        yield
    finally:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        log_file.close()
        if WRANGLER_LOG.exists():
            tail_lines = WRANGLER_LOG.read_text().splitlines()[-30:]
            if tail_lines:
                print("\n--- wrangler dev log (last 30 lines) ---")
                print("\n".join(tail_lines))


def _trigger() -> dict[str, Any]:
    with urllib.request.urlopen(f"{WRANGLER_URL}/trigger", timeout=60) as resp:
        body = resp.read().decode()
        assert resp.status in (200, 500), f"unexpected status: {resp.status}"
        return json.loads(body)


def _kept_alive_events(w3: Web3, registry, from_block: int) -> list[EventData]:
    return registry.events.KeptAlive().get_logs(from_block=from_block)


def _skipped_events(w3: Web3, registry, from_block: int) -> list[EventData]:
    return registry.events.KeepaliveSkipped().get_logs(from_block=from_block)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_00_sanity_state_loaded(contracts, registry_state, participants_state):
    assert registry_state["address"].startswith("0x")
    assert contracts["registry"].functions.subscriptionCount().call() >= 0
    assert PAYER_LABEL in participants_state["participants"]


def test_10_subscribe(w3, contracts, subscribed, batch_id, payer):
    # Subscription is in place; batch should NOT be due yet (fresh batch,
    # remaining per-chunk balance is huge relative to the threshold).
    assert contracts["registry"].functions.subscriptionCount().call() == 1
    assert not contracts["registry"].functions.isDue(batch_id).call()


def test_20_trigger_no_op_when_not_due(w3, wrangler_dev, contracts, batch_id, payer):
    registry_addr = contracts["registry"].address
    payer_addr = Web3.to_checksum_address(payer["address"])
    before_block = w3.eth.block_number
    payer_bzz_before = contracts["bzz"].functions.balanceOf(payer_addr).call()
    nonce_before = w3.eth.get_transaction_count(GAS_BOY_ADDR)

    result = _trigger()
    print(f"[not-due] result = {result}")

    assert result["ok"] is True
    assert result.get("dueCount") == 0
    assert result.get("skipped") == "no subscriptions due"
    # No tx should have been sent.
    assert w3.eth.get_transaction_count(GAS_BOY_ADDR) == nonce_before
    # No balance movement.
    assert contracts["bzz"].functions.balanceOf(payer_addr).call() == payer_bzz_before
    # No events since before_block.
    assert _kept_alive_events(w3, contracts["registry"], before_block) == []


def test_30_trigger_tops_up_when_due(w3, wrangler_dev, contracts, batch_id, payer):
    registry = contracts["registry"]
    stamp = contracts["stamp"]
    bzz = contracts["bzz"]
    payer_addr = Web3.to_checksum_address(payer["address"])

    # Drive chain until due.
    mined = _mine_until_due(w3, registry, stamp, batch_id, EXTENSION_BLOCKS)
    print(f"[due] mined {mined} blocks to trigger due state")
    assert registry.functions.isDue(batch_id).call()

    # Snapshot.
    price = stamp.functions.lastPrice().call()
    depth = stamp.functions.batches(batch_id).call()[1]
    threshold = price * EXTENSION_BLOCKS
    expected_total = threshold << depth

    norm_bal_before = stamp.functions.batches(batch_id).call()[4]
    payer_bzz_before = bzz.functions.balanceOf(payer_addr).call()
    stamp_bzz_before = bzz.functions.balanceOf(stamp.address).call()
    nonce_before = w3.eth.get_transaction_count(GAS_BOY_ADDR)
    before_block = w3.eth.block_number

    # Sanity: estimatedTopUp matches our math.
    est_per_chunk, est_total = registry.functions.estimatedTopUp(batch_id).call()
    assert est_per_chunk == threshold
    assert est_total == expected_total

    result = _trigger()
    print(f"[due] result = {result}")

    assert result["ok"] is True, result
    assert result["dueCount"] == 1
    assert result["txHash"].startswith("0x")

    # Exactly one tx from gas-boy.
    assert w3.eth.get_transaction_count(GAS_BOY_ADDR) == nonce_before + 1

    # KeptAlive event with exact values.
    events = _kept_alive_events(w3, registry, before_block)
    assert len(events) == 1, f"expected 1 KeptAlive, got {len(events)}"
    args = events[0]["args"]
    assert args["caller"] == GAS_BOY_ADDR
    assert args["batchId"] == batch_id
    assert args["payer"] == payer_addr
    assert args["topUpPerChunk"] == threshold
    assert args["totalAmount"] == expected_total

    # Balance deltas.
    assert bzz.functions.balanceOf(payer_addr).call() == payer_bzz_before - expected_total
    assert bzz.functions.balanceOf(stamp.address).call() == stamp_bzz_before + expected_total

    # normalisedBalance advanced by threshold.
    assert stamp.functions.batches(batch_id).call()[4] == norm_bal_before + threshold

    # Not due anymore.
    assert not registry.functions.isDue(batch_id).call()


def test_40_hysteresis_second_trigger_noop(w3, wrangler_dev, contracts, batch_id, payer):
    registry = contracts["registry"]
    bzz = contracts["bzz"]
    payer_addr = Web3.to_checksum_address(payer["address"])

    payer_bzz_before = bzz.functions.balanceOf(payer_addr).call()
    nonce_before = w3.eth.get_transaction_count(GAS_BOY_ADDR)
    before_block = w3.eth.block_number

    result = _trigger()
    print(f"[hysteresis] result = {result}")

    assert result["ok"] is True
    assert result.get("dueCount") == 0
    assert w3.eth.get_transaction_count(GAS_BOY_ADDR) == nonce_before
    assert bzz.functions.balanceOf(payer_addr).call() == payer_bzz_before
    assert _kept_alive_events(w3, registry, before_block) == []


def test_50_next_cycle_tops_up_again(w3, wrangler_dev, contracts, batch_id, payer):
    registry = contracts["registry"]
    stamp = contracts["stamp"]
    bzz = contracts["bzz"]
    payer_addr = Web3.to_checksum_address(payer["address"])

    mined = _mine_until_due(w3, registry, stamp, batch_id, EXTENSION_BLOCKS)
    print(f"[cycle2] mined {mined} blocks to trigger second due state")

    price = stamp.functions.lastPrice().call()
    depth = stamp.functions.batches(batch_id).call()[1]
    threshold = price * EXTENSION_BLOCKS
    expected_total = threshold << depth
    norm_bal_before = stamp.functions.batches(batch_id).call()[4]
    payer_bzz_before = bzz.functions.balanceOf(payer_addr).call()
    before_block = w3.eth.block_number

    result = _trigger()
    print(f"[cycle2] result = {result}")

    assert result["ok"] is True and result["dueCount"] == 1

    events = _kept_alive_events(w3, registry, before_block)
    assert len(events) == 1
    assert events[0]["args"]["totalAmount"] == expected_total

    assert stamp.functions.batches(batch_id).call()[4] == norm_bal_before + threshold
    assert bzz.functions.balanceOf(payer_addr).call() == payer_bzz_before - expected_total
    assert not registry.functions.isDue(batch_id).call()


def test_60_failing_sub_emits_skipped(w3, wrangler_dev, contracts, batch_id, payer):
    """If the payer revokes allowance, keepalive should skip that batch,
    emit KeepaliveSkipped, and gas-boy's HTTP handler should still 200."""
    registry = contracts["registry"]
    bzz = contracts["bzz"]
    payer_key = "0x" + payer["signing_key"]
    payer_addr = Web3.to_checksum_address(payer["address"])

    # Revoke allowance.
    tx = bzz.functions.approve(registry.address, 0).build_transaction(_tx_defaults(w3, payer_addr))
    _send(w3, payer_key, tx)
    assert bzz.functions.allowance(payer_addr, registry.address).call() == 0

    # Drive to due.
    _mine_until_due(w3, registry, contracts["stamp"], batch_id, EXTENSION_BLOCKS)
    assert registry.functions.isDue(batch_id).call()

    before_block = w3.eth.block_number
    payer_bzz_before = bzz.functions.balanceOf(payer_addr).call()

    result = _trigger()
    print(f"[fail-sub] result = {result}")

    # Worker still reports ok (the tx itself succeeded — keepalive's try/catch
    # per-batch means the wrapping transaction doesn't revert).
    assert result["ok"] is True
    assert result["dueCount"] == 1

    skipped = _skipped_events(w3, registry, before_block)
    kept = _kept_alive_events(w3, registry, before_block)
    assert len(skipped) == 1, f"expected KeepaliveSkipped, got {len(skipped)}"
    assert skipped[0]["args"]["batchId"] == batch_id
    assert kept == []
    # No BZZ moved.
    assert bzz.functions.balanceOf(payer_addr).call() == payer_bzz_before

    # Restore allowance so cleanup is clean for reruns.
    tx = bzz.functions.approve(registry.address, 2**256 - 1).build_transaction(_tx_defaults(w3, payer_addr))
    _send(w3, payer_key, tx)
