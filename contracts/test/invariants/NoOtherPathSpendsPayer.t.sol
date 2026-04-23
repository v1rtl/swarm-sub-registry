// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {RegistryFixture} from "../fixtures/RegistryFixture.sol";
import {PayerHandler} from "./PayerHandler.sol";

/// @notice TEST-PLAN §3.6 (I8) — invariant: every BZZ delta from a payer
///         equals the sum of observed Toppedup + createVolume charges.
contract NoOtherPathSpendsPayerInvariant is RegistryFixture {
    PayerHandler internal handler;

    function setUp() public override {
        super.setUp();
        // PayerHandler mints BZZ during construction; needs minter role first.
        handler = PayerHandler(address(_deployHandler()));
        targetContract(address(handler));
    }

    function _deployHandler() internal returns (PayerHandler h) {
        // Pre-authorize a handler address? Simpler: grant minter to a
        // sentinel, deploy, transfer. Easiest: grant MINTER_ROLE to the
        // create2-predictable address is overkill — use a two-step: deploy
        // a stub that the fixture grants minter to, then have *that* stub
        // deploy the handler. Alternative & chosen: grant MINTER_ROLE to
        // the test contract (already has it) and expose a tiny helper in
        // the handler so the mint happens via this contract.
        // Accept the simpler route: compute CREATE address, grant role there.
        address predicted = computeCreateAddress(address(this), vm.getNonce(address(this)));
        bzz.grantRole(bzz.MINTER_ROLE(), predicted);
        h = new PayerHandler(
            registry, stamp, bzz, DEFAULT_DEPTH, DEFAULT_BUCKET, GRACE_BLOCKS
        );
    }

    function invariant_spentEqualsAllowedPerPayer() public view {
        for (uint256 i = 0; i < 3; ++i) {
            address p = handler.payers(i);
            uint256 spent = handler.spentByPayer(p);
            uint256 allowed = handler.allowedByPayer(p);
            assertEq(spent, allowed, "payer outflow diverged from allowed");
        }
    }
}
