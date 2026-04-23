# Swarm Volume Registry — Usage

A reference for integrating with a deployed `VolumeRegistry` contract. Aimed at LLM agents writing integrations and at humans driving the contract from `cast` or ad-hoc scripts. Authoritative architecture lives in [`DESIGN.md`](./DESIGN.md); this file documents the *public-facing* behavior only.

## Contents

1. [What this is](#1-what-this-is)
2. [Deployments](#2-deployments)
3. [Concepts](#3-concepts)
4. [Role profiles](#4-role-profiles)
5. [Setup](#5-setup)
6. [API reference](#6-api-reference)
7. [Events](#7-events)
8. [How topups work](#8-how-topups-work)
9. [Retirement](#9-retirement)
10. [Revocation](#10-revocation)
11. [Survival guarantee](#11-survival-guarantee)
12. [Cost estimation](#12-cost-estimation)
13. [Uploading to Swarm with Bee](#13-uploading-to-swarm-with-bee)
14. [Not in v1](#14-not-in-v1)
15. [References](#15-references)

---

## 1. What this is

`VolumeRegistry` is a Swarm contract that wraps postage batch lifecycle behind a two-role ownership model and a permissionless keeper API.

- You create a *volume* once. It is an on-chain record bound 1:1 to a Postage batch.
- A separately-authorized *funding wallet* (the "payer") holds BZZ. Payment happens via ERC20 `approve` — no custody, no delegation beyond the allowance.
- A *keeper* — anyone — calls `trigger(volumeId)` on a schedule, and the registry tops the batch back up to a fixed runway target. An altruistic keeper runs hourly, so the common case requires no keeper setup on your part.
- Revoking the payer is a single O(1) call that disables topups across every volume managed by the (owner, payer) pair.

The contract does not custody BZZ, does not sign chunks, is not upgradeable, and has no admin role.

## 2. Deployments

| Chain | `VolumeRegistry` | `PostageStamp` | `BZZ` | `PriceOracle` | `graceBlocks` |
|---|---|---|---|---|---|
| Gnosis Chain | `0x0000000000000000000000000000000000000000` (placeholder; not yet deployed) | `0x45a1502382541Cd610CC9068e88727426b696293` | `0xdBF3Ea6F5beE45c02255B2c26a16F300502F68da` | `0x47EeF336e7fE5bED98499A4696bce8f28c1B0a8b` | `17280` |

`graceBlocks` is constructor-immutable. A different runway target requires a fresh deployment.

At runtime you can discover the chain-local dependencies from the registry itself:

```sh
cast call $REGISTRY "postage()(address)"
cast call $REGISTRY "bzz()(address)"
cast call $REGISTRY "graceBlocks()(uint64)"
cast call $POSTAGE  "priceOracle()(address)"
```

## 3. Concepts

- **Volume.** A registry-tracked object, 1:1 with a Postage batch, identified by a `bytes32 volumeId` that is exactly Postage's `batchId`. A volume cannot rebind to a new batch; if the batch dies, the volume retires.
- **Owner.** The address that manages the volume's lifecycle: create, delete, transfer ownership, designate a payer. Also signs chunks in the common case (see §4).
- **Funding wallet / payer.** The address that holds BZZ and has approved the registry to pull from it. Authorized once via a two-sided handshake; revocable by either side at any time.
- **Keeper.** Anyone. Calls `trigger(volumeId)` (or its batched form) and the registry forwards a bounded topup to Postage out of the payer's allowance. This project runs an altruistic keeper on approximately hourly cadence against the Gnosis deployment. You may run your own keeper, or call `trigger` yourself whenever you like; the contract makes no assumptions about who does it.

## 4. Role profiles

Two configurations cover the common cases.

### Profile A — single EOA

Owner and payer are the same EOA. Chunk signing is done by the same key. One transaction costs one signature.

- **When to use:** small or experimental volumes, development setups, demos.
- **Blast radius if the key is compromised:** total. The attacker can create volumes that drain your allowance, `deleteVolume` existing ones, and sign arbitrary chunks.

### Profile B — Safe-funded

Owner is an EOA; payer is a Safe (or any smart-contract wallet that can execute ERC20 `approve` and an arbitrary call). Chunk signing is still done by the owner EOA.

- **When to use:** any volume worth protecting. The Safe holds BZZ and the allowance; the owner EOA can only cause spending up to the outstanding allowance.
- **Blast radius if the owner key is compromised:** bounded by the Safe's current allowance to the registry. Mitigated by (a) keeping the allowance sized to near-term needs rather than `type(uint256).max`, and (b) revoking the account in a single Safe transaction, which kills topups across every volume under the pair.
- **Blast radius if the Safe is compromised:** outside the registry's protection boundary.

Separate chunk-signer addresses (owner ≠ signer) are supported by the contract but considered advanced usage. See [`DESIGN.md`](./DESIGN.md) §5.

## 5. Setup

### 5.1 Single EOA (Profile A)

All four calls are from the same EOA.

```sh
export REGISTRY=0x...         # §2
export BZZ=0x...              # §2
export POSTAGE=0x...          # §2
export YOU=0x...              # your EOA
export AMOUNT=...             # BZZ allowance in PLUR; sized per §12

# 1. Approve registry to pull BZZ on your behalf.
cast send $BZZ "approve(address,uint256)" $REGISTRY $AMOUNT

# 2. Designate yourself as your own payer.
cast send $REGISTRY "designateFundingWallet(address)" $YOU

# 3. Confirm the designation (activates the account).
cast send $REGISTRY "confirmAuth(address)" $YOU

# 4. Create a volume.
#    depth:            log2(chunk count); see §12
#    bucketDepth:      16  (fixed by the PostageStamp deployment)
#    ttlExpiry:        unix seconds, or 0 for no expiry
#    immutableBatch:   false (evict oldest on overflow) or true (reject new uploads when full)
cast send $REGISTRY \
  "createVolume(address,uint8,uint8,uint64,bool)" \
  $YOU 22 16 0 false
```

The `volumeId` is returned from `createVolume` and emitted as the indexed first topic of `VolumeCreated`. Pull it from the transaction receipt:

```sh
cast receipt <TX_HASH> --json | jq -r '.logs[] | select(.topics[0] == "<VolumeCreated topic>") | .topics[1]'
```

Self-designation still requires the handshake in v1 — there is no short-circuit for owner == payer. This is deferred to v2.

### 5.2 Safe-funded (Profile B), batched via Safe Transaction Service

Two state changes need to land atomically on the Safe side: `BZZ.approve(registry, amount)` and `VolumeRegistry.confirmAuth(owner)`. The owner's `designateFundingWallet` is a separate EOA transaction.

```sh
export REGISTRY=0x...
export BZZ=0x...
export SAFE=0x...              # your Safe
export OWNER=0x...              # your owner EOA
export AMOUNT=...

# Step 1 — from the owner EOA.
cast send $REGISTRY "designateFundingWallet(address)" $SAFE
```

Step 2 is a Safe transaction wrapping two inner calls inside a single `delegatecall` to `MultiSendCallOnly`:

- `to=$BZZ, value=0, data=approve(REGISTRY, AMOUNT)`, operation `CALL`
- `to=$REGISTRY, value=0, data=confirmAuth(OWNER)`, operation `CALL`

Propose it via the Safe Transaction Service (`https://safe-transaction-gnosis-chain.safe.global`) and collect signatures through the normal Safe flow, or construct and submit directly with the Safe SDK. Both inner calls land in a single confirmed transaction; `AccountActivated(OWNER, SAFE)` is emitted on success.

Step 3 — `createVolume` — is from the owner EOA, unchanged from §5.1 step 4.

When allocating the allowance (`$AMOUNT`), prefer a bounded figure covering your projected next-N-days drain (see §12) over `type(uint256).max`. The allowance is the per-pair drain ceiling under owner-key compromise.

## 6. API reference

All functions live on the single `VolumeRegistry` contract. Preconditions listed are the user-facing ones; see [`DESIGN.md`](./DESIGN.md) §7, §8 for authoritative semantics.

### 6.1 Owner functions

```solidity
function createVolume(
    address chunkSigner,      // pass your own address; see §4
    uint8   depth,            // 1 << depth chunks; §12
    uint8   bucketDepth,      // 16 on Gnosis; matches PostageStamp
    uint64  ttlExpiry,        // 0 = no expiry
    bool    immutableBatch    // true = reject overflow; false = evict oldest
) external returns (bytes32 volumeId);
```
Preconditions: `accounts[msg.sender].active == true`; payer has approved at least `graceBlocks × currentPrice × (1 << depth)` BZZ to the registry. The full initial topup is pulled from the payer at creation. Emits `VolumeCreated`.

```solidity
function deleteVolume(bytes32 volumeId) external;
```
Owner-only. Transitions the volume to `Retired.OwnerDeleted` and removes it from the active set. No on-chain refund — Postage has no reclaim path. Emits `VolumeRetired(id, OwnerDeleted)`.

```solidity
function transferVolumeOwnership(bytes32 volumeId, address newOwner) external;
```
Owner-only. The volume's payer lookup switches to `accounts[newOwner]`. Until the new owner has an active account, `trigger` calls emit `TopupSkipped(NoAuth)` and do not spend BZZ. Emits `VolumeOwnershipTransferred`.

```solidity
function designateFundingWallet(address payer) external;  // 0 to clear
```
Unilateral owner action. Sets `designated[msg.sender] = payer`; the payer must then call `confirmAuth(msg.sender)` to activate. Emits `PayerDesignated`.

### 6.2 Payer functions

```solidity
function confirmAuth(address owner) external;
```
Requires `designated[owner] == msg.sender`. Overwrites any prior `accounts[owner]` atomically. Emits `AccountActivated`.

```solidity
function revoke(address owner) external;
```
Callable by the owner or by the currently-confirmed payer. Sets `accounts[owner].active = false`. Does **not** retire any volumes — they coast on their remaining batch balance until the batch dies. Emits `AccountRevoked`.

### 6.3 Keeper functions

```solidity
function trigger(bytes32 volumeId) external;
function trigger(bytes32[] calldata volumeIds) external;
function reap(bytes32 volumeId) external;
```
- `trigger(id)` — top up one volume. See §8 for semantics.
- `trigger(ids[])` — loop with per-item `try/catch`; one revert never aborts the batch. Preferred for keepers.
- `reap(id)` — detach a volume that has already transitioned to a retirement condition but hasn't yet been observed by a trigger. Usually unnecessary.

### 6.4 Views

```solidity
struct VolumeView {
    bytes32 volumeId;
    address owner;
    address payer;          // resolved from accounts[owner]
    address chunkSigner;
    uint64  createdAt;
    uint64  ttlExpiry;
    uint8   depth;
    uint8   status;         // 0 = Active, 1 = Retired
    bool    accountActive;
}

function getVolume(bytes32 volumeId) external view returns (VolumeView memory);
function getActiveVolumes(uint256 offset, uint256 limit) external view returns (VolumeView[] memory);
function getActiveVolumeCount() external view returns (uint256);
function getAccount(address owner) external view returns (Account memory);
```

`getActiveVolumes` paginates the active-volume index and returns one RPC round-trip worth of data per page. Suitable for dashboards and keeper-style enumeration.

## 7. Events

| Event | Emitted when |
|---|---|
| `VolumeCreated(bytes32 indexed volumeId, address indexed owner, address chunkSigner, uint8 depth, uint64 ttlExpiry)` | Owner created a volume. First indexed topic is the volumeId. |
| `VolumeRetired(bytes32 indexed volumeId, uint8 reason)` | Volume transitioned to `Retired`. `reason` ∈ `{OwnerDeleted=0, VolumeExpired=1, BatchDied=2, DepthChanged=3}`. |
| `VolumeOwnershipTransferred(bytes32 indexed volumeId, address indexed from, address indexed to)` | `transferVolumeOwnership` succeeded. |
| `PayerDesignated(address indexed owner, address payer)` | Owner called `designateFundingWallet`. |
| `AccountActivated(address indexed owner, address indexed payer)` | Payer confirmed; account is now `Active`. |
| `AccountRevoked(address indexed owner, address indexed payer, address revoker)` | Either party called `revoke`. |
| `Toppedup(bytes32 indexed volumeId, uint256 amount, uint256 newNormalisedBalance)` | A trigger pulled BZZ from the payer and forwarded to Postage. |
| `TopupSkipped(bytes32 indexed volumeId, uint8 reason)` | A trigger ran but moved no BZZ. `reason` ∈ `{NoAuth=0, PaymentFailed=1}`. Volume remains `Active`. |

## 8. How topups work

On each `trigger(volumeId)` the registry:

1. Checks the volume is still `Active` and its Postage batch still exists at the recorded depth.
2. Computes `target = graceBlocks × currentPrice` (per chunk).
3. Reads the batch's current `normalisedBalance`. If it is already ≥ `target`, returns as a no-op.
4. Otherwise, pulls `deficit × (1 << depth)` BZZ from the payer via `transferFrom` and calls `PostageStamp.topUp(volumeId, deficit)`.

This makes triggers **idempotent within a block at constant price**: calling `trigger(id)` twice in a row after a successful topup moves no BZZ on the second call. The same property holds any time the batch is already at or above target.

If the payer's balance or allowance is insufficient, the trigger emits `TopupSkipped(PaymentFailed)` and leaves the volume `Active`. Topups resume automatically on the next trigger after the payer tops up or re-approves.

If the account is revoked, the trigger emits `TopupSkipped(NoAuth)` and leaves the volume `Active`. The volume then coasts on its remaining batch balance until the batch dies.

## 9. Retirement

Retirement is terminal. A retired volume cannot be revived, cannot be triggered, and is removed from the active set.

| Reason | Cause | Detection |
|---|---|---|
| `OwnerDeleted` | Owner called `deleteVolume`. | Direct. |
| `VolumeExpired` | `ttlExpiry != 0 && now ≥ ttlExpiry`. | Next `trigger` or `reap`. |
| `BatchDied` | Postage reports the batch as expired or nonexistent. | Next `trigger` or `reap`. |
| `DepthChanged` | The chunk signer called `PostageStamp.increaseDepth` directly, diverging the batch from the volume's recorded depth. | Next `trigger` or `reap`. |

The correct response to any retirement is to create a new volume. Depth changes in particular are not a v1-supported operation — create a new, larger volume and migrate off-chain.

## 10. Revocation

`revoke(owner)` is the emergency off-switch for a (owner, payer) pair.

- Callable by either the owner or the currently-confirmed payer.
- Flips `accounts[owner].active` to `false` in O(1).
- Affects **every volume** under that pair — the payer is resolved at trigger time from `accounts[owner]`, not stored per volume.
- Does **not** retire any volumes. Each volume continues to drain its existing batch balance until the batch dies (`BatchDied` retirement on the next trigger).

If you want the batches dead sooner, `deleteVolume` each one after revoking.

Re-activating the same (owner, payer) pair requires a fresh `confirmAuth(owner)` call from the payer. Re-designation is only needed if `designated[owner]` was cleared in the interim.

## 11. Survival guarantee

Under the worst-case price schedule permitted by Swarm's `PriceOracle`, a volume that was last successfully topped up at block `t0` is guaranteed to survive at least

```
f × graceBlocks  blocks  before its batch dies
```

where `f ≈ 0.9567` for `graceBlocks = 17280` on Gnosis Chain. In wall-clock terms at 5-second blocks: promised runway is ~24 h, worst-case runway is ~22.95 h. Under flat or falling prices the runway meets or exceeds 24 h.

See [`DESIGN.md`](./DESIGN.md) §10.1 for derivation.

## 12. Cost estimation

Two currencies are involved.

### BZZ — storage

Postage's per-chunk per-block price is one number, read from the oracle:

```sh
cast call $POSTAGE "lastPrice()(uint64)"              # current price, PLUR per chunk per block
cast call $POSTAGE "priceOracle()(address)"           # the oracle
cast call $REGISTRY "graceBlocks()(uint64)"           # 17280 on Gnosis
```

Formulas (all in PLUR = 10⁻¹⁶ BZZ):

- **Initial charge at `createVolume`:** `graceBlocks × currentPrice × (1 << depth)`.
- **Steady-state drain rate:** `currentPrice × (1 << depth)` per block. At 5-second Gnosis blocks: `currentPrice × (1 << depth) / 5` PLUR per second.
- **Per-topup charge:** up to the initial charge, usually less — the registry only tops up the observed deficit back to target.

For a safe allowance, compute your projected N-day drain at the current price, then multiply by a margin (e.g. 2×) to absorb price rises and let you skip re-approvals:

```
allowance ≥  currentPrice × (1 << depth) × blocksPerDay × N × 2
```

where `blocksPerDay = 17280` on Gnosis.

### Batch size and the utilization gotcha

Nominal batch size is `(1 << depth) × 4 KiB`, because each chunk is 4 KiB. Effective usable size is smaller, because chunks distribute over `2^bucketDepth` buckets and buckets can overflow before the batch as a whole is full. Smaller batches suffer more from this — at low depths you can lose a large fraction of nominal capacity.

Swarm's documentation explains bucket-utilization in detail and is the source of truth on how to size a batch for a given target payload. Do not pick depth purely from the nominal table below:

| `depth` | Nominal size (chunks × 4 KiB) |
|---|---|
| 17 | 512 MiB |
| 18 | 1 GiB |
| 20 | 4 GiB |
| 22 | 16 GiB |
| 24 | 64 GiB |
| 28 | 1 TiB |

See Swarm documentation (<https://docs.ethswarm.org>) for the utilization adjustment.

### xDAI — gas

Gnosis Chain gas costs are small. Exact numbers will be added once benchmarked; an individual `trigger` is designed to be cheaper than a direct `PostageStamp.topUp` call would be for the same outcome, because the registry batches allowance management. `trigger(bytes32[])` amortizes a further savings across the batch.

Your own gas budget only matters if you plan to call `trigger` yourself. In the common case where the altruistic hourly keeper is sufficient, gas is somebody else's problem.

## 13. Uploading to Swarm with Bee

The registry does not touch your upload path. It keeps your Postage batch alive; actually uploading data to it happens through a Bee node using the chunk-signer key associated with the batch.

Minimum setup:

1. **Run a light node.** `--full-node=false` is fine; full/ultralight distinctions do not matter for upload. See Bee's install and configuration documentation (<https://docs.ethswarm.org/docs/bee/installation>).
2. **Fund the node's wallet with xDAI only.** The node needs a small amount of xDAI to deploy its chequebook contract on first run (one-time) and to pay ongoing transaction gas. It does **not** need BZZ. Storage is paid for by the registry's payer, not by the node.
3. **Configure the node's signer key to match your volume's chunk signer.** In Profile A or Profile B this is your owner EOA. Bee reads its signer from a JSON keystore file placed at `<data-dir>/keys/swarm.key` (verify against your Bee version's documentation). Generate the keystore with `bee-clef` or any Ethereum keystore tool, drop the file at that path, and set the corresponding password through Bee's password config.
4. **Upload.** Bee automatically discovers Postage batches whose `owner` matches the node's signer and treats them as usable for uploads. No manual batch registration on the node side is needed. Standard `bee-api` upload endpoints (`/bzz`, `/chunks`, `/bytes`) will select an appropriate batch when you supply the `swarm-postage-batch-id` header, or auto-select if you have only one usable batch.

The volume's `chunkSigner` address must equal the node's Ethereum address exactly; Postage checks `batch.owner == msg.sender` when minting and Bee checks the same equality when selecting batches.

## 14. Not in v1

The following are intentionally out of scope for the first deployment:

- **Depth changes after creation.** Create a new volume with the larger depth instead.
- **Signer rotation.** The chunk signer is fixed per volume for its entire lifetime.
- **Multiple payers per owner.** At most one active account per owner.
- **Safe `AllowanceModule` payment path.** Payment is plain ERC20 `approve` / `transferFrom`.
- **EIP-712 / off-chain auth.** All authorizations are on-chain.
- **Admin or operator roles.** The contract has none; no upgradeability.
- **Implicit self-designation** for the single-EOA profile. The handshake is uniform.

See [`DESIGN.md`](./DESIGN.md) §13 for the full deferred-feature list.

## 15. References

- [`DESIGN.md`](./DESIGN.md) — authoritative architecture, invariants, and derivations.
- [Swarm documentation](https://docs.ethswarm.org) — upload semantics, batch utilization, Bee configuration.
- [`ethersphere/storage-incentives`](https://github.com/ethersphere/storage-incentives) — `PostageStamp` and `PriceOracle` source.
- [Safe documentation](https://docs.safe.global) — Safe Transaction Service and MultiSend encoding for Profile B.
