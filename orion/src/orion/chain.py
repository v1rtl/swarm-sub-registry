"""Layer 1 — anvil lifecycle and RPC helpers.

Ported from ../../alectryon-harness/python/src/alectryon_harness/deploy.py
(subprocess-spawn path) + driver.py (RPC extensions). Orion adds a
dedicated state/chain.json so the three layers can be operated
independently; alectryon-harness didn't need this because it spawned +
deployed in one process.
"""

from __future__ import annotations

import os
import signal
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

from eth_account import Account
from web3 import Web3

from orion import state as _state

# Anvil dev mnemonic — accounts 0..31 are deterministic and prefunded.
# Account 0 is our canonical deployer (holds DEFAULT_ADMIN_ROLE on every
# contract the constellation deployer wires up).
_ANVIL_DEPLOYER_KEY = bytes.fromhex(
    "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
)
_CHAIN_STATE_FILENAME = "chain.json"
_ANVIL_SPAWN_TIMEOUT_S = 15

# Canonical Multicall3 deployment — same address on every EVM chain it
# has been published on (deterministic CREATE2). Recent anvil versions
# pre-deploy it; older versions (and our pinned environment) do not, so
# we inject the deployed bytecode via `anvil_setCode` after spawn. viem
# and other libs assume this address is populated.
MULTICALL3_ADDRESS = "0xcA11bde05977b3631167028862bE2a173976CA11"
_MULTICALL3_BYTECODE_PATH = Path(__file__).parent / "data" / "multicall3.hex"


@dataclass
class Chain:
    """Handle on a running anvil.

    Construct via :meth:`Chain.up` (spawn) or :meth:`Chain.attach`
    (external). Both paths write ``state_dir/chain.json``;
    :meth:`Chain.load` re-attaches from that file. :meth:`down` kills
    the anvil iff we own it (``pid is not None`` AND the pid points at
    a live process in our group).
    """

    rpc: str
    chain_id: int
    deployer_key: bytes
    pid: Optional[int] = None
    state_dir: Path = field(default_factory=lambda: Path("state"))

    # Lazy Web3 — keeps the dataclass trivially JSON-serialisable.
    _w3: Optional[Web3] = field(default=None, init=False, repr=False)

    # ---- accessors ---------------------------------------------------

    @property
    def w3(self) -> Web3:
        if self._w3 is None:
            self._w3 = Web3(Web3.HTTPProvider(self.rpc))
        return self._w3

    @property
    def deployer_addr(self) -> str:
        return Account.from_key(self.deployer_key).address

    # ---- factories ---------------------------------------------------

    @classmethod
    def up(
        cls,
        *,
        port: int = 8545,
        accounts: int = 32,
        balance: int = 10_000,
        block_time: Optional[float] = None,
        keep_running: bool = True,
        state_dir: Path = Path("state"),
    ) -> "Chain":
        """Spawn a fresh anvil and return a Chain bound to it.

        ``keep_running=True`` (default): anvil is put in its own process
        group via ``start_new_session`` so it survives driver exit. The
        caller (or a later ``Chain.load(...).down()``) must reap it.

        ``keep_running=False``: anvil stays in the parent's session and
        an :mod:`atexit` hook terminates it on process shutdown. Pair
        with a context-manager pattern (``with Chain.up(...) as c: ...``)
        for deterministic teardown — the atexit hook is a safety net
        for crash paths, not the primary lifecycle.
        """
        proc = _spawn_anvil(
            port=port, accounts=accounts, balance=balance,
            block_time=block_time, detach=keep_running,
        )
        rpc = f"http://127.0.0.1:{port}"
        w3 = Web3(Web3.HTTPProvider(rpc))
        chain = cls(
            rpc=rpc,
            chain_id=w3.eth.chain_id,
            deployer_key=_ANVIL_DEPLOYER_KEY,
            pid=proc.pid,
            state_dir=state_dir,
        )
        chain._w3 = w3
        chain.ensure_multicall3()
        chain._save_state()

        if not keep_running:
            # Register a SIGTERM hook so the anvil dies if the driver
            # exits without calling down() (e.g. on uncaught exception).
            import atexit
            atexit.register(_terminate_proc_silently, proc)

        return chain

    @classmethod
    def attach(cls, *, rpc: str, state_dir: Path = Path("state")) -> "Chain":
        """Attach to an already-running anvil. Does not own the process."""
        w3 = Web3(Web3.HTTPProvider(rpc))
        if not w3.is_connected():
            raise RuntimeError(f"cannot reach RPC at {rpc}")
        chain = cls(
            rpc=rpc,
            chain_id=w3.eth.chain_id,
            deployer_key=_ANVIL_DEPLOYER_KEY,
            pid=None,
            state_dir=state_dir,
        )
        chain._w3 = w3
        chain._save_state()
        return chain

    @classmethod
    def load(
        cls,
        state_dir: Path = Path("state"),
        *,
        require_connection: bool = True,
    ) -> "Chain":
        """Re-attach to the chain described by ``state_dir/chain.json``.

        ``require_connection=True`` (default) raises if the RPC in the
        state file is unreachable — appropriate for read/write paths
        that need a live chain. Cleanup paths (``down``, ``orion down``)
        pass ``False`` so they can reap stale state even when the chain
        process has died or been killed out-of-band.
        """
        path = state_dir / _CHAIN_STATE_FILENAME
        if not path.exists():
            raise RuntimeError(
                f"no chain state at {path}. run `Chain.up` or `Chain.attach` first."
            )
        data = _state.read(path)
        w3 = Web3(Web3.HTTPProvider(data["rpc"]))
        if require_connection and not w3.is_connected():
            raise RuntimeError(f"RPC at {data['rpc']} not reachable (chain gone?)")
        chain = cls(
            rpc=data["rpc"],
            chain_id=data["chain_id"],
            deployer_key=bytes.fromhex(data["deployer_key"]),
            pid=data.get("pid"),
            state_dir=state_dir,
        )
        chain._w3 = w3
        return chain

    # ---- lifecycle ---------------------------------------------------

    def down(self) -> None:
        """Terminate the anvil we own (if any) and clear chain.json.

        ``attach(..)`` chains have ``pid=None`` and are no-ops here.
        ``load(..).down()`` reaps a prior spawn-and-detach. If the anvil
        was spawned with ``keep_running=False`` (same session as the
        parent), kill the single process; otherwise kill the whole
        process group (standard detach-and-own path).
        """
        if self.pid is not None:
            try:
                proc_pgid = os.getpgid(self.pid)
            except ProcessLookupError:
                proc_pgid = None
            if proc_pgid is None:
                pass  # already dead
            elif proc_pgid == os.getpgid(os.getpid()):
                # Same session as us — plain kill, don't killpg (would
                # also terminate the driver).
                try:
                    os.kill(self.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            else:
                try:
                    os.killpg(proc_pgid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        path = self.state_dir / _CHAIN_STATE_FILENAME
        if path.exists():
            path.unlink()

    # ---- anvil RPC extensions ---------------------------------------

    def mine(self, blocks: int = 1) -> None:
        """Mine ``blocks`` block(s) via ``evm_mine``."""
        for _ in range(blocks):
            self.w3.provider.make_request("evm_mine", [])

    def snapshot(self) -> str:
        """Take an EVM snapshot. Returns an opaque id (hex string)."""
        r = self.w3.provider.make_request("evm_snapshot", [])
        return r["result"]

    def revert(self, snapshot_id: str) -> bool:
        """Revert to ``snapshot_id``. Returns True iff the snapshot existed."""
        r = self.w3.provider.make_request("evm_revert", [snapshot_id])
        return bool(r.get("result", False))

    def set_interval_mining(self, seconds: float) -> None:
        """Enable anvil interval-mining. ``seconds=0`` restores instamine."""
        self.w3.provider.make_request("anvil_setIntervalMining", [int(seconds)])

    def impersonate(self, address: str) -> "ImpersonationHandle":
        """Context manager that impersonates ``address`` for a ``with`` block."""
        return ImpersonationHandle(self, address)

    def ensure_multicall3(self) -> bool:
        """Inject the canonical Multicall3 bytecode at the canonical
        address via ``anvil_setCode`` if it is not already present.

        Returns ``True`` if bytecode was newly injected, ``False`` if it
        was already there. Idempotent — safe to call from
        :meth:`Chain.up` (we always inject) and from
        :meth:`Chain.attach` (skips if the host anvil pre-deployed it,
        as recent Foundry versions do).
        """
        existing = self.w3.eth.get_code(MULTICALL3_ADDRESS)
        if len(existing) > 0:
            return False
        bytecode = _MULTICALL3_BYTECODE_PATH.read_text().strip()
        if not bytecode.startswith("0x"):
            bytecode = "0x" + bytecode
        self.w3.provider.make_request(
            "anvil_setCode", [MULTICALL3_ADDRESS, bytecode]
        )
        return True

    # ---- state persistence ------------------------------------------

    def _save_state(self) -> None:
        _state.write(
            self.state_dir / _CHAIN_STATE_FILENAME,
            {
                "rpc": self.rpc,
                "chain_id": self.chain_id,
                "deployer_key": self.deployer_key.hex(),
                "deployer_addr": self.deployer_addr,
                "pid": self.pid,
            },
        )

    # ---- context-manager glue ---------------------------------------

    def __enter__(self) -> "Chain":
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.down()


class ImpersonationHandle:
    """Context manager that impersonates an account for the duration of a
    ``with`` block. Funds the impersonated address with 1 ETH so contract
    addresses (zero balance by default) can submit transactions.

    ::

        with chain.impersonate(oracle_addr):
            postage.functions.setPrice(44_445).transact({"from": oracle_addr})
    """

    def __init__(self, chain: Chain, address: str) -> None:
        self._chain = chain
        self._address = address

    def __enter__(self) -> "ImpersonationHandle":
        w3 = self._chain.w3
        w3.provider.make_request("anvil_impersonateAccount", [self._address])
        w3.provider.make_request("anvil_setBalance", [self._address, hex(10**18)])
        return self

    def __exit__(self, *exc_info: object) -> None:
        self._chain.w3.provider.make_request(
            "anvil_stopImpersonatingAccount", [self._address]
        )


# ─── Private helpers ────────────────────────────────────────────────


def _terminate_proc_silently(proc: subprocess.Popen) -> None:
    """atexit helper: best-effort kill with no errors propagated."""
    if proc.poll() is not None:
        return
    try:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
    except Exception:
        pass


def _spawn_anvil(
    *,
    port: int,
    accounts: int,
    balance: int,
    block_time: Optional[float],
    detach: bool = True,
) -> subprocess.Popen:
    """Spawn anvil and block until its RPC is responsive. Raises on timeout.

    ``detach=True`` puts anvil in its own session/process group so it
    survives parent exit; ``down()`` then reaps it via ``killpg``.
    ``detach=False`` leaves it in the parent's session so driver exit
    delivers SIGHUP. Pair with atexit for proactive cleanup.
    """
    cmd = [
        "anvil",
        "--port", str(port),
        "--accounts", str(accounts),
        "--balance", str(balance),
        "--silent",
    ]
    if block_time is not None:
        cmd += ["--block-time", str(block_time)]

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        start_new_session=detach,
    )

    deadline = time.time() + _ANVIL_SPAWN_TIMEOUT_S
    rpc = f"http://127.0.0.1:{port}"
    while time.time() < deadline:
        try:
            w3 = Web3(Web3.HTTPProvider(rpc))
            if w3.is_connected() and w3.eth.chain_id:
                return proc
        except Exception:
            pass
        if proc.poll() is not None:
            err = (proc.stderr.read() or b"").decode()[-500:] if proc.stderr else ""
            raise RuntimeError(f"anvil died during startup: {err}")
        time.sleep(0.1)

    # Ran out of time — kill and raise.
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except Exception:
        proc.terminate()
    raise TimeoutError(
        f"anvil did not become responsive within {_ANVIL_SPAWN_TIMEOUT_S}s at {rpc}"
    )
