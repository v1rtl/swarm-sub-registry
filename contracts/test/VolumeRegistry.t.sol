// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {VolumeRegistry} from "../src/VolumeRegistry.sol";
import {IPostageStamp} from "../src/interfaces/IPostageStamp.sol";
import {MockPostageStamp} from "./mocks/MockPostageStamp.sol";
import {MintableBZZ} from "./mocks/MintableBZZ.sol";

contract VolumeRegistryTest is Test {
    MintableBZZ public bzz;
    MockPostageStamp public stamp;
    VolumeRegistry public reg;

    address internal owner = makeAddr("owner");
    address internal owner2 = makeAddr("owner2");
    address internal payer = makeAddr("payer");
    address internal payer2 = makeAddr("payer2");
    address internal chunkSigner = makeAddr("chunkSigner");
    address internal chunkSigner2 = makeAddr("chunkSigner2");
    address internal anyone = makeAddr("anyone");

    bytes32 internal constant A = bytes32(uint256(0xA));
    bytes32 internal constant B = bytes32(uint256(0xB));

    uint32 internal constant GRACE = 17280;   // ~24h @ 5s blocks
    uint64 internal constant PRICE = 160_000;
    uint8 internal constant DEPTH = 21;

    function setUp() public {
        bzz = new MintableBZZ();
        stamp = new MockPostageStamp(IERC20(address(bzz)));
        reg = new VolumeRegistry(IERC20(address(bzz)), IPostageStamp(address(stamp)));

        stamp.setPrice(PRICE);
        stamp.setCurrentTotalOutPayment(0);

        // Batch A: remaining = target * 2 → NOT due
        stamp.createBatch(A, chunkSigner, DEPTH, uint256(PRICE) * GRACE * 2);
        // Batch B: remaining = target - 1 → DUE
        stamp.createBatch(B, chunkSigner2, DEPTH, uint256(PRICE) * GRACE - 1);

        bzz.mint(payer, 1e22);
        bzz.mint(payer2, 1e22);
        vm.prank(payer);
        bzz.approve(address(reg), type(uint256).max);
        vm.prank(payer2);
        bzz.approve(address(reg), type(uint256).max);
    }

    // Helpers ------------------------------------------------------------

    function _fullHandshake(address _owner, address _payer) internal {
        vm.prank(_owner);
        reg.designatePayer(_payer);
        vm.prank(_payer);
        reg.confirmAccount(_owner);
    }

    function _createVolume(bytes32 id, address _owner, address _signer, uint32 grace) internal {
        vm.prank(_owner);
        reg.createVolume(id, _signer, 0, grace);
    }

    // ------------------------------------------------------------------
    // Account handshake
    // ------------------------------------------------------------------

    function test_Designate_StoresButDoesNotActivate() public {
        vm.prank(owner);
        reg.designatePayer(payer);

        assertEq(reg.designated(owner), payer);
        (address p, bool active) = reg.accounts(owner);
        assertEq(p, address(0));
        assertFalse(active);
        assertEq(reg.effectivePayer(owner), address(0));
    }

    function test_Confirm_RequiresDesignation() public {
        vm.prank(payer);
        vm.expectRevert(VolumeRegistry.NotDesignated.selector);
        reg.confirmAccount(owner);
    }

    function test_Confirm_RequiresMatchingPayer() public {
        vm.prank(owner);
        reg.designatePayer(payer);
        // A different payer cannot install itself
        vm.prank(payer2);
        vm.expectRevert(VolumeRegistry.NotDesignated.selector);
        reg.confirmAccount(owner);
    }

    function test_FullHandshake_ActivatesAccount() public {
        _fullHandshake(owner, payer);
        (address p, bool active) = reg.accounts(owner);
        assertEq(p, payer);
        assertTrue(active);
        assertEq(reg.effectivePayer(owner), payer);
    }

    function test_Revoke_ByOwner() public {
        _fullHandshake(owner, payer);
        vm.expectEmit(true, true, true, false);
        emit VolumeRegistry.AccountRevoked(owner, payer, owner);
        vm.prank(owner);
        reg.revokeAccount(owner);
        assertEq(reg.effectivePayer(owner), address(0));
        assertEq(reg.designated(owner), address(0));
    }

    function test_Revoke_ByPayer() public {
        _fullHandshake(owner, payer);
        vm.prank(payer);
        reg.revokeAccount(owner);
        assertEq(reg.effectivePayer(owner), address(0));
    }

    function test_Revoke_UnauthorizedThirdParty() public {
        _fullHandshake(owner, payer);
        vm.prank(anyone);
        vm.expectRevert(VolumeRegistry.NotAuthorizedToRevoke.selector);
        reg.revokeAccount(owner);
    }

    function test_Revoke_NoAccount() public {
        vm.prank(owner);
        vm.expectRevert(VolumeRegistry.NoAccount.selector);
        reg.revokeAccount(owner);
    }

    function test_SelfPay_StillRequiresHandshake() public {
        // Owner designates themselves as payer
        vm.prank(owner);
        reg.designatePayer(owner);
        // Must still confirm (even though same address)
        assertEq(reg.effectivePayer(owner), address(0));
        vm.prank(owner);
        reg.confirmAccount(owner);
        assertEq(reg.effectivePayer(owner), owner);
    }

    // ------------------------------------------------------------------
    // Volume lifecycle
    // ------------------------------------------------------------------

    function test_CreateVolume_StoresAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit VolumeRegistry.VolumeCreated(A, owner, chunkSigner, 0, DEPTH, GRACE);
        vm.prank(owner);
        reg.createVolume(A, chunkSigner, 0, GRACE);

        (
            address vOwner,
            address vSigner,
            uint64 ttlExpiry,
            uint8 initDepth,
            uint32 graceBlocks
        ) = reg.volumes(A);
        assertEq(vOwner, owner);
        assertEq(vSigner, chunkSigner);
        assertEq(ttlExpiry, 0);
        assertEq(initDepth, DEPTH);
        assertEq(graceBlocks, GRACE);
        assertEq(reg.volumeCount(), 1);
        assertEq(reg.batchIds(0), A);
    }

    function test_CreateVolume_RejectsZeroGrace() public {
        vm.prank(owner);
        vm.expectRevert(VolumeRegistry.ZeroGrace.selector);
        reg.createVolume(A, chunkSigner, 0, 0);
    }

    function test_CreateVolume_RejectsDuplicate() public {
        _createVolume(A, owner, chunkSigner, GRACE);
        vm.prank(owner2);
        vm.expectRevert(VolumeRegistry.AlreadyExists.selector);
        reg.createVolume(A, chunkSigner, 0, GRACE);
    }

    function test_CreateVolume_ChunkSignerMismatch() public {
        vm.prank(owner);
        vm.expectRevert(VolumeRegistry.ChunkSignerMismatch.selector);
        reg.createVolume(A, makeAddr("notTheSigner"), 0, GRACE);
    }

    function test_ModifyVolume_OwnerOnly() public {
        _createVolume(A, owner, chunkSigner, GRACE);
        vm.prank(anyone);
        vm.expectRevert(VolumeRegistry.NotOwner.selector);
        reg.modifyVolume(A, 1000, GRACE * 2);

        vm.prank(owner);
        reg.modifyVolume(A, 1000, GRACE * 2);
        (,, uint64 ttl,, uint32 g) = reg.volumes(A);
        assertEq(ttl, 1000);
        assertEq(g, GRACE * 2);
    }

    function test_ModifyVolume_NotExists() public {
        vm.expectRevert(VolumeRegistry.NotExists.selector);
        reg.modifyVolume(A, 100, GRACE);
    }

    function test_ExtendVolume_AlwaysReverts() public {
        _createVolume(A, owner, chunkSigner, GRACE);
        vm.prank(owner);
        vm.expectRevert(VolumeRegistry.DepthUnsupported.selector);
        reg.extendVolume(A, DEPTH + 1);
    }

    function test_DeleteVolume_RemovesFromIndex() public {
        _createVolume(A, owner, chunkSigner, GRACE);
        _createVolume(B, owner2, chunkSigner2, GRACE);

        vm.expectEmit(true, true, false, false);
        emit VolumeRegistry.VolumeDeleted(A, owner);
        vm.prank(owner);
        reg.deleteVolume(A);

        assertEq(reg.volumeCount(), 1);
        assertEq(reg.batchIds(0), B);
        (address o,,,,) = reg.volumes(A);
        assertEq(o, address(0));
    }

    function test_DeleteVolume_OwnerOnly() public {
        _createVolume(A, owner, chunkSigner, GRACE);
        vm.prank(anyone);
        vm.expectRevert(VolumeRegistry.NotOwner.selector);
        reg.deleteVolume(A);
    }

    function test_TransferOwnership_HandsOffManagement() public {
        _createVolume(A, owner, chunkSigner, GRACE);
        vm.expectEmit(true, true, true, false);
        emit VolumeRegistry.VolumeOwnershipTransferred(A, owner, owner2);
        vm.prank(owner);
        reg.transferOwnership(A, owner2);

        (address o,,,,) = reg.volumes(A);
        assertEq(o, owner2);

        // Old owner loses management rights
        vm.prank(owner);
        vm.expectRevert(VolumeRegistry.NotOwner.selector);
        reg.deleteVolume(A);

        // New owner can delete
        vm.prank(owner2);
        reg.deleteVolume(A);
        assertEq(reg.volumeCount(), 0);
    }

    // ------------------------------------------------------------------
    // Keepalive
    // ------------------------------------------------------------------

    function test_Keepalive_SkipsWithoutAccount() public {
        _createVolume(B, owner2, chunkSigner2, GRACE);
        // No handshake → effectivePayer == 0 → skipped silently
        uint256 before = bzz.balanceOf(payer);
        vm.prank(anyone);
        reg.keepalive();
        assertEq(bzz.balanceOf(payer), before);
    }

    function test_Keepalive_DueVolumeToppedUp_PreciseTarget() public {
        _createVolume(B, owner2, chunkSigner2, GRACE);
        _fullHandshake(owner2, payer2);

        uint256 target = uint256(PRICE) * GRACE;
        // Remaining before = target - 1; top-up should bring us to exactly target
        uint256 expectedPerChunk = 1;  // target - (target - 1) = 1
        uint256 expectedTotal = expectedPerChunk << DEPTH;

        uint256 payerBefore = bzz.balanceOf(payer2);

        vm.expectEmit(true, true, true, true);
        emit VolumeRegistry.KeptAlive(anyone, B, payer2, expectedPerChunk, expectedTotal);
        vm.prank(anyone);
        reg.keepalive();

        assertEq(bzz.balanceOf(payer2), payerBefore - expectedTotal);
        // Post-topup remaining should equal exactly target
        (,,,, uint256 normBal,) = stamp.batches(B);
        uint256 cto = stamp.currentTotalOutPayment();
        assertEq(normBal - cto, target);
    }

    function test_Keepalive_Idempotent_StrictNoOp() public {
        _createVolume(B, owner2, chunkSigner2, GRACE);
        _fullHandshake(owner2, payer2);

        vm.prank(anyone);
        reg.keepalive();
        uint256 snapshot = bzz.balanceOf(payer2);

        // Second call in the same block: must be exact no-op (not even 1 wei)
        vm.prank(anyone);
        reg.keepalive();
        assertEq(bzz.balanceOf(payer2), snapshot);
        assertFalse(reg.isDue(B));
    }

    function test_Keepalive_SkipsExpiredVolume() public {
        vm.prank(owner2);
        reg.createVolume(B, chunkSigner2, uint64(block.number + 100), GRACE);
        _fullHandshake(owner2, payer2);

        // Advance past ttlExpiry
        vm.roll(block.number + 101);

        uint256 before = bzz.balanceOf(payer2);
        vm.prank(anyone);
        reg.keepalive();
        assertEq(bzz.balanceOf(payer2), before);
    }

    function test_Keepalive_SkipsAfterPayerRevocation() public {
        _createVolume(B, owner2, chunkSigner2, GRACE);
        _fullHandshake(owner2, payer2);
        vm.prank(payer2);
        reg.revokeAccount(owner2);

        uint256 before = bzz.balanceOf(payer2);
        vm.prank(anyone);
        reg.keepalive();
        assertEq(bzz.balanceOf(payer2), before);
    }

    function test_Keepalive_SkipsFailingPull_EmitsSkipped() public {
        _createVolume(B, owner2, chunkSigner2, GRACE);
        _fullHandshake(owner2, payer2);
        vm.prank(payer2);
        bzz.approve(address(reg), 0);

        vm.recordLogs();
        vm.prank(anyone);
        reg.keepalive();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("KeepaliveSkipped(bytes32,bytes)")) {
                found = true;
                break;
            }
        }
        assertTrue(found, "KeepaliveSkipped expected");
    }

    function test_KeepaliveOne_BubblesRevert() public {
        _createVolume(B, owner2, chunkSigner2, GRACE);
        _fullHandshake(owner2, payer2);
        vm.prank(payer2);
        bzz.approve(address(reg), 0);

        vm.prank(anyone);
        vm.expectRevert();
        reg.keepaliveOne(B);
    }

    function test_KeepaliveOne_TopsUpDueVolume() public {
        _createVolume(B, owner2, chunkSigner2, GRACE);
        _fullHandshake(owner2, payer2);

        vm.prank(anyone);
        bool toppedUp = reg.keepaliveOne(B);
        assertTrue(toppedUp);
    }

    function test_KeepaliveOne_ReturnsFalseWhenNotDue() public {
        _createVolume(A, owner, chunkSigner, GRACE); // A is not due (remaining = target*2)
        _fullHandshake(owner, payer);

        vm.prank(anyone);
        bool toppedUp = reg.keepaliveOne(A);
        assertFalse(toppedUp);
    }

    function test_KeepaliveOne_OnlySelf() public {
        vm.expectRevert(VolumeRegistry.OnlySelf.selector);
        reg._keepaliveOne(A, PRICE, 0);
    }

    // ------------------------------------------------------------------
    // Pruning
    // ------------------------------------------------------------------

    function test_IsDead_TruthTable() public {
        // no volume → false
        assertFalse(reg.isDead(A));

        // volume + alive batch → false
        _createVolume(A, owner, chunkSigner, GRACE);
        assertFalse(reg.isDead(A));

        // volume-level expiry passed → true
        vm.prank(owner);
        reg.modifyVolume(A, uint64(block.number + 5), GRACE);
        vm.roll(block.number + 10);
        assertTrue(reg.isDead(A));

        // un-expire (set far future), delete batch on PostageStamp → true
        vm.prank(owner);
        reg.modifyVolume(A, 0, GRACE);
        stamp.deleteBatch(A);
        assertTrue(reg.isDead(A));
    }

    function test_PruneOne_RemovesReapedBatch() public {
        _createVolume(A, owner, chunkSigner, GRACE);
        stamp.deleteBatch(A);
        vm.prank(anyone);
        reg.pruneOne(A);
        assertEq(reg.volumeCount(), 0);
    }

    function test_PruneOne_RemovesExpiredVolume() public {
        vm.prank(owner);
        reg.createVolume(A, chunkSigner, uint64(block.number + 5), GRACE);
        vm.roll(block.number + 10);

        vm.prank(anyone);
        reg.pruneOne(A);
        assertEq(reg.volumeCount(), 0);
    }

    function test_PruneOne_RevertsOnAliveVolume() public {
        _createVolume(A, owner, chunkSigner, GRACE);
        vm.prank(anyone);
        vm.expectRevert(VolumeRegistry.NotDead.selector);
        reg.pruneOne(A);
    }

    function test_PruneOne_RevertsOnNotExists() public {
        vm.prank(anyone);
        vm.expectRevert(VolumeRegistry.NotExists.selector);
        reg.pruneOne(bytes32(uint256(0xDEAD)));
    }

    function test_PruneDead_MixedArray() public {
        bytes32 C = bytes32(uint256(0xCCCC));
        bytes32 D = bytes32(uint256(0xDDDD));
        // A alive; B reaped (dead); C volume-expired (dead); D no volume
        _createVolume(A, owner, chunkSigner, GRACE);
        _createVolume(B, owner2, chunkSigner2, GRACE);
        vm.prank(owner);
        stamp.createBatch(C, chunkSigner, DEPTH, uint256(PRICE) * GRACE * 2);
        vm.prank(owner);
        reg.createVolume(C, chunkSigner, uint64(block.number + 5), GRACE);

        stamp.deleteBatch(B);
        vm.roll(block.number + 10); // past C's expiry

        bytes32[] memory ids = new bytes32[](4);
        ids[0] = A; ids[1] = B; ids[2] = C; ids[3] = D;

        vm.recordLogs();
        vm.prank(anyone);
        reg.pruneDead(ids);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 pruned;
        uint256 skipped;
        bool sawNotDead;
        bool sawNotExists;
        bytes4 notDeadSel = VolumeRegistry.NotDead.selector;
        bytes4 notExistsSel = VolumeRegistry.NotExists.selector;
        for (uint256 i = 0; i < logs.length; ++i) {
            bytes32 t = logs[i].topics[0];
            if (t == keccak256("Pruned(bytes32,address)")) pruned++;
            else if (t == keccak256("PruneSkipped(bytes32,bytes)")) {
                skipped++;
                bytes memory reason = abi.decode(logs[i].data, (bytes));
                bytes4 sel;
                assembly { sel := mload(add(reason, 32)) }
                if (sel == notDeadSel) sawNotDead = true;
                if (sel == notExistsSel) sawNotExists = true;
            }
        }
        assertEq(pruned, 2);
        assertEq(skipped, 2);
        assertTrue(sawNotDead);
        assertTrue(sawNotExists);
        assertEq(reg.volumeCount(), 1); // only A remains
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function test_IsDue_RequiresActiveAccount() public {
        _createVolume(B, owner2, chunkSigner2, GRACE);
        assertFalse(reg.isDue(B)); // no account yet
        _fullHandshake(owner2, payer2);
        assertTrue(reg.isDue(B));
    }

    function test_EstimatedTopUp_TargetsPreciseBalance() public {
        _createVolume(B, owner2, chunkSigner2, GRACE);
        (uint256 perChunk, uint256 total) = reg.estimatedTopUp(B);
        assertEq(perChunk, 1);                // target - (target-1) = 1
        assertEq(total, uint256(1) << DEPTH);
    }

    function test_EstimatedTopUp_NotExists() public view {
        (uint256 perChunk, uint256 total) = reg.estimatedTopUp(bytes32(uint256(0xDEAD)));
        assertEq(perChunk, 0);
        assertEq(total, 0);
    }

    // ------------------------------------------------------------------
    // Security-style invariants from notes/words.md
    // ------------------------------------------------------------------

    /// After a volume is removed, no further topup can route through it,
    /// even if the payer account is still active.
    function test_Removal_NoTopupAfterDelete() public {
        _createVolume(B, owner2, chunkSigner2, GRACE);
        _fullHandshake(owner2, payer2);
        vm.prank(owner2);
        reg.deleteVolume(B);

        uint256 before = bzz.balanceOf(payer2);
        vm.prank(anyone);
        reg.keepalive();
        assertEq(bzz.balanceOf(payer2), before);
    }

    /// Revocation must stop topups across every volume managed by the
    /// same (owner, payer) pair (we don't store payer per-volume).
    function test_Revocation_StopsAllVolumesForPair() public {
        bytes32 id2 = bytes32(uint256(0xBB));
        stamp.createBatch(id2, chunkSigner2, DEPTH, uint256(PRICE) * GRACE - 1);

        _createVolume(B, owner2, chunkSigner2, GRACE);
        _createVolume(id2, owner2, chunkSigner2, GRACE);
        _fullHandshake(owner2, payer2);

        vm.prank(payer2);
        reg.revokeAccount(owner2);

        uint256 before = bzz.balanceOf(payer2);
        vm.prank(anyone);
        reg.keepalive();
        assertEq(bzz.balanceOf(payer2), before);
    }
}
