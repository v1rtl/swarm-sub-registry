"""Prometheus metrics sidecar.

Scope:
  - Read-only. Never writes to the chain.
  - Pull-based. Prometheus scrapes us; we query on-scrape via web3.
  - Generic. Nothing in this module is protocol-specific. Per-profile
    metric definitions live in ``orion.profiles.<name>_metrics``.

Usage:
    orion metrics serve --profile swarm --port 9464

The command blocks. To run in background, use your process manager of
choice (``&``, systemd, docker-compose …). For the canonical
Prometheus + Grafana + exporter compose file, see ``deploy/``.
"""

from __future__ import annotations

import importlib
import json
import logging
import time
from pathlib import Path
from typing import Iterable, Optional

from prometheus_client import REGISTRY, make_wsgi_app
from prometheus_client.core import GaugeMetricFamily
from prometheus_client.registry import Collector

from orion.chain import Chain

log = logging.getLogger("orion.metrics")


# ─── Profile-facing interface ───────────────────────────────────────
#
# A profile's metrics module exports a ``COLLECTORS`` list of
# ``Collector`` subclasses or factory callables. Each collector is
# passed the (chain, deployment, state_dir) triple and yields metric
# families on ``.collect()``.


class ProfileCollector(Collector):
    """Base class for profile-specific collectors.

    Subclasses override :meth:`collect`. The runtime binds the
    collector to the current chain + deployment + state_dir before
    scraping starts; subclasses can read those via ``self.chain`` /
    ``self.deployment`` / ``self.state_dir``.
    """

    def __init__(self, chain: Chain, deployment: dict, state_dir: Path) -> None:
        self.chain = chain
        self.deployment = deployment
        self.state_dir = state_dir

    def collect(self) -> Iterable:  # pragma: no cover
        raise NotImplementedError


# ─── Built-in generic collector (chain-level) ───────────────────────


class ChainCollector(ProfileCollector):
    """Chain-level metrics that any profile wants.

    - ``orion_block_number``: latest block seen by the RPC.
    - ``orion_chain_id_info``: chain id as a label on a constant 1-gauge.

    (Prometheus reports ``scrape_duration_seconds`` as a job-level
    metric, so orion doesn't duplicate that here.)
    """

    def collect(self):
        try:
            block = self.chain.w3.eth.block_number
            yield GaugeMetricFamily(
                "orion_block_number",
                "Latest block number seen by the RPC",
                value=block,
            )
        except Exception as e:
            log.warning("ChainCollector block_number failed: %s", e)

        info = GaugeMetricFamily(
            "orion_chain_id_info",
            "Chain id (labels carry the value)",
            labels=["chain_id"],
        )
        info.add_metric([str(self.chain.chain_id)], 1)
        yield info


# ─── Profile loader ─────────────────────────────────────────────────


def load_profile_collectors(profile: str) -> list[type[ProfileCollector]]:
    """Import ``orion.profiles.<profile>_metrics`` and return its
    ``COLLECTORS`` list. Missing module → empty list (so a profile
    without metrics emits chain-level only)."""
    try:
        mod = importlib.import_module(f"orion.profiles.{profile}_metrics")
    except ModuleNotFoundError:
        log.info("no metrics module for profile %r; using chain-level only", profile)
        return []
    cols = getattr(mod, "COLLECTORS", None)
    if cols is None:
        log.warning(
            "orion.profiles.%s_metrics has no COLLECTORS list", profile,
        )
        return []
    return list(cols)


# ─── Runtime ─────────────────────────────────────────────────────────


def register_collectors(
    chain: Chain,
    deployment: dict,
    state_dir: Path,
    profile: str,
) -> list[ProfileCollector]:
    """Instantiate and register the chain-level + profile-specific
    collectors with the default Prometheus registry. Returns the list
    of registered instances (so callers can unregister on teardown).
    """
    instances: list[ProfileCollector] = [ChainCollector(chain, deployment, state_dir)]
    for cls in load_profile_collectors(profile):
        instances.append(cls(chain, deployment, state_dir))
    for inst in instances:
        REGISTRY.register(inst)
    return instances


def unregister_all(collectors: list[ProfileCollector]) -> None:
    for c in collectors:
        try:
            REGISTRY.unregister(c)
        except KeyError:
            pass


def serve(
    *,
    chain: Chain,
    deployment: dict,
    state_dir: Path,
    profile: str,
    port: int = 9464,
    host: str = "0.0.0.0",
) -> None:
    """Block forever serving Prometheus scrapes on ``host:port``.

    The default port 9464 follows the Prometheus "exporter" convention
    (9000-series reserved for exporters; 9464 is one of the canonical
    OpenMetrics examples). Override if it collides.
    """
    from wsgiref.simple_server import make_server, WSGIRequestHandler

    collectors = register_collectors(chain, deployment, state_dir, profile)
    log.info(
        "orion metrics: profile=%s collectors=%d serving on http://%s:%d/metrics",
        profile, len(collectors), host, port,
    )

    # Silence the default access log; Prometheus scrapes every 15s by
    # default and the noise is useless for interactive dev. Swap for a
    # structured logger if operating at scale.
    class _QuietHandler(WSGIRequestHandler):
        def log_message(self, *args, **kwargs):
            return

    app = make_wsgi_app()
    httpd = make_server(host, port, app, handler_class=_QuietHandler)
    try:
        httpd.serve_forever()
    finally:
        unregister_all(collectors)


# ─── Helpers for profile collectors ─────────────────────────────────


def load_participants(state_dir: Path) -> dict[str, dict]:
    """Convenience for profile collectors: read participants.json as a
    dict keyed by label. Returns ``{}`` if the file is absent."""
    path = state_dir / "participants.json"
    if not path.exists():
        return {}
    return json.loads(path.read_text()).get("participants", {})


def safe_call(fn, *args, default=None, **kwargs):
    """Call a web3 contract function; return ``default`` on any
    exception. Keeps a single bad view-call from breaking a whole
    scrape."""
    try:
        return fn(*args, **kwargs)
    except Exception as e:
        log.debug("safe_call %s failed: %s", getattr(fn, "__name__", fn), e)
        return default
