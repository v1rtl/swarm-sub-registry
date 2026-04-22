// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IPostageStamp
/// @notice Minimal surface of Swarm's PostageStamp contract used by
/// `SubscriptionRegistry`.
/// @dev Matches the ABI of
/// https://github.com/ethersphere/storage-incentives/blob/master/src/PostageStamp.sol
interface IPostageStamp {
    function batches(bytes32 batchId)
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

    function lastPrice() external view returns (uint64);

    function currentTotalOutPayment() external view returns (uint256);

    function topUp(bytes32 batchId, uint256 topupAmountPerChunk) external;
}
