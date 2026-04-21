"""orion CLI.

Surface shape is final; implementations land as alectryon-harness migrates
onto orion. For the working reference, see
../alectryon-harness/python/src/alectryon_harness/.
"""

import click


@click.group()
def main() -> None:
    """orion — local test-harness construction kit."""


# ---------------------------------------------------------------------------
# Layer 1: chain
# ---------------------------------------------------------------------------

@main.group()
def chain() -> None:
    """Anvil lifecycle (layer 1)."""


@chain.command("up")
@click.option("--port", default=8545, type=int)
@click.option("--accounts", default=32, type=int)
@click.option("--balance", default=10000, type=int)
@click.option("--keep-running/--no-keep-running", default=True)
def chain_up(port: int, accounts: int, balance: int, keep_running: bool) -> None:
    """Spawn a fresh anvil and write state/chain.json."""
    raise NotImplementedError


@chain.command("attach")
@click.option("--rpc", default="http://127.0.0.1:8545")
def chain_attach(rpc: str) -> None:
    """Attach to an already-running anvil."""
    raise NotImplementedError


@chain.command("down")
def chain_down() -> None:
    """Terminate the anvil referenced in state/chain.json."""
    raise NotImplementedError


# ---------------------------------------------------------------------------
# Layer 2: constellation
# ---------------------------------------------------------------------------

@main.command("deploy")
@click.option("--profile", required=True)
@click.option("--artifacts", envvar="ORION_ARTIFACTS")
def deploy(profile: str, artifacts: str) -> None:
    """Deploy a named profile against the chain in state/chain.json."""
    raise NotImplementedError


# ---------------------------------------------------------------------------
# Layer 3: participants
# ---------------------------------------------------------------------------

@main.group()
def participants() -> None:
    """Funded participant provisioning (layer 3)."""


@participants.command("provision")
@click.option("--label", required=True)
@click.option("--overlays", default=1, type=int)
def participants_provision(label: str, overlays: int) -> None:
    """Derive → fund → mint → approve → role-bind."""
    raise NotImplementedError


@participants.command("list")
def participants_list() -> None:
    raise NotImplementedError


@participants.command("wipe")
def participants_wipe() -> None:
    raise NotImplementedError


# ---------------------------------------------------------------------------
# Priming helpers
# ---------------------------------------------------------------------------

@main.group()
def prime() -> None:
    """Seed deployed state to realistic values."""


@prime.command("set-postage-price")
@click.option("--wei-per-chunkblock", required=True, type=int)
def prime_set_postage_price(wei_per_chunkblock: int) -> None:
    """Impersonate PriceOracle to set PostageStamp.lastPrice."""
    raise NotImplementedError


# ---------------------------------------------------------------------------
# Convenience: everything in one shot
# ---------------------------------------------------------------------------

@main.command("up")
@click.option("--profile", required=True)
@click.option("--artifacts", envvar="ORION_ARTIFACTS")
def up(profile: str, artifacts: str) -> None:
    """chain up + deploy, as a single command."""
    raise NotImplementedError


@main.command("status")
def status() -> None:
    """Dump current chain + deployment + participants state."""
    raise NotImplementedError


if __name__ == "__main__":
    main()
