"""Layer 1 — anvil lifecycle and RPC helpers.

Port target: ../alectryon-harness/python/src/alectryon_harness/deploy.py
(the subprocess-spawn path) + the anvil RPC extensions scattered through
that module.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Optional


@dataclass
class Chain:
    """Handle on a running anvil.

    Construct via ``Chain.up(...)`` (spawn-and-own / spawn-and-detach) or
    ``Chain.attach(rpc=...)`` (external anvil). Both paths converge on the
    same state: a ``Web3`` bound to ``rpc``, a canonical deployer key, and
    an atomic state-file at ``state/chain.json``.
    """

    rpc: str
    chain_id: int
    deployer_key: bytes
    pid: Optional[int] = None  # None for attach-only

    # ---- factories ----------------------------------------------------

    @classmethod
    def up(
        cls,
        *,
        port: int = 8545,
        accounts: int = 32,
        balance: int = 10_000,
        keep_running: bool = True,
        state_dir: Path = Path("state"),
    ) -> "Chain":
        """Spawn a fresh anvil, write state/chain.json, return handle."""
        raise NotImplementedError

    @classmethod
    def attach(cls, *, rpc: str, state_dir: Path = Path("state")) -> "Chain":
        """Attach to an existing anvil, write state/chain.json, return handle."""
        raise NotImplementedError

    @classmethod
    def load(cls, state_dir: Path = Path("state")) -> "Chain":
        """Re-attach using the state/chain.json written by a prior run."""
        raise NotImplementedError

    # ---- lifecycle ---------------------------------------------------

    def down(self) -> None:
        """Terminate the anvil process, if we own it."""
        raise NotImplementedError

    # ---- anvil RPC extensions ---------------------------------------

    def mine(self, blocks: int = 1) -> None:
        raise NotImplementedError

    def snapshot(self) -> str:
        raise NotImplementedError

    def revert(self, snapshot_id: str) -> None:
        raise NotImplementedError

    def impersonate(self, address: str) -> "ImpersonationHandle":
        """Return a context manager that impersonates ``address``."""
        raise NotImplementedError

    def set_interval_mining(self, seconds: int) -> None:
        raise NotImplementedError


class ImpersonationHandle:
    """Context manager returned by ``Chain.impersonate``."""

    def __enter__(self) -> "ImpersonationHandle":
        raise NotImplementedError

    def __exit__(self, *exc_info: object) -> None:
        raise NotImplementedError
