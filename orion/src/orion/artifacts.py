"""Hardhat artifact loader.

Reads ``{bytecode, deployedBytecode, abi}`` from Hardhat-style deploy
artifacts; sanity-checks the bytecode prefix (``0x6080...`` for
standard Solidity init) before handing it to the deployer. See
``ISSUES.md`` §Artifact bytecode prefix for why.

Resolution: given ``(name, artifacts_dir)``, search the subdirectories
``[mainnet, testnet, testnetlight]`` in order for ``<name>.json`` and
return the first match. This is what the Swarm profile relies on to
pick up ``testnet/TestToken.json`` when the mainnet artifact of the
same logical contract is a bridge shim. Consumers that want tighter
control pass ``artifacts_dir`` pointing directly at a single subdir —
a file at ``<artifacts_dir>/<name>.json`` takes precedence over any
subdir hit.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

# Search order under ``artifacts_dir``. mainnet first because it's the
# canonical bytecode-under-test; testnet only wins where mainnet has a
# non-deployable artifact (e.g. Token → TestToken).
_SUBDIR_SEARCH = ("mainnet", "testnet", "testnetlight")


class ArtifactError(RuntimeError):
    """Raised when an artifact is missing or not a deployable Solidity contract."""


@dataclass(frozen=True)
class Artifact:
    """Loaded Hardhat deploy artifact."""

    name: str
    abi: list[Any]
    bytecode: bytes
    source_path: Path
    mainnet_address: str = ""


def load(name: str, *, artifacts_dir: Path) -> Artifact:
    """Load ``<artifacts_dir>/<subdir>/<name>.json`` (first hit across
    :data:`_SUBDIR_SEARCH`) and validate the bytecode prefix.

    Raises :class:`ArtifactError` if no matching file exists or the
    bytecode isn't ``0x6080...``.
    """
    artifacts_dir = Path(artifacts_dir)

    # A file directly under artifacts_dir takes precedence — useful
    # when a caller points at a single subdir.
    direct = artifacts_dir / f"{name}.json"
    candidates: list[Path] = []
    if direct.exists():
        candidates.append(direct)
    for sub in _SUBDIR_SEARCH:
        p = artifacts_dir / sub / f"{name}.json"
        if p.exists():
            candidates.append(p)

    if not candidates:
        searched = [str(direct)] + [str(artifacts_dir / sub / f"{name}.json") for sub in _SUBDIR_SEARCH]
        raise ArtifactError(f"{name}.json not found under {artifacts_dir}. tried: {searched}")

    path = candidates[0]
    with path.open() as f:
        j = json.load(f)

    bc_hex = j.get("bytecode", "")
    if isinstance(bc_hex, str) and bc_hex.startswith("0x"):
        bc_hex = bc_hex[2:]
    validate_bytecode_prefix(bc_hex, name=name, source=path)

    return Artifact(
        name=name,
        abi=j["abi"],
        bytecode=bytes.fromhex(bc_hex),
        source_path=path,
        mainnet_address=j.get("address", ""),
    )


def validate_bytecode_prefix(
    bytecode_hex: str,
    *,
    name: str = "<unknown>",
    source: Optional[Path] = None,
) -> None:
    """Raise :class:`ArtifactError` if ``bytecode_hex`` is obviously not
    deployable init code.

    We used to pattern-match a specific Solidity preamble here, but
    legitimate init bytecode has many valid prefixes:

    - ``6080604052…`` — classic free-memory-pointer setup (pre-immutables)
    - ``60e06040…`` / ``60c06040…`` — Solidity 0.8+ with immutables
    - ``60018054…`` — proxy / upgradeable storage-slot init

    The check is now intentionally loose: must be non-empty, a plausible
    length, and start with a PUSH opcode (``0x60``–``0x7f``). Bridge
    references like ``0x00050000…`` or empty/null artifacts fail this.
    The real "is this a contract?" test is the post-deploy ``getCode``
    check in :func:`orion.constellation._deploy_contract`.
    """
    if not bytecode_hex or len(bytecode_hex) < 10:
        src = f" (from {source})" if source else ""
        head = bytecode_hex[:16] if bytecode_hex else "<empty>"
        raise ArtifactError(
            f"{name}{src}: bytecode too short to be deployable (got 0x{head}). "
            f"This is usually a bridge reference or empty artifact."
        )
    first = int(bytecode_hex[0:2], 16)
    if not (0x60 <= first <= 0x7f):
        src = f" (from {source})" if source else ""
        head = bytecode_hex[:16]
        raise ArtifactError(
            f"{name}{src}: bytecode doesn't start with a PUSH opcode "
            f"(got 0x{head}). This is usually a bridge reference or non-EVM "
            f"artifact. Try a different subdirectory (e.g. testnet/ for TestToken)."
        )
