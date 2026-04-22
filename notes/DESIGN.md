# Swarm Volume Registry — Design (v2 proposal)

> **Status note (added after repo walk on 2026-04-22).**
> The currently-deployed contract is `contracts/src/SubscriptionRegistry.sol`,
> a simpler payer-only model: `subscribe(batchId, extensionBlocks)` stores
> `{payer, extensionBlocks}` per batchId; permissionless `keepalive()` tops
> up any batch whose remaining per-chunk balance has dropped below
> `extensionBlocks × lastPrice`. No owner/payer separation, no two-sided
> auth handshake, no volume-lifecycle semantics.
>
> **This document describes a v2 rework**, not an incremental change:
> introduces the owner/payer split, `Account` handshake, volume state
> machine, and four retirement edges. It is not what ships for the
> 2026-04-24 demo. v1 demo ships on the existing `SubscriptionRegistry`;
> `TEST-PLAN.md` targets that contract.
>
> Treat this document as the target architecture for post-demo work.

Companion to `words.md`. This document fixes the v2 architecture; rationale for deviations from `words.md` is captured inline.

## 1. Goals

Bring volume-lifecycle semantics and a two-role (owner / payer) ownership model to Swarm postage-stamp batches. A volume is a first-class object the owner manages; its underlying postage batch is an implementation detail kept alive by a keeper loop funded by a separately-authorized payer.

Non-goals in v2:
- Per-owner multiple funding sources.
- Signer rotation, owner-level signing delegation.
- Depth/size modifications (batches are strictly immutable-shape post-creation).
- Reliability layer (keepalive timelock with claimable assets).
- Safe `AllowanceModule` payment path (ERC20 approve only).
- Owner-initiated EIP-712 auth flows.

## 2. Actors

| Actor | Type | Role |
|---|---|---|
| Owner | EOA or contract | Manages volume lifecycle: create, delete, transfer ownership, designate payer. |
| Chunk signer | EOA | Signs chunks; identical to the underlying Postage batch owner. May equal the volume owner; in v2 may differ. |
| Payer ("funding wallet") | EOA or Safe | Holds BZZ. Authorizes an owner as a permitted spender, revokes. |
| Keeper ("gas boy") | Anyone | Off-chain service that calls `trigger(volumeId)` on a schedule. Pays xDAI for gas. |
| Upload client | Off-chain | Submits chunks signed by the chunk signer to Swarm nodes. Out of scope for this registry. |

## 3. Components

A single contract, `VolumeRegistry`, organised into two logical components:

- **Registry component.** Holds volume records, account records, and the active-volume index. Exposes owner-facing and view APIs.
- **Paymaster component.** Exposes `trigger`, computes topup amounts, pulls BZZ from payer, forwards to `PostageStamp`. Retires volumes when invariants are violated.

They share storage in one contract to avoid cross-contract calls on the hot path.

External dependencies (unmodified):
- `PostageStamp` — Swarm's existing stamp contract. Used through: `createBatch`, `topUp`, `batches`, `currentTotalOutPayment`, price oracle view.
- `BZZ` — ERC20 token. Used through: `transferFrom`, `approve`.

## 4. Data model

```
struct Volume {
    address owner;          // set at create; mutable via transferOwnership
    address chunkSigner;    // set at create; immutable (matches Postage batch owner)
    uint64  createdAt;      // block.timestamp at create
    uint64  ttlExpiry;      // 0 = no expiry
    uint8   depth;          // set at create; treated as immutable — any divergence on Postage retires the volume
    uint8   status;         // Active | Retired
    uint32  activeIndex;    // position in activeVolumeIds (for O(1) removal)
}

struct Account {
    address payer;
    bool    active;
}

mapping(bytes32 volumeId => Volume) volumes;   // volumeId == Postage batchId
mapping(address owner => address)   designated; // owner's chosen payer (pre-confirmation)
mapping(address owner => Account)   accounts;

bytes32[] activeVolumeIds;                      // swap-and-pop; enumerated by keepers
uint256   nextNonce;                            // monotonic counter passed to Postage.createBatch
```

**Volume identifier**: reuse `batchId` produced by Postage, derived as `keccak256(abi.encode(address(this), nonce))` — i.e. salted by the registry's own address and the monotonic `nextNonce` it supplies to `createBatch`. One Postage batch ⇔ one volume forever; volume cannot rebind to a new batch.

**Account identifier**: the owner address. At most one active account per owner. Changing payer = re-designate + re-confirm (atomic overwrite).

## 5. Invariants

- **I1 — Volume ⇔ batch.** Every `Active` volume corresponds to a live Postage batch whose owner is `volume.chunkSigner` and whose depth is `volume.depth`.
- **I2 — Batch immutability.** A volume is `Retired` if Postage reports its batch as expired, at a different depth than `volume.depth`, or at a different owner than `volume.chunkSigner`. (The last condition is defensive; current Postage does not mutate batch owner.)
- **I3 — Payer bounded exposure.** BZZ can only leave `payer` via paymaster if: `accounts[owner].active == true`, `accounts[owner].payer == payer`, volume is `Active`, amount is bounded by (target balance − current balance) × chunks.
- **I4 — Auth bilaterality.** An account is `Active` only after both `designateFundingWallet(payer)` by owner and `confirmAuth(owner)` by payer have been executed.
- **I5 — Trigger idempotence.** Two consecutive `trigger(volumeId)` calls with no intervening block production topped-up zero. Computed target balance is the single source of truth; no timestamp-based rate limits.
- **I6 — Survival.** A volume whose last successful create-or-topup was at block `t0` is guaranteed to survive at least `f × graceBlocks` blocks from `t0` before its batch dies, where `f` is the realization floor derived in §10.1 (`f ≈ 0.9567` for the Gnosis default `graceBlocks = 17280`). Under flat or falling prices the bound is achieved with equality / exceeded.
- **I7 — Removal finality.** A `Retired` volume cannot be revived, receives no further topups, and is removed from `activeVolumeIds`.

## 6. State machines

### 6.1 Volume

```
    (createVolume)
         │
         ▼
    ┌────────┐    deleteVolume / TTL pass / batch dead / depth mismatch
    │ Active ├──────────────────────────────────────────────────────▶ Retired
    └────────┘                                                         (terminal)
```

Entry edges to `Retired`:
- `Retired.OwnerDeleted` — owner calls `deleteVolume`.
- `Retired.VolumeExpired` — `ttlExpiry != 0 && now >= ttlExpiry`; detected by next trigger or by anyone calling `reap(volumeId)`.
- `Retired.BatchDied` — Postage reports batch no longer existing (balance exhausted or never existed).
- `Retired.DepthChanged` — Postage reports depth ≠ `volume.depth`.

### 6.2 Account

```
        (designateFundingWallet)          (confirmAuth)
    ∅ ─────────────────────────▶ Designated ──────────────▶ Active
    ▲                                                         │
    │                                                         │
    └── revoke (by owner or payer) ◀─────────────────────────┘
```

`designateFundingWallet(p)` by owner sets `designated[owner] = p`. Calling with `p = address(0)` clears designation.

`confirmAuth(owner)` by payer requires `designated[owner] == msg.sender`, then sets `accounts[owner] = {payer: msg.sender, active: true}`. Atomic overwrite of any prior account.

`revoke(owner)` callable by `msg.sender == owner || msg.sender == accounts[owner].payer`. Sets `accounts[owner].active = false`. Does **not** retire any volumes; volumes coast on remaining batch balance until `BatchDied`.

## 7. API

Signatures only. No implementation.

### 7.1 Owner API

```
function createVolume(
    address chunkSigner,
    uint8   depth,
    uint8   bucketDepth,
    uint64  ttlExpiry,          // 0 = no expiry
    bool    immutableBatch
) external returns (bytes32 volumeId);

function deleteVolume(bytes32 volumeId) external;

function transferVolumeOwnership(bytes32 volumeId, address newOwner) external;

function designateFundingWallet(address payer) external;  // payer = 0 to clear
```

- `createVolume` requires `accounts[msg.sender].active == true`. Initial per-chunk balance is not user-chosen: the registry computes `perChunk = currentPrice × graceBlocks` so the volume is born with exactly the runway described in §10.1. Total BZZ charge `= perChunk × (1 << depth)` is pulled from `accounts[msg.sender].payer` via ERC20 `transferFrom` (payer must have approved at least this amount). Registry then calls `PostageStamp.createBatch(chunkSigner, perChunk, depth, bucketDepth, nonce, immutableBatch)`, passing the internally-managed `nextNonce` (§4) and incrementing. Inserts into `activeVolumeIds`. The returned `volumeId` equals Postage's `batchId = keccak256(abi.encode(address(this), nonce))`; callers discover it via the return value or the `VolumeCreated` event. Postage's `minimumInitialBalancePerChunk` floor is guaranteed by the constructor check in §10.
- `deleteVolume` requires `msg.sender == volume.owner && volume.status == Active`. Transitions to `Retired.OwnerDeleted`, swap-and-pop from active list. No on-chain refund (Postage has no reclaim).
- `transferVolumeOwnership` requires `msg.sender == volume.owner`. Account context follows the new owner — volume's payer lookup will now use `accounts[newOwner]`. Documented: new owner must have an active account or topups will skip.
- `designateFundingWallet` is unilateral owner action. Does not require any account state.

### 7.2 Payer API

```
function confirmAuth(address owner) external;

function revoke(address owner) external;
```

- `confirmAuth` requires `designated[owner] == msg.sender`. Overwrites any prior `accounts[owner]`.
- `revoke` callable by either owner or current payer.

### 7.3 Keeper API

```
function trigger(bytes32 volumeId) external;
function trigger(bytes32[] calldata volumeIds) external;
function reap(bytes32 volumeId) external;
```

- `trigger(id)` — see §8.
- `trigger(ids[])` — loops with per-item `try/catch`; one failure never aborts the batch.
- `reap(id)` — detaches `Retired` volumes that were retired in a prior trigger; mostly unnecessary since trigger does its own reaping, but exposed for manual cleanup.

### 7.4 Views

```
struct VolumeView {
    bytes32 volumeId;
    address owner;
    address payer;          // resolved from accounts[owner]
    address chunkSigner;
    uint64  createdAt;
    uint64  ttlExpiry;
    uint8   depth;
    uint8   status;
    bool    accountActive;
}

function getVolume(bytes32 volumeId) external view returns (VolumeView memory);

function getActiveVolumes(uint256 offset, uint256 limit)
    external view returns (VolumeView[] memory);

function getActiveVolumeCount() external view returns (uint256);

function getAccount(address owner) external view returns (Account memory);
```

`getActiveVolumes` is the keeper's primary read; returns enough data for off-chain policy filters (depth threshold, minimum TTL window, `accountActive`) without a second RPC round-trip per volume.

## 8. Trigger semantics

`trigger(volumeId)`:

1. Load `v = volumes[volumeId]`. Revert if `v.status != Active`.
2. Load Postage batch `b = PostageStamp.batches[volumeId]`. If `b` does not exist or is expired → retire `BatchDied`, emit `VolumeRetired`, return.
3. If `b.depth != v.depth` → retire `DepthChanged`, emit, return.
4. If `v.ttlExpiry != 0 && block.timestamp >= v.ttlExpiry` → retire `VolumeExpired`, emit, return.
5. `acct = accounts[v.owner]`. If `!acct.active` → emit `TopupSkipped(NoAuth)`, return. **No retire.**
6. Compute `target = currentPrice × graceBlocks`.
   Compute `deficit = target > b.normalisedBalance ? target - b.normalisedBalance : 0`.
   If `deficit == 0` → return (idempotent no-op).
7. `amount = deficit × (1 << v.depth)`.
   Try `BZZ.transferFrom(acct.payer, this, amount)`. On revert (insufficient balance, revoked approval, spending-limit hit, Safe module config) → emit `TopupSkipped(PaymentFailed)`, return. **No retire.**
8. `BZZ.approve(postage, amount); PostageStamp.topUp(volumeId, deficit);` emit `Toppedup`.

The check order matters: batch/depth/TTL retire-edges are evaluated before auth/payment, so a lapsed auth does not mask an expired batch.

## 9. Events

```
event VolumeCreated(bytes32 indexed volumeId, address indexed owner, address chunkSigner, uint8 depth, uint64 ttlExpiry);
event VolumeRetired(bytes32 indexed volumeId, uint8 reason);  // OwnerDeleted | VolumeExpired | BatchDied | DepthChanged
event VolumeOwnershipTransferred(bytes32 indexed volumeId, address indexed from, address indexed to);

event PayerDesignated(address indexed owner, address payer);
event AccountActivated(address indexed owner, address indexed payer);
event AccountRevoked(address indexed owner, address indexed payer, address revoker);

event Toppedup(bytes32 indexed volumeId, uint256 amount, uint256 newNormalisedBalance);
event TopupSkipped(bytes32 indexed volumeId, uint8 reason);  // NoAuth | PaymentFailed
```

## 10. Deployment parameters

Set once at construction; all three are immutable thereafter:

| Param | Type | Description |
|---|---|---|
| `postage` | address | PostageStamp contract |
| `bzz` | address | BZZ ERC20 |
| `graceBlocks` | uint64 | Target runway per topup cycle, in blocks. Drives both the initial charge at `createVolume` and the topup target in `trigger`. Chosen value: **17280** (≈ 24 h on Gnosis Chain's 5 s blocks). See §10.1 for the bound this implies. |

**Constructor checks.**
- `graceBlocks ≥ PostageStamp(postage).minimumValidityBlocks()`. Otherwise `createBatch` would revert with `InsufficientBalance` on every `createVolume` (Postage's own floor is `minimumValidityBlocks × lastPrice` per chunk). Verified at deploy; contract refuses to instantiate if violated.
- `postage` and `bzz` are non-zero.

No admin role, no upgradeability for v2. Fresh deploy per chain. Target chain: **Gnosis Chain only** for v2.

### 10.1 Deviation bound for `graceBlocks = 17280`

`graceBlocks` is the runway, in Postage per-chunk-balance-at-current-price units, that the registry charges up front and tops up to. If price stayed flat, a freshly-topped-up volume would survive exactly `graceBlocks` more blocks before its batch dies. Under a rising price, the realised runway is shorter. This section bounds the worst-case shortfall.

**Guarantee we document to users.** If the altruistic gas-boy never returns after a top-up, the batch dies at block `t0 + T`, where `T / graceBlocks ≥ f` in the worst case permitted by Swarm's `PriceOracle`.

**Derivation.** At top-up, per-chunk balance is `graceBlocks × p0`, where `p0` is the oracle price at that moment. Drain to time `T` is `∫_0^T p(s) ds`. Swarm's `PriceOracle` (`ethersphere/storage-incentives/src/PriceOracle.sol`) raises price by at most factor `K_max` per round of `U` blocks; skipped rounds apply `K_max` retroactively to each skipped round, so the compound ceiling is genuine. Bounding the drain by a continuous exponential `p(t) ≤ p0 × e^(λt)` with `λ = ln(K_max)/U`:

```
budget = graceBlocks × p0
drain(T) ≤ p0 × (e^(λT) − 1) / λ
setting drain = budget:    e^(λT) = 1 + λ × graceBlocks
=>   f = T / graceBlocks = ln(1 + λ × graceBlocks) / (λ × graceBlocks)
```

**Constants (Swarm PriceOracle on Gnosis Chain).**

| Symbol | Value | Source |
|---|---|---|
| `U` | 152 blocks | `ROUND_LENGTH` |
| `K_max` | 1 049 417 / 1 048 576 ≈ 1.000 802 | `changeRate[0] / priceBase` (also applied to every skipped round via the catchup loop in `adjustPrice`) |
| `λ` | `ln(K_max) / U ≈ 5.27 × 10⁻⁶` per block | derived |

**Computation for `graceBlocks = 17280`.**

```
λ × graceBlocks  ≈ 5.27e−6 × 17280 ≈ 0.09106
f  = ln(1.09106) / 0.09106 ≈ 0.08712 / 0.09106 ≈ 0.9567
```

So the registry guarantees that a volume whose last successful top-up was at block `t0` lives **at least `0.9567 × 17280 ≈ 16532` blocks** after `t0` before its batch dies, even in the pessimistic scenario where the oracle raises price at the maximum permitted rate for every round throughout the grace period. In wall-clock terms on Gnosis (5 s blocks): promised ~24 h, worst-case ~22.95 h.

**Pessimism.** This is the *floor*, not the expectation. `K_max` only applies when redundancy is reported below target; `PriceOracle` can also *decrease* price (down to a minimum floor), and the neutral `changeRate[4]` leaves price unchanged. Typical realization is at or near 100 %. The 95.67 % figure is the contract-level guarantee we document; normal operation is expected to do much better.

**Changing `graceBlocks` later.** `graceBlocks` is constructor-immutable. A different runway target requires a redeploy. The invariant above is a property of the deployed value only.

## 11. Gas-boy (off-chain)

Serverless (Cloudflare Workers). Paginates `getActiveVolumes(offset, limit)`, applies operator-local policy filter (minimum depth, minimum created-to-expiry window, `accountActive`), batches ids, calls `trigger(ids[])`. Holds an xDAI-funded signer.

Operator policy is purely off-chain; the contract admits any volume that meets its own invariants.

## 12. Symmetries captured

- Account lifecycle: `designate ↔ confirm`; `owner-revoke ↔ payer-revoke`.
- Volume lifecycle: `create ↔ delete (OwnerDeleted)`.
- Retirement edges: four parallel reasons, one terminal state.
- Registry / Paymaster: identical-signature write paths for state, read paths for views.

## 13. Deferred beyond v2

- Per-volume payer override (multiple funding sources per owner).
- Depth increase (coordinated signer + registry flow).
- Signer rotation (requires Postage extension or off-chain re-keying convention).
- Safe AllowanceModule payment path.
- On-chain EIP-712 auth.
- Operator roles with restricted management capabilities.
- Reliability layer (timelock-gated claimable xDAI stash for keeper upkeep).
