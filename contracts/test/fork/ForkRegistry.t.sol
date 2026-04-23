// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {VolumeRegistry} from "../../src/VolumeRegistry.sol";

/// @notice TEST-PLAN §4 — Fork-mode subset against live Sepolia.
///
/// Skipped unless `FOUNDRY_FORK_URL` (or `SEPOLIA_RPC_URL`) is set in the
/// environment. Purpose: catch ABI/parameter drift between our vendored
/// artifacts and the actual live Sepolia contracts. Correctness coverage
/// stays in L1.
///
/// Fork-safe subset:
///   - test_createVolume_happy
///   - test_trigger_happyTopup
///   - test_trigger_zeroDeficit_noop
///   - test_trigger_idempotence_sameBlock
///   - test_activeSet_pagination (moderate N)
///   - Parity assertion at setUp
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
}

interface IPostageStamp {
    function minimumValidityBlocks() external view returns (uint64);
    function lastPrice() external view returns (uint64);
    function priceOracle() external view returns (address);
    function batches(bytes32)
        external
        view
        returns (address, uint8, uint8, bool, uint256, uint256);
    function currentTotalOutPayment() external view returns (uint256);
}

contract ForkRegistryTest is Test {
    // Sepolia addresses per TEST-PLAN §2.2.
    address internal constant SEP_POSTAGE = 0xcdfdC3752caaA826fE62531E0000C40546eC56A6;
    address internal constant SEP_BZZ = 0x543dDb01Ba47acB11de34891cD86B675F04840db;
    address internal constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;

    // Pull the grace-blocks value that Sepolia's demo registry is deployed
    // with. TEST-PLAN §2.3 pins this at 12.
    uint64 internal constant FORK_GRACE_BLOCKS = 12;

    VolumeRegistry internal registry;
    IERC20 internal bzz;
    IPostageStamp internal stamp;

    address internal owner = makeAddr("fork_owner");
    address internal payer = makeAddr("fork_payer");
    address internal chunkSigner = makeAddr("fork_chunk_signer");

    uint8 internal constant DEFAULT_DEPTH = 20;
    uint8 internal constant DEFAULT_BUCKET = 16;

    modifier forkOnly() {
        if (!_forkActive()) {
            emit log("fork test skipped - no FOUNDRY_FORK_URL");
            return;
        }
        _;
    }

    function _forkActive() internal view returns (bool) {
        // foundry sets block.chainid correctly against the fork; sepolia = 11155111.
        return block.chainid == 11155111;
    }

    function setUp() public {
        if (!_forkActive()) return;

        bzz = IERC20(SEP_BZZ);
        stamp = IPostageStamp(SEP_POSTAGE);

        // Parity: Multicall3 bytecode present.
        assertGt(SEP_POSTAGE.code.length, 0, "PostageStamp code missing on fork");
        assertGt(MULTICALL3.code.length, 0, "Multicall3 missing at canonical address");
        // Parity: minimumValidityBlocks == 12.
        assertEq(stamp.minimumValidityBlocks(), uint64(12), "Sepolia minValidityBlocks drift");
        // Parity: PriceOracle discoverable.
        address oracle = stamp.priceOracle();
        assertTrue(oracle != address(0), "PriceOracle not discoverable");

        registry = new VolumeRegistry(SEP_POSTAGE, SEP_BZZ, FORK_GRACE_BLOCKS);

        // Fund + activate.
        deal(SEP_BZZ, payer, 1e30);
        vm.prank(payer);
        bzz.approve(address(registry), type(uint256).max);
        vm.prank(owner);
        registry.designateFundingWallet(payer);
        vm.prank(payer);
        registry.confirmAuth(owner);
    }

    function _charge() internal view returns (uint256) {
        return uint256(stamp.lastPrice()) * FORK_GRACE_BLOCKS * (uint256(1) << DEFAULT_DEPTH);
    }

    function test_fork_createVolume_happy() public forkOnly {
        uint256 balBefore = bzz.balanceOf(payer);
        vm.prank(owner);
        bytes32 id =
            registry.createVolume(chunkSigner, DEFAULT_DEPTH, DEFAULT_BUCKET, 0, false);
        assertEq(balBefore - bzz.balanceOf(payer), _charge());
        (address bOwner, uint8 bDepth,,,,) = stamp.batches(id);
        assertEq(bOwner, chunkSigner);
        assertEq(bDepth, DEFAULT_DEPTH);
    }

    function test_fork_trigger_happyTopup() public forkOnly {
        vm.prank(owner);
        bytes32 id =
            registry.createVolume(chunkSigner, DEFAULT_DEPTH, DEFAULT_BUCKET, 0, false);
        vm.roll(block.number + 5);

        uint256 balBefore = bzz.balanceOf(payer);
        registry.trigger(id);
        assertLt(bzz.balanceOf(payer), balBefore);
    }

    function test_fork_trigger_zeroDeficit_noop() public forkOnly {
        vm.prank(owner);
        bytes32 id =
            registry.createVolume(chunkSigner, DEFAULT_DEPTH, DEFAULT_BUCKET, 0, false);
        uint256 balBefore = bzz.balanceOf(payer);
        registry.trigger(id);
        assertEq(bzz.balanceOf(payer), balBefore);
    }

    function test_fork_trigger_idempotence_sameBlock() public forkOnly {
        vm.prank(owner);
        bytes32 id =
            registry.createVolume(chunkSigner, DEFAULT_DEPTH, DEFAULT_BUCKET, 0, false);
        vm.roll(block.number + 5);
        registry.trigger(id);
        uint256 balAfter1 = bzz.balanceOf(payer);
        registry.trigger(id);
        assertEq(bzz.balanceOf(payer), balAfter1);
    }

    function test_fork_activeSet_pagination_moderate() public forkOnly {
        uint256 n = 30;
        for (uint256 i = 0; i < n; ++i) {
            vm.prank(owner);
            registry.createVolume(chunkSigner, DEFAULT_DEPTH, DEFAULT_BUCKET, 0, false);
        }
        assertEq(registry.getActiveVolumeCount(), n);
        VolumeRegistry.VolumeView[] memory page = registry.getActiveVolumes(0, 20);
        assertEq(page.length, 20);
        VolumeRegistry.VolumeView[] memory rest = registry.getActiveVolumes(20, 20);
        assertEq(rest.length, 10);
    }
}
