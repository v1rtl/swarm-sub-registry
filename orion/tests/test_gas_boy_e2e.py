"""End-to-end integration test for the gas-boy Cloudflare Worker against
the rewritten VolumeRegistry (DESIGN.md / TEST-PLAN.md §5).

This is the L3 scope: orion spins up anvil with the Swarm constellation,
`deploy-to-orion.sh` lowers PostageStamp.minimumValidityBlocks and deploys
the registry, the test creates volumes via the new two-role handshake,
drives wrangler dev's scheduled endpoint, and asserts on-chain state.

Prerequisites (all run from repo root; see gas-boy/scripts/start-dev.sh
for a one-shot driver):

    cd orion
    uv run orion up --profile swarm
    uv run orion prime set-postage-price --wei-per-chunkblock 44445
    uv run orion participants provision --label op-1 --overlays 1 \
        --balance-per-chunk 2000000000
    ../gas-boy/scripts/deploy-to-orion.sh
    uv run pytest tests/test_gas_boy_e2e.py -s

The participant's existing Postage batch (from `orion participants provision`)
is NOT used — the new VolumeRegistry creates its own batches on `createVolume`.
The participant's key serves as:
  - the volume owner (msg.sender on createVolume),
  - the chunkSigner (owner of the Postage batch created by the registry),
  - the designated payer (self-pay — owner == payer).

What this exercises against the volume model:
  - Two-role account handshake: designate + confirm.
  - createVolume charges `graceBlocks × lastPrice × (1<<depth)` from the payer
    and produces a Postage batch with owner=chunkSigner (I1).
  - Worker's scheduled() no-ops when no volumes are due.
  - Mining past the due threshold triggers one `trigger(ids[])` tx with a
    Toppedup event on the registry.
  - Idempotence: a second cron fire with no block progression is a
    strict no-op (I5).
  - Next cycle's fresh topup lands the remaining balance back on target.
  - Payer revokes allowance → TopupSkipped(PaymentFailed); volume still
    Active; worker does not throw (partial-failure path in trigger).
  - revoke(owner) → TopupSkipped(NoAuth) for every volume under that
    (owner, payer) pair (I9 end-to-end).
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

# Anvil prefunded account #1 — gas-boy's caller (distinct from participants).
GAS_BOY_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
GAS_BOY_ADDR = Account.from_key(GAS_BOY_KEY).address

# Registry fixture params (match gas-boy/scripts/deploy-to-orion.sh defaults).
GRACE_BLOCKS = 200

# createVolume parameters. Depth and bucket chosen to satisfy PostageStamp's
# minimumBucketDepth=16 constraint while keeping the charge manageable.
DEPTH = 20
BUCKET_DEPTH = 16

# ---------------------------------------------------------------------------
# ABIs (minimal surfaces of the rewritten VolumeRegistry)
# ---------------------------------------------------------------------------

REGISTRY_ABI = [
    {"type": "function", "name": "designateFundingWallet",
     "stateMutability": "nonpayable",
     "inputs": [{"name": "payer", "type": "address"}], "outputs": []},
    {"type": "function", "name": "confirmAuth",
     "stateMutability": "nonpayable",
     "inputs": [{"name": "owner", "type": "address"}], "outputs": []},
    {"type": "function", "name": "revoke",
     "stateMutability": "nonpayable",
     "inputs": [{"name": "owner", "type": "address"}], "outputs": []},
    {"type": "function", "name": "createVolume",
     "stateMutability": "nonpayable",
     "inputs": [
         {"name": "chunkSigner", "type": "address"},
         {"name": "depth", "type": "uint8"},
         {"name": "bucketDepth", "type": "uint8"},
         {"name": "ttlExpiry", "type": "uint64"},
         {"name": "immutableBatch", "type": "bool"},
     ],
     "outputs": [{"type": "bytes32"}]},
    {"type": "function", "name": "deleteVolume",
     "stateMutability": "nonpayable",
     "inputs": [{"type": "bytes32"}], "outputs": []},
    {"type": "function", "name": "transferVolumeOwnership",
     "stateMutability": "nonpayable",
     "inputs": [{"type": "bytes32"}, {"type": "address"}], "outputs": []},
    {"type": "function", "name": "trigger",
     "stateMutability": "nonpayable",
     "inputs": [{"name": "volumeIds", "type": "bytes32[]"}], "outputs": []},
    {"type": "function", "name": "reap",
     "stateMutability": "nonpayable",
     "inputs": [{"type": "bytes32"}], "outputs": []},
    {"type": "function", "name": "getActiveVolumeCount",
     "stateMutability": "view",
     "inputs": [], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "getActiveVolumes",
     "stateMutability": "view",
     "inputs": [{"type": "uint256"}, {"type": "uint256"}],
     "outputs": [{
         "type": "tuple[]",
         "components": [
             {"name": "volumeId", "type": "bytes32"},
             {"name": "owner", "type": "address"},
             {"name": "payer", "type": "address"},
             {"name": "chunkSigner", "type": "address"},
             {"name": "createdAt", "type": "uint64"},
             {"name": "ttlExpiry", "type": "uint64"},
             {"name": "depth", "type": "uint8"},
             {"name": "status", "type": "uint8"},
             {"name": "accountActive", "type": "bool"},
         ],
     }]},
    {"type": "function", "name": "getVolume",
     "stateMutability": "view",
     "inputs": [{"type": "bytes32"}],
     "outputs": [{
         "type": "tuple",
         "components": [
             {"name": "volumeId", "type": "bytes32"},
             {"name": "owner", "type": "address"},
             {"name": "payer", "type": "address"},
             {"name": "chunkSigner", "type": "address"},
             {"name": "createdAt", "type": "uint64"},
             {"name": "ttlExpiry", "type": "uint64"},
             {"name": "depth", "type": "uint8"},
             {"name": "status", "type": "uint8"},
             {"name": "accountActive", "type": "bool"},
         ],
     }]},
    {"type": "function", "name": "getAccount",
     "stateMutability": "view",
     "inputs": [{"type": "address"}],
     "outputs": [{
         "type": "tuple",
         "components": [
             {"name": "payer", "type": "address"},
             {"name": "active", "type": "bool"},
         ],
     }]},
    {"type": "function", "name": "graceBlocks",
     "stateMutability": "view",
     "inputs": [], "outputs": [{"type": "uint64"}]},
    # Events
    {"type": "event", "name": "VolumeCreated", "anonymous": False, "inputs": [
        {"indexed": True, "name": "volumeId", "type": "bytes32"},
        {"indexed": True, "name": "owner", "type": "address"},
        {"indexed": False, "name": "chunkSigner", "type": "address"},
        {"indexed": False, "name": "depth", "type": "uint8"},
        {"indexed": False, "name": "ttlExpiry", "type": "uint64"}]},
    {"type": "event", "name": "VolumeRetired", "anonymous": False, "inputs": [
        {"indexed": True, "name": "volumeId", "type": "bytes32"},
        {"indexed": False, "name": "reason", "type": "uint8"}]},
    {"type": "event", "name": "Toppedup", "anonymous": False, "inputs": [
        {"indexed": True, "name": "volumeId", "type": "bytes32"},
        {"indexed": False, "name": "amount", "type": "uint256"},
        {"indexed": False, "name": "newNormalisedBalance", "type": "uint256"}]},
    {"type": "event", "name": "TopupSkipped", "anonymous": False, "inputs": [
        {"indexed": True, "name": "volumeId", "type": "bytes32"},
        {"indexed": False, "name": "reason", "type": "uint8"}]},
    {"type": "event", "name": "AccountActivated", "anonymous": False, "inputs": [
        {"indexed": True, "name": "owner", "type": "address"},
        {"indexed": True, "name": "payer", "type": "address"}]},
    {"type": "event", "name": "AccountRevoked", "anonymous": False, "inputs": [
        {"indexed": True, "name": "owner", "type": "address"},
        {"indexed": True, "name": "payer", "type": "address"},
        {"indexed": False, "name": "revoker", "type": "address"}]},
]

# Retirement / skip reason enums — mirror VolumeRegistry.sol constants.
REASON_OWNER_DELETED = 1
REASON_VOLUME_EXPIRED = 2
REASON_BATCH_DIED = 3
REASON_DEPTH_CHANGED = 4
REASON_BATCH_OWNER_MISMATCH = 5
SKIP_NO_AUTH = 1
SKIP_PAYMENT_FAILED = 2
STATUS_ACTIVE = 1
STATUS_RETIRED = 2

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
    {"type": "function", "name": "minimumValidityBlocks", "stateMutability": "view",
     "inputs": [], "outputs": [{"type": "uint64"}]},
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
    return p


@pytest.fixture(scope="module")
def contracts(w3: Web3, deployment_state: dict[str, Any], registry_state: dict[str, Any]):
    addr = Web3.to_checksum_address
    return {
        "registry": w3.eth.contract(
            address=addr(registry_state["address"]), abi=REGISTRY_ABI
        ),
        "bzz": w3.eth.contract(
            address=addr(deployment_state["contracts"]["Token"]), abi=ERC20_ABI
        ),
        "stamp": w3.eth.contract(
            address=addr(deployment_state["contracts"]["PostageStamp"]), abi=STAMP_ABI
        ),
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
        "gas": 3_000_000,
        "gasPrice": w3.eth.gas_price,
    }


def _anvil_mine(w3: Web3, n: int) -> None:
    w3.provider.make_request("anvil_mine", [hex(n)])


# PostageStamp storage: slot 5 = totalOutPayment (uint256).
# Used to fast-forward drain without mining millions of blocks.
_SLOT_TOTAL_OUT_PAYMENT = 5


def _remaining_per_chunk(stamp, volume_id: bytes) -> int:
    nb = stamp.functions.batches(volume_id).call()[4]
    cto = stamp.functions.currentTotalOutPayment().call()
    return nb - cto


def _is_due(stamp, registry, volume_id: bytes) -> bool:
    """Replicate gas-boy's client-side due check."""
    remaining = _remaining_per_chunk(stamp, volume_id)
    if remaining <= 0:
        return False
    price = stamp.functions.lastPrice().call()
    grace = registry.functions.graceBlocks().call()
    target = price * grace
    return remaining < target


def _fast_forward_to_near_due(
    w3: Web3, stamp, volume_id: bytes, grace_blocks: int, margin: int = 10
) -> None:
    """Bump totalOutPayment so only `margin` blocks of real mining are
    needed to push the volume into the due state."""
    price = stamp.functions.lastPrice().call()
    if price == 0:
        return
    norm_bal = stamp.functions.batches(volume_id).call()[4]
    cto = stamp.functions.currentTotalOutPayment().call()
    remaining = norm_bal - cto
    target = price * grace_blocks
    gap = remaining - target
    if gap <= price * margin:
        return
    current_top = int.from_bytes(
        w3.eth.get_storage_at(stamp.address, _SLOT_TOTAL_OUT_PAYMENT), "big"
    )
    bump = gap - margin * price
    new_top = current_top + bump
    w3.provider.make_request(
        "anvil_setStorageAt",
        [
            stamp.address,
            hex(_SLOT_TOTAL_OUT_PAYMENT),
            "0x" + new_top.to_bytes(32, "big").hex(),
        ],
    )


def _mine_until_due(
    w3: Web3, registry, stamp, volume_id: bytes, grace_blocks: int
) -> int:
    if _is_due(stamp, registry, volume_id):
        return 0
    price = stamp.functions.lastPrice().call()
    assert price > 0, "lastPrice is 0 — run `uv run orion prime set-postage-price ...`"
    _fast_forward_to_near_due(w3, stamp, volume_id, grace_blocks)

    norm_bal = stamp.functions.batches(volume_id).call()[4]
    cto = stamp.functions.currentTotalOutPayment().call()
    remaining = norm_bal - cto
    target = price * grace_blocks
    gap = remaining - target
    if gap < 0:
        return 0
    blocks = (gap // price) + 1
    _anvil_mine(w3, int(blocks))
    assert _is_due(stamp, registry, volume_id), (
        f"still not due after mining {blocks} "
        f"(price={price} grace={grace_blocks} remaining={remaining} target={target})"
    )
    return int(blocks)


# ---------------------------------------------------------------------------
# Volume lifecycle fixture
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def volume_id(
    w3: Web3, contracts, participant, registry_state
) -> bytes:
    """Set up a single volume. Self-pay: participant is both owner and
    payer. Returns the created volumeId. Idempotent across test re-runs:
    if an active volume already exists for this owner we reuse it.
    """
    print("\n[volume_setup] starting")
    key = "0x" + participant["signing_key"]
    addr = Web3.to_checksum_address(participant["address"])
    registry = contracts["registry"]
    registry_addr = registry.address

    # 0. Sanity: PostageStamp.minimumValidityBlocks lowered by deploy script.
    mvb = contracts["stamp"].functions.minimumValidityBlocks().call()
    assert mvb <= GRACE_BLOCKS, (
        f"PostageStamp.minimumValidityBlocks={mvb} > graceBlocks={GRACE_BLOCKS}; "
        f"re-run gas-boy/scripts/deploy-to-orion.sh which lowers it via "
        f"anvil_setStorageAt"
    )

    # 1. Max BZZ approval to registry (idempotent).
    cur = contracts["bzz"].functions.allowance(addr, registry_addr).call()
    if cur < 2**255:
        _send(
            w3, key,
            contracts["bzz"].functions.approve(
                registry_addr, 2**256 - 1
            ).build_transaction(_tx_defaults(w3, addr)),
        )
        print("[volume_setup] approved BZZ")

    # 2. Self-pay handshake.
    acct = registry.functions.getAccount(addr).call()
    acct_payer, acct_active = acct[0], acct[1]
    if not (acct_active and acct_payer == addr):
        _send(
            w3, key,
            registry.functions.designateFundingWallet(addr).build_transaction(
                _tx_defaults(w3, addr)
            ),
        )
        _send(
            w3, key,
            registry.functions.confirmAuth(addr).build_transaction(
                _tx_defaults(w3, addr)
            ),
        )
        print("[volume_setup] handshake complete")

    # 3. Reuse any existing active volume for this owner; else create.
    count = registry.functions.getActiveVolumeCount().call()
    existing: bytes | None = None
    if count > 0:
        page = registry.functions.getActiveVolumes(0, count).call()
        for v in page:
            if v[1].lower() == addr.lower() and v[7] == STATUS_ACTIVE:
                existing = v[0]
                break
    if existing is None:
        tx = registry.functions.createVolume(
            addr, DEPTH, BUCKET_DEPTH, 0, False
        ).build_transaction(_tx_defaults(w3, addr))
        r = _send(w3, key, tx)
        created_events = registry.events.VolumeCreated().process_receipt(r)
        assert len(created_events) == 1, f"expected 1 VolumeCreated, got {len(created_events)}"
        existing = created_events[0]["args"]["volumeId"]
        print(f"[volume_setup] volume created: 0x{existing.hex()}")
    else:
        print(f"[volume_setup] reusing existing volume: 0x{existing.hex()}")

    assert registry.functions.getActiveVolumeCount().call() >= 1
    return existing


# ---------------------------------------------------------------------------
# Wrangler dev subprocess
# ---------------------------------------------------------------------------

WRANGLER_LOG = GAS_BOY_DIR / ".wrangler-dev.log"


def _wait_for_health(
    port: int, log_path: Path, proc: subprocess.Popen, timeout: float = 60.0
) -> None:
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
def wrangler_dev(registry_state, volume_id) -> Iterator[None]:
    (GAS_BOY_DIR / ".dev.vars").write_text(f'PRIVATE_KEY="{GAS_BOY_KEY}"\n')
    log_file = WRANGLER_LOG.open("w")
    cmd = [
        "wrangler", "dev",
        "--port", str(WRANGLER_PORT),
        "--ip", "127.0.0.1",
        "--var", f"REGISTRY_ADDRESS:{registry_state['address']}",
        "--var", f"POSTAGE_ADDRESS:{registry_state['postage_stamp']}",
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

    Wrangler's cron simulation returns no body; we scrape the latest
    `gas-boy/scheduled` JSON log line written after the request settles.
    """
    log_len_before = WRANGLER_LOG.stat().st_size if WRANGLER_LOG.exists() else 0
    with urllib.request.urlopen(WRANGLER_CRON_URL, timeout=60) as resp:
        assert resp.status == 200, f"unexpected status: {resp.status}"
        resp.read()

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
    raise RuntimeError("no gas-boy/scheduled log line observed after cron fire")


def _toppedup_events(registry, from_block: int) -> list[EventData]:
    return registry.events.Toppedup().get_logs(from_block=from_block)


def _skipped_events(registry, from_block: int) -> list[EventData]:
    return registry.events.TopupSkipped().get_logs(from_block=from_block)


def _retired_events(registry, from_block: int) -> list[EventData]:
    return registry.events.VolumeRetired().get_logs(from_block=from_block)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_00_sanity_state_loaded(contracts, registry_state, participants_state):
    assert registry_state["address"].startswith("0x")
    # graceBlocks read from the live registry matches the state file.
    grace_onchain = contracts["registry"].functions.graceBlocks().call()
    assert grace_onchain == registry_state.get("grace_blocks", GRACE_BLOCKS)
    assert PAYER_LABEL in participants_state["participants"]


def test_10_volume_setup(contracts, volume_id, participant):
    addr = Web3.to_checksum_address(participant["address"])
    registry = contracts["registry"]
    assert registry.functions.getActiveVolumeCount().call() >= 1

    v = registry.functions.getVolume(volume_id).call()
    assert v[0] == volume_id
    assert v[1].lower() == addr.lower()
    assert v[2].lower() == addr.lower() # payer == owner (self-pay)
    assert v[3].lower() == addr.lower() # chunkSigner == owner
    assert v[7] == STATUS_ACTIVE
    assert v[8] is True # accountActive

    # Sanity: not yet due (fresh batch at target).
    assert not _is_due(contracts["stamp"], registry, volume_id)


def test_20_cron_no_op_when_not_due(
    w3, wrangler_dev, contracts, volume_id, participant
):
    addr = Web3.to_checksum_address(participant["address"])
    # +1 so we only match events from blocks mined during this test.
    before_block = w3.eth.block_number + 1
    bzz_before = contracts["bzz"].functions.balanceOf(addr).call()
    nonce_before = w3.eth.get_transaction_count(GAS_BOY_ADDR)

    result = _cron()
    print(f"[not-due] result = {result}")

    assert result["ok"] is True
    # activeCount ≥ 1 but dueCount == 0 → worker sends no tx.
    assert result.get("dueCount") == 0
    assert result.get("skipped") in (
        "no due volumes",
        "no active volumes",
    )
    assert w3.eth.get_transaction_count(GAS_BOY_ADDR) == nonce_before
    assert contracts["bzz"].functions.balanceOf(addr).call() == bzz_before
    assert _toppedup_events(contracts["registry"], before_block) == []


def test_30_cron_triggers_when_due(
    w3, wrangler_dev, contracts, volume_id, participant
):
    registry = contracts["registry"]
    stamp = contracts["stamp"]
    bzz = contracts["bzz"]
    addr = Web3.to_checksum_address(participant["address"])

    mined = _mine_until_due(w3, registry, stamp, volume_id, GRACE_BLOCKS)
    print(f"[due] mined {mined} blocks")
    assert _is_due(stamp, registry, volume_id)

    price = stamp.functions.lastPrice().call()
    depth = stamp.functions.batches(volume_id).call()[1]
    target = price * GRACE_BLOCKS

    bzz_before = bzz.functions.balanceOf(addr).call()
    stamp_bzz_before = bzz.functions.balanceOf(stamp.address).call()
    nonce_before = w3.eth.get_transaction_count(GAS_BOY_ADDR)
    before_block = w3.eth.block_number

    result = _cron()
    print(f"[due] result = {result}")

    assert result["ok"] is True, result
    assert result["dueCount"] == 1
    assert result["txHash"].startswith("0x")
    assert w3.eth.get_transaction_count(GAS_BOY_ADDR) == nonce_before + 1

    events = _toppedup_events(registry, before_block)
    assert len(events) == 1, f"expected 1 Toppedup, got {len(events)}"
    args = events[0]["args"]
    assert args["volumeId"] == volume_id
    actual_amount = args["amount"]

    # amount == deficit << depth, deficit = target - remaining_at_tx.
    # remaining_at_tx varies with mining timing, so we check invariants
    # instead: amount > 0 and amount ≤ target << depth (full top-up bound).
    assert 0 < actual_amount <= (target << depth)

    # Payer balance went down by exactly the emitted amount.
    assert bzz.functions.balanceOf(addr).call() == bzz_before - actual_amount
    assert bzz.functions.balanceOf(stamp.address).call() == stamp_bzz_before + actual_amount

    # Post-topup invariant: remaining per-chunk landed on target.
    assert _remaining_per_chunk(stamp, volume_id) == target
    assert not _is_due(stamp, registry, volume_id)


def test_40_idempotent_second_cron_strict_noop(
    w3, wrangler_dev, contracts, volume_id, participant
):
    """I5: a second cron fire in the same block range produces no tx."""
    registry = contracts["registry"]
    bzz = contracts["bzz"]
    addr = Web3.to_checksum_address(participant["address"])

    bzz_before = bzz.functions.balanceOf(addr).call()
    nonce_before = w3.eth.get_transaction_count(GAS_BOY_ADDR)
    before_block = w3.eth.block_number + 1

    result = _cron()
    print(f"[idempotent] result = {result}")

    assert result["ok"] is True
    assert result.get("dueCount") == 0
    assert w3.eth.get_transaction_count(GAS_BOY_ADDR) == nonce_before
    assert bzz.functions.balanceOf(addr).call() == bzz_before
    assert _toppedup_events(registry, before_block) == []


def test_50_next_cycle_tops_up_again(
    w3, wrangler_dev, contracts, volume_id, participant
):
    registry = contracts["registry"]
    stamp = contracts["stamp"]
    bzz = contracts["bzz"]
    addr = Web3.to_checksum_address(participant["address"])

    mined = _mine_until_due(w3, registry, stamp, volume_id, GRACE_BLOCKS)
    print(f"[cycle2] mined {mined} blocks")

    price = stamp.functions.lastPrice().call()
    target = price * GRACE_BLOCKS
    bzz_before = bzz.functions.balanceOf(addr).call()
    before_block = w3.eth.block_number

    result = _cron()
    print(f"[cycle2] result = {result}")

    assert result["ok"] is True and result["dueCount"] == 1
    events = _toppedup_events(registry, before_block)
    assert len(events) == 1
    actual_amount = events[0]["args"]["amount"]
    assert bzz.functions.balanceOf(addr).call() == bzz_before - actual_amount
    assert _remaining_per_chunk(stamp, volume_id) == target
    assert not _is_due(stamp, registry, volume_id)


def test_60_payment_failure_is_skip_not_retire(
    w3, wrangler_dev, contracts, volume_id, participant
):
    """TEST-PLAN §3.4 / §5.1 S7b: payer revokes allowance → TopupSkipped
    (PaymentFailed); volume still Active; worker returns cleanly."""
    registry = contracts["registry"]
    bzz = contracts["bzz"]
    stamp = contracts["stamp"]
    key = "0x" + participant["signing_key"]
    addr = Web3.to_checksum_address(participant["address"])

    _send(
        w3, key,
        bzz.functions.approve(registry.address, 0).build_transaction(
            _tx_defaults(w3, addr)
        ),
    )
    assert bzz.functions.allowance(addr, registry.address).call() == 0

    _mine_until_due(w3, registry, stamp, volume_id, GRACE_BLOCKS)
    assert _is_due(stamp, registry, volume_id)

    before_block = w3.eth.block_number
    bzz_before = bzz.functions.balanceOf(addr).call()

    result = _cron()
    print(f"[fail-pull] result = {result}")

    assert result["ok"] is True
    # gas-boy's client-side filter still marks the volume due (it doesn't
    # know about allowance); the contract emits TopupSkipped.
    assert result["dueCount"] == 1

    skipped = _skipped_events(registry, before_block)
    toppedup = _toppedup_events(registry, before_block)
    retired = _retired_events(registry, before_block)
    assert len(skipped) == 1, f"expected TopupSkipped, got {len(skipped)}"
    assert skipped[0]["args"]["volumeId"] == volume_id
    assert skipped[0]["args"]["reason"] == SKIP_PAYMENT_FAILED
    assert toppedup == []
    assert retired == [], "PaymentFailed must not retire the volume"
    assert bzz.functions.balanceOf(addr).call() == bzz_before

    # Volume still Active.
    v = registry.functions.getVolume(volume_id).call()
    assert v[7] == STATUS_ACTIVE

    # Restore allowance for subsequent tests.
    _send(
        w3, key,
        bzz.functions.approve(registry.address, 2**256 - 1).build_transaction(
            _tx_defaults(w3, addr)
        ),
    )


def test_70_revoke_account_yields_noauth_skip(
    w3, wrangler_dev, contracts, volume_id, participant
):
    """I9 end-to-end: revoke(owner) → TopupSkipped(NoAuth); balance unchanged."""
    registry = contracts["registry"]
    bzz = contracts["bzz"]
    stamp = contracts["stamp"]
    key = "0x" + participant["signing_key"]
    addr = Web3.to_checksum_address(participant["address"])

    _send(
        w3, key,
        registry.functions.revoke(addr).build_transaction(_tx_defaults(w3, addr)),
    )
    acct = registry.functions.getAccount(addr).call()
    assert acct[1] is False, "revoke should deactivate"

    _mine_until_due(w3, registry, stamp, volume_id, GRACE_BLOCKS)

    # With accountActive=false, gas-boy's filter excludes the volume → no tx.
    before_block = w3.eth.block_number + 1
    bzz_before = bzz.functions.balanceOf(addr).call()
    nonce_before = w3.eth.get_transaction_count(GAS_BOY_ADDR)

    result = _cron()
    print(f"[revoked] result = {result}")

    assert result["ok"] is True
    assert result.get("dueCount") == 0, (
        "gas-boy filter should drop inactive-account volumes pre-submission"
    )
    assert w3.eth.get_transaction_count(GAS_BOY_ADDR) == nonce_before
    assert bzz.functions.balanceOf(addr).call() == bzz_before
    assert _toppedup_events(registry, before_block) == []
    # Volume still Active (NoAuth is a skip, not a retire).
    v = registry.functions.getVolume(volume_id).call()
    assert v[7] == STATUS_ACTIVE

    # Also verify the contract-level behaviour directly: a manual trigger
    # call (bypassing gas-boy's filter) emits TopupSkipped(NoAuth).
    manual_before_block = w3.eth.block_number + 1
    ids = [volume_id]
    _send(
        w3, GAS_BOY_KEY,
        registry.functions.trigger(ids).build_transaction(_tx_defaults(w3, GAS_BOY_ADDR)),
    )
    skipped = _skipped_events(registry, manual_before_block)
    assert len(skipped) == 1
    assert skipped[0]["args"]["reason"] == SKIP_NO_AUTH
    assert bzz.functions.balanceOf(addr).call() == bzz_before
