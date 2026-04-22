"""End-to-end integration test for the gas-boy Cloudflare Worker
against the VolumeRegistry contract.

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
from 17280 → 100, allowing a small GRACE_BLOCKS (200) and fast mining.

Then:

    uv run pytest tests/test_gas_boy_e2e.py -s

What this exercises (against the volume model):
  - Deploy + createVolume + designate/confirm flow works against a live
    anvil + PostageStamp.
  - Worker's scheduled() cron correctly no-ops when nothing is due.
  - When blocks are mined past the due threshold, the Worker calls
    `keepalive()` exactly once, emits `KeptAlive`, and advances the
    batch's normalisedBalance by (target - remaining_before).
  - Idempotency: a second cron fire with no block progression is a
    strict no-op (bit-exact, not "approximately").
  - Cycle: mining another grace-period's worth of blocks makes the volume
    due again and the Worker tops it up a second time.
  - A payer that revokes their allowance yields `KeepaliveSkipped` and
    does NOT crash the Worker (scheduled() still completes cleanly).

The test spawns `wrangler dev` as a subprocess and drives it by hitting
wrangler's built-in scheduled-simulation endpoint
(`/cdn-cgi/handler/scheduled`). Since scheduled() doesn't return a body,
results are observed via:
  (a) on-chain events (KeptAlive, KeepaliveSkipped, Pruned, PruneSkipped)
  (b) the JSON log lines gas-boy writes to stdout (captured to a log file)
"""
from __future__ import annotations

import json
import os
import re
import signal
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
WRANGLER_CRON_URL = f"{WRANGLER_URL}/cdn-cgi/handler/scheduled"

# Anvil prefunded account #1 — gas-boy's caller (distinct from op-0/op-1 payer).
GAS_BOY_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
GAS_BOY_ADDR = Account.from_key(GAS_BOY_KEY).address

# We lower PostageStamp.minimumValidityBlocks from 17280 → 100 via
# anvil_setStorageAt (see `lowered_min_validity` fixture), so
# GRACE_BLOCKS can be small and `anvil_mine` calls finish instantly.
GRACE_BLOCKS = 200

# ---------------------------------------------------------------------------
# ABIs (minimal surfaces)
# ---------------------------------------------------------------------------

REGISTRY_ABI = [
    {"type": "function", "name": "designatePayer", "stateMutability": "nonpayable",
     "inputs": [{"type": "address"}], "outputs": []},
    {"type": "function", "name": "confirmAccount", "stateMutability": "nonpayable",
     "inputs": [{"type": "address"}], "outputs": []},
    {"type": "function", "name": "revokeAccount", "stateMutability": "nonpayable",
     "inputs": [{"type": "address"}], "outputs": []},
    {"type": "function", "name": "createVolume", "stateMutability": "nonpayable",
     "inputs": [{"type": "bytes32"}, {"type": "address"}, {"type": "uint64"}, {"type": "uint32"}],
     "outputs": []},
    {"type": "function", "name": "deleteVolume", "stateMutability": "nonpayable",
     "inputs": [{"type": "bytes32"}], "outputs": []},
    {"type": "function", "name": "modifyVolume", "stateMutability": "nonpayable",
     "inputs": [{"type": "bytes32"}, {"type": "uint64"}, {"type": "uint32"}], "outputs": []},
    {"type": "function", "name": "volumes", "stateMutability": "view",
     "inputs": [{"type": "bytes32"}],
     "outputs": [{"type": "address", "name": "owner"},
                 {"type": "address", "name": "chunkSigner"},
                 {"type": "uint64", "name": "ttlExpiry"},
                 {"type": "uint8", "name": "initialDepth"},
                 {"type": "uint32", "name": "graceBlocks"}]},
    {"type": "function", "name": "accounts", "stateMutability": "view",
     "inputs": [{"type": "address"}],
     "outputs": [{"type": "address", "name": "payer"},
                 {"type": "bool", "name": "active"}]},
    {"type": "function", "name": "isDue", "stateMutability": "view",
     "inputs": [{"type": "bytes32"}], "outputs": [{"type": "bool"}]},
    {"type": "function", "name": "isDead", "stateMutability": "view",
     "inputs": [{"type": "bytes32"}], "outputs": [{"type": "bool"}]},
    {"type": "function", "name": "volumeCount", "stateMutability": "view",
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
         {"indexed": False, "name": "perChunk", "type": "uint256"},
         {"indexed": False, "name": "totalAmount", "type": "uint256"}]},
    {"type": "event", "name": "KeepaliveSkipped", "anonymous": False,
     "inputs": [
         {"indexed": True, "name": "batchId", "type": "bytes32"},
         {"indexed": False, "name": "reason", "type": "bytes"}]},
    {"type": "event", "name": "VolumeCreated", "anonymous": False,
     "inputs": [
         {"indexed": True, "name": "batchId", "type": "bytes32"},
         {"indexed": True, "name": "owner", "type": "address"},
         {"indexed": True, "name": "chunkSigner", "type": "address"},
         {"indexed": False, "name": "ttlExpiry", "type": "uint64"},
         {"indexed": False, "name": "initialDepth", "type": "uint8"},
         {"indexed": False, "name": "graceBlocks", "type": "uint32"}]},
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
    pid = chain_state.get("pid")
    if pid:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pytest.fail(
                f"anvil pid {pid} from state/chain.json is dead — "
                f"state is stale, re-run `uv run orion up --profile swarm`"
            )
    w = Web3(Web3.HTTPProvider(chain_state["rpc"], request_kwargs={"timeout": 120}))
    if not w.is_connected():
        pytest.fail(f"anvil not reachable at {chain_state['rpc']} (pid={pid})")
    if w.eth.chain_id != chain_state["chain_id"]:
        pytest.fail("chain_id mismatch — wrong anvil?")
    return w


PAYER_LABEL = "op-1"

@pytest.fixture(scope="module")
def participant(participants_state: dict[str, Any]) -> dict[str, Any]:
    p = participants_state["participants"].get(PAYER_LABEL)
    assert p is not None, f"{PAYER_LABEL} not provisioned — see test docstring"
    assert p["batches"], f"{PAYER_LABEL} has no batch"
    return p


@pytest.fixture(scope="module")
def batch_id(participant: dict[str, Any]) -> bytes:
    return bytes.fromhex(participant["batches"][0]["batch_id"][2:])


@pytest.fixture(scope="module")
def contracts(w3: Web3, deployment_state: dict[str, Any], registry_state: dict[str, Any]):
    addr = Web3.to_checksum_address
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
    w3.provider.make_request("anvil_mine", [hex(n)])


def _fast_forward_to_near_due(w3: Web3, stamp, batch_id: bytes,
                              grace_blocks: int, margin: int = 10) -> None:
    """Bump PostageStamp.totalOutPayment (slot 5) so only `margin` blocks
    of real mining are needed to push the volume into the due state."""
    price = stamp.functions.lastPrice().call()
    if price == 0:
        return
    norm_bal = stamp.functions.batches(batch_id).call()[4]
    cto = stamp.functions.currentTotalOutPayment().call()
    remaining = norm_bal - cto
    target = price * grace_blocks
    gap = remaining - target
    if gap <= price * margin:
        return  # already close enough
    current_top = int.from_bytes(
        w3.eth.get_storage_at(stamp.address, _SLOT_TOTAL_OUT_PAYMENT), "big")
    bump = gap - margin * price
    new_top = current_top + bump
    w3.provider.make_request("anvil_setStorageAt", [
        stamp.address,
        hex(_SLOT_TOTAL_OUT_PAYMENT),
        "0x" + new_top.to_bytes(32, "big").hex(),
    ])


def _mine_until_due(w3: Web3, registry, stamp, batch_id: bytes,
                    grace_blocks: int) -> int:
    if registry.functions.isDue(batch_id).call():
        return 0
    price = stamp.functions.lastPrice().call()
    assert price > 0, "lastPrice is 0 — run `uv run orion prime set-postage-price ...`"

    _fast_forward_to_near_due(w3, stamp, batch_id, grace_blocks)

    norm_bal = stamp.functions.batches(batch_id).call()[4]
    cto = stamp.functions.currentTotalOutPayment().call()
    remaining = norm_bal - cto
    target = price * grace_blocks
    gap = remaining - target
    if gap < 0:
        return 0
    blocks = (gap // price) + 1
    _anvil_mine(w3, int(blocks))
    assert registry.functions.isDue(batch_id).call(), (
        f"still not due after mining {blocks} (price={price} grace={grace_blocks} "
        f"remaining={remaining} target={target})"
    )
    return int(blocks)


# PostageStamp storage layout (from compiled artifact):
#   slot 5: totalOutPayment (uint256)
#   slot 9: lastPrice(uint64, offset 0) | minimumValidityBlocks(uint64, offset 8)
#           | lastUpdatedBlock(uint64, offset 16)
_SLOT_TOTAL_OUT_PAYMENT = 5
_SLOT_PRICE_PACKED = 9
_MIN_VALIDITY_BLOCKS = 100


def _poke_slot9(w3: Web3, stamp_addr: str, *, min_validity: int | None = None) -> None:
    raw = w3.eth.get_storage_at(Web3.to_checksum_address(stamp_addr), _SLOT_PRICE_PACKED)
    val = int.from_bytes(raw, "big")
    mask64 = (1 << 64) - 1
    if min_validity is not None:
        val = (val & ~(mask64 << 64)) | (min_validity << 64)
    w3.provider.make_request("anvil_setStorageAt", [
        Web3.to_checksum_address(stamp_addr),
        hex(_SLOT_PRICE_PACKED),
        "0x" + val.to_bytes(32, "big").hex(),
    ])


@pytest.fixture(scope="module")
def lowered_min_validity(w3: Web3, contracts):
    _poke_slot9(w3, contracts["stamp"].address, min_validity=_MIN_VALIDITY_BLOCKS)
    return True


# ---------------------------------------------------------------------------
# Volume fixture: owner is the participant (payer and owner fold into one
# identity here since the participant already holds BZZ and has a postage
# batch registered with their key as chunkSigner on PostageStamp).
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def volumed(w3: Web3, contracts, participant, batch_id, registry_state, lowered_min_validity):
    """Set up a complete volume: designate+confirm account (self-pay) and
    create the volume entry. Idempotent across test re-runs."""
    print("\n[volumed] starting")
    key = "0x" + participant["signing_key"]
    addr = Web3.to_checksum_address(participant["address"])
    registry_addr = Web3.to_checksum_address(registry_state["address"])

    # Approve BZZ to registry (max) if not already
    cur = contracts["bzz"].functions.allowance(addr, registry_addr).call()
    if cur < 2**255:
        _send(w3, key, contracts["bzz"].functions.approve(
            registry_addr, 2**256 - 1
        ).build_transaction(_tx_defaults(w3, addr)))
        print("[volumed] approved BZZ")

    # Self-pay handshake: designate self, then confirm self
    acct_payer, acct_active = contracts["registry"].functions.accounts(addr).call()
    if not (acct_active and acct_payer == addr):
        _send(w3, key, contracts["registry"].functions.designatePayer(addr).build_transaction(
            _tx_defaults(w3, addr)))
        _send(w3, key, contracts["registry"].functions.confirmAccount(addr).build_transaction(
            _tx_defaults(w3, addr)))
        print("[volumed] handshake completed")

    # Create volume if not present (owner = chunkSigner = participant)
    existing_owner, *_ = contracts["registry"].functions.volumes(batch_id).call()
    if existing_owner == "0x0000000000000000000000000000000000000000":
        _send(w3, key, contracts["registry"].functions.createVolume(
            batch_id, addr, 0, GRACE_BLOCKS
        ).build_transaction(_tx_defaults(w3, addr)))
        print("[volumed] volume created")

    assert contracts["registry"].functions.volumeCount().call() == 1
    print("[volumed] done")
    return True


# ---------------------------------------------------------------------------
# Wrangler dev subprocess + cron simulation helper
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
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as r:
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
def wrangler_dev(registry_state, volumed) -> Iterator[None]:
    (GAS_BOY_DIR / ".dev.vars").write_text(f'PRIVATE_KEY="{GAS_BOY_KEY}"\n')
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
        cmd, cwd=GAS_BOY_DIR,
        stdout=log_file, stderr=subprocess.STDOUT,
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


_LOG_RE = re.compile(r'\{"kind":"gas-boy/scheduled"[^}]*\}')


def _cron() -> dict[str, Any]:
    """Fire wrangler's scheduled handler and return the parsed RunResult.

    Wrangler's cron simulation endpoint returns no body, so we scrape the
    latest `gas-boy/scheduled` JSON log line written to WRANGLER_LOG after
    the request settles.
    """
    log_len_before = WRANGLER_LOG.stat().st_size if WRANGLER_LOG.exists() else 0
    with urllib.request.urlopen(WRANGLER_CRON_URL, timeout=60) as resp:
        assert resp.status == 200, f"unexpected status: {resp.status}"
        resp.read()

    # Poll the log file for the new JSON log line
    deadline = time.time() + 30
    while time.time() < deadline:
        if WRANGLER_LOG.exists() and WRANGLER_LOG.stat().st_size > log_len_before:
            with WRANGLER_LOG.open("r") as f:
                f.seek(log_len_before)
                new = f.read()
            matches = _LOG_RE.findall(new)
            if matches:
                return json.loads(matches[-1])
        time.sleep(0.1)
    raise RuntimeError(f"no gas-boy/scheduled log line observed after cron fire")


def _kept_alive_events(registry, from_block: int) -> list[EventData]:
    return registry.events.KeptAlive().get_logs(from_block=from_block)


def _skipped_events(registry, from_block: int) -> list[EventData]:
    return registry.events.KeepaliveSkipped().get_logs(from_block=from_block)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_00_sanity_state_loaded(contracts, registry_state, participants_state):
    assert registry_state["address"].startswith("0x")
    assert contracts["registry"].functions.volumeCount().call() >= 0
    assert PAYER_LABEL in participants_state["participants"]


def test_10_volume_setup(contracts, volumed, batch_id, participant):
    addr = Web3.to_checksum_address(participant["address"])
    assert contracts["registry"].functions.volumeCount().call() == 1
    assert not contracts["registry"].functions.isDue(batch_id).call()
    (payer, active) = contracts["registry"].functions.accounts(addr).call()
    assert active and payer == addr


def test_20_cron_no_op_when_not_due(w3, wrangler_dev, contracts, batch_id, participant):
    addr = Web3.to_checksum_address(participant["address"])
    # +1 so we only match events from NEW blocks mined during this test,
    # not whatever was at the latest block when we took the snapshot.
    before_block = w3.eth.block_number + 1
    bzz_before = contracts["bzz"].functions.balanceOf(addr).call()
    nonce_before = w3.eth.get_transaction_count(GAS_BOY_ADDR)

    result = _cron()
    print(f"[not-due] result = {result}")

    assert result["ok"] is True
    assert result.get("dueCount") == 0
    assert result.get("deadCount") == 0
    assert result.get("skipped") == "no subscriptions actionable"
    assert w3.eth.get_transaction_count(GAS_BOY_ADDR) == nonce_before
    assert contracts["bzz"].functions.balanceOf(addr).call() == bzz_before
    assert _kept_alive_events(contracts["registry"], before_block) == []


def test_30_cron_tops_up_when_due(w3, wrangler_dev, contracts, batch_id, participant):
    registry = contracts["registry"]
    stamp = contracts["stamp"]
    bzz = contracts["bzz"]
    addr = Web3.to_checksum_address(participant["address"])

    mined = _mine_until_due(w3, registry, stamp, batch_id, GRACE_BLOCKS)
    print(f"[due] mined {mined} blocks")
    assert registry.functions.isDue(batch_id).call()

    price = stamp.functions.lastPrice().call()
    depth = stamp.functions.batches(batch_id).call()[1]
    target = price * GRACE_BLOCKS

    bzz_before = bzz.functions.balanceOf(addr).call()
    stamp_bzz_before = bzz.functions.balanceOf(stamp.address).call()
    nonce_before = w3.eth.get_transaction_count(GAS_BOY_ADDR)
    before_block = w3.eth.block_number

    # estimatedTopUp and KeptAlive's exact `perChunk` depend on the block
    # at which the tx is mined (cto advances by `price` each block), not
    # the block at which we took the Python-side snapshot. The robust
    # invariant to assert is the post-condition: remaining == target
    # after the top-up (which is the whole point of precise targeting).

    result = _cron()
    print(f"[due] result = {result}")

    assert result["ok"] is True, result
    assert result["dueCount"] == 1
    assert result["txHash"].startswith("0x")
    assert w3.eth.get_transaction_count(GAS_BOY_ADDR) == nonce_before + 1

    events = _kept_alive_events(registry, before_block)
    assert len(events) == 1, f"expected 1 KeptAlive, got {len(events)}"
    args = events[0]["args"]
    assert args["caller"] == GAS_BOY_ADDR
    assert args["batchId"] == batch_id
    assert args["payer"] == addr
    actual_per_chunk = args["perChunk"]
    actual_total = args["totalAmount"]
    assert actual_total == actual_per_chunk << depth
    assert 0 < actual_per_chunk <= target

    # Payer paid exactly the emitted totalAmount
    assert bzz.functions.balanceOf(addr).call() == bzz_before - actual_total
    assert bzz.functions.balanceOf(stamp.address).call() == stamp_bzz_before + actual_total

    # Post-topup invariant: remaining landed exactly on target.
    norm_bal_after = stamp.functions.batches(batch_id).call()[4]
    cto_after = stamp.functions.currentTotalOutPayment().call()
    assert norm_bal_after - cto_after == target
    assert not registry.functions.isDue(batch_id).call()


def test_40_idempotent_second_cron_strict_noop(w3, wrangler_dev, contracts, batch_id, participant):
    registry = contracts["registry"]
    bzz = contracts["bzz"]
    addr = Web3.to_checksum_address(participant["address"])

    bzz_before = bzz.functions.balanceOf(addr).call()
    nonce_before = w3.eth.get_transaction_count(GAS_BOY_ADDR)
    # +1 so test_30's KeptAlive (at the latest block before this test
    # started) isn't falsely matched by `get_logs(from_block=...)`.
    before_block = w3.eth.block_number + 1

    result = _cron()
    print(f"[idempotent] result = {result}")

    assert result["ok"] is True
    assert result.get("dueCount") == 0
    assert w3.eth.get_transaction_count(GAS_BOY_ADDR) == nonce_before
    assert bzz.functions.balanceOf(addr).call() == bzz_before
    assert _kept_alive_events(registry, before_block) == []


def test_50_next_cycle_tops_up_again(w3, wrangler_dev, contracts, batch_id, participant):
    registry = contracts["registry"]
    stamp = contracts["stamp"]
    bzz = contracts["bzz"]
    addr = Web3.to_checksum_address(participant["address"])

    mined = _mine_until_due(w3, registry, stamp, batch_id, GRACE_BLOCKS)
    print(f"[cycle2] mined {mined} blocks")

    price = stamp.functions.lastPrice().call()
    depth = stamp.functions.batches(batch_id).call()[1]
    target = price * GRACE_BLOCKS
    bzz_before = bzz.functions.balanceOf(addr).call()
    before_block = w3.eth.block_number

    result = _cron()
    print(f"[cycle2] result = {result}")

    assert result["ok"] is True and result["dueCount"] == 1
    events = _kept_alive_events(registry, before_block)
    assert len(events) == 1

    actual_total = events[0]["args"]["totalAmount"]
    assert actual_total == events[0]["args"]["perChunk"] << depth
    # Post-topup invariant: remaining landed on target (block-timing-independent).
    norm_bal_after = stamp.functions.batches(batch_id).call()[4]
    cto_after = stamp.functions.currentTotalOutPayment().call()
    assert norm_bal_after - cto_after == target
    assert bzz.functions.balanceOf(addr).call() == bzz_before - actual_total
    assert not registry.functions.isDue(batch_id).call()


def test_60_failing_pull_emits_skipped(w3, wrangler_dev, contracts, batch_id, participant):
    """Payer revokes allowance → keepalive's per-volume try/catch emits
    KeepaliveSkipped; gas-boy's scheduled still completes cleanly."""
    registry = contracts["registry"]
    bzz = contracts["bzz"]
    key = "0x" + participant["signing_key"]
    addr = Web3.to_checksum_address(participant["address"])

    _send(w3, key, bzz.functions.approve(registry.address, 0).build_transaction(
        _tx_defaults(w3, addr)))
    assert bzz.functions.allowance(addr, registry.address).call() == 0

    _mine_until_due(w3, registry, contracts["stamp"], batch_id, GRACE_BLOCKS)
    assert registry.functions.isDue(batch_id).call()

    before_block = w3.eth.block_number
    bzz_before = bzz.functions.balanceOf(addr).call()

    result = _cron()
    print(f"[fail-pull] result = {result}")

    assert result["ok"] is True
    assert result["dueCount"] == 1

    skipped = _skipped_events(registry, before_block)
    kept = _kept_alive_events(registry, before_block)
    assert len(skipped) == 1, f"expected KeepaliveSkipped, got {len(skipped)}"
    assert skipped[0]["args"]["batchId"] == batch_id
    assert kept == []
    assert bzz.functions.balanceOf(addr).call() == bzz_before

    # Restore allowance so cleanup is clean for reruns.
    _send(w3, key, bzz.functions.approve(registry.address, 2**256 - 1).build_transaction(
        _tx_defaults(w3, addr)))
