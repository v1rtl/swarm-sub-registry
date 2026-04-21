"""Economic priming — seed deployed state to realistic values.

Fresh mainnet-bytecode deployments run correct *code* against zero
*state*. This module exposes helpers that use anvil account
impersonation to set the variables that drive accrual (prices, oracle
feeds, utilisation targets) without modifying the deployed role table.

See SKILLS §Economic priming in ../alectryon-harness/SKILLS.md.
"""

from __future__ import annotations

from typing import Any

from orion.chain import Chain


def set_postage_price(
    chain: Chain,
    deployment: dict[str, Any],
    *,
    wei_per_chunkblock: int,
) -> None:
    """Set ``PostageStamp.lastPrice`` via PriceOracle impersonation.

    Mainnet calibration (round 301042, 2026-04-19): 44,445 wei/chunkblock.
    See ../kabashira-docs/ALECTRYON_ECONOMICS.md for context.
    """
    raise NotImplementedError
