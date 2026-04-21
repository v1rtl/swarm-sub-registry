# orion

A general-purpose construction kit for local test harnesses against Swarm
(and, in general, any multi-contract EVM protocol that can be bootstrapped
from pre-compiled Hardhat artifacts). The kit spins up an anvil node,
deploys a "constellation" of contracts, provisions funded participants,
and hands you a state bundle that downstream drivers can consume.

`orion` is the extraction of the generic machinery that
`alectryon-harness/` needed in order to test the Alectryon Technique
against live Swarm bytecode. That harness was the first consumer; this
repo is the reusable substrate. `alectryon-harness` will migrate to
`orion` as an upstream once the public interface stabilises
(see `ARCHITECTURE.md` for the consumption model).

## What you get

- **Chain layer** — spawn-or-attach anvil with the dev mnemonic, 32 funded
  accounts, snapshot/revert helpers.
- **Constellation layer** — declare a set of contracts + their
  constructor dependencies + their post-deploy role grants as data; the
  deployer handles topological ordering, bytecode-prefix sanity checks,
  and atomic state writeout.
- **Participant layer** — the canonical five-step `derive → fund → mint →
  approve → role-bind` pattern, with deterministic label-based key
  derivation and per-run state records.
- **Priming layer** — helpers for seeding the deployment with realistic
  state (e.g. setting `PostageStamp.lastPrice` via anvil account
  impersonation) so downstream tests see non-zero economics.
- **CLI** — a single `orion` entry point exposing each layer as a
  subcommand, so the whole bring-up is four commands:

  ```bash
  uv sync
  orion chain up                                     # layer 1
  orion deploy --profile swarm                       # layer 2
  orion participants provision --label op-0          # layer 3
  orion status                                       # inspect
  ```

## Quick start

```bash
cd orion
git submodule update --init vendor/storage-incentives   # pinned Hardhat artifacts
uv sync

# bring up the reference Swarm constellation in one call
orion up --profile swarm

# provision one operator (1 staked overlay + 1 postage batch)
orion participants provision --label op-0 --overlays 1

# drive rounds
orion rounds status
orion rounds mine --blocks 152
```

See `GETTING_STARTED.md` for the full walkthrough.

## Status

This repo is a scaffold — documentation and module shape are in place,
implementation lands incrementally as `alectryon-harness/` is migrated
onto it. See `ISSUES.md` for known gaps.

| Layer | State |
|---|---|
| Documentation (README, ARCHITECTURE, GETTING_STARTED, ISSUES) | ✅ drafted |
| Python package skeleton (`src/orion/`) | ✅ drafted |
| Vendored `storage-incentives` (pinned git submodule) | ✅ `vendor/storage-incentives/` |
| Chain layer | ⏳ port from `alectryon-harness/python/src/alectryon_harness/deploy.py` |
| Constellation layer | ⏳ port `deploy.py` + `artifacts.py` |
| Participant layer | ⏳ port `participants.py` |
| Priming helpers | ⏳ port `set_price` path |
| Profile: Swarm | ⏳ encode `SWARM_CONSTELLATION.md` as data |
| CLI | ⏳ stitch the above together |

## Name

`orion` — a constellation of bright stars used for navigation. The
constellation metaphor is inherited from
`../kabashira-docs/SWARM_CONSTELLATION.md`, where a "constellation" is a
small fixed set of contracts that must be deployed and wired together.
This tool brings them up.

## Related

- `../kabashira/` — Rust Swarm client (retrieval, BMT, postage, alectryon binary).
- `../kabashira-docs/` — protocol reference docs (SWARM_CONSTELLATION,
  ALECTRYON_ECONOMICS, CacheAscent, FLEET_DEPLOYMENTS, …).
- `../alectryon-harness/` — first consumer; the Alectryon Technique
  harness, currently self-contained, will migrate to `orion` as an
  upstream dependency.

## Docs index

| Doc | Scope |
|---|---|
| `README.md` | this file |
| `GETTING_STARTED.md` | end-to-end bring-up walkthrough |
| `ARCHITECTURE.md` | three-layer model, extension points, consumption model |
| `ISSUES.md` | known pitfalls, scope limits, upstream gaps |
| `CLAUDE.md` | instructions for Claude Code working in this repo |
