// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title VolumeRegistry
/// @notice Volume-lifecycle layer over Swarm postage-stamp batches.
/// @dev See notes/DESIGN.md for the full specification. This implementation
///      is a direct mechanical translation of that document and of the
///      companion notes/TEST-PLAN.md. In particular:
///        - two-role model (owner / payer), bilateral auth (I4);
///        - `graceBlocks` is immutable global (§10);
///        - `volumeId == batchId == keccak256(abi.encode(address(this), nonce))`;
///        - trigger check-order is: status → batch-dead → owner-mismatch
///          → depth-changed → TTL-expired → auth → payment (§8);
///        - retire beats auth-skip; payment-failure does not retire.
interface IERC20Like {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IPostageStampLike {
    struct Batch {
        address owner;
        uint8 depth;
        uint8 bucketDepth;
        bool immutableFlag;
        uint256 normalisedBalance;
        uint256 lastUpdatedBlockNumber;
    }

    function batches(bytes32 id)
        external
        view
        returns (
            address owner,
            uint8 depth,
            uint8 bucketDepth,
            bool immutableFlag,
            uint256 normalisedBalance,
            uint256 lastUpdatedBlockNumber
        );

    function currentTotalOutPayment() external view returns (uint256);

    function lastPrice() external view returns (uint64);

    function minimumValidityBlocks() external view returns (uint64);

    function minimumInitialBalancePerChunk() external view returns (uint256);

    function createBatch(
        address owner,
        uint256 initialBalancePerChunk,
        uint8 depth,
        uint8 bucketDepth,
        bytes32 nonce,
        bool immutableFlag
    ) external returns (bytes32);

    function topUp(bytes32 batchId, uint256 topupAmountPerChunk) external;
}

contract VolumeRegistry {
    // ---------------------------------------------------------------------
    // Constants / enums
    // ---------------------------------------------------------------------

    uint8 internal constant STATUS_ACTIVE = 1;
    uint8 internal constant STATUS_RETIRED = 2;

    // Retire reasons (packed into `VolumeRetired.reason`).
    uint8 public constant REASON_OWNER_DELETED = 1;
    uint8 public constant REASON_VOLUME_EXPIRED = 2;
    uint8 public constant REASON_BATCH_DIED = 3;
    uint8 public constant REASON_DEPTH_CHANGED = 4;
    uint8 public constant REASON_BATCH_OWNER_MISMATCH = 5; // defensive branch — DESIGN §6.1

    // TopupSkipped reasons.
    uint8 public constant SKIP_NO_AUTH = 1;
    uint8 public constant SKIP_PAYMENT_FAILED = 2;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    struct Volume {
        address owner;
        address chunkSigner;
        uint64 createdAt;
        uint64 ttlExpiry; // 0 = no expiry
        uint8 depth;
        uint8 status;
        uint32 activeIndex;
    }

    struct Account {
        address payer;
        bool active;
    }

    struct VolumeView {
        bytes32 volumeId;
        address owner;
        address payer; // resolved from accounts[owner]
        address chunkSigner;
        uint64 createdAt;
        uint64 ttlExpiry;
        uint8 depth;
        uint8 status;
        bool accountActive;
    }

    // ---------------------------------------------------------------------
    // Immutable wiring
    // ---------------------------------------------------------------------

    IPostageStampLike public immutable postage;
    IERC20Like public immutable bzz;
    uint64 public immutable graceBlocks;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    mapping(bytes32 => Volume) internal _volumes;
    mapping(address => address) public designated; // owner → chosen payer (pre-confirmation)
    mapping(address => Account) internal _accounts;

    bytes32[] internal _activeVolumeIds;
    uint256 public nextNonce;

    // ---------------------------------------------------------------------
    // Events  (see DESIGN §9)
    // ---------------------------------------------------------------------

    event VolumeCreated(
        bytes32 indexed volumeId,
        address indexed owner,
        address chunkSigner,
        uint8 depth,
        uint64 ttlExpiry
    );
    event VolumeRetired(bytes32 indexed volumeId, uint8 reason);
    event VolumeOwnershipTransferred(
        bytes32 indexed volumeId,
        address indexed from,
        address indexed to
    );

    event PayerDesignated(address indexed owner, address payer);
    event AccountActivated(address indexed owner, address indexed payer);
    event AccountRevoked(address indexed owner, address indexed payer, address revoker);

    event Toppedup(bytes32 indexed volumeId, uint256 amount, uint256 newNormalisedBalance);
    event TopupSkipped(bytes32 indexed volumeId, uint8 reason);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error GraceBlocksBelowFloor(uint64 grace, uint64 floor_);
    error AccountNotActive();
    error NotVolumeOwner();
    error VolumeNotActive();
    error NotDesignated();
    error NotAuthorizedToRevoke();
    error DesignationClearedOnActivate();

    // ---------------------------------------------------------------------
    // Constructor  (DESIGN §10)
    // ---------------------------------------------------------------------

    constructor(address _postage, address _bzz, uint64 _graceBlocks) {
        if (_postage == address(0) || _bzz == address(0)) revert ZeroAddress();
        uint64 floor_ = IPostageStampLike(_postage).minimumValidityBlocks();
        if (_graceBlocks < floor_) revert GraceBlocksBelowFloor(_graceBlocks, floor_);

        postage = IPostageStampLike(_postage);
        bzz = IERC20Like(_bzz);
        graceBlocks = _graceBlocks;
    }

    // =====================================================================
    // Account API  (§7.1, §7.2)
    // =====================================================================

    /// @notice Owner designates a payer candidate. Pass `address(0)` to clear.
    /// @dev Unilateral — does not grant any spend permission until the payer
    ///      confirms via `confirmAuth(msg.sender)`.
    function designateFundingWallet(address payer) external {
        designated[msg.sender] = payer;
        emit PayerDesignated(msg.sender, payer);
    }

    /// @notice Payer confirms a previously-designated owner→payer pairing.
    ///         Atomic overwrite of any prior `accounts[owner]`.
    function confirmAuth(address owner) external {
        if (designated[owner] != msg.sender) revert NotDesignated();
        _accounts[owner] = Account({payer: msg.sender, active: true});
        emit AccountActivated(owner, msg.sender);
    }

    /// @notice Revoke an account. Callable by the owner or the confirmed payer.
    ///         Only flips `active`; leaves `payer` intact for possible
    ///         re-activation via a later `confirmAuth`.
    function revoke(address owner) external {
        Account storage acct = _accounts[owner];
        if (msg.sender != owner && msg.sender != acct.payer) revert NotAuthorizedToRevoke();
        address payer = acct.payer;
        acct.active = false;
        emit AccountRevoked(owner, payer, msg.sender);
    }

    function getAccount(address owner) external view returns (Account memory) {
        return _accounts[owner];
    }

    // =====================================================================
    // Volume lifecycle  (§7.1)
    // =====================================================================

    function createVolume(
        address chunkSigner,
        uint8 depth,
        uint8 bucketDepth,
        uint64 ttlExpiry,
        bool immutableBatch
    ) external returns (bytes32 volumeId) {
        Account storage acct = _accounts[msg.sender];
        if (!acct.active) revert AccountNotActive();
        if (chunkSigner == address(0)) revert ZeroAddress();

        // Initial per-chunk balance is contract-computed.
        uint256 currentPrice = uint256(postage.lastPrice());
        uint256 perChunk = currentPrice * uint256(graceBlocks);
        uint256 totalCharge = perChunk << depth;

        address payer = acct.payer;

        // Pull BZZ from payer → registry. Both `transferFrom`s and
        // `createBatch` live in the same transaction; any failure reverts
        // atomically and leaves no state change.
        require(bzz.transferFrom(payer, address(this), totalCharge), "BZZ_TRANSFER_FAIL");
        // Approve PostageStamp exactly once per call; leaves no lingering
        // allowance once createBatch consumes it.
        require(bzz.approve(address(postage), totalCharge), "BZZ_APPROVE_FAIL");

        bytes32 nonce = bytes32(nextNonce);
        unchecked {
            ++nextNonce;
        }
        volumeId = postage.createBatch(chunkSigner, perChunk, depth, bucketDepth, nonce, immutableBatch);
        // Sanity — PostageStamp derives the same way, so this equality is
        // mechanical; kept as a defensive assertion against upstream drift.
        require(
            volumeId == keccak256(abi.encode(address(this), nonce)),
            "BATCHID_MISMATCH"
        );

        uint32 idx = uint32(_activeVolumeIds.length);
        _volumes[volumeId] = Volume({
            owner: msg.sender,
            chunkSigner: chunkSigner,
            createdAt: uint64(block.timestamp),
            ttlExpiry: ttlExpiry,
            depth: depth,
            status: STATUS_ACTIVE,
            activeIndex: idx
        });
        _activeVolumeIds.push(volumeId);

        emit VolumeCreated(volumeId, msg.sender, chunkSigner, depth, ttlExpiry);
    }

    function deleteVolume(bytes32 volumeId) external {
        Volume storage v = _volumes[volumeId];
        if (v.owner != msg.sender) revert NotVolumeOwner();
        if (v.status != STATUS_ACTIVE) revert VolumeNotActive();
        _retire(volumeId, REASON_OWNER_DELETED);
    }

    function transferVolumeOwnership(bytes32 volumeId, address newOwner) external {
        Volume storage v = _volumes[volumeId];
        if (v.owner != msg.sender) revert NotVolumeOwner();
        if (v.status != STATUS_ACTIVE) revert VolumeNotActive();
        if (newOwner == address(0)) revert ZeroAddress();
        address prev = v.owner;
        v.owner = newOwner;
        emit VolumeOwnershipTransferred(volumeId, prev, newOwner);
    }

    // =====================================================================
    // Keeper API  (§7.3, §8)
    // =====================================================================

    function trigger(bytes32 volumeId) external {
        _triggerOne(volumeId);
    }

    /// @notice Batched trigger. Per-item try/catch: one bad id never aborts
    ///         the cycle. Reverts from an inner call are swallowed silently
    ///         (the contract itself only ever emits `TopupSkipped` or
    ///         `VolumeRetired` on a successful check — the revert path is
    ///         reserved for malformed input like "volume already retired",
    ///         which is uninteresting in a batched context).
    function trigger(bytes32[] calldata volumeIds) external {
        uint256 n = volumeIds.length;
        for (uint256 i = 0; i < n; ++i) {
            try this._triggerExt(volumeIds[i]) {} catch {}
        }
    }

    /// @dev External entry for try/catch wrapping. Never call directly from
    ///      outside — `trigger(bytes32)` is the public surface.
    function _triggerExt(bytes32 volumeId) external {
        require(msg.sender == address(this), "INTERNAL_ONLY");
        _triggerOne(volumeId);
    }

    /// @notice Retire an Active volume whose TTL has passed. No-op on an
    ///         already-retired volume. Mostly unnecessary; trigger() handles
    ///         this edge too.
    function reap(bytes32 volumeId) external {
        Volume storage v = _volumes[volumeId];
        if (v.status != STATUS_ACTIVE) return; // idempotent
        if (v.ttlExpiry != 0 && block.timestamp >= v.ttlExpiry) {
            _retire(volumeId, REASON_VOLUME_EXPIRED);
        }
    }

    function _triggerOne(bytes32 volumeId) internal {
        Volume storage v = _volumes[volumeId];
        // Step 1 — volume must be Active. Revert (not skip) so malformed
        // single-id calls are loud; batched calls swallow this.
        if (v.status != STATUS_ACTIVE) revert VolumeNotActive();

        // Step 2 — read Postage batch.
        (
            address bOwner,
            uint8 bDepth,
            , // bucketDepth
            , // immutableFlag
            uint256 bNormalisedBalance,

        ) = postage.batches(volumeId);

        uint256 outpayment = postage.currentTotalOutPayment();
        bool batchMissing = (bOwner == address(0));
        bool batchExpired = !batchMissing && (bNormalisedBalance <= outpayment);
        if (batchMissing || batchExpired) {
            _retire(volumeId, REASON_BATCH_DIED);
            return;
        }

        // Step 2b — owner mismatch (defensive; I2).
        if (bOwner != v.chunkSigner) {
            _retire(volumeId, REASON_BATCH_OWNER_MISMATCH);
            return;
        }

        // Step 3 — depth mismatch.
        if (bDepth != v.depth) {
            _retire(volumeId, REASON_DEPTH_CHANGED);
            return;
        }

        // Step 4 — TTL.
        if (v.ttlExpiry != 0 && block.timestamp >= v.ttlExpiry) {
            _retire(volumeId, REASON_VOLUME_EXPIRED);
            return;
        }

        // Step 5 — auth. After this point, every retire-edge has been
        // checked; a revoked account only prevents payment, never retires.
        Account storage acct = _accounts[v.owner];
        if (!acct.active) {
            emit TopupSkipped(volumeId, SKIP_NO_AUTH);
            return;
        }

        // Step 6 — compute deficit. remaining = normalised − outpayment.
        uint256 remaining = bNormalisedBalance - outpayment; // strictly positive (expired caught above)
        uint256 currentPrice = uint256(postage.lastPrice());
        uint256 target = currentPrice * uint256(graceBlocks);
        if (remaining >= target) {
            // I5 idempotence: zero-deficit is a silent no-op.
            return;
        }
        uint256 deficit = target - remaining;
        uint256 amount = deficit << v.depth;

        // Step 7 — pull BZZ. transferFrom failure is not a retire-edge.
        try IERC20Like(address(bzz)).transferFrom(acct.payer, address(this), amount) returns (bool ok) {
            if (!ok) {
                emit TopupSkipped(volumeId, SKIP_PAYMENT_FAILED);
                return;
            }
        } catch {
            emit TopupSkipped(volumeId, SKIP_PAYMENT_FAILED);
            return;
        }

        // Step 8 — approve & topUp. If this reverts (e.g. Postage paused),
        // the whole trigger() reverts; batched callers get try/catch-level
        // isolation. We do NOT swallow it here — a live Postage failure is
        // a contract-level state worth surfacing.
        require(bzz.approve(address(postage), amount), "BZZ_APPROVE_FAIL");
        postage.topUp(volumeId, deficit);

        (, , , , uint256 newBalance, ) = postage.batches(volumeId);
        emit Toppedup(volumeId, amount, newBalance);
    }

    // =====================================================================
    // Views  (§7.4)
    // =====================================================================

    function getVolume(bytes32 volumeId) external view returns (VolumeView memory) {
        Volume storage v = _volumes[volumeId];
        Account storage acct = _accounts[v.owner];
        return VolumeView({
            volumeId: volumeId,
            owner: v.owner,
            payer: acct.payer,
            chunkSigner: v.chunkSigner,
            createdAt: v.createdAt,
            ttlExpiry: v.ttlExpiry,
            depth: v.depth,
            status: v.status,
            accountActive: acct.active
        });
    }

    function getActiveVolumeCount() external view returns (uint256) {
        return _activeVolumeIds.length;
    }

    function getActiveVolumes(uint256 offset, uint256 limit)
        external
        view
        returns (VolumeView[] memory out)
    {
        uint256 n = _activeVolumeIds.length;
        if (offset >= n) return new VolumeView[](0);
        uint256 end = offset + limit;
        if (end > n) end = n;
        uint256 len = end - offset;
        out = new VolumeView[](len);
        for (uint256 i = 0; i < len; ++i) {
            bytes32 id = _activeVolumeIds[offset + i];
            Volume storage v = _volumes[id];
            Account storage acct = _accounts[v.owner];
            out[i] = VolumeView({
                volumeId: id,
                owner: v.owner,
                payer: acct.payer,
                chunkSigner: v.chunkSigner,
                createdAt: v.createdAt,
                ttlExpiry: v.ttlExpiry,
                depth: v.depth,
                status: v.status,
                accountActive: acct.active
            });
        }
    }

    // =====================================================================
    // Internals
    // =====================================================================

    function _retire(bytes32 volumeId, uint8 reason) internal {
        Volume storage v = _volumes[volumeId];
        v.status = STATUS_RETIRED;

        // swap-and-pop active list
        uint32 idx = v.activeIndex;
        uint256 last = _activeVolumeIds.length - 1;
        if (uint256(idx) != last) {
            bytes32 lastId = _activeVolumeIds[last];
            _activeVolumeIds[idx] = lastId;
            _volumes[lastId].activeIndex = idx;
        }
        _activeVolumeIds.pop();
        v.activeIndex = 0;

        emit VolumeRetired(volumeId, reason);
    }
}
