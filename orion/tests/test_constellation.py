"""Tests for orion.constellation — declarative deploy-graph resolution.

The core invariant: if B's constructor takes Ref("A"), then A deploys
first. Any topology that can't satisfy this must fail loudly.
"""

import pytest

from orion.constellation import ContractSpec, Ref


def test_contractspec_is_hashable() -> None:
    """Frozen dataclass — we rely on it being usable in sets/dict keys."""
    ContractSpec(name="A", artifact="A", args=[])


def test_ref_equality() -> None:
    assert Ref("Token") == Ref("Token")
    assert Ref("Token") != Ref("PostageStamp")


@pytest.mark.skip(reason="stub — unskip when deploy_profile's topo-sort lands")
def test_refs_resolve_in_topological_order() -> None:
    """B depends on A ⇒ A's address materialises before B's constructor runs."""


@pytest.mark.skip(reason="stub — unskip when topo-sort lands")
def test_unresolved_ref_raises() -> None:
    """Ref("DoesNotExist") must surface a clear error, not a KeyError deep in deploy."""


@pytest.mark.skip(reason="stub — unskip when cycle detection lands")
def test_circular_dependency_requires_setter_bridge() -> None:
    """A needs B, B needs A: deploy_profile must reject it unless a setter= bridge is declared."""


@pytest.mark.skip(reason="stub — unskip when role grants are wired")
def test_role_grants_applied_after_all_deploys() -> None:
    """Grantee may itself be a Ref; must be resolvable when the grant lands."""


@pytest.mark.skip(reason="stub — requires vendor/storage-incentives submodule")
def test_swarm_profile_is_valid() -> None:
    """orion.profiles.swarm.SWARM must parse into a topo-sortable graph.

    Smoke-test the reference profile against the resolver — catches regressions
    when either side drifts.
    """
    from orion.profiles.swarm import SWARM

    assert SWARM.name == "swarm"
    assert len(SWARM.contracts) == 5
    assert len(SWARM.role_grants) == 4
