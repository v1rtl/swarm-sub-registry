// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ISafe {
    function getTransactionHash(address to, uint256 value, bytes calldata, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address refundReceiver, uint256 nonce) external view returns (bytes32);
}

contract ComputeHash {
   address constant SAFE = 0x1b5BB8C4Ea0E9B8a9BCd91Cc3B81513dB0bA8766;
    address constant TO = 0xcdfdC3752caaA826fE62531E0000C40546eC56A6;

    function getHash() public view returns (bytes32) {
        bytes memory data = abi.encodeWithSignature("createBatch(address,uint256,uint8,uint8,bytes32,bool)",
            0x3F98263f333820Ff739D0707586c77513B13932A,
            1924176,
            17,
            16,
            bytes32(0x0000000000000000000000000000000000000000000000000000000000000001),
            false
        );
        return ISafe(SAFE).getTransactionHash(TO, 0, data, 0, 0, 0, 0, address(0), address(0), 4);
    }
}