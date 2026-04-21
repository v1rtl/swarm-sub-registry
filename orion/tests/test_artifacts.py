"""Tests for orion.artifacts — Hardhat artifact loading + bytecode sanity.

All stubs until the module lands. See ISSUES.md:artifact-prefix for why
the bytecode-prefix check isn't optional.
"""

import pytest


@pytest.mark.skip(reason="stub — unskip when validate_bytecode_prefix lands")
def test_validate_accepts_standard_solidity_prefix() -> None:
    from orion.artifacts import validate_bytecode_prefix

    # Standard Solidity init bytecode begins 0x6080...
    validate_bytecode_prefix("0x608060405234801561001057600080fd5b50")


@pytest.mark.skip(reason="stub — unskip when validate_bytecode_prefix lands")
def test_validate_rejects_bridged_token_prefix() -> None:
    """Swarm mainnet Token.json starts with 0x000500... (bridge shim, not EVM init)."""
    from orion.artifacts import ArtifactError, validate_bytecode_prefix

    with pytest.raises(ArtifactError):
        validate_bytecode_prefix("0x000500010009")


@pytest.mark.skip(reason="stub — unskip when load() lands")
def test_load_reads_bytecode_abi_and_deployed_bytecode(tmp_path) -> None:
    """Loader must return {bytecode, deployedBytecode, abi}."""


@pytest.mark.skip(reason="stub — requires vendor/storage-incentives submodule")
def test_load_real_testnet_testtoken() -> None:
    """Integration: testnet TestToken.json must parse + pass the prefix check.

    Covers the Swarm profile's happy path end-to-end through the loader.
    """
