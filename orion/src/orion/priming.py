"""Economic priming — seed deployed state to realistic values.

Fresh mainnet-bytecode deployments run correct *code* against zero
*state*. This module exposes helpers that use anvil account
impersonation to set the variables that drive accrual (prices, oracle
feeds, utilisation targets) without modifying the deployed role table.

Generic pattern: impersonate the role-holder, call the privileged
setter, release the impersonation. For Swarm the role-holder is a
contract (``PriceOracle`` holds ``PRICE_ORACLE_ROLE`` on
``PostageStamp``), so impersonation stands in for what would otherwise
require modifying the deploy to grant a second role.

See SKILLS §Economic priming in ``../../alectryon-harness/SKILLS.md``.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Optional

from orion import artifacts as _artifacts
from orion.chain import Chain
from orion.constellation import _resolve_artifacts_dir


def set_postage_price(
    chain: Chain,
    deployment: dict[str, Any],
    *,
    wei_per_chunkblock: int,
    artifacts_dir: Optional[Path] = None,
) -> int:
    """Set ``PostageStamp.lastPrice`` via ``PriceOracle`` impersonation.

    ``PostageStamp.setPrice`` is gated by ``PRICE_ORACLE_ROLE``, which
    :func:`orion.constellation.deploy_profile` grants to the
    ``PriceOracle`` contract address. We impersonate that address via
    anvil's account-impersonation hook, submit the ``setPrice`` tx, and
    release — no change to the deployed role table. Returns the new
    ``lastPrice`` as read back from the chain.

    Mainnet calibration (round 301042, 2026-04-19): 44,445 wei/chunkblock.
    See ``../kabashira-docs/ALECTRYON_ECONOMICS.md`` for context.
    """
    w3 = chain.w3
    art_dir = _resolve_artifacts_dir(artifacts_dir)
    postage_abi = _artifacts.load("PostageStamp", artifacts_dir=art_dir).abi
    postage = w3.eth.contract(
        address=deployment["contracts"]["PostageStamp"], abi=postage_abi,
    )
    oracle_addr = deployment["contracts"]["PriceOracle"]

    with chain.impersonate(oracle_addr):
        tx_hash = postage.functions.setPrice(wei_per_chunkblock).transact(
            {"from": oracle_addr}
        )
        receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=30)
        if receipt["status"] != 1:
            raise RuntimeError(f"setPrice({wei_per_chunkblock}) reverted: {dict(receipt)}")

    return postage.functions.lastPrice().call()
