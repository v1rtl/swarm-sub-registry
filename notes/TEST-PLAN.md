# Swarm Volume Registry — Test Plan

Companion to `notes/DESIGN.md`. This document is the test specification; no implementation code belongs here. It predates contract implementation: the builder agent reads `DESIGN.md` and this file (and no other source) to produce both `VolumeRegistry.sol` and the test suite.

**Existing code in `contracts/src/` (any of `SubscriptionRegistry.sol`, `VolumeRegistry.sol`) is scratch work and is ignored.** Do not read it, do not reuse any of it. DESIGN.md and this document are authoritative.

Section references of the form "§N" / "I-N" point into `DESIGN.md`.

---

## 1. Layering

Four layers, each catching a different class of bug.

| Layer | Tooling | Scope | What it catches |
|---|---|---|---|
| **L1** | Foundry unit + invariant tests | VolumeRegistry + real vendored PostageStamp/PriceOracle/BZZ, hermetic | Contract correctness against the invariants in §5. |
| **L2** | Foundry with `--fork-url $SEPOLIA_RPC` | Subset of L1 run against live Sepolia | Drift between our vendored artifacts / deployment scripts and the actual live Sepolia contracts. |
| **L3** | orion + `wrangler dev` + anvil | Full stack: contracts + gas-boy + Safe payer against a local devnet | Cross-component bugs: multicall read paths, cron timing, Safe→registry auth flow, race conditions. |
| **L4** | Scripted + manual against Sepolia testnet | Production gas-boy on Cloudflare Workers prod; Bee node uploading chunks | Demo rehearsal + real-network integration (Safe Transaction Service API, live PriceOracle dynamics). |

L1 carries most of the correctness load. L2 is thin (flag-toggled re-run of L1 happy-path subset). L3 validates the shipping stack. L4 is dress rehearsal.

---

## 2. Test environments

### 2.1 Devnet (L1, L2 local variant, L3)

Contracts deployed via orion's Swarm profile, extended with Safe singleton + ProxyFactory:

- Fresh `VolumeRegistry` per test fixture.
- Fresh `PostageStamp` with `minimumValidityBlocks = 12` (matches Sepolia).
- `PriceOracle` deployed fresh; `lastPrice` primed via `orion prime set-postage-price` before any test touches it.
- Canonical **Multicall3 at `0xCA11bde05977b3631167028862bE2a173976CA11`** injected by orion via `anvil_setCode`.
- `BZZ` via orion's TestToken.
- Safe singleton + ProxyFactory deployed by orion (new additions to the Swarm profile). Used for L3 payer scenarios.
- `graceBlocks` in L1/L3 fixtures: small (10–20 blocks) so time-based tests complete quickly.

### 2.2 Sepolia testnet (L2 fork, L4)

| Contract | Address |
|---|---|
| PostageStamp | `0xcdfdC3752caaA826fE62531E0000C40546eC56A6` |
| BZZ (TestToken) | `0x543dDb01Ba47acB11de34891cD86B675F04840db` |
| Multicall3 | `0xCA11bde05977b3631167028862bE2a173976CA11` |
| PriceOracle | read `priceOracle()` on PostageStamp at test setup |
| Safe singleton + ProxyFactory | canonical Safe deployment on Sepolia |
| Safe Transaction Service | `https://safe-transaction-sepolia.safe.global` (L4 only) |

Confirmed: Sepolia PostageStamp's `minimumValidityBlocks() = 12` (~2.4 min at 12 s blocks). `graceBlocks` for the L4 demo registry deployment: **`12`**.

### 2.3 Parity checklist

Values that must agree across environments or one layer is testing something different from the others:

| Item | Devnet | Sepolia |
|---|---|---|
| `graceBlocks` (registry constructor) | fixture-local, ≥ 12 | `12` |
| `minimumValidityBlocks` (Postage) | `12` | `12` |
| Multicall3 address | `0xCA11…` via `anvil_setCode` | `0xCA11…` canonical |
| BZZ address | TestToken from orion | `0x543d…40db` |
| PostageStamp address | fresh deploy | `0xcdfd…56A6` |
| PriceOracle K_max, ROUND_LENGTH | imported from vendored source | read from live PriceOracle at setup |
| `lastPrice` | primed via orion | oracle-driven, live |
| Safe contracts | orion-deployed | canonical Sepolia addresses |

Every test environment must assert, at setup, that **code exists at the Multicall3 address**. Silent drift here turns gas-boy reads into zeros.

---

## 3. L1 — Foundry unit + invariant suite

Baseline strategy: **example-based tests** for every invariant, every state-machine transition (including negative paths), and every retirement edge. Layered on top: **Foundry fuzz + invariant testing** for I3, I7, I8, I9, where the state space is large enough that example tests will miss witnesses.

Fixtures live in `contracts/test/fixtures/`. Naming convention: `test_<subject>_<condition>_<expected>`.

### 3.1 Account state machine (§6.2, I4)

Each test starts from a clean account (no designation, no active record).

| Test | Setup | Action | Assert |
|---|---|---|---|
| `test_designate_setsDesignated` | — | owner calls `designateFundingWallet(p)` | `designated[owner] == p`; `PayerDesignated(owner, p)` emitted |
| `test_designate_zeroClears` | designated[owner]=p | owner calls `designateFundingWallet(0)` | `designated[owner] == 0` |
| `test_confirmAuth_withoutDesignation_reverts` | — | p calls `confirmAuth(owner)` | revert |
| `test_confirmAuth_wrongDesignee_reverts` | designated[owner]=p1 | p2 calls `confirmAuth(owner)` | revert |
| `test_confirmAuth_activates` | designated[owner]=p | p calls `confirmAuth(owner)` | `accounts[owner] == {p, true}`; `AccountActivated(owner, p)` |
| `test_reconfirm_overwrites` | accounts[owner]={p1,true}; designated[owner]=p2 | p2 calls `confirmAuth(owner)` | `accounts[owner] == {p2, true}` atomically |
| `test_revoke_byOwner_deactivates` | accounts[owner]={p,true} | owner calls `revoke(owner)` | `accounts[owner].active == false`; `AccountRevoked` emitted with `revoker=owner` |
| `test_revoke_byPayer_deactivates` | accounts[owner]={p,true} | p calls `revoke(owner)` | same as above with `revoker=p` |
| `test_revoke_byThirdParty_reverts` | accounts[owner]={p,true} | stranger calls `revoke(owner)` | revert |
| `test_revoke_preservesPayerIdentity` | accounts[owner]={p,true} | owner calls `revoke(owner)` | `accounts[owner].payer == p` (only `active` flips); used for re-activation via `confirmAuth` |

### 3.2 Volume lifecycle (§7.1, I1)

| Test | Setup | Action | Assert |
|---|---|---|---|
| `test_createVolume_happy` | active account, payer approved | owner calls `createVolume(chunkSigner, depth, bucketDepth, ttlExpiry, immutableBatch)` | volumeId returned == `keccak256(abi.encode(address(this), nonce))`; `Volume` record matches; in `activeVolumeIds`; `VolumeCreated` emitted; BZZ moved from payer equals `graceBlocks × currentPrice × (1<<depth)`; Postage batch exists with owner=chunkSigner, depth=depth |
| `test_createVolume_inactiveAccount_reverts` | no active account | owner calls `createVolume(…)` | revert |
| `test_createVolume_payerInsufficientBalance_reverts` | active account, payer has less BZZ than charge | owner calls `createVolume(…)` | revert (propagated from ERC20) |
| `test_createVolume_payerInsufficientAllowance_reverts` | active account, payer approved < charge | owner calls `createVolume(…)` | revert |
| `test_createVolume_graceBlocksBelowPostageFloor_constructorReverts` | deploy registry with `graceBlocks < PostageStamp.minimumValidityBlocks()` | — | constructor reverts (§10 constructor check) |
| `test_deleteVolume_retiresAndRemoves` | active volume | owner calls `deleteVolume(id)` | status=Retired, reason=OwnerDeleted; removed from `activeVolumeIds` via swap-and-pop; `VolumeRetired(id, OwnerDeleted)` emitted |
| `test_deleteVolume_byNonOwner_reverts` | active volume | stranger calls `deleteVolume(id)` | revert |
| `test_deleteVolume_alreadyRetired_reverts` | retired volume | owner calls `deleteVolume(id)` | revert (status != Active) |
| `test_transferOwnership_rotates` | active volume | owner calls `transferVolumeOwnership(id, newOwner)` | `volume.owner == newOwner`; `VolumeOwnershipTransferred` emitted; old owner can no longer `deleteVolume` |
| `test_transferOwnership_accountContextFollows` | A owns volume, A has active account with payer p1; B has no account | A transfers to B | next trigger on the volume takes `TopupSkipped(NoAuth)` branch (payer lookup uses accounts[B]) |

### 3.3 Active set and views (§7.4, swap-and-pop correctness)

| Test | Assert |
|---|---|
| `test_activeSet_emptyInitially` | `getActiveVolumeCount() == 0`; `getActiveVolumes(0, 10)` returns empty array |
| `test_activeSet_insertionPreservesOrder` | create v1, v2, v3 → `getActiveVolumes(0, 3)` returns them in insertion order |
| `test_activeSet_swapPopMiddle` | create v1, v2, v3; delete v2 → active list is [v1, v3] (v3's activeIndex updated) |
| `test_activeSet_pagination` | create 150 volumes; `getActiveVolumes(0, 100)` returns first 100, `getActiveVolumes(100, 100)` returns remaining 50 |
| `test_getVolume_resolvesPayerFromAccount` | volume owned by A, accounts[A]={p, active}; `getVolume(id).payer == p`, `accountActive == true` |
| `test_getVolume_afterRevoke_showsInactive` | above, then revoke(A); `getVolume(id).accountActive == false`, `payer` still reports p |

### 3.4 Trigger semantics (§8)

Check-order is load-bearing: batch/depth/TTL retire-edges evaluated before auth/payment (DESIGN.md §8 closing paragraph). Tests below pin that order.

| Test | Setup | Action | Assert |
|---|---|---|---|
| `test_trigger_happyTopup` | active volume, batch below target | `trigger(id)` | BZZ transferred equals formula; `PostageStamp.topUp` called with correct `deficit`; `Toppedup` event |
| `test_trigger_zeroDeficit_noop` | batch already ≥ target | `trigger(id)` | no transfers, no events |
| `test_trigger_idempotence_sameBlock` (I5) | fresh topup just succeeded | `trigger(id)` again in same block | second call is a no-op; no transfer |
| `test_trigger_retired_reverts` | retired volume | `trigger(id)` | revert (§8 step 1) |
| `test_trigger_inactiveAccount_skipsNoRetire` | volume active, account revoked | `trigger(id)` | `TopupSkipped(NoAuth)`; volume still Active; no transfer |
| `test_trigger_insufficientBalance_skipsNoRetire` | active account, payer drained | `trigger(id)` | `TopupSkipped(PaymentFailed)`; volume still Active |
| `test_trigger_revokedAllowance_skipsNoRetire` | active account, payer approve(0) | `trigger(id)` | `TopupSkipped(PaymentFailed)`; volume still Active |
| `test_trigger_batchDied_retires` | TTL-like: Postage reports batch gone | `trigger(id)` | retires BatchDied; removed from active list; no transfer |
| `test_trigger_depthChanged_retires` | chunkSigner called `Postage.increaseDepth` directly (vm.prank) | `trigger(id)` | retires DepthChanged |
| `test_trigger_ttlExpired_retires` | `ttlExpiry` in past | `trigger(id)` | retires VolumeExpired |
| `test_trigger_ordering_batchDiedBeatsNoAuth` | batch dead AND account revoked | `trigger(id)` | retires BatchDied (not TopupSkipped) — §8 step 2 precedes step 5 |
| `test_trigger_ordering_depthChangedBeatsNoAuth` | depth diverged AND account revoked | `trigger(id)` | retires DepthChanged |
| `test_trigger_ordering_ttlExpiredBeatsNoAuth` | TTL passed AND account revoked | `trigger(id)` | retires VolumeExpired |
| `test_triggerBatch_perItemTryCatch` | 3 volumes: one healthy, one retired already, one revoked account | `trigger([id1,id2,id3])` | id1 topped up, id2 skipped (revert swallowed), id3 emits TopupSkipped; batch does not revert |
| `test_reap_idempotent` | already-retired volume | `reap(id)` | no-op, no events |
| `test_reap_retiresTtlExpiredVolume` | active volume with TTL in past | `reap(id)` | retires VolumeExpired without needing a trigger |

### 3.5 Retirement edges (§6.1, I2, I7)

Cross-cutting tests that a retired volume is truly terminal.

| Test | Assert |
|---|---|
| `test_retired_cannotBeTriggered` | `trigger(id)` reverts for any retirement reason |
| `test_retired_notInActiveList` | volumeId absent from `activeVolumeIds` and from `getActiveVolumes(…)` pagination |
| `test_retired_deleteVolumeReverts` | owner can't re-delete |
| `test_retired_transferOwnershipReverts` | owner can't transfer a retired volume |
| `test_retired_noTransferFromPayer` | after retirement, no path causes BZZ to leave payer (asserted via balance snapshot before/after sequence of calls) |
| `test_i2_defensiveBatchOwnerMismatch` | use `vm.store` to force `PostageStamp.batches(id).owner != volume.chunkSigner`; `trigger(id)` retires (reason: whichever edge DESIGN.md assigns; BatchDied if we treat mismatched-owner as dead, else a dedicated reason — decide during implementation and pin here) |

### 3.6 Charge correctness (I8)

Two lenses: (a) exact-formula assertions on the two code paths that spend payer BZZ; (b) invariant: no other code path touches payer BZZ.

| Test | Assert |
|---|---|
| `test_createVolume_chargeEqualsFormula` | `payer.balanceBefore - payer.balanceAfter == graceBlocks × currentPrice × (1<<depth)` exactly |
| `test_trigger_chargeEqualsDeficitFormula` | `payer.balanceBefore - payer.balanceAfter == max(0, graceBlocks × currentPrice − b.normalisedBalance) × (1<<v.depth)` exactly |
| `invariant_noOtherPathSpendsPayer` (fuzz) | Handler calls any public function in random order with random args; invariant: cumulative BZZ out of payer == sum of observed `Toppedup` deltas + sum of observed `VolumeCreated` formula charges. No other delta is ever observed. |

### 3.7 Payer-bounded exposure (I3)

Fuzz/invariant style, since the state space of (account, volume, call order) is too large for example tests.

| Test | Spec |
|---|---|
| `invariant_transferOnlyIfGuarded` | Handler calls arbitrary registry methods with arbitrary accounts/volumes. Invariant: every BZZ transfer out of payer happened in a block where (account.active, volume.status=Active, account.payer=currentPayer) held, and was ≤ formula bound. |
| `test_transferNeverUnderInactiveAccount` (example witness) | Set up active volume whose account has been revoked; `trigger(id)`; assert `payer.balance` unchanged |
| `test_transferNeverAfterRetire` | active account, retired volume (e.g. deleted); `trigger(id)` reverts; balance unchanged |
| `test_transferNeverUsingOldPayer` | account was {p1,true}; designate p2; p2 confirms (overwrites); `trigger(id)`; p1.balance unchanged, p2.balance decreased |

### 3.8 Survival floor (I6)

Harness:

- Deploy real PriceOracle. Set `lastPrice = p0`.
- Create volume (charges `graceBlocks × p0 × (1<<depth)` into the batch).
- At each PriceOracle round boundary, use `vm.prank(priceOracleAdmin)` to call the real setter with `p_i = p_{i-1} × K_max` where K_max is read from the deployed PriceOracle's `changeRate[0] / priceBase`.
- Do not call `trigger`. Advance blocks.
- Measure T = block at which `PostageStamp.batches(id)` reports dead.
- Assert `T ≥ floor(f × graceBlocks)` where f is computed in-test using the same K_max and ROUND_LENGTH values (parametrized, not hardcoded — DESIGN.md §10.1 gives 0.9567 for the 17280/Gnosis case, but the test computes its own f from the observed constants).

| Test | Spec |
|---|---|
| `test_survival_worstCasePrice_gnosisDefault` | `graceBlocks = 17280`, depth arbitrary (say 20); run harness; assert T ≥ ⌊0.9567 × 17280⌋ |
| `test_survival_worstCasePrice_shortGrace` | `graceBlocks = 12` (Sepolia-demo config); assert T ≥ ⌊f × 12⌋ (f very close to 1 because λ·graceBlocks is tiny) |
| `test_survival_flatPrice_exactGrace` | hold price at p0; T = graceBlocks exactly (floor met with equality up to rounding) |
| `test_survival_fallingPrice_exceedsGrace` | schedule decreasing price; T > graceBlocks |

### 3.9 Revocation atomicity (I9)

| Test | Spec |
|---|---|
| `test_revoke_disablesAllVolumesInPair` | owner A creates volumes v1..v5, all active; payer calls `revoke(A)`; subsequent `trigger([v1..v5])` emits 5 × `TopupSkipped(NoAuth)`; payer.balance unchanged |
| `invariant_revokedOwnerSpendsZero` (fuzz) | Handler creates volumes and revokes accounts at random. Invariant: in any block where `accounts[owner].active == false`, `trigger` calls on that owner's volumes produce no `Toppedup` and no BZZ delta from `accounts[owner].payer`. |

### 3.10 Nonce monotonicity and batch-id derivation

| Test | Assert |
|---|---|
| `test_createVolume_nonceIncrements` | two sequential creates produce volumeIds from `nonce` and `nonce+1` |
| `test_volumeId_matchesKeccak` | returned volumeId == `keccak256(abi.encode(address(registry), nonce))` |

---

## 4. L2 — Fork mode

Same test binary as L1, entry point branches on `FOUNDRY_FORK_URL`. In fork mode:

- Use live Sepolia `PostageStamp`, `BZZ`, `PriceOracle`, Multicall3.
- Deploy only `VolumeRegistry` freshly.
- Restrict to tests tagged `[fork-safe]`: tests that don't need `vm.prank` on addresses we don't control (so no forced depth-increase, no I2 defensive-branch test, no forced PriceOracle rate schedule).

Fork-safe subset:
- `test_createVolume_happy` — adapted to pull BZZ from a funded address (`vm.deal` + `deal` cheatcode on BZZ storage).
- `test_trigger_happyTopup`.
- `test_trigger_zeroDeficit_noop`.
- `test_trigger_idempotence_sameBlock`.
- `test_activeSet_pagination` at moderate N.
- Parity assertion: Multicall3 code length > 0 at canonical address; `PostageStamp.minimumValidityBlocks() == 12`; PriceOracle address discovered via `PostageStamp.priceOracle()` matches what our vendored source expects.

Purpose: catch ABI/parameter drift between vendored artifacts and live Sepolia. Not a re-run of the correctness suite.

---

## 5. L3 — Devnet e2e

Tooling: orion deploys contracts to a fresh anvil; gas-boy runs under `wrangler dev`; pytest (already used in `orion/tests/`) drives scenarios by calling `wrangler dev`'s scheduled-trigger endpoint and reading on-chain state.

`graceBlocks` = small (pick during implementation; 10–20 blocks). One volume fixture = one test.

### 5.1 Scenarios

| ID | Scenario | Validates |
|---|---|---|
| **S1** | Single-key path. Owner EOA = chunkSigner. Payer is a 1-of-1 Safe owned by the same EOA. Safe approves BZZ; owner designates Safe; Safe calls `confirmAuth(owner)` via `execTransaction`; owner `createVolume`; advance blocks; invoke gas-boy's scheduled handler; assert Postage batch balance rose and volume still in active set. | Happy-path, Safe-as-payer via direct `execTransaction` (no Safe API), I1, I5 across multiple cycles. |
| **S2** | Separate chunkSigner. Owner EOA, Payer Safe, chunkSigner is a third EOA. Otherwise identical to S1. | Three-address role split; confirms chunkSigner != owner works end-to-end. |
| **S3** | Race — retire between read and trigger. Advance blocks until 3 volumes are due. Trigger gas-boy cron; in the *same* anvil block, before gas-boy's tx mines, have the owner of v2 call `deleteVolume(v2)`. Let both txs mine. | Per-item try/catch in `trigger(ids[])`: v1 and v3 topped up, v2 contributed nothing; gas-boy scheduled handler did not throw. |
| **S4** | Mixed-failure cycle. 3 volumes: one healthy, one with its account revoked mid-cycle, one with TTL expired. Single gas-boy cycle. | v1 topped up; v2 emitted `TopupSkipped(NoAuth)`, still Active; v3 retired `VolumeExpired`; no revert in handler. |
| **S5** | Revocation atomicity. 5 volumes under one (A, Safe-P) pair. Safe executes `revoke(A)`. Trigger next gas-boy cycle. | All 5 `trigger` calls take NoAuth path; Safe's BZZ balance unchanged; I9 confirmed end-to-end including multicall read path. |
| **S6** | DepthChanged. Create volume with chunkSigner EOA. chunkSigner (separately funded) calls `PostageStamp.increaseDepth` directly. Trigger next cycle. | Volume retires `DepthChanged`; removed from `activeVolumeIds`; gas-boy's next read excludes it. |
| **S7a** | Payer drained. Safe's BZZ balance reduced below topup amount between cycles. | `TopupSkipped(PaymentFailed)`; volume still Active; no partial transfer. |
| **S7b** | Allowance zeroed. Safe calls `approve(registry, 0)` between cycles. | Same as S7a. |
| **S8** | Transfer ownership. A creates volume; A transfers to B (no active account); gas-boy cycle → NoAuth skip; B designates and confirms its own payer; gas-boy cycle → topup from B's payer. | Account context follows owner (§7.1); no spurious drain during the gap. |
| **S9** | Pagination under load. Create 150 volumes across multiple owners. gas-boy cycle reads via two multicall pages. | gas-boy processes all 150 without exceeding Workers CPU budget. |

### 5.2 Gas-boy tests (bun/vitest, anvil-backed)

The gas-boy worker is new code targeting `trigger` / `getActiveVolumes` / `getActiveVolumeCount`. Tests live in `gas-boy/test/`, run against an anvil instance the test fixture spins up.

| Test | Spec |
|---|---|
| `test_liveness_oneDue_sendsTrigger` | 3 volumes, one due. Scheduled handler invoked. Asserts one `trigger(ids[])` tx sent with the due volumeId. **Most important test — blocks the demo if it fails.** |
| `test_partialFailure_cycleCompletes` | 5 volumes, one mocked to revert. Cycle sends `trigger` for all 5; handler exits cleanly. |
| `test_neverThrows_allRetired` | All volumes retired between read and trigger. Handler logs, returns without throwing. |
| `test_emptyRegistry_noop` | `getActiveVolumeCount() == 0`. Handler sends no tx; no revert. (Non-blocking for demo per user scope.) |
| `test_pagination_multipleReadPages` | 150 volumes, limit=100. Handler issues 2 multicall reads, processes all. |
| `test_multicall3_missing_detectedEarly` | Anvil without `anvil_setCode` injection of Multicall3. Handler detects (at setup-time assertion, or via a diagnostic read) and logs rather than silently returning zeros. |

Spam/wasted-gas cases (empty-registry cron fires repeatedly, all-retired cron fires) are acceptable for demo; they must not throw but don't need optimization.

---

## 6. L4 — Sepolia testnet + demo

Audience-facing surface is a **live dashboard** (separate piece of demo-only infra, owned by a junior dev, out of scope for this plan beyond a smoke check). Dashboard does direct RPC reads of `PostageStamp.batches(id).normalisedBalance` for a known set of volumeIds on a short timer, plotting each as a time series. Registered retirement shows up as a greyed-out / stopped line.

Gas-boy runs on Cloudflare Workers prod with cron at the 1-min floor (5 Sepolia blocks per tick). Accepted constraint — drain-spike sawtooth remains clearly visible at this cadence against `graceBlocks = 12`.

### 6.1 Pre-demo smoke (scripted)

Runs the day of the demo; asserts end state. Leaves the system pre-seeded so the dashboard has live sawtooths on-screen when the audience arrives. Two Safes are used: **Safe A** pre-approved and pre-authed for pre-seeded owner A, **Safe B** freshly funded with BZZ but *not* connected to the registry — it's the vehicle for the onboarding beat in §6.2 act 2.

1. Deploy fresh `VolumeRegistry(postage=0xcdfd…, bzz=0x543d…, graceBlocks=12)` to Sepolia.
2. Pre-existing **Safe A** (known address, owner A as sole signer for the smoke script, co-signer added before demo) and **Safe B** (separately owned, pre-funded with enough BZZ to cover act 2's volume charge + runway). Safe B does nothing in this step — it stays untouched and un-approved.
3. Owner A calls `designateFundingWallet(SafeA)`.
4. Safe A executes a **batched `execTransaction` via MultiSendCallOnly** (delegatecall) containing two inner calls:
   - `BZZ.approve(registry, large)`
   - `VolumeRegistry.confirmAuth(ownerA)`
   
   Scripted single-signer (Safe A's sole smoke signer). On success, Safe A's BZZ allowance to the registry is set **and** `accounts[ownerA].active = true` atomically, in one tx.
5. Owner A creates **3 pre-seeded volumes** (V1, V2, V3) with `chunkSigner = Bee's signer`, `depth` from Bee's config, `ttlExpiry = 0`, `immutableBatch = false`.
6. Point gas-boy's prod Worker at the new registry address; wait for ≥2 cron cycles (≥2 min) so each volume has at least one observed topup before curtain-up.
7. Dashboard smoke: dashboard process connects to Sepolia RPC, fetches `normalisedBalance` for V1/V2/V3, renders non-empty sawtooth. (Junior dev confirms visually; no automated assertion needed beyond "it draws".)
8. Assert: each of V1, V2, V3 in `activeVolumeIds`; each has at least one `Toppedup` event since creation; each has `normalisedBalance > 0`; `BZZ.allowance(SafeB, registry) == 0`; `accounts[ownerB].active == false`.

### 6.2 Live demo script (manual, ≤10 min)

Narrative carried by the dashboard. Each act either makes a new sawtooth appear or visibly changes an existing one within ≤1 cron tick. Acts that need to "resolve" (revoke → no more topups) do not need to run to batch death; the audience gets it as soon as the expected topup-spike fails to appear.

1. **Opening (10–30 s).** Dashboard shows V1/V2/V3 sawtoothing steadily. Narrate: each spike is an autonomous gas-boy topup; the slope between is BZZ draining at current Swarm storage price.
2. **Fresh-owner onboarding, live (2–3 min).** A new volume owner B joins, bringing fresh **Safe B** as payer (pre-funded with BZZ in smoke step 2, but not yet connected to the registry). Owner B calls `designateFundingWallet(SafeB)` (own EOA tx). Owner B then **posts one batched transaction to Safe Transaction Service** (`safe-transaction-sepolia.safe.global`) for Safe B to execute — a MultiSend wrapping (i) `BZZ.approve(registry, large)` and (ii) `confirmAuth(ownerB)`. Safe B's co-signer opens Safe{Wallet}, signs **once**, executes → both state changes land atomically; `AccountActivated(ownerB, SafeB)` on-chain. Owner B calls `createVolume` for V4 → new plot line appears on the dashboard at its initial target, begins drawing its first drain. Bee (pre-configured, confirmed to discover third-party batches) discovers V4's batch and becomes upload-capable on it; optionally mention in narration. Narrative beat: "the entire payer-side onboarding — allowance + authorization — is a single signature."
3. **Delete (5–15 s).** Owner calls `deleteVolume(V1)`. Next dashboard refresh (or immediately, if dashboard also watches `VolumeRetired` events — junior dev's call): V1's line greys out instantly. Reason on screen: `OwnerDeleted`. Narrate the distinction from the revoke case that follows.
4. **Revoke (≤1 min to visible effect).** Safe A calls `revoke(ownerA)` (via a scripted `execTransaction` on Safe A; no batching needed — this is a single call). Audience watches V2 and V3: their drains continue, but **the next expected topup spikes don't appear** on either. Narrate I9 — one call disabled *every* volume under ownerA in the same cron tick. V4 continues to sawtooth normally (it's under Owner B / Safe B; revoke is scoped to the (owner, payer) pair that called it). No wait for batch death; the missing spikes are the whole beat.
5. **Depth change (optional, ≤1 min).** chunkSigner (separately funded key) calls `PostageStamp.increaseDepth(V3's batchId, currentDepth+1)` directly. Next gas-boy cycle: V3 retires `DepthChanged`. Dashboard greys out V3 with a distinct reason from V1's `OwnerDeleted`. Skip if running long.
6. **Close.** Dashboard state: V1 grey (`OwnerDeleted`); V2 draining, no spikes (revoked account, coasting on remaining runway); V3 grey (`DepthChanged` if act 5 ran, else draining without spikes); V4 sawtoothing happily under Owner B / Safe B.

Overlap: acts 3 and 4 affect disjoint volumes (V1 vs V2+V3) so they stage back-to-back on the same dashboard frame. V4 continuing to sawtooth throughout is a live counterexample to "revoke nuked everything" — makes I9's scoping visible.

### 6.3 Safe Transaction Service dependency

Act 2 is the only thing in this plan that exercises propose-via-API. Requires:

- Safe deployed on Sepolia (canonical addresses — already there).
- Working access to `safe-transaction-sepolia.safe.global`.
- Safe{Wallet} web UI accessible to whoever holds the co-signer key on demo day.

If any of these is unavailable, fall back to direct `execTransaction` (the mechanism used in pre-demo smoke step 3 and in L3 S1) and narrate the difference. Graceful degradation, not a test failure.

### 6.4 Dashboard (demo-only, out of scope)

Owned by @v1rtl. Direct RPC reads of `PostageStamp.batches(id).normalisedBalance` for a known volumeId list, on a short timer, plotted as time series. Retirement rendering (greying out a stopped line) is at their discretion; can be driven by polling `registry.getVolume(id).status` or by listening for `VolumeRetired` events.

Only test-plan obligation: the smoke check in §6.1 step 6 — dashboard opens, connects, draws a non-empty frame for the pre-seeded volumes. No assertions on correctness of the rendering itself.

---

## 7. Order of work

1. This plan finalised and approved.
2. **Builder subagent** (fresh context, reads only DESIGN.md + this file):
   - Implements L1 test skeletons first (tests written against the specification, not against any implementation).
   - Implements `VolumeRegistry.sol` to pass L1.
   - Implements L3 orion profile additions (Safe contracts) and gas-boy worker against the VolumeRegistry API.
   - Implements L3 scenarios in pytest.
3. L2 fork tests added after L1 green.
4. L4 scripts written against a Sepolia deployment once L1/L3 are green.

Existing `contracts/src/SubscriptionRegistry.sol`, `contracts/src/VolumeRegistry.sol` and any existing `gas-boy/` worker code are **not** inputs — they are to be deleted or left untouched at the builder's discretion; none of their logic carries over.
