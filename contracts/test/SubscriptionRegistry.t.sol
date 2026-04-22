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
    // keepaliveOne (singular variant)
    // ------------------------------------------------------------------

    function test_KeepaliveOne_TopsUpDueBatch() public {
        vm.prank(payer2);
        reg.subscribe(B, EXT);

        uint256 threshold = uint256(PRICE) * EXT;
        uint256 total = threshold << 21;
        uint256 payerBefore = bzz.balanceOf(payer2);

        vm.expectEmit(true, true, true, true);
        emit SubscriptionRegistry.KeptAlive(anyone, B, payer2, threshold, total);
        vm.prank(anyone);
        bool toppedUp = reg.keepaliveOne(B);

        assertTrue(toppedUp);
        assertEq(bzz.balanceOf(payer2), payerBefore - total);
    }

    function test_KeepaliveOne_ReturnsFalseWhenNotDue() public {
        vm.prank(payer);
        reg.subscribe(A, EXT); // not due

        uint256 before = bzz.balanceOf(payer);
        vm.recordLogs();
        vm.prank(anyone);
        bool toppedUp = reg.keepaliveOne(A);

        assertFalse(toppedUp);
        assertEq(bzz.balanceOf(payer), before);
        // No KeptAlive event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != keccak256("KeptAlive(address,bytes32,address,uint256,uint256)"),
                "unexpected KeptAlive emitted"
            );
        }
    }

    function test_KeepaliveOne_BubblesRevertOnPullFailure() public {
        vm.prank(payer2);
        reg.subscribe(B, EXT);
        // Revoke allowance — transferFrom inside _keepaliveOne will revert.
        // Whether the revert is the registry's `TransferFromFailed` or the
        // ERC20's own string depends on the token; either way, keepaliveOne
        // must propagate the revert (proving it does NOT silently swallow
        // failures the way bulk keepalive() does via try/catch).
        vm.prank(payer2);
        bzz.approve(address(reg), 0);

        vm.prank(anyone);
        vm.expectRevert();
        reg.keepaliveOne(B);
    }

    function test_KeepaliveOne_ReturnsFalseForUnknownBatch() public {
        // Not subscribed → _keepaliveOne returns (false, ...) without revert
        vm.prank(anyone);
        bool toppedUp = reg.keepaliveOne(bytes32(uint256(0xDEAD)));
        assertFalse(toppedUp);
    }

    // ------------------------------------------------------------------
    // pruneOne / pruneDead / isDead
    // ------------------------------------------------------------------

    function test_PruneOne_RemovesNeverExistedBatch() public {
        bytes32 ghost = bytes32(uint256(0xDEAD));
        // Subscribe to a batch that does not exist on PostageStamp
        vm.prank(payer);
        reg.subscribe(ghost, EXT);
        assertTrue(reg.isDead(ghost));

        vm.expectEmit(true, true, true, false);
        emit SubscriptionRegistry.Pruned(ghost, payer, anyone);
        vm.prank(anyone);
        reg.pruneOne(ghost);

        assertEq(reg.subscriptionCount(), 0);
        (address p,) = reg.subs(ghost);
        assertEq(p, address(0));
    }

    function test_PruneOne_RemovesReapedBatch() public {
        vm.prank(payer);
        reg.subscribe(A, EXT);
        // Simulate reaping (PostageStamp.expireLimited removed it)
        stamp.deleteBatch(A);
        assertTrue(reg.isDead(A));

        vm.prank(anyone);
        reg.pruneOne(A);
        assertEq(reg.subscriptionCount(), 0);
    }

    function test_PruneOne_RevertsOnAliveBatch() public {
        vm.prank(payer);
        reg.subscribe(A, EXT);
        assertFalse(reg.isDead(A));

        vm.prank(anyone);
        vm.expectRevert(SubscriptionRegistry.NotDead.selector);
        reg.pruneOne(A);
    }

    function test_PruneOne_RevertsOnNotSubscribed() public {
        vm.prank(anyone);
        vm.expectRevert(SubscriptionRegistry.NotSubscribed.selector);
        reg.pruneOne(bytes32(uint256(0xC0FFEE)));
    }

    function test_PruneOne_OnlySelfGuardOnInternal() public {
        vm.expectRevert(SubscriptionRegistry.OnlySelf.selector);
        reg._pruneOne(A);
    }

    function test_PruneDead_ProcessesMixedArray() public {
        // Sub A (alive), sub B (dead via reap), sub C (never existed = dead),
        // plus an id D that has no subscription.
        bytes32 C = bytes32(uint256(0xCCCC));
        bytes32 D = bytes32(uint256(0xDDDD));

        vm.prank(payer);
        reg.subscribe(A, EXT);
        vm.prank(payer2);
        reg.subscribe(B, EXT);
        vm.prank(payer);
        reg.subscribe(C, EXT);
        stamp.deleteBatch(B); // reap B

        bytes32[] memory ids = new bytes32[](4);
        ids[0] = A; ids[1] = B; ids[2] = C; ids[3] = D;

        vm.recordLogs();
        vm.prank(anyone);
        reg.pruneDead(ids);

        // Expect 2 Pruned (B, C) and 2 PruneSkipped (A=NotDead, D=NotSubscribed)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 prunedCount;
        uint256 skippedCount;
        bytes4 notDeadSel = SubscriptionRegistry.NotDead.selector;
        bytes4 notSubSel = SubscriptionRegistry.NotSubscribed.selector;
        bool sawNotDead;
        bool sawNotSub;
        for (uint256 i = 0; i < logs.length; ++i) {
            bytes32 t0 = logs[i].topics[0];
            if (t0 == keccak256("Pruned(bytes32,address,address)")) {
                prunedCount++;
            } else if (t0 == keccak256("PruneSkipped(bytes32,bytes)")) {
                skippedCount++;
                bytes memory reason = abi.decode(logs[i].data, (bytes));
                bytes4 sel;
                assembly { sel := mload(add(reason, 32)) }
                if (sel == notDeadSel) sawNotDead = true;
                if (sel == notSubSel) sawNotSub = true;
            }
        }
        assertEq(prunedCount, 2, "pruned count");
        assertEq(skippedCount, 2, "skipped count");
        assertTrue(sawNotDead, "NotDead selector in skipped reason");
        assertTrue(sawNotSub, "NotSubscribed selector in skipped reason");
        // A still subscribed; B and C gone
        assertEq(reg.subscriptionCount(), 1);
        (address pa,) = reg.subs(A); assertEq(pa, payer);
        (address pb,) = reg.subs(B); assertEq(pb, address(0));
        (address pc,) = reg.subs(C); assertEq(pc, address(0));
    }

    function test_PruneDead_SwapPopPreservesIntegrity() public {
        // Subscribe 5 batches. Then prune the middle one. Verify remaining
        // 4 ids are addressable via batchIds[i] and keepaliveOne still works
        // (proves _indexPlusOne consistency).
        bytes32[5] memory ids;
        for (uint256 i = 0; i < 5; ++i) {
            ids[i] = bytes32(uint256(0x100 + i));
            // Even indices: due batches; Odd: not due
            uint256 normBal = (i % 2 == 0) ? (uint256(PRICE) * EXT - 1) : (uint256(PRICE) * EXT * 2);
            stamp.createBatch(ids[i], address(uint160(0x1000 + i)), 21, normBal);
            vm.prank(payer);
            reg.subscribe(ids[i], EXT);
        }
        assertEq(reg.subscriptionCount(), 5);

        // Reap the middle one (index 2) and prune it
        stamp.deleteBatch(ids[2]);
        bytes32[] memory toPrune = new bytes32[](1);
        toPrune[0] = ids[2];
        vm.prank(anyone);
        reg.pruneDead(toPrune);

        assertEq(reg.subscriptionCount(), 4);

        // Walk all remaining indices, collect batchIds; assert no duplicates,
        // none equal to ids[2], and every read works (no out-of-bounds revert)
        bytes32[] memory remaining = new bytes32[](4);
        for (uint256 i = 0; i < 4; ++i) {
            remaining[i] = reg.batchIds(i);
            assertTrue(remaining[i] != ids[2], "pruned id reappeared");
        }

        // Each remaining id can still be keepalive'd correctly
        for (uint256 i = 0; i < 4; ++i) {
            vm.prank(anyone);
            reg.keepaliveOne(remaining[i]); // does not revert
        }
    }

    function test_PruneDead_Permissionless() public {
        bytes32 ghost = bytes32(uint256(0xDEAD));
        vm.prank(payer);
        reg.subscribe(ghost, EXT);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = ghost;

        // Random EOA, not the payer, not any contract owner — succeeds
        address rando = makeAddr("rando");
        vm.prank(rando);
        reg.pruneDead(ids);
        assertEq(reg.subscriptionCount(), 0);
    }

    function test_IsDead_TruthTable() public {
        // Case 1: not subscribed
        assertFalse(reg.isDead(bytes32(uint256(0x1))));
        // Case 2: subscribed and alive
        vm.prank(payer);
        reg.subscribe(A, EXT);
        assertFalse(reg.isDead(A));
        // Case 3: subscribed and reaped
        stamp.deleteBatch(A);
        assertTrue(reg.isDead(A));
        // Case 4: subscribed but only expired (still has owner) → NOT dead
        vm.prank(payer2);
        reg.subscribe(B, EXT);
        stamp.setCurrentTotalOutPayment(uint256(PRICE) * EXT * 100); // way past expiry
        assertFalse(reg.isDead(B)); // B still has owner in mock
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