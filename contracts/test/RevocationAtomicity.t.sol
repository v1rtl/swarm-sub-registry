// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {RegistryFixture} from "./fixtures/RegistryFixture.sol";
import {VolumeRegistry} from "../src/VolumeRegistry.sol";

/// @notice TEST-PLAN §3.9 — Revocation atomicity (I9).
contract RevocationAtomicityTest is RegistryFixture {
    event TopupSkipped(bytes32 indexed volumeId, uint8 reason);

    function test_revoke_disablesAllVolumesInPair() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * 50);

        bytes32[] memory ids = new bytes32[](5);
        for (uint256 i = 0; i < 5; ++i) ids[i] = _createDefaultVolume(OWNER, CHUNK_SIGNER);

        vm.prank(PAYER);
        registry.revoke(OWNER);

        _roll(5);
        uint256 balBefore = bzz.balanceOf(PAYER);

        // Expect 5 TopupSkipped(NoAuth) events.
        for (uint256 i = 0; i < 5; ++i) {
            vm.expectEmit(true, true, true, true);
            emit TopupSkipped(ids[i], registry.SKIP_NO_AUTH());
        }
        registry.trigger(ids);

        assertEq(bzz.balanceOf(PAYER), balBefore, "revoked: no BZZ spent");
        // All still Active.
        for (uint256 i = 0; i < 5; ++i) assertEq(registry.getVolume(ids[i]).status, 1);
    }
}
