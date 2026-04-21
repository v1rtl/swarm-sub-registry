"""Layer 2 — declarative constellation deployer.

Ported from ``../../alectryon-harness/python/src/alectryon_harness/deploy.py``
(the hardcoded Swarm order) into a data-driven form: a
:class:`Constellation` is a list of :class:`ContractSpec` + a list of
:class:`RoleGrant`, and :func:`deploy_profile` walks them both. The
Swarm profile that used to be 150 lines of imperative code is ~40
lines of declaration in ``profiles/swarm.py``.

Ordering: ``contracts`` is expected to be in topological order.
:class:`Ref` args into earlier contracts are resolved at deploy time;
a :class:`Ref` that points at a not-yet-deployed contract is an error.
Circular dependencies go through ``setters`` (not yet used by the
built-in profile; left as :class:`list[Any]` until a profile needs it).
"""

from __future__ import annotations

import importlib
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

from eth_account import Account
from web3 import Web3

from orion import artifacts as _artifacts
from orion import state as _state
from orion.chain import Chain


_DEPLOYMENT_STATE_FILENAME = "deployment.json"

# Default artifact search root if the caller doesn't pass one or set
# $ORION_ARTIFACTS. Relative to CWD; the CLI expects you to run from the
# orion project root.
_DEFAULT_ARTIFACTS_DIR = Path("vendor/storage-incentives/deployments")


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
    args: tuple[Any, ...] = ()

    def __init__(self, name: str, artifact: str, args: Optional[list[Any]] = None) -> None:
        # frozen=True + mutable default needs the workaround: accept a list
        # (profile-author convenience) and freeze internally to a tuple.
        object.__setattr__(self, "name", name)
        object.__setattr__(self, "artifact", artifact)
        object.__setattr__(self, "args", tuple(args) if args is not None else ())


@dataclass(frozen=True)
class RoleGrant:
    """One post-deploy role grant: ``contract.grantRole(role, grantee)``.

    ``grantee`` is either a contract name from the same constellation or
    a raw 0x-prefixed address.
    """

    contract: str
    role: str
    grantee: str


@dataclass
class Constellation:
    """Declarative constellation spec. See :func:`deploy_profile`."""

    name: str
    contracts: list[ContractSpec]
    role_grants: list[RoleGrant]
    setters: list[Any] = field(default_factory=list)


# ─── Deploy ─────────────────────────────────────────────────────────


def deploy_profile(
    chain: Chain,
    *,
    profile: str,
    artifacts_dir: Optional[Path] = None,
) -> dict[str, Any]:
    """Deploy the constellation defined by ``profile`` against ``chain``.

    Writes ``<chain.state_dir>/deployment.json`` and returns the
    deployment dict::

        {
          "profile":     <profile-name>,
          "rpc":         <chain.rpc>,
          "chain_id":    <chain.chain_id>,
          "deployer":    <chain.deployer_addr>,
          "contracts":   {<name>: <address>, ...},
          "role_grants": [{contract, role, grantee_name, grantee, tx_hash}, ...],
        }
    """
    spec = _load_profile(profile)
    art_dir = _resolve_artifacts_dir(artifacts_dir)

    w3 = chain.w3
    deployer = chain.deployer_addr

    addresses: dict[str, str] = {}
    abis: dict[str, list[Any]] = {}

    # 1) Deploy each contract in listed order, resolving Refs to prior addrs.
    for cspec in spec.contracts:
        art = _artifacts.load(cspec.artifact, artifacts_dir=art_dir)
        ctor_args = tuple(_resolve_arg(a, addresses) for a in cspec.args)
        addr = _deploy_contract(chain, art, ctor_args, deployer)
        addresses[cspec.name] = addr
        abis[cspec.name] = art.abi

    # 2) Apply role grants in listed order.
    grant_records: list[dict[str, str]] = []
    for g in spec.role_grants:
        if g.contract not in addresses:
            raise RuntimeError(f"role grant on unknown contract {g.contract!r}")
        grantee_addr = addresses.get(g.grantee, g.grantee)
        tx_hash = _grant_role(
            chain, contract_addr=addresses[g.contract], abi=abis[g.contract],
            role_name=g.role, grantee=grantee_addr, sender=deployer,
        )
        grant_records.append({
            "contract": g.contract,
            "role": g.role,
            "grantee_name": g.grantee,
            "grantee": grantee_addr,
            "tx_hash": tx_hash,
        })

    deployment = {
        "profile": spec.name,
        "rpc": chain.rpc,
        "chain_id": chain.chain_id,
        "deployer": deployer,
        "contracts": addresses,
        "role_grants": grant_records,
    }
    _state.write(chain.state_dir / _DEPLOYMENT_STATE_FILENAME, deployment)
    return deployment


# ─── Internals ──────────────────────────────────────────────────────


def _load_profile(name: str) -> Constellation:
    """Import ``orion.profiles.<name>`` and find its :class:`Constellation`.

    Profiles are discovered by type, not by attribute name: any
    module-level ``Constellation`` instance works. This keeps profile
    authors from having to remember a naming convention.
    """
    module = importlib.import_module(f"orion.profiles.{name}")
    for attr in vars(module).values():
        if isinstance(attr, Constellation):
            return attr
    raise RuntimeError(
        f"profile {name!r}: no Constellation instance found in orion.profiles.{name}"
    )


def _resolve_artifacts_dir(explicit: Optional[Path]) -> Path:
    if explicit is not None:
        return Path(explicit)
    env = os.environ.get("ORION_ARTIFACTS")
    if env:
        return Path(env)
    return _DEFAULT_ARTIFACTS_DIR


def _resolve_arg(arg: Any, addresses: dict[str, str]) -> Any:
    if isinstance(arg, Ref):
        if arg.name not in addresses:
            raise RuntimeError(
                f"Ref({arg.name!r}) used before that contract was deployed — "
                f"reorder ContractSpecs so {arg.name} comes first"
            )
        return addresses[arg.name]
    return arg


def _deploy_contract(
    chain: Chain,
    art: _artifacts.Artifact,
    ctor_args: tuple[Any, ...],
    deployer_addr: str,
) -> str:
    """Sign + submit the deploy tx, return the deployed address."""
    w3 = chain.w3
    acct = Account.from_key(chain.deployer_key)
    contract = w3.eth.contract(abi=art.abi, bytecode=art.bytecode)

    tx = contract.constructor(*ctor_args).build_transaction({
        "from": deployer_addr,
        "nonce": w3.eth.get_transaction_count(deployer_addr),
        "gas": 10_000_000,
        "chainId": chain.chain_id,
    })
    # Stay on legacy gas fields — anvil supports both; mixing 1559 + gasPrice
    # raises. See ISSUES.md §EIP-1559 vs. legacy gas fields.
    tx.pop("maxFeePerGas", None)
    tx.pop("maxPriorityFeePerGas", None)
    tx["gasPrice"] = w3.eth.gas_price

    signed = acct.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    if receipt.status != 1:
        raise RuntimeError(f"{art.name} deployment reverted: {dict(receipt)}")

    addr = receipt["contractAddress"]
    if not addr:
        raise RuntimeError(f"{art.name}: deploy tx succeeded but contractAddress is empty")

    # Post-deploy sanity check — if the constructor returned 0x the tx
    # still "succeeds", but the address has no code. Catch that here so
    # the failure surfaces at deploy time, not at first call.
    code = w3.eth.get_code(addr)
    if len(code) == 0:
        raise RuntimeError(
            f"{art.name} deployed at {addr} but has no runtime bytecode. "
            f"Constructor may have returned empty. Artifact source: {art.source_path}"
        )
    return addr


def _grant_role(
    chain: Chain,
    *,
    contract_addr: str,
    abi: list[Any],
    role_name: str,
    grantee: str,
    sender: str,
) -> str:
    """Call ``contract.grantRole(ROLE, grantee)`` and return the tx hash."""
    w3 = chain.w3
    acct = Account.from_key(chain.deployer_key)
    contract = w3.eth.contract(address=contract_addr, abi=abi)

    # OZ AccessControl exposes role constants as bytes32-returning view fns.
    try:
        role_bytes = contract.functions[role_name]().call()
    except Exception as e:
        raise RuntimeError(
            f"{role_name} constant not callable on {contract_addr} — "
            f"is this contract an AccessControl derivative? underlying: {e}"
        ) from e

    tx = contract.functions.grantRole(role_bytes, grantee).build_transaction({
        "from": sender,
        "nonce": w3.eth.get_transaction_count(sender),
        "gas": 200_000,
        "chainId": chain.chain_id,
    })
    tx.pop("maxFeePerGas", None)
    tx.pop("maxPriorityFeePerGas", None)
    tx["gasPrice"] = w3.eth.gas_price

    signed = acct.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=30)
    if receipt.status != 1:
        raise RuntimeError(
            f"grantRole({role_name}, {grantee}) on {contract_addr} reverted"
        )
    return tx_hash.hex()
