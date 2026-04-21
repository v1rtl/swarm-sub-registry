"""orion CLI.

Thin wrapper that dispatches click subcommands into the layer modules.
Each subcommand mirrors a single public entry point (``Chain.up``,
``deploy_profile``, ``participants.provision``, …) with the
``state_dir`` defaulting to ``./state`` relative to the working
directory.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Optional

import click

from orion import participants as _participants
from orion import priming as _priming
from orion.chain import Chain
from orion.constellation import deploy_profile

DEFAULT_STATE_DIR = Path("state")


def _deployment_path(state_dir: Path) -> Path:
    return state_dir / "deployment.json"


def _read_deployment(state_dir: Path) -> dict:
    path = _deployment_path(state_dir)
    if not path.exists():
        raise click.ClickException(
            f"no deployment state at {path}. run `orion deploy --profile <name>` first."
        )
    with path.open() as f:
        return json.load(f)


@click.group()
def main() -> None:
    """orion — local test-harness construction kit."""


# ─── Layer 1: chain ──────────────────────────────────────────────────


@main.group()
def chain() -> None:
    """Anvil lifecycle (layer 1)."""


@chain.command("up")
@click.option("--port", default=8545, type=int)
@click.option("--accounts", default=32, type=int)
@click.option("--balance", default=10_000, type=int)
@click.option(
    "--block-time", default=None, type=float,
    help="Seconds per block; omit for instamine (default).",
)
@click.option("--keep-running/--no-keep-running", default=True)
def chain_up(
    port: int, accounts: int, balance: int, block_time: Optional[float], keep_running: bool
) -> None:
    """Spawn a fresh anvil and write state/chain.json."""
    c = Chain.up(
        port=port, accounts=accounts, balance=balance,
        block_time=block_time, keep_running=keep_running,
        state_dir=DEFAULT_STATE_DIR,
    )
    click.echo(f"anvil up  pid={c.pid}  rpc={c.rpc}  chain_id={c.chain_id}")
    click.echo(f"state written to {DEFAULT_STATE_DIR / 'chain.json'}")


@chain.command("attach")
@click.option("--rpc", default="http://127.0.0.1:8545")
def chain_attach(rpc: str) -> None:
    """Attach to an already-running anvil; write state/chain.json."""
    c = Chain.attach(rpc=rpc, state_dir=DEFAULT_STATE_DIR)
    click.echo(f"attached to {c.rpc}  chain_id={c.chain_id}")


@chain.command("down")
def chain_down() -> None:
    """Terminate the anvil referenced in state/chain.json."""
    c = Chain.load(state_dir=DEFAULT_STATE_DIR)
    c.down()
    click.echo(f"anvil pid={c.pid} terminated  state/chain.json removed")


# ─── Layer 2: constellation ──────────────────────────────────────────


@main.command("deploy")
@click.option("--profile", required=True)
@click.option("--artifacts", envvar="ORION_ARTIFACTS",
              help="Path to deployments dir; defaults to vendor/storage-incentives/deployments")
def deploy(profile: str, artifacts: Optional[str]) -> None:
    """Deploy a named profile against the chain in state/chain.json."""
    c = Chain.load(state_dir=DEFAULT_STATE_DIR)
    d = deploy_profile(
        c, profile=profile,
        artifacts_dir=Path(artifacts) if artifacts else None,
    )
    click.echo(f"profile '{d['profile']}' deployed — {len(d['contracts'])} contracts, "
               f"{len(d['role_grants'])} role grants")
    for name, addr in d["contracts"].items():
        click.echo(f"  {name:15s} {addr}")


# ─── Layer 3: participants ──────────────────────────────────────────


@main.group()
def participants() -> None:
    """Funded participant provisioning (layer 3)."""


@participants.command("provision")
@click.option("--label", required=True)
@click.option("--overlays", default=1, type=int)
@click.option("--stake-wei", default=10**17, type=int,
              help="Stake per overlay in wei (Swarm minimum = 10^17).")
@click.option("--batch-depth", default=22, type=int)
@click.option("--bucket-depth", default=16, type=int)
@click.option("--balance-per-chunk", default=None, type=int,
              help="Auto-picked from current lastPrice if unset.")
@click.option("--role-binding", default="swarm", show_default=True)
@click.option("--artifacts", envvar="ORION_ARTIFACTS")
def participants_provision(
    label: str,
    overlays: int,
    stake_wei: int,
    batch_depth: int,
    bucket_depth: int,
    balance_per_chunk: Optional[int],
    role_binding: str,
    artifacts: Optional[str],
) -> None:
    """Derive → fund → mint → approve → role-bind a participant."""
    c = Chain.load(state_dir=DEFAULT_STATE_DIR)
    d = _read_deployment(DEFAULT_STATE_DIR)
    p = _participants.provision(
        c, d,
        label=label, overlays=overlays, stake_wei=stake_wei,
        batch_depth=batch_depth, bucket_depth=bucket_depth,
        balance_per_chunk=balance_per_chunk,
        role_binding=role_binding,
        artifacts_dir=Path(artifacts) if artifacts else None,
    )
    click.echo(f"provisioned '{p.label}'  address={p.address}")
    click.echo(f"  overlays={len(p.overlays)}  batches={len(p.batches)}")


@participants.command("list")
def participants_list() -> None:
    """Print all provisioned participants in state/participants.json."""
    all_ = _participants.load_all(DEFAULT_STATE_DIR)
    if not all_:
        click.echo("no participants provisioned")
        return
    for label, p in all_.items():
        ov = len(p.overlays)
        ba = len(p.batches)
        click.echo(f"{label:20s} {p.address}  overlays={ov}  batches={ba}")


@participants.command("wipe")
def participants_wipe() -> None:
    """Delete state/participants.json. Does NOT un-stake on-chain."""
    _participants.wipe(DEFAULT_STATE_DIR)
    click.echo("participants.json removed (on-chain state untouched)")


# ─── Priming ────────────────────────────────────────────────────────


@main.group()
def prime() -> None:
    """Seed deployed state to realistic values."""


@prime.command("set-postage-price")
@click.option("--wei-per-chunkblock", required=True, type=int)
@click.option("--artifacts", envvar="ORION_ARTIFACTS")
def prime_set_postage_price(wei_per_chunkblock: int, artifacts: Optional[str]) -> None:
    """Impersonate PriceOracle to set PostageStamp.lastPrice."""
    c = Chain.load(state_dir=DEFAULT_STATE_DIR)
    d = _read_deployment(DEFAULT_STATE_DIR)
    result = _priming.set_postage_price(
        c, d,
        wei_per_chunkblock=wei_per_chunkblock,
        artifacts_dir=Path(artifacts) if artifacts else None,
    )
    click.echo(f"lastPrice now {result} wei/chunkblock")


# ─── Convenience: compound commands ─────────────────────────────────


@main.command("up")
@click.option("--profile", required=True)
@click.option("--artifacts", envvar="ORION_ARTIFACTS")
@click.option("--port", default=8545, type=int)
def up(profile: str, artifacts: Optional[str], port: int) -> None:
    """chain up + deploy, as a single command."""
    c = Chain.up(port=port, state_dir=DEFAULT_STATE_DIR)
    click.echo(f"anvil up  pid={c.pid}  rpc={c.rpc}")
    d = deploy_profile(
        c, profile=profile,
        artifacts_dir=Path(artifacts) if artifacts else None,
    )
    click.echo(f"profile '{d['profile']}' deployed — {len(d['contracts'])} contracts")
    for name, addr in d["contracts"].items():
        click.echo(f"  {name:15s} {addr}")


@main.command("status")
def status() -> None:
    """Summarise chain + deployment + participants state."""
    click.echo("── chain ──")
    try:
        c = Chain.load(state_dir=DEFAULT_STATE_DIR)
        click.echo(f"  rpc={c.rpc}  chain_id={c.chain_id}  pid={c.pid}")
        click.echo(f"  block_number={c.w3.eth.block_number}")
    except RuntimeError as e:
        click.echo(f"  (no chain: {e})")
        return

    click.echo("── deployment ──")
    try:
        d = _read_deployment(DEFAULT_STATE_DIR)
        click.echo(f"  profile={d['profile']}  contracts={len(d['contracts'])}  grants={len(d['role_grants'])}")
        for name, addr in d["contracts"].items():
            click.echo(f"    {name:15s} {addr}")
    except click.ClickException as e:
        click.echo(f"  ({e.message})")
        return

    click.echo("── participants ──")
    all_ = _participants.load_all(DEFAULT_STATE_DIR)
    if not all_:
        click.echo("  (none provisioned)")
    else:
        for label, p in all_.items():
            click.echo(f"  {label:20s} {p.address}  overlays={len(p.overlays)}  batches={len(p.batches)}")


if __name__ == "__main__":
    main()
