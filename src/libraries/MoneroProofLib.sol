// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {INoihoBridge} from "../interfaces/INoihoBridge.sol";

library MoneroProofLib {
    uint256 private constant MONERO_SCALAR_ORDER = 0x1000000000000000000000000000000014def9dea2f79cd65812631a5cf5d3ed;
    uint256 private constant MAX_XMR_ADDRESS_LENGTH = 106;

    function isCanonicalTxSecretKey(bytes32 txSecretKey) internal pure returns (bool) {
        uint256 scalar = 0;
        for (uint256 i = 0; i < 32; i++) {
            scalar |= uint256(uint8(txSecretKey[i])) << (i * 8);
        }
        return scalar > 0 && scalar < MONERO_SCALAR_ORDER;
    }

    function requireCanonicalTxSecretKey(bytes32 txSecretKey) internal pure {
        require(isCanonicalTxSecretKey(txSecretKey), INoihoBridge.InvalidTransactionSecretKey());
    }

    function transactionKey(bytes32 txid, bytes32 txSecretKey) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(txid, txSecretKey));
    }

    function validateXmrAddress(string calldata xmrAddress) internal pure {
        uint256 length = bytes(xmrAddress).length;
        require(length > 0 && length <= MAX_XMR_ADDRESS_LENGTH, INoihoBridge.InvalidXMRAddressLength());
    }
}
