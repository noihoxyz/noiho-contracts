// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

enum OrderType {
    uninitiated,
    wrap,
    unwrap
}

enum OrderStatus {
    uninitiated,
    open,
    intended,
    filled,
    witnessedSuccess,
    witnessedFail,
    finalizedNoDispute,
    disputed,
    finalizedInFavorOfWitness,
    finalizedInFavorOfDisputer,
    cancelled,
    error
}

struct Order {
    address orderer;
    OrderType orderType;
    OrderStatus orderStatus;
    OrderStatus statusBeforeDispute;
    uint40 orderCreationTime;
    address maker;
    uint96 amountXMRn;
    address taker;
    uint96 witnessFee;
    address witnessAddress;
    uint96 amountXMR;
    address disputer;
    uint96 disputeBond;
    uint40 takerIntentTime;
    uint40 fulfillmentTime;
    uint40 witnessTime;
    uint40 fulfillmentCommitmentBlock;
    uint96 heldWitnessBond;
    bytes32 fulfillmentCommitment;
    bytes32 xmrTxid;
    bytes32 xmrTxSecretKey;
    string xmrAddress;
}

struct OrderData {
    uint256 orderId;
    OrderType orderType;
    OrderStatus orderStatus;
    uint256 orderCreationTime;
    address orderer;
    string xmrAddress;
    bytes32 xmrTxid;
    bytes32 xmrTxSecretKey;
    address ethAddress;
    uint256 amountXMR;
    uint256 amountXMRn;
    address witnessAddress;
    uint256 witnessFee;
    address maker;
    address taker;
    uint256 takerIntentTime;
    uint256 fulfillmentTime;
    uint256 witnessTime;
    address disputer;
    bytes32 fulfillmentCommitment;
    uint256 fulfillmentCommitmentBlock;
}

struct LiquidityProviderConfig {
    string xmrAddress;
    uint256 fixedToll;
    uint256 percentageToll;
    uint256 minPerTxn;
    bool isLiquidityProvider;
}

struct WitnessData {
    address witnessAddress;
    uint256 bond;
    uint256 bondHeld;
    bool active;
}

struct WrapRequest {
    uint256 amountXMR;
    address liquidityProviderAddress;
    uint256 witnessFee;
    address recipient;
    uint256 minAmountXMRn;
}

struct UnwrapRequest {
    uint256 amountXMRn;
    uint256 amountXMR;
    string xmrAddress;
}

enum FilterType {
    Orderer,
    Status,
    StatusAndMaker,
    StatusAndTaker
}

struct OrderFilter {
    FilterType filterType;
    OrderStatus status;
    address addr;
}
