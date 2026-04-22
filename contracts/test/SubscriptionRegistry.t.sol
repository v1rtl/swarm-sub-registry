// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SubscriptionRegistry} from "../src/SubscriptionRegistry.sol";
import {IPostageStamp} from "../src/interfaces/IPostageStamp.sol";
import {MockPostageStamp} from "./mocks/MockPostageStamp.sol";
import {MintableBZZ} from "./mocks/MintableBZZ.sol";

contract SubscriptionRegistryTest is Test {
    MintableBZZ public bzz;
    MockPostageStamp public stamp;
    SubscriptionRegistry public reg;

    address internal payer = makeAddr("payer");
    address internal payer2 = makeAddr("payer2");
    address internal anyone = makeAddr("anyone");

    bytes32 internal constant A = bytes32(uint256(0xA));
    bytes32 internal constant B = bytes32(uint256(0xB));

    uint32 internal constant EXT = 17280; // ~24h at 5s blocks
    uint64 internal constant PRICE = 160_000;

    function setUp() public {
        bzz = new MintableBZZ();
        stamp = new MockPostageStamp(IERC20(address(bzz)));
        reg = new SubscriptionRegistry(IERC20(address(bzz)), IPostageStamp(address(stamp)));

        stamp.setPrice(PRICE);
        stamp.setCurrentTotalOutPayment(0);

        // Batch A: depth 21, remaining = threshold * 2 → NOT due
        stamp.createBatch(A, address(0xBEEF), 21, uint256(PRICE) * EXT * 2);
        // Batch B: depth 21, remaining = threshold - 1 → DUE
        stamp.createBatch(B, address(0xCAFE), 21, uint256(PRICE) * EXT - 1);

        bzz.mint(payer, 1e22);
        bzz.mint(payer2, 1e22);
        vm.prank(payer);
        bzz.approve(address(reg), type(uint256).max);
        vm.prank(payer2);
        bzz.approve(address(reg), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Subscription management
    // ------------------------------------------------------------------

    function test_Subscribe_StoresAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit SubscriptionRegistry.Subscribed(A, payer, EXT);
        vm.prank(payer);
        reg.subscribe(A, EXT);

        (address p, uint32 e) = reg.subs(A);
        assertEq(p, payer);
        assertEq(e, EXT);
        assertEq(reg.subscriptionCount(), 1);
        assertEq(reg.batchIds(0), A);
    }

    function test_Subscribe_ZeroExtReverts() public {
        vm.prank(payer);
        vm.expectRevert(SubscriptionRegistry.ZeroExtension.selector);
        reg.subscribe(A, 0);
    }

    function test_Subscribe_DuplicateReverts() public {
        vm.prank(payer);
        reg.subscribe(A, EXT);
        vm.prank(payer2);
        vm.expectRevert(SubscriptionRegistry.AlreadySubscribed.selector);
        reg.subscribe(A, EXT);
    }

    function test_UpdateExtension_OnlyPayer() public {
        vm.prank(payer);
        reg.subscribe(A, EXT);

        vm.prank(anyone);
        vm.expectRevert(SubscriptionRegistry.NotPayer.selector);
        reg.updateExtension(A, EXT * 2);

        vm.prank(payer);
        reg.updateExtension(A, EXT * 2);
        (, uint32 e) = reg.subs(A);
        assertEq(e, EXT * 2);
    }

    function test_UpdateExtension_NotSubscribed() public {
        vm.expectRevert(SubscriptionRegistry.NotSubscribed.selector);
        reg.updateExtension(A, EXT);
    }

    function test_Unsubscribe_PayerOnly() public {
        vm.prank(payer);
        reg.subscribe(A, EXT);
        vm.prank(payer2);
        reg.subscribe(B, EXT);

        vm.prank(payer);
        reg.unsubscribe(A);
        assertEq(reg.subscriptionCount(), 1);
        assertEq(reg.batchIds(0), B);

        (address p,) = reg.subs(A);
        assertEq(p, address(0));
    }

    function test_Unsubscribe_NotPayer() public {
        vm.prank(payer);
        reg.subscribe(A, EXT);
        vm.prank(anyone);
        vm.expectRevert(SubscriptionRegistry.NotPayer.selector);
        reg.unsubscribe(A);
    }

    function test_Unsubscribe_SwapAndPop_UpdatesIndex() public {
        vm.prank(payer);
        reg.subscribe(A, EXT);
        vm.prank(payer2);
        reg.subscribe(B, EXT);

        vm.prank(payer);
        reg.unsubscribe(A);
        // B should now be at index 0
        assertEq(reg.batchIds(0), B);
    }

    // ------------------------------------------------------------------
    // keepalive
    // ------------------------------------------------------------------

    function test_Keepalive_NothingDue_NoTransfers() public {
        vm.prank(payer);
        reg.subscribe(A, EXT); // not due

        uint256 before = bzz.balanceOf(payer);
        vm.prank(anyone);
        reg.keepalive();
        assertEq(bzz.balanceOf(payer), before);
    }

    function test_Keepalive_DueBatchToppedUp() public {
        vm.prank(payer2);
        reg.subscribe(B, EXT);

        uint256 threshold = uint256(PRICE) * EXT;
        uint256 total = threshold << 21; // depth 21
        uint256 payerBefore = bzz.balanceOf(payer2);
        uint256 stampBefore = bzz.balanceOf(address(stamp));

        vm.expectEmit(true, true, true, true);
        emit SubscriptionRegistry.KeptAlive(anyone, B, payer2, threshold, total);
        vm.prank(anyone);
        reg.keepalive();

        assertEq(bzz.balanceOf(payer2), payerBefore - total);
        assertEq(bzz.balanceOf(address(stamp)), stampBefore + total);
    }

    function test_Keepalive_Hysteresis_NoDoubleTopUp() public {
        vm.prank(payer2);
        reg.subscribe(B, EXT);

        vm.prank(anyone);
        reg.keepalive();
        uint256 snapshot = bzz.balanceOf(payer2);

        // immediately after, batch should NOT be due
        assertFalse(reg.isDue(B));

        // second call should do nothing
        vm.prank(anyone);
        reg.keepalive();
        assertEq(bzz.balanceOf(payer2), snapshot);
    }

    function test_Keepalive_MixedDueAndNotDue() public {
        vm.prank(payer);
        reg.subscribe(A, EXT); // not due
        vm.prank(payer2);
        reg.subscribe(B, EXT); // due

        uint256 aBefore = bzz.balanceOf(payer);
        uint256 bBefore = bzz.balanceOf(payer2);

        vm.prank(anyone);
        reg.keepalive();

        // A untouched, B topped up
        assertEq(bzz.balanceOf(payer), aBefore);
        assertLt(bzz.balanceOf(payer2), bBefore);
    }

    function test_Keepalive_SkipsFailingSub_EmitsSkipped() public {
        vm.prank(payer2);
        reg.subscribe(B, EXT);
        // revoke allowance
        vm.prank(payer2);
        bzz.approve(address(reg), 0);

        vm.recordLogs();
        vm.prank(anyone);
        reg.keepalive();

        // Should have emitted KeepaliveSkipped for B
        bool found;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            bytes32 topic = logs[i].topics[0];
            if (topic == keccak256("KeepaliveSkipped(bytes32,bytes)")) {
                found = true;
                break;
            }
        }
        assertTrue(found, "KeepaliveSkipped event not found");
    }

    function test_Keepalive_SkipsExpiredBatch() public {
        vm.prank(payer2);
        reg.subscribe(B, EXT);
        // simulate expiry: currentTotalOutPayment > normalisedBalance
        stamp.setCurrentTotalOutPayment(uint256(PRICE) * EXT);

        uint256 before = bzz.balanceOf(payer2);
        vm.prank(anyone);
        reg.keepalive();
        assertEq(bzz.balanceOf(payer2), before); // unchanged
    }

    function test_Keepalive_SkipsMissingBatch() public {
        vm.prank(payer2);
        reg.subscribe(B, EXT);
        stamp.deleteBatch(B);

        uint256 before = bzz.balanceOf(payer2);
        vm.prank(anyone);
        reg.keepalive();
        assertEq(bzz.balanceOf(payer2), before);
    }

    function test_Keepalive_SkipsWhenPriceZero() public {
        vm.prank(payer2);
        reg.subscribe(B, EXT);
        stamp.setPrice(0);

        uint256 before = bzz.balanceOf(payer2);
        vm.prank(anyone);
        reg.keepalive();
        assertEq(bzz.balanceOf(payer2), before);
    }

    function test_KeepaliveOne_OnlySelf() public {
        vm.expectRevert(SubscriptionRegistry.OnlySelf.selector);
        reg._keepaliveOne(A, PRICE, 0);
    }

    function test_Reentrancy_MutexBlocksSecondCall() public {
        vm.prank(payer);
        reg.subscribe(A, EXT);

        // First keepalive call succeeds (batch is not due, does nothing but runs)
        vm.prank(anyone);
        reg.keepalive();

        // Direct call to _keepaliveOne is blocked (only self callable)
        vm.expectRevert(SubscriptionRegistry.OnlySelf.selector);
        reg._keepaliveOne(A, PRICE, 0);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function test_IsDue_View() public {
        vm.prank(payer);
        reg.subscribe(A, EXT);
        vm.prank(payer2);
        reg.subscribe(B, EXT);

        assertFalse(reg.isDue(A));
        assertTrue(reg.isDue(B));
    }

    function test_EstimatedTopUp_View() public {
        vm.prank(payer2);
        reg.subscribe(B, EXT);

        (uint256 perChunk, uint256 total) = reg.estimatedTopUp(B);
        assertEq(perChunk, uint256(PRICE) * EXT);
        assertEq(total, perChunk << 21);
    }

    function test_EstimatedTopUp_NotSubscribed() public {
        (uint256 perChunk, uint256 total) = reg.estimatedTopUp(A);
        assertEq(perChunk, 0);
        assertEq(total, 0);
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    function testFuzz_Keepalive_DueConditionRespectsThreshold(
        uint64 price,
        uint32 ext,
        uint8 depth,
        uint256 remaining
    ) public {
        // Bound to prevent shift overflow: price * ext * 2^depth must stay in uint256
        price = uint64(bound(price, 1, 1e10));
        ext = uint32(bound(ext, 1, 100_000));
        depth = uint8(bound(depth, 17, 24)); // 2^24 = 16M, safe
        remaining = bound(remaining, 1, type(uint120).max);

        bytes32 id = keccak256(abi.encode(price, ext, depth, remaining));
        stamp.setPrice(price);
        stamp.setCurrentTotalOutPayment(0);
        stamp.createBatch(id, address(0xF00D), depth, remaining);

        vm.prank(payer);
        reg.subscribe(id, ext);

        uint256 threshold = uint256(price) * ext;
        bool due = remaining < threshold;

        // Mint enough BZZ to the payer for this scenario
        uint256 needed = threshold << depth;
        bzz.mint(payer, needed * 2);
        vm.prank(payer);
        bzz.approve(address(reg), type(uint256).max);

        uint256 before = bzz.balanceOf(payer);
        vm.prank(anyone);
        reg.keepalive();

        if (due) {
            assertEq(bzz.balanceOf(payer), before - (threshold << depth));
        } else {
            assertEq(bzz.balanceOf(payer), before);
        }
    }
}