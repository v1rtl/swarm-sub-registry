// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SubscriptionRegistry} from "../src/SubscriptionRegistry.sol";
import {IPostageStamp} from "../src/interfaces/IPostageStamp.sol";

contract SubscriptionRegistryForkTest is Test {
    // Sepolia testnet addresses
    address internal constant BZZ =
        0x543dDb01Ba47acB11de34891cD86B675F04840db;
    address internal constant STAMP =
        0xcdfdC3752caaA826fE62531E0000C40546eC56A6;

    // Our live batch from earlier in this session
    bytes32 internal constant LIVE_BATCH =
        0x26927168d9dafee1c41a0044e0f8baded0f4c11bec994936ff9bc0da85823179;

    SubscriptionRegistry internal reg;
    address internal payer;

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            console2.log("SKIP: SEPOLIA_RPC_URL not set");
            vm.skip(true);
        }
        vm.createSelectFork(rpc);

        reg = new SubscriptionRegistry(IERC20(BZZ), IPostageStamp(STAMP));

        // Create a fresh funded payer account via deal + impersonation
        payer = makeAddr("fork_payer");
        deal(BZZ, payer, 10e16); // 10 BZZ (16 decimals)

        // Note: we cannot use vm.prank(address(reg)) here because
        // the registry is not an冰淇淋ve EOA.
        // Instead we approve directly on the real BZZ contract.
        vm.prank(payer);
        IERC20(BZZ).approve(address(reg), type(uint256).max);
    }

    /// @notice Subscribes and then forces the batch to become due by advancing
    /// blocks, then calls keepalive and verifies the batch was topped up.
    function test_Fork_KeepaliveTopsUpLiveBatch() public {
        // Subscribe payer to the live batch
        vm.prank(payer);
        reg.subscribe(LIVE_BATCH, 17280);

        // Get initial normalisedBalance
        (,,,, uint256 beforeNorm, ) = IPostageStamp(STAMP).batches(LIVE_BATCH);
        console2.log(" normalisedBalance before:", beforeNorm);

        // The batch is NOT due yet (we just topped it up in this session).
        // Advance blocks until it becomes due.
        // Threshold = price * 17280.
        // Remaining = normalisedBalance - currentTotalOutPayment.
        // Becomes due when currentTotalOutPayment > normalisedBalance - threshold.
        uint64 price = IPostageStamp(STAMP).lastPrice();
        uint256 cto = IPostageStamp(STAMP).currentTotalOutPayment();
        uint256 threshold = uint256(price) * 17280;
        uint256 remaining = beforeNorm > cto ? beforeNorm - cto : 0;

        if (remaining >= threshold) {
            // Not due yet, need to advance blocks
            uint256 blocksNeeded = (remaining - threshold) / price + 1;
            console2.log(" advancing blocks:", blocksNeeded);
            vm.roll(block.number + blocksNeeded);
        }

        // Verify batch is now due
        assertTrue(reg.isDue(LIVE_BATCH), "batch should be due");

        // Record payer BZZ balance before
        uint256 payerBefore = IERC20(BZZ).balanceOf(payer);
        console2.log(" payer BZZ before:", payerBefore);

        // Execute keepalive
        reg.keepalive();

        // Verify batch normalisedBalance increased
        (,,,, uint256 afterNorm, ) = IPostageStamp(STAMP).batches(LIVE_BATCH);
        console2.log(" normalisedBalance after:", afterNorm);

        assertGt(afterNorm, beforeNorm, "normalisedBalance should increase");

        // Verify payer BZZ decreased
        uint256 payerAfter = IERC20(BZZ).balanceOf(payer);
        console2.log(" payer BZZ after:", payerAfter);
        assertLt(payerAfter, payerBefore, "payer should have spent BZZ");
    }

    /// @notice Verify the registry can read live state from Sepolia.
    function test_Fork_EstimatedTopUp_MatchesLivePrice() public {
        vm.prank(payer);
        reg.subscribe(LIVE_BATCH, 17280);

        (uint256 perChunk, uint256 total) = reg.estimatedTopUp(LIVE_BATCH);
        uint256 price = IPostageStamp(STAMP).lastPrice();
        uint256 expected = uint256(price) * 17280;

        console2.log(" price:", price);
        console2.log(" expected perChunk:", expected);
        console2.log(" actual perChunk:", perChunk);

        assertEq(perChunk, expected);
        assertGt(total, 0);
    }
}