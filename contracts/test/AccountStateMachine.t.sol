// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {RegistryFixture} from "./fixtures/RegistryFixture.sol";
import {VolumeRegistry} from "../src/VolumeRegistry.sol";

/// @notice TEST-PLAN §3.1 — Account state machine (DESIGN §6.2, I4).
contract AccountStateMachineTest is RegistryFixture {
    event PayerDesignated(address indexed owner, address payer);
    event AccountActivated(address indexed owner, address indexed payer);
    event AccountRevoked(address indexed owner, address indexed payer, address revoker);

    function test_designate_setsDesignated() public {
        vm.expectEmit(true, true, true, true);
        emit PayerDesignated(OWNER, PAYER);
        vm.prank(OWNER);
        registry.designateFundingWallet(PAYER);
        assertEq(registry.designated(OWNER), PAYER);
    }

    function test_designate_zeroClears() public {
        vm.prank(OWNER);
        registry.designateFundingWallet(PAYER);
        vm.prank(OWNER);
        registry.designateFundingWallet(address(0));
        assertEq(registry.designated(OWNER), address(0));
    }

    function test_confirmAuth_withoutDesignation_reverts() public {
        vm.prank(PAYER);
        vm.expectRevert(VolumeRegistry.NotDesignated.selector);
        registry.confirmAuth(OWNER);
    }

    function test_confirmAuth_wrongDesignee_reverts() public {
        vm.prank(OWNER);
        registry.designateFundingWallet(PAYER);
        vm.prank(PAYER2);
        vm.expectRevert(VolumeRegistry.NotDesignated.selector);
        registry.confirmAuth(OWNER);
    }

    function test_confirmAuth_activates() public {
        vm.prank(OWNER);
        registry.designateFundingWallet(PAYER);
        vm.expectEmit(true, true, true, true);
        emit AccountActivated(OWNER, PAYER);
        vm.prank(PAYER);
        registry.confirmAuth(OWNER);
        VolumeRegistry.Account memory a = registry.getAccount(OWNER);
        assertEq(a.payer, PAYER);
        assertTrue(a.active);
    }

    function test_reconfirm_overwrites() public {
        // Start with {PAYER, true}.
        vm.prank(OWNER);
        registry.designateFundingWallet(PAYER);
        vm.prank(PAYER);
        registry.confirmAuth(OWNER);

        // Designate PAYER2, have them confirm.
        vm.prank(OWNER);
        registry.designateFundingWallet(PAYER2);
        vm.prank(PAYER2);
        registry.confirmAuth(OWNER);

        VolumeRegistry.Account memory a = registry.getAccount(OWNER);
        assertEq(a.payer, PAYER2);
        assertTrue(a.active);
    }

    function test_revoke_byOwner_deactivates() public {
        _activateAccount(OWNER, PAYER, 0);
        vm.expectEmit(true, true, true, true);
        emit AccountRevoked(OWNER, PAYER, OWNER);
        vm.prank(OWNER);
        registry.revoke(OWNER);
        assertFalse(registry.getAccount(OWNER).active);
    }

    function test_revoke_byPayer_deactivates() public {
        _activateAccount(OWNER, PAYER, 0);
        vm.expectEmit(true, true, true, true);
        emit AccountRevoked(OWNER, PAYER, PAYER);
        vm.prank(PAYER);
        registry.revoke(OWNER);
        assertFalse(registry.getAccount(OWNER).active);
    }

    function test_revoke_byThirdParty_reverts() public {
        _activateAccount(OWNER, PAYER, 0);
        vm.prank(STRANGER);
        vm.expectRevert(VolumeRegistry.NotAuthorizedToRevoke.selector);
        registry.revoke(OWNER);
    }

    function test_revoke_preservesPayerIdentity() public {
        _activateAccount(OWNER, PAYER, 0);
        vm.prank(OWNER);
        registry.revoke(OWNER);
        VolumeRegistry.Account memory a = registry.getAccount(OWNER);
        assertEq(a.payer, PAYER, "payer identity lost on revoke");
        assertFalse(a.active);

        // Re-activation via confirmAuth should work without re-designation?
        // Per §6.2 the diagram shows revoke → ∅ (no Designated), so
        // re-activation requires a fresh designate + confirm. Verify that
        // path here.
        vm.prank(OWNER);
        registry.designateFundingWallet(PAYER);
        vm.prank(PAYER);
        registry.confirmAuth(OWNER);
        assertTrue(registry.getAccount(OWNER).active);
    }
}
