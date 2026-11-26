// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {UnwrapRequest} from "../BridgeTypes.sol";

interface IRelayToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IRelayBridge {
    function requestUnwrapFor(address orderer, UnwrapRequest calldata request) external returns (uint256);
}

contract CoreUnwrapRelay {
    IRelayToken public immutable token;
    IRelayBridge public immutable bridge;
    uint256 public immutable refundDelay;

    uint256 public nextId = 1;
    mapping(uint256 => bytes32) public pending;

    uint256 private constant MASK48 = (1 << 48) - 1;
    uint256 private constant HASH_MASK = ~uint256((1 << 96) - 1);
    uint256 private locked = 1;

    event Queued(uint256 indexed id, address indexed orderer, uint256 amountXMRn, uint256 amountXMR, string xmrAddress);
    event Forwarded(uint256 indexed id, uint256 indexed orderId, address indexed orderer);
    event Refunded(uint256 indexed id, address indexed orderer, uint256 amountXMRn);

    error OnlyToken();
    error InvalidRequest();
    error UnknownRequest();
    error RefundNotYetAllowed();
    error TransferFailed();
    error Reentrancy();

    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    constructor(address token_, address bridge_, uint256 refundDelay_) {
        if (token_ == address(0) || bridge_ == address(0) || token_.code.length == 0 || bridge_.code.length == 0) {
            revert InvalidRequest();
        }
        token = IRelayToken(token_);
        bridge = IRelayBridge(bridge_);
        refundDelay = refundDelay_;
    }

    function requestUnwrapFor(address orderer, UnwrapRequest calldata r) external returns (uint256 id) {
        if (msg.sender != address(token)) revert OnlyToken();
        if (orderer == address(0) || r.amountXMRn == 0 || r.amountXMR == 0 || r.amountXMR > r.amountXMRn) {
            revert InvalidRequest();
        }
        if (!token.transferFrom(msg.sender, address(this), r.amountXMRn)) revert TransferFailed();
        unchecked {
            id = nextId++;
        }
        pending[id] = bytes32((uint256(commitment(orderer, r)) & HASH_MASK) | (block.timestamp << 48) | block.number);
        emit Queued(id, orderer, r.amountXMRn, r.amountXMR, r.xmrAddress);
    }

    function forward(uint256 id, address orderer, UnwrapRequest calldata r) external nonReentrant returns (uint256 orderId) {
        _consume(id, orderer, r);
        if (!token.approve(address(bridge), r.amountXMRn)) revert TransferFailed();
        orderId = bridge.requestUnwrapFor(orderer, r);
        emit Forwarded(id, orderId, orderer);
    }

    function refund(uint256 id, address orderer, UnwrapRequest calldata r) external nonReentrant {
        uint256 queuedAt = _consume(id, orderer, r);
        if (msg.sender != orderer && block.timestamp < queuedAt + refundDelay) revert RefundNotYetAllowed();
        if (!token.transfer(orderer, r.amountXMRn)) revert TransferFailed();
        emit Refunded(id, orderer, r.amountXMRn);
    }

    function commitment(address orderer, UnwrapRequest calldata r) public pure returns (bytes32) {
        return keccak256(abi.encode(orderer, r.amountXMRn, r.amountXMR, keccak256(bytes(r.xmrAddress))));
    }

    function queuedAt(uint256 id) external view returns (uint256 timestamp, uint256 blockNumber) {
        uint256 slot = uint256(pending[id]);
        return ((slot >> 48) & MASK48, slot & MASK48);
    }

    function _consume(uint256 id, address orderer, UnwrapRequest calldata r) private returns (uint256 queuedTime) {
        uint256 slot = uint256(pending[id]);
        if (slot == 0 || (slot & HASH_MASK) != (uint256(commitment(orderer, r)) & HASH_MASK)) revert UnknownRequest();
        delete pending[id];
        return (slot >> 48) & MASK48;
    }
}
