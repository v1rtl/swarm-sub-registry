"""Tests for orion.chain — anvil lifecycle helpers.

These spawn a real anvil process on an isolated port. Skipped if the
``anvil`` binary is not on PATH (e.g. CI without Foundry installed).
"""

from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from orion.chain import Chain, MULTICALL3_ADDRESS


pytestmark = pytest.mark.skipif(
    shutil.which("anvil") is None,
    reason="anvil binary not available",
)


def test_up_injects_multicall3_at_canonical_address(tmp_path: Path) -> None:
    """``Chain.up`` must leave Multicall3 callable at its canonical
    address so viem-style multicall consumers (gas-boy, scripts) work
    against orion-spawned anvils without per-caller setup."""
    with Chain.up(port=18546, state_dir=tmp_path, keep_running=False) as c:
        code = c.w3.eth.get_code(MULTICALL3_ADDRESS)
        assert len(code) > 0, "Multicall3 bytecode missing after Chain.up"
        # First two bytes of every Solidity-emitted runtime are 0x6080
        assert code[:2].hex() == "6080"

        # Real call: Multicall3.getBlockNumber() should return current block
        result = c.w3.eth.call(
            {"to": MULTICALL3_ADDRESS, "data": "0x42cbb15c"}
        )
        assert int(result.hex(), 16) == c.w3.eth.block_number


def test_ensure_multicall3_is_idempotent(tmp_path: Path) -> None:
    """A second invocation must be a no-op (returns False) — important
    for ``Chain.attach`` paths where the host anvil may already have it."""
    with Chain.up(port=18547, state_dir=tmp_path, keep_running=False) as c:
        # First call (during Chain.up) already injected; we observe via
        # this second explicit call.
        assert c.ensure_multicall3() is False
