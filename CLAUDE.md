# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**swarm-sub-registry** is a multi-component Ethereum/Swarm infrastructure project:

- **contracts/** — Solidity (Foundry). `SubscriptionRegistry`: permissionless keepalive service for Swarm postage stamp batches. Payers subscribe batches; anyone can call `keepalive()` to top up batches whose remaining balance falls below threshold.
- **orion/** — Python (uv/hatch). Local test harness construction kit for EVM protocols. Three-layer model: chain (anvil lifecycle) → constellation (declarative contract deploy with role wiring) → participants (deterministic key derivation + provisioning). CLI entry point: `orion`.
- **gas-boy/** — TypeScript (Cloudflare Worker). Cron-based bot that calls `SubscriptionRegistry.keepalive()`. Uses viem for EVM interaction.

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
npm install
npm run dev                              # wrangler dev on :8787
npm run typecheck                        # tsc --noEmit
```

## Architecture

### SubscriptionRegistry contract
- `subscribe(batchId, extensionBlocks)` stores a `Subscription{payer, extensionBlocks}`
- `keepalive()` iterates all subscriptions; if `remainingPerChunk < lastPrice * extensionBlocks`, tops up using payer's pre-approved BZZ
- Constructor pre-approves the PostageStamp contract for unlimited BZZ spending
- Payer revoking allowance makes their batch un-keepable (emits `KeepaliveSkipped`, doesn't revert)

### orion layers
Each layer writes a JSON state file (in `orion/state/`, gitignored) consumed by the next:
1. **Chain** (`chain.py`) — spawns/attaches anvil, writes `chain.json`
2. **Constellation** (`constellation.py`) — deploys contracts with topological ordering, wires OpenZeppelin roles, writes `deployment.json`
3. **Participants** (`participants.py`) — derives keys via `keccak256("orion:" + label)`, funds/mints/approves/binds, writes `participants.json`
4. **Priming** (`priming.py`) — optional; seeds state via anvil impersonation (e.g., set `lastPrice`)

The built-in **Swarm profile** (`profiles/swarm.py`) deploys 5 contracts (TestToken, PostageStamp, PriceOracle, StakeRegistry, Redistribution) with 4 role grants. Uses testnet TestToken artifact (mainnet Token is a bridge shim, not deployable).

### gas-boy
Cloudflare Worker with three endpoints: `GET /health`, `POST /trigger` (manual keepalive), and `scheduled` (cron). Reads subscription count, checks `isDue()` for each batch, sends single `keepalive()` tx if any are due. Fire-and-observe pattern (never throws from scheduled).

## Key Pitfalls

- **Fresh deploys have zero price** — `PostageStamp.lastPrice = 0` after constellation deploy. Must run `orion prime set-postage-price --wei-per-chunkblock 44445` before meaningful keepalive testing.
- **Empty-data reverts** — Almost always a missing role grant or missing `approve()`. Check `state/deployment.json` role_grants.
- **Artifact bytecode prefix** — Hardhat artifacts must start with `0x6080` to be deployable. Bridged token artifacts start with `0x000500` and fail.
- **Participant re-runs accumulate state** — Role-binding calls (stake, deposit, topUp) are additive. Same label = same key = accumulated state across runs.

## Submodules

```bash
git submodule update --init               # required after clone
# contracts/lib/forge-std       — Foundry stdlib
# orion/vendor/storage-incentives — Pinned Swarm contract artifacts
```
