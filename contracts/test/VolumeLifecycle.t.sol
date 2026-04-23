// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {RegistryFixture} from "./fixtures/RegistryFixture.sol";
import {VolumeRegistry} from "../src/VolumeRegistry.sol";

/// @notice TEST-PLAN §3.2 — Volume lifecycle (DESIGN §7.1, I1).
contract VolumeLifecycleTest is RegistryFixture {
    event VolumeCreated(
        bytes32 indexed volumeId,
        address indexed owner,
        address chunkSigner,
        uint8 depth,
        uint64 ttlExpiry
    );
    event VolumeRetired(bytes32 indexed volumeId, uint8 reason);
    event VolumeOwnershipTransferred(
        bytes32 indexed volumeId, address indexed from, address indexed to
    );
    event TopupSkipped(bytes32 indexed volumeId, uint8 reason);

    // --- createVolume ---------------------------------------------------

    function test_createVolume_happy() public {
        uint256 charge = _expectedCreateCharge(DEFAULT_DEPTH);
        _activateAccount(OWNER, PAYER, charge * 2);

        uint256 payerBalBefore = bzz.balanceOf(PAYER);
        uint256 nonce = registry.nextNonce();
        bytes32 expectedId = keccak256(abi.encode(address(registry), bytes32(nonce)));

        vm.expectEmit(true, true, true, true);
        emit VolumeCreated(expectedId, OWNER, CHUNK_SIGNER, DEFAULT_DEPTH, 0);
        vm.prank(OWNER);
        bytes32 id =
            registry.createVolume(CHUNK_SIGNER, DEFAULT_DEPTH, DEFAULT_BUCKET, 0, false);

        assertEq(id, expectedId, "volumeId formula mismatch");

        // Volume record.
        VolumeRegistry.VolumeView memory v = registry.getVolume(id);
        assertEq(v.owner, OWNER);
        assertEq(v.chunkSigner, CHUNK_SIGNER);
        assertEq(v.depth, DEFAULT_DEPTH);
        assertEq(v.ttlExpiry, 0);
        assertEq(v.status, 1); // STATUS_ACTIVE
        assertEq(v.payer, PAYER);
        assertTrue(v.accountActive);

        // In active set.
        assertEq(registry.getActiveVolumeCount(), 1);

        // BZZ transfer amount.
        assertEq(bzz.balanceOf(PAYER), payerBalBefore - charge, "payer charge exact");

        // Postage batch exists with correct owner/depth.
        (address bOwner, uint8 bDepth,,,,) = stamp.batches(id);
        assertEq(bOwner, CHUNK_SIGNER);
        assertEq(bDepth, DEFAULT_DEPTH);

        // Nonce advanced.
        assertEq(registry.nextNonce(), nonce + 1);
    }

    function test_createVolume_inactiveAccount_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(VolumeRegistry.AccountNotActive.selector);
        registry.createVolume(CHUNK_SIGNER, DEFAULT_DEPTH, DEFAULT_BUCKET, 0, false);
    }

    function test_createVolume_payerInsufficientBalance_reverts() public {
        // active account, payer has less BZZ than charge
        uint256 charge = _expectedCreateCharge(DEFAULT_DEPTH);
        _activateAccount(OWNER, PAYER, charge - 1);
        vm.prank(OWNER);
        vm.expectRevert(); // ERC20: transfer amount exceeds balance
        registry.createVolume(CHUNK_SIGNER, DEFAULT_DEPTH, DEFAULT_BUCKET, 0, false);
    }

    function test_createVolume_payerInsufficientAllowance_reverts() public {
        uint256 charge = _expectedCreateCharge(DEFAULT_DEPTH);
        // _activateAccount approves unlimited; override to something small.
        vm.prank(OWNER);
        registry.designateFundingWallet(PAYER);
        vm.prank(PAYER);
        registry.confirmAuth(OWNER);
        bzz.mint(PAYER, charge * 2);
        vm.prank(PAYER);
        bzz.approve(address(registry), charge - 1);

        vm.prank(OWNER);
        vm.expectRevert();
        registry.createVolume(CHUNK_SIGNER, DEFAULT_DEPTH, DEFAULT_BUCKET, 0, false);
    }

    function test_createVolume_graceBlocksBelowPostageFloor_constructorReverts() public {
        // Floor is 12 (set in fixture); 11 must revert.
        vm.expectRevert(
            abi.encodeWithSelector(
                VolumeRegistry.GraceBlocksBelowFloor.selector, uint64(11), uint64(12)
            )
        );
        new VolumeRegistry(address(stamp), address(bzz), 11);
    }

    // --- deleteVolume ---------------------------------------------------

    function test_deleteVolume_retiresAndRemoves() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * 2);
        bytes32 id = _createDefaultVolume(OWNER, CHUNK_SIGNER);

        vm.expectEmit(true, true, true, true);
        emit VolumeRetired(id, registry.REASON_OWNER_DELETED());
        vm.prank(OWNER);
        registry.deleteVolume(id);

        assertEq(registry.getVolume(id).status, 2); // STATUS_RETIRED
        assertEq(registry.getActiveVolumeCount(), 0);
    }

    function test_deleteVolume_byNonOwner_reverts() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * 2);
        bytes32 id = _createDefaultVolume(OWNER, CHUNK_SIGNER);

        vm.prank(STRANGER);
        vm.expectRevert(VolumeRegistry.NotVolumeOwner.selector);
        registry.deleteVolume(id);
    }

    function test_deleteVolume_alreadyRetired_reverts() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * 2);
        bytes32 id = _createDefaultVolume(OWNER, CHUNK_SIGNER);
        vm.prank(OWNER);
        registry.deleteVolume(id);

        vm.prank(OWNER);
        vm.expectRevert(VolumeRegistry.VolumeNotActive.selector);
        registry.deleteVolume(id);
    }

    // --- transferVolumeOwnership ---------------------------------------

    function test_transferOwnership_rotates() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * 2);
        bytes32 id = _createDefaultVolume(OWNER, CHUNK_SIGNER);

        vm.expectEmit(true, true, true, true);
        emit VolumeOwnershipTransferred(id, OWNER, OWNER_B);
        vm.prank(OWNER);
        registry.transferVolumeOwnership(id, OWNER_B);

        assertEq(registry.getVolume(id).owner, OWNER_B);

        // Old owner can no longer delete.
        vm.prank(OWNER);
        vm.expectRevert(VolumeRegistry.NotVolumeOwner.selector);
        registry.deleteVolume(id);

        // New owner can.
        vm.prank(OWNER_B);
        registry.deleteVolume(id);
        assertEq(registry.getVolume(id).status, 2);
    }

    function test_transferOwnership_accountContextFollows() public {
        // A has active account with PAYER; creates a volume.
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * 10);
        bytes32 id = _createDefaultVolume(OWNER, CHUNK_SIGNER);

        // Transfer to B who has no account at all.
        vm.prank(OWNER);
        registry.transferVolumeOwnership(id, OWNER_B);

        // Advance a block so there is a nonzero deficit.
        _roll(5);

        // Expect NoAuth skip — payer lookup now uses accounts[OWNER_B].
        uint256 payerBalBefore = bzz.balanceOf(PAYER);
        vm.expectEmit(true, true, true, true);
        emit TopupSkipped(id, registry.SKIP_NO_AUTH());
        registry.trigger(id);

        // Original payer untouched.
        assertEq(bzz.balanceOf(PAYER), payerBalBefore);
        // Volume still active — NoAuth never retires.
        assertEq(registry.getVolume(id).status, 1);
    }
}
