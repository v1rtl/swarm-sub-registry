"""Tests for orion.participants — deterministic identity derivation.

Pattern per FUNDED_PARTICIPANTS.md §Signing keys:
    private_key = keccak256(prefix + label)

Determinism is the whole point of the scheme — without it, debugging
across runs breaks.
"""

import pytest


@pytest.mark.skip(reason="stub — unskip when derive_signing_key lands")
def test_derive_is_deterministic() -> None:
    from orion.participants import derive_signing_key

    assert derive_signing_key("op-0") == derive_signing_key("op-0")


@pytest.mark.skip(reason="stub — unskip when derive_signing_key lands")
def test_derive_differs_between_labels() -> None:
    from orion.participants import derive_signing_key

    assert derive_signing_key("op-0") != derive_signing_key("op-1")


@pytest.mark.skip(reason="stub — unskip when derive_signing_key lands")
def test_derive_respects_prefix_partition() -> None:
    """Two harnesses sharing a chain partition their keyspaces via prefix."""
    from orion.participants import derive_signing_key

    assert (
        derive_signing_key("op-0", prefix=b"ns-a:")
        != derive_signing_key("op-0", prefix=b"ns-b:")
    )


@pytest.mark.skip(reason="stub — pin golden values when the function lands")
def test_derive_matches_pinned_golden_value() -> None:
    """Lock the derivation scheme with an independently-computed value.

    Pin with: python -c 'from eth_hash.auto import keccak;
    print(keccak(b"orion:participant:op-0").hex())'
    """
    from orion.participants import derive_signing_key

    expected = bytes.fromhex("TODO")  # noqa: F841
    assert derive_signing_key("op-0") == expected
