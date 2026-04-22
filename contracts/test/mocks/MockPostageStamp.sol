// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @dev Test double that mimics the subset of PostageStamp used by
/// `SubscriptionRegistry`. State is directly settable so tests can
/// construct exact scenarios.
contract MockPostageStamp {
    struct Batch {
        address owner;
        uint8 depth;
        uint8 bucketDepth;
        bool immutableFlag;
        uint256 normalisedBalance;
        uint256 lastUpdatedBlockNumber;
    }

    mapping(bytes32 => Batch) public batches;
    uint64 public lastPrice;
    uint256 public currentTotalOutPayment;
    IERC20 public immutable bzz;

    bool public failTopUp; // forces topUp to revert, for test scenarios

    constructor(IERC20 _bzz) {
        bzz = _bzz;
    }

    function setPrice(uint64 p) external {
        lastPrice = p;
    }

    function setCurrentTotalOutPayment(uint256 v) external {
        currentTotalOutPayment = v;
    }

    function setFailTopUp(bool v) external {
        failTopUp = v;
    }

    function createBatch(bytes32 id, address owner_, uint8 depth, uint256 normBal) external {
        batches[id] = Batch({
            owner: owner_,
            depth: depth,
            bucketDepth: 16,
            immutableFlag: false,
            normalisedBalance: normBal,
            lastUpdatedBlockNumber: block.number
        });
    }

    function deleteBatch(bytes32 id) external {
        delete batches[id];
    }

    function topUp(bytes32 id, uint256 perChunk) external {
        require(!failTopUp, "mock: topUp forced revert");
        Batch storage b = batches[id];
        require(b.owner != address(0), "mock: no batch");
        uint256 total = perChunk << b.depth;
        require(bzz.transferFrom(msg.sender, address(this), total), "mock: xfer");
        b.normalisedBalance += perChunk;
    }
}
