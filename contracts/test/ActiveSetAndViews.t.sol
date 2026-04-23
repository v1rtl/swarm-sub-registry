// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {RegistryFixture} from "./fixtures/RegistryFixture.sol";
import {VolumeRegistry} from "../src/VolumeRegistry.sol";

/// @notice TEST-PLAN §3.3 — Active set and views (DESIGN §7.4, swap-and-pop).
contract ActiveSetAndViewsTest is RegistryFixture {
    function test_activeSet_emptyInitially() public {
        assertEq(registry.getActiveVolumeCount(), 0);
        VolumeRegistry.VolumeView[] memory vs = registry.getActiveVolumes(0, 10);
        assertEq(vs.length, 0);
    }

    function test_activeSet_insertionPreservesOrder() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * 10);
        bytes32 v1 = _createDefaultVolume(OWNER, CHUNK_SIGNER);
        bytes32 v2 = _createDefaultVolume(OWNER, CHUNK_SIGNER);
        bytes32 v3 = _createDefaultVolume(OWNER, CHUNK_SIGNER);

        VolumeRegistry.VolumeView[] memory vs = registry.getActiveVolumes(0, 3);
        assertEq(vs.length, 3);
        assertEq(vs[0].volumeId, v1);
        assertEq(vs[1].volumeId, v2);
        assertEq(vs[2].volumeId, v3);
    }

    function test_activeSet_swapPopMiddle() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * 10);
        bytes32 v1 = _createDefaultVolume(OWNER, CHUNK_SIGNER);
        bytes32 v2 = _createDefaultVolume(OWNER, CHUNK_SIGNER);
        bytes32 v3 = _createDefaultVolume(OWNER, CHUNK_SIGNER);

        vm.prank(OWNER);
        registry.deleteVolume(v2);

        // Active list should be [v1, v3]. Swap-and-pop moved v3 into v2's slot.
        VolumeRegistry.VolumeView[] memory vs = registry.getActiveVolumes(0, 10);
        assertEq(vs.length, 2);
        assertEq(vs[0].volumeId, v1);
        assertEq(vs[1].volumeId, v3);
        assertEq(registry.getActiveVolumeCount(), 2);
    }

    function test_activeSet_pagination() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * 200);
        bytes32[] memory ids = new bytes32[](150);
        for (uint256 i = 0; i < 150; ++i) {
            ids[i] = _createDefaultVolume(OWNER, CHUNK_SIGNER);
        }

        VolumeRegistry.VolumeView[] memory page1 = registry.getActiveVolumes(0, 100);
        assertEq(page1.length, 100);
        for (uint256 i = 0; i < 100; ++i) assertEq(page1[i].volumeId, ids[i]);

        VolumeRegistry.VolumeView[] memory page2 = registry.getActiveVolumes(100, 100);
        assertEq(page2.length, 50);
        for (uint256 i = 0; i < 50; ++i) assertEq(page2[i].volumeId, ids[100 + i]);

        // Offset beyond end returns empty.
        VolumeRegistry.VolumeView[] memory overflow = registry.getActiveVolumes(150, 10);
        assertEq(overflow.length, 0);
    }

    function test_getVolume_resolvesPayerFromAccount() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * 2);
        bytes32 id = _createDefaultVolume(OWNER, CHUNK_SIGNER);

        VolumeRegistry.VolumeView memory v = registry.getVolume(id);
        assertEq(v.payer, PAYER);
        assertTrue(v.accountActive);
    }

    function test_getVolume_afterRevoke_showsInactive() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * 2);
        bytes32 id = _createDefaultVolume(OWNER, CHUNK_SIGNER);
        vm.prank(OWNER);
        registry.revoke(OWNER);

        VolumeRegistry.VolumeView memory v = registry.getVolume(id);
        assertEq(v.payer, PAYER, "payer identity retained after revoke");
        assertFalse(v.accountActive);
    }
}
