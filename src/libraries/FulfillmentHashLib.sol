// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {OrderType} from "../BridgeTypes.sol";

library FulfillmentHashLib {
    bytes32 private constant FULFILLMENT_DOMAIN = keccak256("NOIHO_FULFILLMENT_V1");

    function hash(
        address bridge,
        uint256 orderId,
        address fulfiller,
        OrderType orderType,
        uint256 takerIntentTime,
        bytes32 xmrTxid,
        bytes32 xmrTxSecretKey,
        bytes32 salt
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                FULFILLMENT_DOMAIN,
                block.chainid,
                bridge,
                orderId,
                fulfiller,
                orderType,
                takerIntentTime,
                xmrTxid,
                xmrTxSecretKey,
                salt
            )
        );
    }
}
