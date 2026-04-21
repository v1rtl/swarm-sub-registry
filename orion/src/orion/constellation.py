"""Layer 2 — constellation deployer.

Port targets:
- ../alectryon-harness/python/src/alectryon_harness/deploy.py (the per-contract
  deploy + role-grant loop)
- ../alectryon-harness/python/src/alectryon_harness/artifacts.py
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Optional

from orion.chain import Chain


@dataclass(frozen=True)
class Ref:
    """Reference to another contract in the same constellation, by name."""

    name: str


@dataclass(frozen=True)
class ContractSpec:
    """One contract in a constellation.

    ``args`` is a list of constructor arguments; any :class:`Ref` is
    resolved at deploy time to the address of the named contract.
    """

    name: str
    artifact: str
    args: list[Any] = field(default_factory=list)


@dataclass(frozen=True)
class RoleGrant:
    """One post-deploy role grant: ``contract.grantRole(role, grantee)``."""

    contract: str
    role: str
    grantee: str  # contract name (resolved at grant time) or raw address


@dataclass
class Constellation:
    """Declarative constellation spec.

    The deployer resolves ``contracts`` topologically, then applies
    ``role_grants`` in order. See :func:`deploy_profile`.
    """

    name: str
    contracts: list[ContractSpec]
    role_grants: list[RoleGrant]
    setters: list[Any] = field(default_factory=list)  # for circular deps


def deploy_profile(
    chain: Chain,
    *,
    profile: str,
    artifacts_dir: Optional[str] = None,
) -> dict[str, Any]:
    """Deploy ``profile`` against ``chain``; write state/deployment.json.

    The return value is the deployment state dict: ``{contracts: {name: addr},
    role_grants: [...], chain_id: ..., rpc: ...}``.
    """
    raise NotImplementedError
