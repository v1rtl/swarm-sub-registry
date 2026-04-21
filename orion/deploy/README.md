# Metrics sidecar — Prometheus + Grafana (podman)

A `podman compose` stack that scrapes orion's metrics exporter and
shows dashboards in Grafana. Run it alongside an already-running
orion deployment.

The stack uses the standard tool-neutral `compose.yaml` filename, so
`docker compose` also reads it unchanged — but podman is the
reference.

## Prerequisites

- `podman` 4.5+ and `podman compose` (or `podman-compose`).
  - Check: `podman --version && podman compose version`.
  - `podman compose` ships with podman 4.4+; older systems can
    `pip install podman-compose` and use that binary instead.
- A running orion deployment with the metrics exporter serving on
  the host at `:9464`:

  ```bash
  orion up --profile swarm
  orion prime set-postage-price --wei-per-chunkblock 44445
  orion participants provision --label op-0 --overlays 1
  orion metrics serve --profile swarm --port 9464
  ```

  The exporter binds `0.0.0.0` by default so containers can reach it
  via `host.containers.internal`.

## Bring the stack up

```bash
cd deploy/
podman compose up -d
```

- **Prometheus** — http://localhost:9090
- **Grafana** — http://localhost:3000

Grafana is configured for anonymous admin access (no login prompt),
auto-provisions the Prometheus datasource, and auto-loads the
dashboards in `grafana/dashboards/`. Open the "Orion" folder in the
dashboard list to find them.

## Tear down

```bash
podman compose down        # stop but keep data volumes
podman compose down -v     # also wipe Prometheus TSDB + Grafana state
```

## What the dashboard shows

`grafana/dashboards/swarm.json` — the reference Swarm-profile
dashboard:

- **Chain / round / phase header** — block height, current round,
  active commit/reveal/claim phase, chain id.
- **Redistribution pot** — `orion_swarm_pot_wei` converted to BZZ
  (16 decimals). Watching this rise confirms priming worked and
  batches are accruing.
- **Batch balances** — one line per batch, scaled to BZZ. Decline
  over time is normal; balance is spent down into the pot each block.
- **Participants table** — effective stake, native balance, token
  balance per label.

## Extending the stack for other profiles

1. Write `src/orion/profiles/<name>_metrics.py` exposing a
   `COLLECTORS` list (see `profiles/swarm_metrics.py` for the
   template).
2. Run the exporter with `--profile <name>`.
3. Duplicate `grafana/dashboards/swarm.json` → `<name>.json`, adjust
   the PromQL queries for your profile's metric names. Grafana picks
   it up on the next provisioning pass (~10 s; see
   `grafana/provisioning/dashboards/orion.yml`).

## Troubleshooting

**"connection refused" in Prometheus targets (state: down)** — the
exporter isn't running on the host, or it's bound to `127.0.0.1`
only. Default is `0.0.0.0`; if you overrode it to `127.0.0.1`,
either switch back or use `network_mode: host` on the Prometheus
service (see next note).

**`host.containers.internal` doesn't resolve** — happens on podman
< 4.5 or on unusual network configurations. Two fixes:

1. Add `network_mode: host` to the Prometheus service in
   `compose.yaml`. Prometheus then runs in the host's network
   namespace and reaches the exporter at `127.0.0.1:9464`. Change
   the prometheus.yml target to `127.0.0.1:9464` to match.
2. Or upgrade podman. 4.5+ is widely available.

**SELinux denials on Fedora/RHEL rootless podman** — the
`:Z` relabel flags on volume mounts in `compose.yaml` handle this.
If you see "permission denied" on the dashboard or datasource
files despite `:Z`, check `getenforce`; disable SELinux (`sudo
setenforce 0`) temporarily to confirm it's the cause.

**"No data" in Grafana panels with target UP** — datasource wiring
is fine; the PromQL in the dashboard just doesn't match your
profile's metric names. Open the Prometheus graph at
http://localhost:9090/graph, type a metric name (start with
`orion_`), and autocomplete shows what's actually being scraped.

**Grafana dashboard not appearing** — the provisioner scans every
10 s; give it a moment. If still missing after 30 s, check
`podman logs orion-grafana` for provisioning errors (usually a
malformed dashboard JSON).

## Running the exporter in a container too

If you'd rather not have the exporter as a host-side process, the
same stack can include it — add a service to `compose.yaml` that
mounts the orion source and runs `uv run orion metrics serve`, with
`host.containers.internal` swapped for `host.containers.internal` to
reach the anvil process. Anvil also can move into a container but
that's a bigger change (volumes for state, port publishing).
Left as a follow-on; the host-side-exporter shape is simpler for
iterating on profile code.
