// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

library OracleReaderLib {
    enum ReadStatus {
        Success,
        CallFailed,
        InvalidPrice
    }
    address private constant ORACLE = 0x0000000000000000000000000000000000000807;

    function readPrice(uint32 index) internal view returns (ReadStatus, uint64) {
        (bool ok, bytes memory result) = ORACLE.staticcall(abi.encode(index));
        if (!ok || result.length < 32) return (ReadStatus.CallFailed, 0);
        uint256 raw = abi.decode(result, (uint256));
        if (raw == 0 || raw > type(uint64).max) return (ReadStatus.InvalidPrice, 0);
        return (ReadStatus.Success, uint64(raw));
    }
}
