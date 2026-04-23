# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **Status note (2026-04-23).** The authoritative architecture is `notes/DESIGN.md`. The Solidity code currently in `contracts/src/` (`SubscriptionRegistry`, `VolumeRegistry`) and the description of it in the *Architecture → VolumeRegistry contract* section below is **scratch / prototype work** predating the design freeze — not a shipped prior version. Expect substantial rewrite or replacement during implementation. Where this file and `notes/DESIGN.md` disagree (e.g. three-role model vs owner/payer split, `designatePayer`/`confirmAccount` vs `designateFundingWallet`/`confirmAuth`, `keepalive` vs `trigger`, `initialDepth`/`graceBlocks` stored per-volume vs global immutable `graceBlocks`), `notes/DESIGN.md` wins. The `orion/` and `gas-boy/` sections describe support infrastructure that is expected to survive largely intact.

## Project Overview

**swarm-sub-registry** is a multi-component Ethereum/Swarm infrastructure project:

- **contracts/** — Solidity (Foundry). `VolumeRegistry`: volume-lifecycle layer over Swarm postage stamp batches with a three-role model (volume owner, payer, chunk signer). Owner creates volumes; payer authorization is a two-party handshake (owner designates, payer confirms); anyone can call `keepalive()` to top up volumes whose remaining balance falls below `graceBlocks × lastPrice`.
- **orion/** — Python (uv/hatch). Local test harness construction kit for EVM protocols. Three-layer model: chain (anvil lifecycle) → constellation (declarative contract deploy with role wiring) → participants (deterministic key derivation + provisioning). CLI entry point: `orion`.
- **gas-boy/** — TypeScript (Cloudflare Worker). Cron-based bot that calls `VolumeRegistry.keepalive()` and `pruneDead()`. Uses viem (incl. multicall) for EVM interaction.

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

### VolumeRegistry contract
Three-role model (volume owner, payer, chunk signer). Key types:
- `struct Account { address payer; bool active; }` keyed by owner.
- `struct Volume { address owner; address chunkSigner; uint64 ttlExpiry; uint8 initialDepth; uint32 graceBlocks; }`.

**Account handshake (owner ↔ payer).** Two-party, prevents unilateral self-install:
- `designatePayer(payer)` — owner picks a payer (pre-confirm).
- `confirmAccount(owner)` — payer (msg.sender) confirms; requires `designated[owner] == msg.sender`. Sets `accounts[owner] = {payer, active:true}`.
- `revokeAccount(owner)` — either the owner or the confirmed payer can dissolve. Affects **every** volume managed by the (owner, payer) pair — payer is not stored per-volume.

**Volume lifecycle.** Owner-only:
- `createVolume(batchId, chunkSigner, ttlExpiry, graceBlocks)` — asserts `PostageStamp.batches(id).owner == chunkSigner` so v1 keeps the postage-batch-owner and the declared chunk signer aligned. Records `initialDepth` from PostageStamp at creation time.
- `modifyVolume(batchId, newTtlExpiry, newGraceBlocks)` — adjust expiry/grace only. Depth and chunkSigner are frozen.
- `extendVolume(batchId, newDepth)` — **unconditionally reverts with `DepthUnsupported`** (aka "Batch depth increase not supported in v1"). Depth changes are not supported in v1; because the registry's API never calls `PostageStamp.increaseDepth`, no depth change can flow through this contract.
- `deleteVolume(batchId)` — permanent removal.
- `transferOwnership(batchId, newOwner)` — hand off management.

**Keepalive.** Precise idempotent top-up:
- `keepalive()` iterates all volumes; tops up any whose batch `remainingPerChunk < graceBlocks × lastPrice`. `perChunk = target - remaining` so consecutive calls in the same block are strict no-ops. Per-volume failures emit `KeepaliveSkipped`.
- `keepaliveOne(batchId)` — singular, reverts bubble.
- `pruneDead(batchIds[])` / `pruneOne(batchId)` — permissionless cleanup when `isDead(id)` is true (volume's `ttlExpiry` passed, OR `PostageStamp.batches(id).owner == 0`). Per-id failures emit `PruneSkipped` with the revert selector embedded.
- `isDue(batchId)` / `isDead(batchId)` — view helpers used by gas-boy via multicall.
- Constructor pre-approves the PostageStamp contract for unlimited BZZ spending.

### orion layers
Each layer writes a JSON state file (in `orion/state/`, gitignored) consumed by the next:
1. **Chain** (`chain.py`) — spawns/attaches anvil, writes `chain.json`. Also auto-injects the canonical Multicall3 deployment at `0xcA11bde05977b3631167028862bE2a173976CA11` via `anvil_setCode` so multicall-aware consumers (gas-boy, viem) work out of the box.
2. **Constellation** (`constellation.py`) — deploys contracts with topological ordering, wires OpenZeppelin roles, writes `deployment.json`
3. **Participants** (`participants.py`) — derives keys via `keccak256("orion:" + label)`, funds/mints/approves/binds, writes `participants.json`
4. **Priming** (`priming.py`) — optional; seeds state via anvil impersonation (e.g., set `lastPrice`)

The built-in **Swarm profile** (`profiles/swarm.py`) deploys 5 contracts (TestToken, PostageStamp, PriceOracle, StakeRegistry, Redistribution) with 4 role grants. Uses testnet TestToken artifact (mainnet Token is a bridge shim, not deployable).

### gas-boy
Cloudflare Worker with `GET /health` and a `scheduled` cron handler. Each cycle: reads all volumes in 3 RPC round-trips via Multicall3 (`volumeCount` + bulk `batchIds` + bulk `isDue`/`isDead`), then sends `keepalive()` if any are due and `pruneDead()` if any are dead. Sequential txs, each with independent simulate + receipt + log entry. Fire-and-observe pattern (never throws from scheduled).

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
