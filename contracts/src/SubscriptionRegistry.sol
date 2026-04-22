// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPostageStamp} from "./interfaces/IPostageStamp.sol";

/// @title SubscriptionRegistry
/// @notice Permissionless keepalive service for Swarm postage stamp batches.
///
/// Each subscription stores a payer and a desired per-cycle extension length
/// measured in **blocks** (not seconds). Any caller may invoke `keepalive()`,
/// which iterates all subscriptions and tops up batches whose remaining
/// per-chunk balance has dropped below one full extension period
/// (`extensionBlocks * lastPrice`). BZZ is pulled from each payer via
/// `transferFrom` using the allowance they granted to this contract; the
/// contract then calls `PostageStamp.topUp`.
///
/// SECURITY:
/// - No drain risk: the "remaining < threshold" check ensures each batch
///   is topped up at most once per extension cycle.
/// - No oracle risk: `lastPrice` and `currentTotalOutPayment` are read once per
///   transaction; a single tx cannot span an oracle update.
///
/// Block-time reminder (caller must pick `extensionBlocks` for the target chain):
///   - Gnosis Chain (~5 s/block):  24h ≈ 17280 blocks
///   - Sepolia      (~12 s/block): 24h ≈ 7200  blocks
contract SubscriptionRegistry {
    struct Subscription {
        address payer;
        uint32 extensionBlocks;
    }

    IERC20 public immutable bzz;
    IPostageStamp public immutable stamp;

    mapping(bytes32 => Subscription) public subs;
    bytes32[] public batchIds;
    mapping(bytes32 => uint256) private _indexPlusOne; // 0 means absent

    uint256 private _locked = 1;

    event Subscribed(bytes32 indexed batchId, address indexed payer, uint32 extensionBlocks);
    event ExtensionUpdated(bytes32 indexed batchId, uint32 extensionBlocks);
    event Unsubscribed(bytes32 indexed batchId, address indexed payer);
    event KeptAlive(
        address indexed caller,
        bytes32 indexed batchId,
        address indexed payer,
        uint256 topUpPerChunk,
        uint256 totalAmount
    );
    event KeepaliveSkipped(bytes32 indexed batchId, bytes reason);

    error AlreadySubscribed();
    error NotSubscribed();
    error NotPayer();
    error ZeroExtension();
    error Reentrancy();
    error TransferFromFailed();
    error OnlySelf();

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(IERC20 _bzz, IPostageStamp _stamp) {
        bzz = _bzz;
        stamp = _stamp;
        // One-time unlimited approval so `stamp.topUp` can spend the BZZ
        // we pulled from the payer without a per-call `approve`.
        _bzz.approve(address(_stamp), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Subscription management (payer-driven)
    // ------------------------------------------------------------------

    /// @notice Register `msg.sender` as the payer for `batchId`.
    /// @param batchId          Postage stamp batch id to keep alive.
    /// @param extensionBlocks  Blocks of TTL to add per keepalive cycle.
    ///                         Must be > 0. Also acts as the "low-water"
    ///                         threshold at which a keepalive becomes due.
    function subscribe(bytes32 batchId, uint32 extensionBlocks) external {
        if (extensionBlocks == 0) revert ZeroExtension();
        if (subs[batchId].payer != address(0)) revert AlreadySubscribed();

        subs[batchId] = Subscription({payer: msg.sender, extensionBlocks: extensionBlocks});
        batchIds.push(batchId);
        _indexPlusOne[batchId] = batchIds.length;

        emit Subscribed(batchId, msg.sender, extensionBlocks);
    }

    /// @notice Change the extension length for an existing subscription.
    function updateExtension(bytes32 batchId, uint32 newExtensionBlocks) external {
        if (newExtensionBlocks == 0) revert ZeroExtension();
        Subscription storage s = subs[batchId];
        if (s.payer == address(0)) revert NotSubscribed();
        if (s.payer != msg.sender) revert NotPayer();
        s.extensionBlocks = newExtensionBlocks;
        emit ExtensionUpdated(batchId, newExtensionBlocks);
    }

    /// @notice Cancel a subscription. O(1) swap-and-pop.
    function unsubscribe(bytes32 batchId) external {
        Subscription memory s = subs[batchId];
        if (s.payer == address(0)) revert NotSubscribed();
        if (s.payer != msg.sender) revert NotPayer();

        uint256 idx = _indexPlusOne[batchId] - 1;
        uint256 last = batchIds.length - 1;
        if (idx != last) {
            bytes32 lastId = batchIds[last];
            batchIds[idx] = lastId;
            _indexPlusOne[lastId] = idx + 1;
        }
        batchIds.pop();
        delete _indexPlusOne[batchId];
        delete subs[batchId];

        emit Unsubscribed(batchId, s.payer);
    }

    // ------------------------------------------------------------------
    // Keepalive
    // ------------------------------------------------------------------

    /// @notice Iterate all subscriptions and top up any batch whose
    /// remaining per-chunk balance has dropped below `extensionBlocks * lastPrice`.
    /// Permissionless; any caller may invoke.
    function keepalive() external nonReentrant {
        uint64 price = stamp.lastPrice();
        uint256 cto = stamp.currentTotalOutPayment();
        uint256 n = batchIds.length;
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = batchIds[i];
            try this._keepaliveOne(id, price, cto) returns (
                bool toppedUp, address payer, uint256 perChunk, uint256 total
            ) {
                if (toppedUp) emit KeptAlive(msg.sender, id, payer, perChunk, total);
            } catch (bytes memory err) {
                emit KeepaliveSkipped(id, err);
            }
        }
    }

    /// @dev External only so `try/catch` in `keepalive()` can isolate per-batch
    /// failures. Restricted to self-calls.
    function _keepaliveOne(bytes32 id, uint64 price, uint256 cto)
        external
        returns (bool toppedUp, address payer, uint256 perChunk, uint256 total)
    {
        if (msg.sender != address(this)) revert OnlySelf();

        Subscription memory s = subs[id];
        if (s.payer == address(0)) return (false, address(0), 0, 0);
        if (price == 0) return (false, s.payer, 0, 0);

        (address owner_, uint8 depth,,, uint256 normBal,) = stamp.batches(id);
        if (owner_ == address(0)) return (false, s.payer, 0, 0); // batch missing
        if (normBal <= cto) return (false, s.payer, 0, 0); // expired

        uint256 remainingPerChunk = normBal - cto;
        uint256 threshold = uint256(price) * uint256(s.extensionBlocks);
        if (remainingPerChunk >= threshold) return (false, s.payer, 0, 0);

        uint256 t = threshold << depth; // threshold * 2^depth
        if (!bzz.transferFrom(s.payer, address(this), t)) revert TransferFromFailed();
        stamp.topUp(id, threshold);

        return (true, s.payer, threshold, t);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function subscriptionCount() external view returns (uint256) {
        return batchIds.length;
    }

    /// @notice Convenience: would `keepalive()` top up this batch right now?
    function isDue(bytes32 id) external view returns (bool) {
        Subscription memory s = subs[id];
        if (s.payer == address(0)) return false;
        uint64 price = stamp.lastPrice();
        if (price == 0) return false;
        (address owner_,,,, uint256 normBal,) = stamp.batches(id);
        if (owner_ == address(0)) return false;
        uint256 cto = stamp.currentTotalOutPayment();
        if (normBal <= cto) return false;
        return (normBal - cto) < uint256(price) * uint256(s.extensionBlocks);
    }

    /// @notice Estimated per-chunk and total BZZ required for the next top-up.
    function estimatedTopUp(bytes32 id) external view returns (uint256 perChunk, uint256 total) {
        Subscription memory s = subs[id];
        if (s.payer == address(0)) return (0, 0);
        uint64 price = stamp.lastPrice();
        (, uint8 depth,,,,) = stamp.batches(id);
        perChunk = uint256(price) * uint256(s.extensionBlocks);
        total = perChunk << depth;
    }
}
