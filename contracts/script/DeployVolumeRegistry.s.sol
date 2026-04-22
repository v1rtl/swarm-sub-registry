// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {VolumeRegistry} from "../src/VolumeRegistry.sol";
import {IPostageStamp} from "../src/interfaces/IPostageStamp.sol";

contract DeployVolumeRegistry is Script {
    function run() external {
        // Sepolia defaults; override via env vars for other chains
        address bzz = vm.envOr(
            "BZZ",
            address(0x543dDb01Ba47acB11de34891cD86B675F04840db)
        );
        address stamp = vm.envOr(
            "POSTAGE_STAMP",
            address(0xcdfdC3752caaA826fE62531E0000C40546eC56A6)
        );
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        VolumeRegistry reg = new VolumeRegistry(
            IERC20(bzz),
            IPostageStamp(stamp)
        );
        vm.stopBroadcast();

        console2.log("VolumeRegistry deployed at:", address(reg));
        console2.log("  BZZ token:           ", bzz);
        console2.log("  PostageStamp:       ", stamp);
    }
}
