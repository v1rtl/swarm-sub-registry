// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {RegistryFixture} from "./fixtures/RegistryFixture.sol";
import {VolumeRegistry} from "../src/VolumeRegistry.sol";

/// @notice TEST-PLAN §3.7 — Payer-bounded exposure (I3). Example witnesses;
///         the fuzz invariant lives in invariants/TransferOnlyIfGuarded.t.sol.
contract PayerBoundedExposureTest is RegistryFixture {
    uint64 internal constant FUND_MULT = 20;

    function test_transferNeverUnderInactiveAccount() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * FUND_MULT);
        bytes32 id = _createDefaultVolume(OWNER, CHUNK_SIGNER);

        vm.prank(OWNER);
        registry.revoke(OWNER);

        _roll(5);
        uint256 before = bzz.balanceOf(PAYER);
        registry.trigger(id);
        assertEq(bzz.balanceOf(PAYER), before);
    }

    function test_transferNeverAfterRetire() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * FUND_MULT);
        bytes32 id = _createDefaultVolume(OWNER, CHUNK_SIGNER);

        vm.prank(OWNER);
        registry.deleteVolume(id);

        uint256 before = bzz.balanceOf(PAYER);
        vm.expectRevert(VolumeRegistry.VolumeNotActive.selector);
        registry.trigger(id);
        assertEq(bzz.balanceOf(PAYER), before);
    }

    function test_transferNeverUsingOldPayer() public {
        // account was {PAYER, true}; volume created charging PAYER.
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * FUND_MULT);
        bytes32 id = _createDefaultVolume(OWNER, CHUNK_SIGNER);

        // Re-designate + confirm PAYER2 (atomic overwrite).
        _activateAccount(OWNER, PAYER2, _expectedCreateCharge(DEFAULT_DEPTH) * FUND_MULT);

        _roll(5);
        uint256 p1Before = bzz.balanceOf(PAYER);
        uint256 p2Before = bzz.balanceOf(PAYER2);
        registry.trigger(id);

        assertEq(bzz.balanceOf(PAYER), p1Before, "old payer untouched");
        assertLt(bzz.balanceOf(PAYER2), p2Before, "new payer charged");
    }
}
