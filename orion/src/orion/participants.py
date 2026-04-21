"""Layer 3 — funded participant provisioning.

Port target: ../alectryon-harness/python/src/alectryon_harness/participants.py.
Canonical pattern documented at
../alectryon-harness/docs/FUNDED_PARTICIPANTS.md.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from orion.chain import Chain


DEFAULT_KEY_PREFIX = b"orion:participant:"


def derive_signing_key(label: str, *, prefix: bytes = DEFAULT_KEY_PREFIX) -> bytes:
    """Deterministic signing key: ``keccak256(prefix + label)``.

    Same label ⇒ same 32-byte private key ⇒ same Ethereum address across
    runs. Changing ``prefix`` partitions the keyspace (useful when two
    harnesses share a chain).
    """
    raise NotImplementedError


@dataclass
class Participant:
    label: str
    address: str
    signing_key: bytes
    overlays: list[dict[str, Any]]  # {nonce, overlay, stake_wei, height}
    batches: list[dict[str, Any]]   # {batch_id, depth, bucket_depth, balance_per_chunk}


def provision(
    chain: Chain,
    deployment: dict[str, Any],
    *,
    label: str,
    overlays: int = 1,
    stake_wei: int = 10**17,
    batch_depth: int = 22,
    bucket_depth: int = 16,
    role_binding: str = "swarm",
) -> Participant:
    """Run the five-step pattern: derive → fund → mint → approve → role-bind.

    ``role_binding`` selects the protocol adapter (e.g. ``"swarm"`` binds
    via StakeRegistry.manageStake + PostageStamp.createBatch).
    """
    raise NotImplementedError
