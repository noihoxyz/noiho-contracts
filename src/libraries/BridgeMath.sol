// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {INoihoBridge} from "../interfaces/INoihoBridge.sol";

library BridgeMath {
    uint256 internal constant BPS = 10_000;

    function wrapOutput(uint256 amount, uint256 fixedToll, uint256 percentageToll) internal pure returns (uint256) {
        return (amount - fixedToll) * (BPS - percentageToll) / BPS;
    }

    function requiredWitnessBond(uint256 amountXMRn, uint256 ratioBps) internal pure returns (uint256) {
        return amountXMRn * ratioBps / BPS;
    }

    function minimumWitnessFeeRate(uint64 hypePrice, uint64 xmrPrice, uint256 chainId) internal pure returns (uint256) {
        require(chainId == 998 || chainId == 999, INoihoBridge.UnsupportedChain());
        uint256 multiplier = chainId == 999 ? 10000 : 1000;
        return uint256(xmrPrice) * multiplier / uint256(hypePrice);
    }
}
