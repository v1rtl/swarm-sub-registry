// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {RegistryFixture} from "./fixtures/RegistryFixture.sol";
import {VolumeRegistry} from "../src/VolumeRegistry.sol";

/// @notice TEST-PLAN §3.4 — Trigger semantics (DESIGN §8).
///
/// Check-order is load-bearing: batch-dead → batch-owner-mismatch → depth
/// → TTL → auth → payment. Ordering tests below pin this.
contract TriggerSemanticsTest is RegistryFixture {
    event Toppedup(bytes32 indexed volumeId, uint256 amount, uint256 newNormalisedBalance);
    event TopupSkipped(bytes32 indexed volumeId, uint8 reason);
    event VolumeRetired(bytes32 indexed volumeId, uint8 reason);

    uint64 internal constant FUND_MULT = 20;

    function _setupActiveVolume() internal returns (bytes32 id) {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * FUND_MULT);
        id = _createDefaultVolume(OWNER, CHUNK_SIGNER);
    }

    // -------- happy-path & idempotence ---------------------------------

    function test_trigger_happyTopup() public {
        bytes32 id = _setupActiveVolume();

        // Roll a few blocks so batch drains below target.
        _roll(5);

        uint256 price = uint256(stamp.lastPrice());
        uint256 target = price * GRACE_BLOCKS;
        (, , , , uint256 nb, ) = stamp.batches(id);
        uint256 outpay = stamp.currentTotalOutPayment();
        uint256 remaining = nb - outpay;
        uint256 deficit = target - remaining;
        uint256 expected = deficit << DEFAULT_DEPTH;

        uint256 balBefore = bzz.balanceOf(PAYER);

        // Accept any newNormalisedBalance value in the event.
        vm.expectEmit(true, true, true, false);
        emit Toppedup(id, expected, 0);
        registry.trigger(id);

        assertEq(bzz.balanceOf(PAYER), balBefore - expected, "charge matches formula");

        // Volume still active.
        assertEq(registry.getVolume(id).status, 1);
    }

    function test_trigger_zeroDeficit_noop() public {
        bytes32 id = _setupActiveVolume();
        // Fresh volume: remaining per-chunk == target exactly. No deficit.
        uint256 balBefore = bzz.balanceOf(PAYER);
        registry.trigger(id);
        assertEq(bzz.balanceOf(PAYER), balBefore);
    }

    function test_trigger_idempotence_sameBlock() public {
        bytes32 id = _setupActiveVolume();
        _roll(5);
        registry.trigger(id); // first call: non-zero deficit → topup
        uint256 balAfterFirst = bzz.balanceOf(PAYER);
        // Second call in the same block → deficit == 0 → strict no-op.
        registry.trigger(id);
        assertEq(bzz.balanceOf(PAYER), balAfterFirst);
    }

    function test_trigger_retired_reverts() public {
        bytes32 id = _setupActiveVolume();
        vm.prank(OWNER);
        registry.deleteVolume(id);
        vm.expectRevert(VolumeRegistry.VolumeNotActive.selector);
        registry.trigger(id);
    }

    // -------- skip-no-retire paths (auth / payment) --------------------

    function test_trigger_inactiveAccount_skipsNoRetire() public {
        bytes32 id = _setupActiveVolume();
        _roll(5);
        vm.prank(OWNER);
        registry.revoke(OWNER);

        uint256 balBefore = bzz.balanceOf(PAYER);
        vm.expectEmit(true, true, true, true);
        emit TopupSkipped(id, registry.SKIP_NO_AUTH());
        registry.trigger(id);
        assertEq(bzz.balanceOf(PAYER), balBefore);
        assertEq(registry.getVolume(id).status, 1);
    }

    function test_trigger_insufficientBalance_skipsNoRetire() public {
        bytes32 id = _setupActiveVolume();
        _roll(5);

        // Drain payer to 0.
        uint256 bal = bzz.balanceOf(PAYER);
        vm.prank(PAYER);
        bzz.transfer(STRANGER, bal);

        vm.expectEmit(true, true, true, true);
        emit TopupSkipped(id, registry.SKIP_PAYMENT_FAILED());
        registry.trigger(id);
        assertEq(registry.getVolume(id).status, 1);
    }

    function test_trigger_revokedAllowance_skipsNoRetire() public {
        bytes32 id = _setupActiveVolume();
        _roll(5);

        vm.prank(PAYER);
        bzz.approve(address(registry), 0);

        uint256 balBefore = bzz.balanceOf(PAYER);
        vm.expectEmit(true, true, true, true);
        emit TopupSkipped(id, registry.SKIP_PAYMENT_FAILED());
        registry.trigger(id);
        assertEq(bzz.balanceOf(PAYER), balBefore);
        assertEq(registry.getVolume(id).status, 1);
    }

    // -------- retire edges ---------------------------------------------

    function test_trigger_batchDied_retires() public {
        bytes32 id = _setupActiveVolume();
        // A batch dies when normalisedBalance <= currentTotalOutPayment.
        // With lastPrice=INITIAL_PRICE and initial normalised = outpay + perChunk,
        // outpay per block == lastPrice. Need to roll more than GRACE_BLOCKS
        // AND keep price-driven drain outstripping topups (no trigger). Roll
        // enough blocks so drain exceeds initial per-chunk deposit.
        _roll(uint256(GRACE_BLOCKS) + 1);

        // Sanity: batch.normalisedBalance <= outpay now.
        (, , , , uint256 nb, ) = stamp.batches(id);
        assertLe(nb, stamp.currentTotalOutPayment());

        uint256 balBefore = bzz.balanceOf(PAYER);
        vm.expectEmit(true, true, true, true);
        emit VolumeRetired(id, registry.REASON_BATCH_DIED());
        registry.trigger(id);
        assertEq(registry.getVolume(id).status, 2);
        assertEq(registry.getActiveVolumeCount(), 0);
        assertEq(bzz.balanceOf(PAYER), balBefore, "no charge on retire");
    }

    function test_trigger_depthChanged_retires() public {
        bytes32 id = _setupActiveVolume();

        // Depth-increase halves per-chunk remaining balance; Postage's floor
        // is `minimumValidityBlocks * lastPrice`. Fund CHUNK_SIGNER and
        // topUp the batch so post-halving remaining still clears the floor.
        uint256 topupPerChunk = uint256(stamp.lastPrice()) * GRACE_BLOCKS * 4;
        uint256 topupTotal = topupPerChunk << DEFAULT_DEPTH;
        bzz.mint(CHUNK_SIGNER, topupTotal);
        vm.prank(CHUNK_SIGNER);
        bzz.approve(address(stamp), type(uint256).max);
        vm.prank(CHUNK_SIGNER);
        stamp.topUp(id, topupPerChunk);

        // chunkSigner (batch owner on Postage) calls increaseDepth directly.
        vm.prank(CHUNK_SIGNER);
        stamp.increaseDepth(id, DEFAULT_DEPTH + 1);

        vm.expectEmit(true, true, true, true);
        emit VolumeRetired(id, registry.REASON_DEPTH_CHANGED());
        registry.trigger(id);
        assertEq(registry.getVolume(id).status, 2);
    }

    function test_trigger_ttlExpired_retires() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * FUND_MULT);
        uint64 ttl = uint64(block.timestamp + 100);
        bytes32 id = _createVolumeWithTtl(OWNER, CHUNK_SIGNER, ttl);

        vm.warp(ttl + 1);

        vm.expectEmit(true, true, true, true);
        emit VolumeRetired(id, registry.REASON_VOLUME_EXPIRED());
        registry.trigger(id);
        assertEq(registry.getVolume(id).status, 2);
    }

    // -------- ordering tests (retire beats NoAuth) ---------------------

    function test_trigger_ordering_batchDiedBeatsNoAuth() public {
        bytes32 id = _setupActiveVolume();
        // Revoke account first.
        vm.prank(OWNER);
        registry.revoke(OWNER);
        // Then let batch die by rolling blocks.
        _roll(uint256(GRACE_BLOCKS) + 1);

        vm.expectEmit(true, true, true, true);
        emit VolumeRetired(id, registry.REASON_BATCH_DIED());
        registry.trigger(id);
    }

    function test_trigger_ordering_depthChangedBeatsNoAuth() public {
        bytes32 id = _setupActiveVolume();

        uint256 topupPerChunk = uint256(stamp.lastPrice()) * GRACE_BLOCKS * 4;
        uint256 topupTotal = topupPerChunk << DEFAULT_DEPTH;
        bzz.mint(CHUNK_SIGNER, topupTotal);
        vm.prank(CHUNK_SIGNER);
        bzz.approve(address(stamp), type(uint256).max);
        vm.prank(CHUNK_SIGNER);
        stamp.topUp(id, topupPerChunk);
        vm.prank(CHUNK_SIGNER);
        stamp.increaseDepth(id, DEFAULT_DEPTH + 1);

        // Revoke account.
        vm.prank(OWNER);
        registry.revoke(OWNER);

        vm.expectEmit(true, true, true, true);
        emit VolumeRetired(id, registry.REASON_DEPTH_CHANGED());
        registry.trigger(id);
    }

    function test_trigger_ordering_ttlExpiredBeatsNoAuth() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * FUND_MULT);
        uint64 ttl = uint64(block.timestamp + 100);
        bytes32 id = _createVolumeWithTtl(OWNER, CHUNK_SIGNER, ttl);

        vm.prank(OWNER);
        registry.revoke(OWNER);
        vm.warp(ttl + 1);

        vm.expectEmit(true, true, true, true);
        emit VolumeRetired(id, registry.REASON_VOLUME_EXPIRED());
        registry.trigger(id);
    }

    // -------- batched trigger ------------------------------------------

    function test_triggerBatch_perItemTryCatch() public {
        // 3 volumes: id1 healthy, id2 retired already, id3 revoked account.
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * 10);
        bytes32 id1 = _createDefaultVolume(OWNER, CHUNK_SIGNER);
        bytes32 id2 = _createDefaultVolume(OWNER, CHUNK_SIGNER);
        bytes32 id3 = _createDefaultVolume(OWNER, CHUNK_SIGNER);

        // Retire id2 via deleteVolume.
        vm.prank(OWNER);
        registry.deleteVolume(id2);

        _roll(3);

        // Create a separate owner/payer for id3 so we can revoke it without
        // affecting id1.
        // Re-use: give OWNER a second payer — no, easier: transfer id3 to a
        // fresh owner whose account we revoke.
        vm.prank(OWNER);
        registry.transferVolumeOwnership(id3, OWNER_B);
        // OWNER_B has no active account → NoAuth skip on trigger.

        bytes32[] memory ids = new bytes32[](3);
        ids[0] = id1;
        ids[1] = id2;
        ids[2] = id3;

        uint256 balBefore = bzz.balanceOf(PAYER);

        // Expect id3 to emit TopupSkipped(NoAuth). id2's revert is swallowed.
        // id1 emits Toppedup.
        vm.recordLogs();
        registry.trigger(ids);

        // id1 topped up (payer balance decreased).
        assertLt(bzz.balanceOf(PAYER), balBefore);
        // id2 still retired, unchanged.
        assertEq(registry.getVolume(id2).status, 2);
        // id3 still active (NoAuth never retires).
        assertEq(registry.getVolume(id3).status, 1);
    }

    // -------- reap -----------------------------------------------------

    function test_reap_idempotent() public {
        bytes32 id = _setupActiveVolume();
        vm.prank(OWNER);
        registry.deleteVolume(id);

        // No-op on already-retired volume. No events, no revert.
        vm.recordLogs();
        registry.reap(id);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_reap_retiresTtlExpiredVolume() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * FUND_MULT);
        uint64 ttl = uint64(block.timestamp + 50);
        bytes32 id = _createVolumeWithTtl(OWNER, CHUNK_SIGNER, ttl);

        vm.warp(ttl + 1);
        vm.expectEmit(true, true, true, true);
        emit VolumeRetired(id, registry.REASON_VOLUME_EXPIRED());
        registry.reap(id);
        assertEq(registry.getVolume(id).status, 2);
    }
}
