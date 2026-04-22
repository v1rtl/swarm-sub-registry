# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**swarm-sub-registry** is a multi-component Ethereum/Swarm infrastructure project:

- **contracts/** — Solidity (Foundry). `SubscriptionRegistry`: permissionless keepalive service for Swarm postage stamp batches. Payers subscribe batches; anyone can call `keepalive()` to top up batches whose remaining balance falls below threshold.
- **orion/** — Python (uv/hatch). Local test harness construction kit for EVM protocols. Three-layer model: chain (anvil lifecycle) → constellation (declarative contract deploy with role wiring) → participants (deterministic key derivation + provisioning). CLI entry point: `orion`.
- **gas-boy/** — TypeScript (Cloudflare Worker). Cron-based bot that calls `SubscriptionRegistry.keepalive()` and `pruneDead()`. Uses viem (incl. multicall) for EVM interaction.

## Build & Test Commands

### Contracts (from `contracts/`)
```bash
forge build                              # compile
forge test                               # all tests
forge test --match-test "test_Subscribe" # single test by name
forge test --match-contract MyTest       # tests in one contract
forge coverage                           # coverage report
```

### orion (from `orion/`)
```bash
uv sync                                  # install deps (creates .venv)
uv run pytest tests/ -v                  # all tests
uv run pytest tests/test_state.py -v     # single test file
uv run pytest tests/test_state.py::test_name -v  # single test
```

### gas-boy (from `gas-boy/`)
```bash
bun install
bun run dev                              # wrangler dev on :8787
bun run typecheck                        # tsc --noEmit
bun run deploy:prod                      # wrangler deploy --env production
```
Use bun, not npm. `bun.lock` is the lockfile of record.

## Architecture

### SubscriptionRegistry contract
- `subscribe(batchId, extensionBlocks)` stores a `Subscription{payer, extensionBlocks}`
- `keepalive()` iterates all subscriptions; if `remainingPerChunk < lastPrice * extensionBlocks`, tops up using payer's pre-approved BZZ. Per-batch failures are isolated via `try/catch` and emitted as `KeepaliveSkipped`.
- `keepaliveOne(batchId)` / `pruneOne(batchId)` — singular variants. Reverts bubble through to the caller (no try/catch) so explicit callers learn exactly why their call failed.
- `pruneDead(batchIds[])` — permissionless cleanup of subscriptions whose batch is no longer known to PostageStamp (`owner == 0`: never created, or reaped by `expireLimited` after expiry). Per-id failures emit `PruneSkipped` with the revert selector embedded; `Pruned` event on success. Pruning is **irreversible** — payer must re-subscribe if the batch is re-created.
- `isDue(batchId)` / `isDead(batchId)` — view helpers used by gas-boy via multicall.
- Constructor pre-approves the PostageStamp contract for unlimited BZZ spending.
- Payer revoking allowance makes their batch un-keepable (bulk `keepalive()` emits `KeepaliveSkipped` and continues; singular `keepaliveOne()` reverts).

### orion layers
Each layer writes a JSON state file (in `orion/state/`, gitignored) consumed by the next:
1. **Chain** (`chain.py`) — spawns/attaches anvil, writes `chain.json`. Also auto-injects the canonical Multicall3 deployment at `0xcA11bde05977b3631167028862bE2a173976CA11` via `anvil_setCode` so multicall-aware consumers (gas-boy, viem) work out of the box.
2. **Constellation** (`constellation.py`) — deploys contracts with topological ordering, wires OpenZeppelin roles, writes `deployment.json`
3. **Participants** (`participants.py`) — derives keys via `keccak256("orion:" + label)`, funds/mints/approves/binds, writes `participants.json`
4. **Priming** (`priming.py`) — optional; seeds state via anvil impersonation (e.g., set `lastPrice`)

The built-in **Swarm profile** (`profiles/swarm.py`) deploys 5 contracts (TestToken, PostageStamp, PriceOracle, StakeRegistry, Redistribution) with 4 role grants. Uses testnet TestToken artifact (mainnet Token is a bridge shim, not deployable).

### gas-boy
Cloudflare Worker with `GET /health` and a `scheduled` cron handler. Each cycle: reads all subscriptions in 3 RPC round-trips via Multicall3 (`subscriptionCount` + bulk `batchIds` + bulk `isDue`/`isDead`), then sends `keepalive()` if any are due and `pruneDead()` if any are dead. Sequential txs, each with independent simulate + receipt + log entry. Fire-and-observe pattern (never throws from scheduled).

## Key Pitfalls

- **Fresh deploys have zero price** — `PostageStamp.lastPrice = 0` after constellation deploy. Must run `orion prime set-postage-price --wei-per-chunkblock 44445` before meaningful keepalive testing.
- **Empty-data reverts** — Almost always a missing role grant or missing `approve()`. Check `state/deployment.json` role_grants.
- **Artifact bytecode prefix** — Hardhat artifacts must start with `0x6080` to be deployable. Bridged token artifacts start with `0x000500` and fail.
- **Participant re-runs accumulate state** — Role-binding calls (stake, deposit, topUp) are additive. Same label = same key = accumulated state across runs.
- **Subscribe-before-create is a footgun** — `pruneDead` will remove subscriptions for batchIds whose `PostageStamp.batches(id).owner == 0`. If you subscribe before calling `createBatch`, gas-boy's next cron will prune you. Always subscribe in the same Safe transaction batch as `createBatch`, or strictly after it has mined.
- **Initial batch TTL must exceed subscribe-tx latency** — using `initialBalancePerChunk = minimumInitialBalancePerChunk()` gives only `minimumValidityBlocks` of TTL (~12 blocks on Sepolia), which can lapse before the subscribe tx mines. Use at least `(extensionBlocks - margin) * lastPrice` so the batch survives long enough to be picked up by the first keepalive.

## Submodules

```bash
git submodule update --init               # required after clone
# contracts/lib/forge-std       — Foundry stdlib
# orion/vendor/storage-incentives — Pinned Swarm contract artifacts
```
