// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console2} from "forge-std/Script.sol";

import {VolumeRegistry} from "../src/VolumeRegistry.sol";

contract DeployVolumeRegistry is Script {
    function run() external {
        // Sepolia defaults; override via env vars for other chains.
        address bzz = vm.envOr("BZZ", address(0x543dDb01Ba47acB11de34891cD86B675F04840db));
        address stamp = vm.envOr(
            "POSTAGE_STAMP", address(0xcdfdC3752caaA826fE62531E0000C40546eC56A6)
        );
        // On Sepolia PostageStamp.minimumValidityBlocks() == 12; demo runway = 12.
        uint64 graceBlocks = uint64(vm.envOr("GRACE_BLOCKS", uint256(12)));
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        VolumeRegistry reg = new VolumeRegistry(stamp, bzz, graceBlocks);
        vm.stopBroadcast();

        console2.log("VolumeRegistry deployed at:", address(reg));
        console2.log("  BZZ token:    ", bzz);
        console2.log("  PostageStamp: ", stamp);
        console2.log("  graceBlocks:  ", uint256(graceBlocks));
    }
}
