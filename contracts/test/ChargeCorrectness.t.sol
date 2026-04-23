// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {RegistryFixture} from "./fixtures/RegistryFixture.sol";
import {VolumeRegistry} from "../src/VolumeRegistry.sol";

/// @notice TEST-PLAN §3.6 — Charge correctness (I8).
///
/// Two lenses:
///   (a) exact-formula assertions on the two code paths that spend payer
///       BZZ (createVolume, trigger),
///   (b) invariant: no other code path touches payer BZZ.
///
/// The invariant lens lives in test/invariants/NoOtherPathSpendsPayer.t.sol.
contract ChargeCorrectnessTest is RegistryFixture {
    uint64 internal constant FUND_MULT = 20;

    function test_createVolume_chargeEqualsFormula() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * FUND_MULT);

        uint256 price = uint256(stamp.lastPrice());
        uint256 expected = price * GRACE_BLOCKS * (uint256(1) << DEFAULT_DEPTH);

        uint256 before = bzz.balanceOf(PAYER);
        vm.prank(OWNER);
        registry.createVolume(CHUNK_SIGNER, DEFAULT_DEPTH, DEFAULT_BUCKET, 0, false);
        assertEq(before - bzz.balanceOf(PAYER), expected, "createVolume charge formula");
    }

    function test_trigger_chargeEqualsDeficitFormula() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * FUND_MULT);
        bytes32 id = _createDefaultVolume(OWNER, CHUNK_SIGNER);

        // Roll blocks so there is a nonzero deficit.
        _roll(7);

        // Recompute formula: deficit = max(0, target - remaining);
        // amount = deficit * (1<<depth).
        uint256 target = uint256(stamp.lastPrice()) * GRACE_BLOCKS;
        (, , , , uint256 nb, ) = stamp.batches(id);
        uint256 outpay = stamp.currentTotalOutPayment();
        uint256 remaining = nb - outpay;
        uint256 deficit = target > remaining ? target - remaining : 0;
        uint256 expected = deficit * (uint256(1) << DEFAULT_DEPTH);

        uint256 before = bzz.balanceOf(PAYER);
        registry.trigger(id);
        assertEq(before - bzz.balanceOf(PAYER), expected, "trigger charge formula");
    }
}
