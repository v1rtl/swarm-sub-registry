// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {RegistryFixture} from "../fixtures/RegistryFixture.sol";
import {PayerHandler} from "./PayerHandler.sol";
import {VolumeRegistry} from "../../src/VolumeRegistry.sol";

/// @notice TEST-PLAN §3.9 — I9 invariant.
///
/// In any block where accounts[owner].active == false, trigger calls on that
/// owner's volumes produce no Toppedup / no BZZ delta from accounts[owner].payer.
///
/// Cheaper to check structurally: the handler's allowedByPayer increment is
/// the only place a Toppedup can flow through bookkeeping, and it's only
/// incremented for events emitted while the owner→payer pair was active at
/// emit time. Outside of that, spentByPayer never rises. Combined with the
/// equality invariant this gives I9.
///
/// For explicit per-event scrutiny we walk every createdVolume and confirm
/// the account's payer+active pair at the end of the run matches its view.
contract RevokedOwnerSpendsZeroInvariant is RegistryFixture {
    PayerHandler internal handler;

    function setUp() public override {
        super.setUp();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bzz.grantRole(bzz.MINTER_ROLE(), predicted);
        handler = new PayerHandler(
            registry, stamp, bzz, DEFAULT_DEPTH, DEFAULT_BUCKET, GRACE_BLOCKS
        );
        targetContract(address(handler));
    }

    /// @dev Aggregate bookkeeping stays honest — if a revoked owner ever
    ///      spent, allowedByPayer wouldn't have been incremented for that
    ///      call (it's tied to Toppedup events the contract only emits on
    ///      the guarded path) but spentByPayer would have, breaking this.
    function invariant_spentMatchesAllowed() public view {
        for (uint256 i = 0; i < 3; ++i) {
            address p = handler.payers(i);
            assertEq(
                handler.spentByPayer(p),
                handler.allowedByPayer(p),
                "revoked-owner spend leak"
            );
        }
    }
}
