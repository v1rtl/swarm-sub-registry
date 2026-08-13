# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **`notes/DESIGN.md` is authoritative for contract architecture.** Where this file and `notes/DESIGN.md` disagree, DESIGN.md wins. `contracts/src/VolumeRegistry.sol` now implements that design (owner/payer split, `designateFundingWallet`/`confirmAuth`, `trigger`, immutable `graceBlocks`); this file describes the surrounding tooling and does not restate the contract spec.

## Project Overview

**swarm-sub-registry** is a multi-component Ethereum/Swarm infrastructure project:

- **contracts/** — Solidity (Foundry). `VolumeRegistry`: a volume-lifecycle and paymaster layer over Swarm postage stamp batches. Owner/payer/chunk-signer roles; payer authorization is a two-party handshake; anyone may call the permissionless `trigger(bytes32[])` keeper surface. Deployed to Gnosis Chain and Sepolia.
- **packages/ethswarm-volume-keeper/** — TypeScript. The published library: **viem actions** for the registry, in viem's own style (`action(client, parameters)` plus `.extend()` decorators). It owns no transports, chain table, endpoint list, keys or environment parsing — the caller supplies the client. Its README doubles as the keeper design note `notes/DESIGN.md` §11 defers to.
- **workers/gas-boy/** — TypeScript (Cloudflare Worker). The reference keeper *bot*: cron trigger, `/health`, and all the deployment concerns the library deliberately excludes (transport, chain table, key handling, env parsing). Ships no RPC endpoints — `RPC_URL` is required. One worker env per registry deployment.
- **dash/** — Static viem-over-CDN dashboard, no build step. `python3 -m http.server`.
- **tg-bot/** — Bun + grammy Telegram bot for volume owners.

`packages/*` and `workers/*` form a Bun workspace rooted at the repo root. `dash/` and `tg-bot/` are deliberately outside it and keep their own installs.

## Build & Test Commands

### Contracts (from `contracts/`)
```bash
forge build                              # compile
forge test                               # all tests
forge test --match-contract TriggerSemantics  # tests in one contract
forge coverage                           # coverage report
```

`foundry.toml` currently sets `skip = ["test/**"]`, so `forge test` finds nothing — the suite in `contracts/test/` needs vendored storage-incentives artifacts that are no longer in the repo. Drop the skip once they're restored.

### Keeper package (from `packages/ethswarm-volume-keeper/`)
```bash
bun install                              # from the repo root
bun test                                 # unit + mock-chain suites
bun run typecheck                        # tsc --noEmit (includes tests)
bun run build                            # tsc -p tsconfig.build.json → dist/
```

### Worker (from `workers/gas-boy/`)
```bash
bun run dev                              # builds the package, then wrangler dev on :8787
bun run typecheck
bun run deploy:sepolia                   # wrangler deploy --env sepolia
bun run deploy:prod                      # wrangler deploy --env production (Gnosis)
```

The worker imports the package's `dist/`, so every worker script builds the package first. Secrets: `wrangler secret put PRIVATE_KEY --env <env>`, or `.dev.vars` locally.

Use bun, not npm. `bun.lock` is the lockfile of record.

## Architecture

### VolumeRegistry contract
See `notes/DESIGN.md` — §7 for the API, §8 for `trigger` semantics, §6 for the state machines, §5 for the invariants and threat model. Test scenarios are in `notes/TEST-PLAN.md`; the Foundry suite in `contracts/test/` is organised by invariant.

Keeper-relevant surface only: `getActiveVolumeCount()`, `getActiveVolumes(offset, limit)`, `getVolume(id)`, `trigger(bytes32[])`, `reap(id)`, plus the immutables `postage()` and `graceBlocks()`.

### Keeper package
Follows viem's extension layout (`viem/op-stack` is the model): one action per file under `src/actions/`, `.extend()` decorators under `src/decorators/`, a flat barrel `index.ts`, and `<Action>Parameters` / `<Action>ReturnType` type names. Actions take `(client, parameters)` and compose through `getAction(client, <viemAction>, '<name>')` so they work on any client that has the capability.

- `actions/` — reads (`getActiveVolumeCount`, `getActiveVolumes`, `collectActiveVolumes`, `getVolume`, `getRegistryConfig`, `getBatchStates`, `getKeeperPlan`) and writes (`trigger`, `reap`, `runKeeperCycle`).
- `getKeeperPlan` is the read-only heart: pin a block → read immutables → enumerate → read batches → triage. `runKeeperCycle` is that plus chunked sending and receipt decoding, and never throws.
- `triage.ts` — **pure** classification into due / dead / noAuth / healthy. Mirrors `_triggerOne`'s check order exactly. Most keeper logic bugs belong in this file's tests, not in an integration test.
- `events.ts` — decodes `Toppedup` / `TopupSkipped` / `VolumeRetired` off receipts, since `trigger` swallows per-item failures and a mined tx otherwise tells you nothing.

Two operating modes: `{ type: "all" }` pages the active index; `{ type: "selected", volumeIds }` reads only given ids.

**Do not add transports, chain definitions, RPC endpoints, private-key handling or env parsing to this package** — that is the bot's job, and it lives in `workers/gas-boy/src/client.ts`.

`test/mock-chain.ts` implements the registry, PostageStamp and Multicall3 behind a viem `custom` transport and hands back a ready wallet+public client, so whole cycles — including sign and send — are tested without anvil.

## Key Pitfalls

- **All reads in a cycle must be pinned to one block.** `_retire` does swap-and-pop on `_activeVolumeIds`, so indices shift when a volume retires. Paging the active index across two block heights can silently skip a volume.
- **A mined `trigger` does not mean anything was funded.** Per-item failures are swallowed by design. Read the decoded events: `TopupSkipped(NoAuth)` = payer revoked, `TopupSkipped(PaymentFailed)` = payer out of BZZ or allowance zeroed.
- **PostageStamp is read from `registry.postage()`**, never configured. Same for `graceBlocks`. Both are constructor-immutable, so they're read once and cached.
- **Under-estimating gas on `trigger` fails silently.** Each id runs as `try this._triggerExt(id) {} catch {}`, and an inner call gets 63/64 of the remaining gas: run short and the inner call reverts on OOG, the catch swallows it, and the tx succeeds having topped up nothing. That is why the estimate is scaled (`gasMultiplier`) and why there is deliberately no gas cap — a ceiling below what the batch needs would drop volumes quietly. Bound work with `maxIdsPerTx`.
- **Volumes with no active account are not sent.** Including them would only emit `TopupSkipped(NoAuth)` and burn gas. They surface as `noAuthCount`.
- **Multicall3 comes from the viem chain definition**, never hardcoded. Gnosis and Sepolia both carry it. Any chain added later must too, or `multicall` throws `Chain … does not support contract "multicall3"`.
- **A mock RPC must fail unknown methods with `-32601`.** viem probes optional methods (`eth_fillTransaction`) and only caches "unsupported" on a proper method-not-found; a generic `Error` makes it re-probe with backoff on every transaction.
- **Fresh deploys have zero price** — `lastPrice = 0` makes the top-up target 0, so nothing is ever due. Seed a price before testing against a fresh chain.
- **A volume whose batch doesn't exist triages as dead** and is retired on the next `trigger`, so create the batch before expecting keeper coverage.

## Submodules

```bash
git submodule update --init               # required after clone
# contracts/lib/forge-std              — Foundry stdlib
# contracts/lib/openzeppelin-contracts — OZ v4.9
```
