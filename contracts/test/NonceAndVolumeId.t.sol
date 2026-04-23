// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {RegistryFixture} from "./fixtures/RegistryFixture.sol";

/// @notice TEST-PLAN §3.10 — Nonce monotonicity and batch-id derivation.
contract NonceAndVolumeIdTest is RegistryFixture {
    function test_createVolume_nonceIncrements() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * 10);

        uint256 n0 = registry.nextNonce();
        bytes32 id0 = _createDefaultVolume(OWNER, CHUNK_SIGNER);
        uint256 n1 = registry.nextNonce();
        bytes32 id1 = _createDefaultVolume(OWNER, CHUNK_SIGNER);
        uint256 n2 = registry.nextNonce();

        assertEq(n1, n0 + 1);
        assertEq(n2, n0 + 2);

        assertEq(id0, keccak256(abi.encode(address(registry), bytes32(n0))));
        assertEq(id1, keccak256(abi.encode(address(registry), bytes32(n1))));
    }

    function test_volumeId_matchesKeccak() public {
        _activateAccount(OWNER, PAYER, _expectedCreateCharge(DEFAULT_DEPTH) * 4);
        uint256 n = registry.nextNonce();
        bytes32 id = _createDefaultVolume(OWNER, CHUNK_SIGNER);
        assertEq(id, keccak256(abi.encode(address(registry), bytes32(n))));
    }
}
