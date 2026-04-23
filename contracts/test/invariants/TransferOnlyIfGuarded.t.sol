// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {RegistryFixture} from "../fixtures/RegistryFixture.sol";
import {PayerHandler} from "./PayerHandler.sol";
import {VolumeRegistry} from "../../src/VolumeRegistry.sol";

/// @notice TEST-PLAN §3.7 — I3 invariant.
///
/// Every BZZ transfer out of a payer must have happened under
/// (account.active, volume.status=Active, account.payer=currentPayer) at the
/// moment of the call, AND must be ≤ the formula bound.
///
/// We enforce this structurally by reusing `spentByPayer == allowedByPayer`
/// from the shared handler: `allowedByPayer` is only ever incremented when
/// the handler observes a Toppedup or createVolume charge, which the contract
/// emits only on the guarded path (DESIGN §8 steps 6-8 plus createVolume's
/// transferFrom). If any unguarded path spent BZZ, `spentByPayer` would
/// outstrip `allowedByPayer` and the invariant would fire.
contract TransferOnlyIfGuardedInvariant is RegistryFixture {
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

    function invariant_payerSpendNeverExceedsFormula() public view {
        for (uint256 i = 0; i < 3; ++i) {
            address p = handler.payers(i);
            assertLe(
                handler.spentByPayer(p),
                handler.allowedByPayer(p),
                "payer spent more than formula allows"
            );
        }
    }

    /// @dev Every active volume's account at end-of-run must still agree
    ///      with what `getVolume` reports, enforcing DESIGN §7.4's contract.
    function invariant_volumeViewMatchesAccount() public view {
        uint256 n = handler.createdVolumeCount();
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = handler.createdVolumeIds(i);
            VolumeRegistry.VolumeView memory v = registry.getVolume(id);
            VolumeRegistry.Account memory a = registry.getAccount(v.owner);
            assertEq(v.payer, a.payer);
            assertEq(v.accountActive, a.active);
        }
    }
}
