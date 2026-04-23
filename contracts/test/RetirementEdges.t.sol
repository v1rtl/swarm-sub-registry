// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {StdStorage, stdStorage} from "forge-std/Test.sol";

import {RegistryFixture} from "./fixtures/RegistryFixture.sol";
import {VolumeRegistry} from "../src/VolumeRegistry.sol";

/// @notice TEST-PLAN §3.5 — Retirement edges (DESIGN §6.1, I2, I7).
contract RetirementEdgesTest is RegistryFixture {
    using stdStorage for StdStorage;

    event VolumeRetired(bytes32 indexed volumeId, uint8 reason);

    uint64 internal constant FUND_MULT = 20;

    function _retiredVolume() internal returns (bytes32 id) {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * FUND_MULT);
        id = _createDefaultVolume(OWNER, CHUNK_SIGNER);
        vm.prank(OWNER);
        registry.deleteVolume(id);
    }

    function test_retired_cannotBeTriggered() public {
        bytes32 id = _retiredVolume();
        vm.expectRevert(VolumeRegistry.VolumeNotActive.selector);
        registry.trigger(id);
    }

    function test_retired_notInActiveList() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * FUND_MULT);
        bytes32 a = _createDefaultVolume(OWNER, CHUNK_SIGNER);
        bytes32 b = _createDefaultVolume(OWNER, CHUNK_SIGNER);
        vm.prank(OWNER);
        registry.deleteVolume(a);

        // Not in raw active list.
        VolumeRegistry.VolumeView[] memory vs = registry.getActiveVolumes(0, 10);
        for (uint256 i = 0; i < vs.length; ++i) {
            assertTrue(vs[i].volumeId != a, "retired volume leaked into active list");
        }
        assertEq(vs.length, 1);
        assertEq(vs[0].volumeId, b);
    }

    function test_retired_deleteVolumeReverts() public {
        bytes32 id = _retiredVolume();
        vm.prank(OWNER);
        vm.expectRevert(VolumeRegistry.VolumeNotActive.selector);
        registry.deleteVolume(id);
    }

    function test_retired_transferOwnershipReverts() public {
        bytes32 id = _retiredVolume();
        vm.prank(OWNER);
        vm.expectRevert(VolumeRegistry.VolumeNotActive.selector);
        registry.transferVolumeOwnership(id, OWNER_B);
    }

    function test_retired_noTransferFromPayer() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * FUND_MULT);
        bytes32 id = _createDefaultVolume(OWNER, CHUNK_SIGNER);
        uint256 balAtCreate = bzz.balanceOf(PAYER);
        vm.prank(OWNER);
        registry.deleteVolume(id);

        // After retirement: no path must transfer BZZ from PAYER. We check a
        // representative sequence of caller-reachable functions.
        _roll(5);

        uint256 balBefore = bzz.balanceOf(PAYER);

        // trigger reverts.
        try registry.trigger(id) {
            revert("trigger should have reverted");
        } catch {}

        // batched trigger on [id] swallows the revert.
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        registry.trigger(ids);

        // reap is a no-op on retired.
        registry.reap(id);

        assertEq(bzz.balanceOf(PAYER), balBefore, "no transfer after retire");
        assertLe(bzz.balanceOf(PAYER), balAtCreate);
    }

    /// @notice I2 defensive branch: force PostageStamp.batches(id).owner !=
    ///         volume.chunkSigner via stdStore; trigger retires with
    ///         reason=BatchOwnerMismatch (DESIGN §6.1 — fifth reason).
    function test_i2_defensiveBatchOwnerMismatch() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * FUND_MULT);
        bytes32 id = _createDefaultVolume(OWNER, CHUNK_SIGNER);

        // Force batches(id).owner != volume.chunkSigner via direct vm.store.
        // stdStore can't resolve slots for struct-returning mappings. Slot
        // confirmed via `forge inspect PostageStamp storage-layout`:
        //   batches → slot 2 (AccessControl._roles=0, then _paused+bzzToken
        //   +minimumBucketDepth packed in slot 1, immutables are inline).
        //   Batch struct slot 0 packs [owner(20), depth(1), bucketDepth(1),
        //   immutableFlag(1)].
        address hijacker = makeAddr("hijacker");
        bytes32 batchesSlot = keccak256(abi.encode(id, uint256(2)));
        bytes32 packed = vm.load(address(stamp), batchesSlot);
        // Clear the low 160 bits (owner) and write hijacker.
        uint256 cleared = uint256(packed) & ~uint256(type(uint160).max);
        uint256 newPacked = cleared | uint256(uint160(hijacker));
        vm.store(address(stamp), batchesSlot, bytes32(newPacked));

        // Sanity: the hijacked owner survived.
        (address bOwner,,,,,) = stamp.batches(id);
        assertEq(bOwner, hijacker);

        vm.expectEmit(true, true, true, true);
        emit VolumeRetired(id, registry.REASON_BATCH_OWNER_MISMATCH());
        registry.trigger(id);
        assertEq(registry.getVolume(id).status, 2);
    }
}
