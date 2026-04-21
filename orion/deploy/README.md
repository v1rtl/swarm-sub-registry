# Metrics sidecar — Prometheus + Grafana

Docker-compose stack that scrapes orion's metrics exporter and shows
dashboards in Grafana. Use it alongside an already-running orion
deployment.

## Prerequisites

- Docker + docker-compose.
- A running orion deployment (`orion up --profile swarm`, see
  `../GETTING_STARTED.md`) with the metrics exporter serving on the
  host at `:9464`:

  ```bash
  orion metrics serve --profile swarm --port 9464
  ```

  The exporter binds to `0.0.0.0` by default, so the containers below
  can reach it via `host.docker.internal`.

## Bring the stack up

```bash
cd deploy/
docker compose up -d
```

- **Prometheus** — http://localhost:9090
- **Grafana** — http://localhost:3000

Grafana is configured for anonymous admin access (no login prompt),
auto-provisions the Prometheus datasource, and auto-loads the dashboards
in `grafana/dashboards/`. Open the "Orion" folder in the dashboard list
to find them.

## Tear down

```bash
docker compose down        # stop but keep data volumes
docker compose down -v     # also wipe Prometheus TSDB + Grafana state
```

## What the dashboard shows

`grafana/dashboards/swarm.json` — the reference Swarm-profile
dashboard:

- **Chain / round / phase header** — block height, current round,
  active commit/reveal/claim phase, chain id.
- **Redistribution pot** — `orion_swarm_pot_wei` converted to BZZ (16
  decimals). Watching this rise confirms the priming worked and batches
  are accruing.
- **Batch balances** — one line per batch, scaled to BZZ. Decline over
  time is normal (balance is spent down to the pot every block).
- **Participants table** — effective stake, native balance, token
  balance per label.

## Extending the stack for other profiles

1. Write `src/orion/profiles/<name>_metrics.py` exposing a
   `COLLECTORS` list (see `profiles/swarm_metrics.py` for the
   template).
2. Run the exporter with `--profile <name>`.
3. Duplicate `grafana/dashboards/swarm.json` into
   `grafana/dashboards/<name>.json`, adjust the PromQL queries for
   your profile's metric names, and Grafana picks it up on the next
   provisioning pass (~10 s, see `grafana/provisioning/dashboards/orion.yml`).

## Troubleshooting

**"connection refused" in Prometheus targets (status: down)** — the
exporter isn't running on the host, or it's bound to `127.0.0.1`
instead of `0.0.0.0`. The exporter's default is `0.0.0.0`; if you
overrode it, switch back or expose the host differently.

**"No data" in Grafana panels** — check Prometheus at
http://localhost:9090/targets. If the orion target is UP, the
datasource wiring is fine and the PromQL in the dashboard is what
needs adjustment.

**Host networking on Linux** — we set
`extra_hosts: "host.docker.internal:host-gateway"` in
`docker-compose.yml`. If your Linux kernel is old enough that
`host-gateway` isn't supported, fall back to `network_mode: host` on
the Prometheus service (less isolated but equivalent here).
