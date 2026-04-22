// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPostageStamp} from "./interfaces/IPostageStamp.sol";

/// @title VolumeRegistry
/// @notice Volume-lifecycle layer over Swarm postage stamp batches.
///
/// A "volume" is our first-class record bundling together a postage batch
/// (by id) with:
///   - an **owner** (manages the volume entry: modify ttl/grace, delete,
///     transfer ownership);
///   - a **chunk signer** (the EOA that bee uses to sign uploads — on
///     PostageStamp this is the batch's `owner` field);
///   - a **payer** (holds BZZ; the entity charged for keepalive top-ups).
///
/// The payer is **not** stored on the volume itself — a single `accounts`
/// table keys (ownerAddress) → {payer, active}. This mirrors the notes'
/// guidance: revoking a payer authorization must affect every volume that
/// shares the (owner, payer) pair.
///
/// Payer authorization requires a two-party handshake:
///   1. `designatePayer(payer)`   — owner picks a payer (pre-confirm)
///   2. `confirmAccount(owner)`   — payer (msg.sender) confirms
/// A payer cannot install themselves without the owner's prior
/// designation. Either party can revoke the authorization at any time.
///
/// v1 limitations:
///   - `extendVolume` is defined but unconditionally reverts with
///     "Batch depth increase not supported in v1". Depth is frozen at
///     volume creation time. Keepalive only adjusts TTL via `PostageStamp.topUp`,
///     never depth.
///
/// Block-time reminder (caller must pick `graceBlocks` for the target chain):
///   - Gnosis Chain (~5 s/block):  24h ≈ 17280 blocks
///   - Sepolia      (~12 s/block): 24h ≈ 7200  blocks
contract VolumeRegistry {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    struct Account {
        address payer;
        bool active;
    }

    struct Volume {
        address owner;          // volume-management rights
        address chunkSigner;    // PostageStamp batch.owner; signs bee uploads
        uint64 ttlExpiry;       // block past which the volume is dead (0 = never)
        uint8 initialDepth;     // frozen at create time
        uint32 graceBlocks;     // keepalive target: graceBlocks × price per chunk
    }

    // ------------------------------------------------------------------
    // Immutable wiring
    // ------------------------------------------------------------------

    IERC20 public immutable bzz;
    IPostageStamp public immutable stamp;

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    // Owner → designated payer (pre-confirmation).
    mapping(address => address) public designated;

    // Owner → confirmed account. An account is (payer, active=true) only
    // after both designatePayer + confirmAccount have run for the same
    // (owner, payer) pair.
    mapping(address => Account) public accounts;

    // Volume data, keyed by batchId.
    mapping(bytes32 => Volume) public volumes;

    // Enumerable list of known batchIds (for keepalive iteration).
    bytes32[] public batchIds;
    mapping(bytes32 => uint256) private _indexPlusOne; // 0 = absent

    // Reentrancy guard.
    uint256 private _locked = 1;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event PayerDesignated(address indexed owner, address indexed payer);
    event AccountConfirmed(address indexed owner, address indexed payer);
    event AccountRevoked(address indexed owner, address indexed payer, address indexed by);

    event VolumeCreated(
        bytes32 indexed batchId,
        address indexed owner,
        address indexed chunkSigner,
        uint64 ttlExpiry,
        uint8 initialDepth,
        uint32 graceBlocks
    );
    event VolumeModified(bytes32 indexed batchId, uint64 ttlExpiry, uint32 graceBlocks);
    event VolumeDeleted(bytes32 indexed batchId, address indexed owner);
    event VolumeOwnershipTransferred(bytes32 indexed batchId, address indexed from, address indexed to);

    event KeptAlive(
        address indexed caller,
        bytes32 indexed batchId,
        address indexed payer,
        uint256 perChunk,
        uint256 totalAmount
    );
    event KeepaliveSkipped(bytes32 indexed batchId, bytes reason);

    event Pruned(bytes32 indexed batchId, address indexed caller);
    event PruneSkipped(bytes32 indexed batchId, bytes reason);

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error AlreadyExists();
    error NotExists();
    error NotOwner();
    error ZeroGrace();
    error NotDesignated();
    error NoAccount();
    error NotAuthorizedToRevoke();
    error ChunkSignerMismatch();
    error DepthUnsupported();
    error TransferFromFailed();
    error OnlySelf();
    error NotDead();
    error Reentrancy();

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    constructor(IERC20 _bzz, IPostageStamp _stamp) {
        bzz = _bzz;
        stamp = _stamp;
        // One-time unlimited approval so `stamp.topUp` can spend the BZZ
        // we pulled from a payer without a per-call `approve`.
        _bzz.approve(address(_stamp), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Account management (owner ↔ payer handshake)
    // ------------------------------------------------------------------

    /// @notice Owner picks a payer. Takes effect only after the payer
    /// subsequently calls `confirmAccount(owner)`.
    function designatePayer(address payer) external {
        designated[msg.sender] = payer;
        emit PayerDesignated(msg.sender, payer);
    }

    /// @notice Payer (msg.sender) confirms they will fund `owner`'s
    /// volumes. Reverts if the owner has not designated msg.sender.
    function confirmAccount(address owner) external {
        if (designated[owner] != msg.sender) revert NotDesignated();
        accounts[owner] = Account({payer: msg.sender, active: true});
        emit AccountConfirmed(owner, msg.sender);
    }

    /// @notice Either party (owner or the confirmed payer) may dissolve
    /// the account. After revocation, keepalive cannot pull from the
    /// payer until a fresh designate+confirm cycle completes.
    function revokeAccount(address owner) external {
        Account memory a = accounts[owner];
        if (a.payer == address(0)) revert NoAccount();
        if (msg.sender != owner && msg.sender != a.payer) revert NotAuthorizedToRevoke();
        delete accounts[owner];
        delete designated[owner];
        emit AccountRevoked(owner, a.payer, msg.sender);
    }

    /// @notice Effective payer for `owner`: the confirmed account's payer
    /// iff active. Self-designation (owner == payer) is allowed but still
    /// requires the full handshake to eliminate accidental self-pay.
    function effectivePayer(address owner) public view returns (address) {
        Account memory a = accounts[owner];
        if (!a.active) return address(0);
        return a.payer;
    }

    // ------------------------------------------------------------------
    // Volume lifecycle
    // ------------------------------------------------------------------

    /// @notice Register a new volume for an already-created postage
    /// batch. Asserts the PostageStamp-level owner of the batch equals
    /// the declared `chunkSigner` so v1 keeps the postage-batch-owner
    /// and the volume's chunkSigner aligned.
    /// @param batchId       Existing postage batch.
    /// @param chunkSigner   EOA that bee will use to sign uploads on this
    ///                      batch (== `stamp.batches(batchId).owner`).
    /// @param ttlExpiry     Block number past which this volume is dead.
    ///                      0 disables volume-level expiry (batch TTL still
    ///                      governs keepalive).
    /// @param graceBlocks   Keepalive target: top-ups maintain
    ///                      `remainingPerChunk ≈ graceBlocks × lastPrice`.
    function createVolume(
        bytes32 batchId,
        address chunkSigner,
        uint64 ttlExpiry,
        uint32 graceBlocks
    ) external {
        if (graceBlocks == 0) revert ZeroGrace();
        if (volumes[batchId].owner != address(0)) revert AlreadyExists();

        (address owner_, uint8 depth,,,,) = stamp.batches(batchId);
        if (owner_ != chunkSigner) revert ChunkSignerMismatch();

        volumes[batchId] = Volume({
            owner: msg.sender,
            chunkSigner: chunkSigner,
            ttlExpiry: ttlExpiry,
            initialDepth: depth,
            graceBlocks: graceBlocks
        });
        batchIds.push(batchId);
        _indexPlusOne[batchId] = batchIds.length;

        emit VolumeCreated(batchId, msg.sender, chunkSigner, ttlExpiry, depth, graceBlocks);
    }

    /// @notice Update a volume's TTL expiry and/or grace period.
    /// Depth and chunkSigner are frozen at creation — use
    /// `extendVolume` for depth (which is not supported in v1).
    function modifyVolume(bytes32 batchId, uint64 newTtlExpiry, uint32 newGraceBlocks) external {
        if (newGraceBlocks == 0) revert ZeroGrace();
        Volume storage v = volumes[batchId];
        if (v.owner == address(0)) revert NotExists();
        if (v.owner != msg.sender) revert NotOwner();
        v.ttlExpiry = newTtlExpiry;
        v.graceBlocks = newGraceBlocks;
        emit VolumeModified(batchId, newTtlExpiry, newGraceBlocks);
    }

    /// @notice Unconditionally reverts. Depth changes are not supported
    /// in v1. Because the registry's API never calls
    /// `PostageStamp.increaseDepth`, no depth change can flow through
    /// this contract; the revert documents the policy explicitly.
    function extendVolume(bytes32, uint8) external pure {
        revert DepthUnsupported();
    }

    /// @notice Permanently remove a volume. Owner-only. Irreversible.
    /// After this, no further keepalive can route topups through this
    /// volume regardless of account state.
    function deleteVolume(bytes32 batchId) external {
        Volume memory v = volumes[batchId];
        if (v.owner == address(0)) revert NotExists();
        if (v.owner != msg.sender) revert NotOwner();
        _remove(batchId);
        emit VolumeDeleted(batchId, v.owner);
    }

    /// @notice Hand management rights off to another address. The new
    /// owner's payer account (if any) takes over — the old owner's
    /// account is unaffected.
    function transferOwnership(bytes32 batchId, address newOwner) external {
        Volume storage v = volumes[batchId];
        if (v.owner == address(0)) revert NotExists();
        if (v.owner != msg.sender) revert NotOwner();
        address from = v.owner;
        v.owner = newOwner;
        emit VolumeOwnershipTransferred(batchId, from, newOwner);
    }

    // ------------------------------------------------------------------
    // Keepalive
    // ------------------------------------------------------------------

    /// @notice Iterate all volumes and top up any whose batch balance
    /// has dropped below `graceBlocks × lastPrice` per chunk. Tops up
    /// precisely to the target (idempotent: a second call made in the
    /// same block after a top-up is a strict no-op).
    function keepalive() external nonReentrant {
        uint64 price = stamp.lastPrice();
        uint256 cto = stamp.currentTotalOutPayment();
        uint256 n = batchIds.length;
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = batchIds[i];
            try this._keepaliveOne(id, price, cto) returns (bool toppedUp, address payer, uint256 perChunk, uint256 total) {
                if (toppedUp) emit KeptAlive(msg.sender, id, payer, perChunk, total);
            } catch (bytes memory err) {
                emit KeepaliveSkipped(id, err);
            }
        }
    }

    /// @notice Keep alive a single volume. Reverts bubble — suitable
    /// for targeted callers that want to know why the call failed.
    function keepaliveOne(bytes32 id) external nonReentrant returns (bool toppedUp) {
        uint64 price = stamp.lastPrice();
        uint256 cto = stamp.currentTotalOutPayment();
        address payer;
        uint256 perChunk;
        uint256 total;
        (toppedUp, payer, perChunk, total) = this._keepaliveOne(id, price, cto);
        if (toppedUp) emit KeptAlive(msg.sender, id, payer, perChunk, total);
    }

    /// @dev External only so the bulk `keepalive()` can try/catch on a
    /// per-volume basis. Restricted to self-calls.
    function _keepaliveOne(bytes32 id, uint64 price, uint256 cto)
        external
        returns (bool toppedUp, address payer, uint256 perChunk, uint256 total)
    {
        if (msg.sender != address(this)) revert OnlySelf();

        Volume memory v = volumes[id];
        if (v.owner == address(0)) return (false, address(0), 0, 0);
        // Volume-level expiry: owner-configured end of life.
        if (v.ttlExpiry != 0 && block.number >= v.ttlExpiry) return (false, address(0), 0, 0);
        if (price == 0) return (false, address(0), 0, 0);

        (address owner_, uint8 depth,,, uint256 normBal,) = stamp.batches(id);
        if (owner_ == address(0)) return (false, address(0), 0, 0); // batch missing / reaped
        if (normBal <= cto) return (false, address(0), 0, 0);       // batch-level expired

        uint256 remainingPerChunk = normBal - cto;
        uint256 target = uint256(price) * uint256(v.graceBlocks);
        if (remainingPerChunk >= target) return (false, address(0), 0, 0);

        // Precise idempotent top-up: bring remaining back to exactly `target`.
        perChunk = target - remainingPerChunk;
        total = perChunk << depth;

        Account memory a = accounts[v.owner];
        if (!a.active) return (false, address(0), 0, 0);
        payer = a.payer;

        if (!bzz.transferFrom(payer, address(this), total)) revert TransferFromFailed();
        stamp.topUp(id, perChunk);
        toppedUp = true;
    }

    // ------------------------------------------------------------------
    // Pruning
    // ------------------------------------------------------------------

    /// @notice True iff this volume is permanently un-keepable:
    /// - its own ttlExpiry has passed, OR
    /// - PostageStamp no longer knows about the batch (never created
    ///   or reaped by `expireLimited`).
    function isDead(bytes32 id) external view returns (bool) {
        Volume memory v = volumes[id];
        if (v.owner == address(0)) return false;
        if (v.ttlExpiry != 0 && block.number >= v.ttlExpiry) return true;
        (address owner_,,,,,) = stamp.batches(id);
        return owner_ == address(0);
    }

    /// @notice Prune one dead volume. Reverts on NotExists / NotDead
    /// so the caller can react.
    function pruneOne(bytes32 id) external nonReentrant {
        this._pruneOne(id);
        emit Pruned(id, msg.sender);
    }

    /// @notice Bulk prune. Per-id failures are caught and emitted as
    /// `PruneSkipped` with the revert selector embedded.
    function pruneDead(bytes32[] calldata ids) external nonReentrant {
        for (uint256 i = 0; i < ids.length; ++i) {
            try this._pruneOne(ids[i]) {
                emit Pruned(ids[i], msg.sender);
            } catch (bytes memory err) {
                emit PruneSkipped(ids[i], err);
            }
        }
    }

    function _pruneOne(bytes32 id) external {
        if (msg.sender != address(this)) revert OnlySelf();
        Volume memory v = volumes[id];
        if (v.owner == address(0)) revert NotExists();

        bool volumeExpired = v.ttlExpiry != 0 && block.number >= v.ttlExpiry;
        (address owner_,,,,,) = stamp.batches(id);
        bool batchGone = owner_ == address(0);
        if (!volumeExpired && !batchGone) revert NotDead();

        _remove(id);
    }

    // ------------------------------------------------------------------
    // Internal: index maintenance (swap-and-pop)
    // ------------------------------------------------------------------

    function _remove(bytes32 id) internal {
        uint256 idx = _indexPlusOne[id] - 1;
        uint256 last = batchIds.length - 1;
        if (idx != last) {
            bytes32 lastId = batchIds[last];
            batchIds[idx] = lastId;
            _indexPlusOne[lastId] = idx + 1;
        }
        batchIds.pop();
        delete _indexPlusOne[id];
        delete volumes[id];
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function volumeCount() external view returns (uint256) {
        return batchIds.length;
    }

    /// @notice True iff `keepalive()` would top up this volume in the
    /// current block (batch alive, volume not expired, active account,
    /// remaining below target).
    function isDue(bytes32 id) external view returns (bool) {
        Volume memory v = volumes[id];
        if (v.owner == address(0)) return false;
        if (v.ttlExpiry != 0 && block.number >= v.ttlExpiry) return false;
        if (!accounts[v.owner].active) return false;
        uint64 price = stamp.lastPrice();
        if (price == 0) return false;
        (address owner_,,,, uint256 normBal,) = stamp.batches(id);
        if (owner_ == address(0)) return false;
        uint256 cto = stamp.currentTotalOutPayment();
        if (normBal <= cto) return false;
        return (normBal - cto) < uint256(price) * uint256(v.graceBlocks);
    }

    /// @notice Target balance (per-chunk and total) that a successful
    /// top-up would leave the batch at. Useful for off-chain budgeting.
    function estimatedTopUp(bytes32 id) external view returns (uint256 perChunk, uint256 total) {
        Volume memory v = volumes[id];
        if (v.owner == address(0)) return (0, 0);
        uint64 price = stamp.lastPrice();
        (, uint8 depth,,, uint256 normBal,) = stamp.batches(id);
        uint256 cto = stamp.currentTotalOutPayment();
        uint256 target = uint256(price) * uint256(v.graceBlocks);
        uint256 remainingPerChunk = normBal > cto ? normBal - cto : 0;
        if (remainingPerChunk >= target) return (0, 0);
        perChunk = target - remainingPerChunk;
        total = perChunk << depth;
    }
}
