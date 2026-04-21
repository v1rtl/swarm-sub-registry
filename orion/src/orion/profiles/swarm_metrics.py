"""Prometheus metrics for the Swarm Constellation profile.

Exposes gauges for redistribution-game state, token balances, per-batch
normalisedBalance, and per-participant stake. Only enumerates *our*
on-chain footprint: participants from ``state/participants.json``,
batches from their records. Doesn't scan events, so it only sees what
the orion harness itself created — which is exactly the "only stuff we
put there" property we want from a fresh (not forked) anvil.
"""

from __future__ import annotations

import time
from typing import Iterable

from prometheus_client.core import GaugeMetricFamily

from orion import artifacts as _artifacts
from orion.metrics import ProfileCollector, load_participants, safe_call


def _postage(chain, deployment, artifacts_dir=None):
    abi = _artifacts.load(
        "PostageStamp", artifacts_dir=_resolve(artifacts_dir),
    ).abi
    return chain.w3.eth.contract(address=deployment["contracts"]["PostageStamp"], abi=abi)


def _redistribution(chain, deployment, artifacts_dir=None):
    abi = _artifacts.load(
        "Redistribution", artifacts_dir=_resolve(artifacts_dir),
    ).abi
    return chain.w3.eth.contract(address=deployment["contracts"]["Redistribution"], abi=abi)


def _stakes(chain, deployment, artifacts_dir=None):
    abi = _artifacts.load(
        "StakeRegistry", artifacts_dir=_resolve(artifacts_dir),
    ).abi
    return chain.w3.eth.contract(address=deployment["contracts"]["StakeRegistry"], abi=abi)


def _token(chain, deployment, artifacts_dir=None):
    abi = _artifacts.load(
        "TestToken", artifacts_dir=_resolve(artifacts_dir),
    ).abi
    return chain.w3.eth.contract(address=deployment["contracts"]["Token"], abi=abi)


def _resolve(d):
    # Import lazily to avoid a constellation → artifacts cycle at module load.
    from orion.constellation import _resolve_artifacts_dir
    return _resolve_artifacts_dir(d)


class PostageCollector(ProfileCollector):
    """PostageStamp view functions: lastPrice, minimumValidityBlocks,
    total pot, per-batch normalisedBalance."""

    def collect(self) -> Iterable:
        postage = _postage(self.chain, self.deployment)

        last_price = safe_call(postage.functions.lastPrice().call, default=None)
        if last_price is not None:
            yield GaugeMetricFamily(
                "orion_swarm_last_price_wei_per_chunkblock",
                "PostageStamp.lastPrice — wei per chunk per block",
                value=last_price,
            )

        min_validity = safe_call(postage.functions.minimumValidityBlocks().call, default=None)
        if min_validity is not None:
            yield GaugeMetricFamily(
                "orion_swarm_minimum_validity_blocks",
                "PostageStamp.minimumValidityBlocks — floor for new batch balances",
                value=min_validity,
            )

        # Pot function name varies across versions: try pot() first, then totalPot().
        pot = safe_call(getattr(postage.functions, "pot", lambda: None)().call, default=None)
        if pot is None:
            pot = safe_call(getattr(postage.functions, "totalPot", lambda: None)().call, default=None)
        if pot is not None:
            yield GaugeMetricFamily(
                "orion_swarm_pot_wei",
                "Accumulated redistribution pot in wei — paid to each round's winner",
                value=pot,
            )

        # Per-batch normalised balance, keyed by (batch_id, owner_label).
        bmetric = GaugeMetricFamily(
            "orion_swarm_batch_normalised_balance_wei",
            "PostageStamp.batches(batch_id).normalisedBalance",
            labels=["batch_id", "label"],
        )
        bdepth = GaugeMetricFamily(
            "orion_swarm_batch_depth",
            "Postage batch depth — 2^depth chunks covered",
            labels=["batch_id", "label"],
        )
        for label, p in load_participants(self.state_dir).items():
            for b in p.get("batches", []):
                batch_id = b["batch_id"]
                info = safe_call(
                    postage.functions.batches(bytes.fromhex(batch_id[2:])).call,
                    default=None,
                )
                if info is None:
                    continue
                # batches(bytes32) returns (owner, depth, bucketDepth, immutable,
                # normalisedBalance, lastUpdatedBlockNumber). Tuple layout may
                # vary; rely on positional indexing after reading the ABI once.
                normalised = info[4] if len(info) > 4 else None
                depth = info[1] if len(info) > 1 else b.get("depth", 0)
                if normalised is not None:
                    bmetric.add_metric([batch_id, label], normalised)
                bdepth.add_metric([batch_id, label], depth)
        yield bmetric
        yield bdepth


class RedistributionCollector(ProfileCollector):
    """Redistribution game-state: current round, phase, anchor presence."""

    def collect(self) -> Iterable:
        r = _redistribution(self.chain, self.deployment)

        cur_round = safe_call(r.functions.currentRound().call, default=None)
        if cur_round is not None:
            yield GaugeMetricFamily(
                "orion_swarm_current_round",
                "Redistribution.currentRound — round counter since deploy",
                value=cur_round,
            )

        # Per-phase presence as a gauge-set. Exactly one is 1.0 at any time.
        phase_m = GaugeMetricFamily(
            "orion_swarm_phase",
            "1 if contract reports this phase; mutually exclusive.",
            labels=["phase"],
        )
        for name, fn in [
            ("commit", r.functions.currentPhaseCommit),
            ("reveal", r.functions.currentPhaseReveal),
            ("claim",  r.functions.currentPhaseClaim),
        ]:
            val = safe_call(fn().call, default=None)
            if val is not None:
                phase_m.add_metric([name], 1.0 if val else 0.0)
        yield phase_m

        # (`currentRevealRoundAnchor` is private storage in this
        # Redistribution version; no auto-getter. If a future version
        # exposes it, the round-0 anchor-set gauge can be re-added.)


class ParticipantCollector(ProfileCollector):
    """Per-participant: effective stake, xDAI balance, BZZ balance."""

    def collect(self) -> Iterable:
        stakes = _stakes(self.chain, self.deployment)
        token = _token(self.chain, self.deployment)

        stake_m = GaugeMetricFamily(
            "orion_swarm_effective_stake_wei",
            "StakeRegistry.nodeEffectiveStake(owner) — 0 when frozen",
            labels=["label", "address"],
        )
        native_m = GaugeMetricFamily(
            "orion_participant_native_balance_wei",
            "w3.eth.get_balance(owner) — xDAI on Gnosis, ETH elsewhere",
            labels=["label", "address"],
        )
        token_m = GaugeMetricFamily(
            "orion_participant_token_balance_wei",
            "Token.balanceOf(owner) — BZZ in the Swarm profile",
            labels=["label", "address"],
        )

        for label, p in load_participants(self.state_dir).items():
            addr = p["address"]
            stake_m.add_metric(
                [label, addr],
                safe_call(stakes.functions.nodeEffectiveStake(addr).call, default=0) or 0,
            )
            native_m.add_metric(
                [label, addr],
                safe_call(self.chain.w3.eth.get_balance, addr, default=0) or 0,
            )
            token_m.add_metric(
                [label, addr],
                safe_call(token.functions.balanceOf(addr).call, default=0) or 0,
            )

        yield stake_m
        yield native_m
        yield token_m


COLLECTORS = [PostageCollector, RedistributionCollector, ParticipantCollector]
