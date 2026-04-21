"""Hardhat artifact loader.

Reads ``{bytecode, deployedBytecode, abi}`` from Hardhat-style deploy
artifacts; sanity-checks the bytecode prefix (``0x608060...`` for
standard Solidity init) before handing it to the deployer. See
ISSUES.md:artifact-prefix.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any


class ArtifactError(RuntimeError):
    """Raised when an artifact is not a deployable Solidity contract."""


def load(name: str, *, artifacts_dir: Path) -> dict[str, Any]:
    """Load ``<artifacts_dir>/<name>.json`` and validate the bytecode prefix."""
    raise NotImplementedError


def validate_bytecode_prefix(bytecode_hex: str) -> None:
    """Raise :class:`ArtifactError` if the bytecode isn't ``0x6080...``."""
    raise NotImplementedError
