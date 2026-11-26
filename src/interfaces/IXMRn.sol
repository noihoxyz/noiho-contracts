// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

interface IXMRn {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
