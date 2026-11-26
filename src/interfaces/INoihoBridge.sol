// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {OrderStatus, OrderData, LiquidityProviderConfig, WrapRequest, UnwrapRequest} from "../BridgeTypes.sol";

interface INoihoBridge {

    event orderPlaced(uint256 indexed orderId);
    event intentSubmitted(uint256 indexed orderId, address _address);
    event orderReset(uint256 indexed orderId);
    event orderFulfilled(uint256 indexed orderId);
    event orderCancelled(uint256 indexed orderId);
    event orderWitnessed(uint256 indexed orderId);
    event orderDisputed(uint256 indexed orderId);
    event orderFinalized(uint256 indexed orderId);
    event FulfillmentCommitted(
        uint256 indexed orderId, address indexed fulfiller, bytes32 commitment, uint256 commitmentBlock
    );
    event FulfillmentRemoved(uint256 indexed orderId, address indexed fulfiller);
    event StuckOrderResolved(uint256 indexed orderId, bool success, address resolver);

    event liquidityProviderRegistered(address liquidityProvider);
    event liquidityProviderUpdated(address liquidityProvider);
    event liquidityAdded(address liquidityProvider, uint256 amount);
    event liquidityRemoved(address liquidityProvider, uint256 amount);
    event liquidityHeld(address liquidityProvider, uint256 amount);
    event liquidityReleased(address liquidityProvider, uint256 amount);
    event WitnessAdded(address _witness);
    event WitnessRemoved(address _witness);
    event WitnessBondPaid(address _witness, uint256 _bond);
    event WitnessBondHeld(uint256 indexed _orderId, uint256 _amount, address _witness);
    event WitnessBondReleased(uint256 indexed _orderId, uint256 _amount, address _witness);
    event WitnessBondSlashed(uint256 indexed _orderId, uint256 _amount, address _witness);
    event WitnessBondWithdrawn(uint256 _amount, address _witness);
    event ETHCredited(address indexed to, uint256 amount);
    event PaymentQuarantined(
        address indexed intendedRecipient, address indexed vault, address indexed asset, uint256 amount
    );

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address account);
    event Unpaused(address account);
    event AuthorizedCallerUpdated(address indexed caller, bool authorized);
    event HypePerpIndexUpdated(uint32 index);
    event XmrPerpIndexUpdated(uint32 index);
    event WitnessBondHoldTimeUpdated(uint256 duration);
    event OrderCancellationTimeUpdated(uint256 duration);
    event IntentCancellationTimeUpdated(uint256 duration);
    event StuckOrderTimeoutUpdated(uint256 duration);
    event DisputeBondThresholdUpdated(uint256 threshold);
    event WitnessSlashRatioUpdated(uint256 ratioBps);
    event SanctionsAdminUpdated(address indexed admin, bool isAdmin);
    event SanctionsVaultUpdated(address indexed previousVault, address indexed newVault);
    event AddressSanctioned(address indexed _address);
    event AddressUnsanctioned(address indexed _address);
    event SanctionedStakeQuarantined(
        address indexed party, address indexed vault, uint256 freeLiquidity, uint256 freeWitnessBond, uint256 pendingEth
    );

    error AddressIsNotAnActiveWitness();
    error AddressIsNotSanctioned();
    error AmountMustBeGreaterThan0();
    error BondHeldByWitness();
    error BondMustBeGreaterThan0();
    error BondReleaseNotAvailableYet();
    error CanOnlyRemoveOwnLiquidity();
    error CannotSanctionSanctionsVault();
    error CommitmentMustBeFromAPriorBlock();
    error ContractNotPaused();
    error ContractPaused();
    error CoreTokenRescueProhibited();
    error DisputePeriodExpired();
    error ETHTransferFailed();
    error FulfillmentAlreadyCommitted();
    error FulfillmentCommitmentWindowExpired();
    error FulfillmentNotCommitted();
    error FulfillmentRemovalWindowExpired();
    error FulfillmentWindowExpired();
    error InsufficientFees();
    error InsufficientLiquidity();
    error InsufficientUnheldBond();
    error InvalidAmount();
    error InvalidCursor();
    error InvalidDependency();
    error InvalidFulfillmentCommitment();
    error InvalidFulfillmentSalt();
    error InvalidLiquidityProvider();
    error InvalidOraclePrice();
    error InvalidOrderRange();
    error InvalidOwner();
    error InvalidPageSize();
    error InvalidReceiver();
    error InvalidRecipient();
    error InvalidSanctionedAddress();
    error InvalidSanctionsVault();
    error InvalidTollConfiguration();
    error InvalidTransactionId();
    error InvalidTransactionSecretKey();
    error InvalidWitnessAddress();
    error InvalidXMRAddressLength();
    error LessThanMinimumAmount();
    error NoSanctionedDisputer();
    error NotASanctionsAdmin();
    error NotAuthorizedCaller();
    error NotPendingOwner();
    error NotYetStuck();
    error NothingToClaim();
    error OnlyActiveWitness();
    error OnlyBridgeOwner();
    error OnlyFulfiller();
    error OnlyMakerCanDispute();
    error OnlyOrderParty();
    error OnlyOrderer();
    error OnlyOrdererCanCancel();
    error OnlyOrdererDuringCancellationWindow();
    error OnlyOrdererOrTakerCanDispute();
    error OnlyOwnerOrAccount();
    error OnlyTaker();
    error OnlyTakerCanDispute();
    error OnlyTakerDuringIntentWindow();
    error OraclePrecompileFailed();
    error OraclePriceNotInitialized();
    error OrderDoesNotExist();
    error OrderNotDisputable();
    error OrderNotDisputed();
    error OrderNotFilled();
    error OrderNotIntended();
    error OrderNotOpen();
    error OrderNotReleasable();
    error OrderNotUnwrapping();
    error OrderPageTooLarge();
    error OutputBelowMinimum();
    error ReentrantCall();
    error SanctionedAddress();
    error SanctionedOrderParty();
    error SanctionsVaultIsSanctioned();
    error SlashRatioOutOfBounds();
    error TokenTransferFailed();
    error TokenTransferFromFailed();
    error TransactionAlreadyUsed();
    error TransferFailed();
    error UnsupportedChain();
    error WitnessBondInsufficient();
    error WitnessFeeBelowFloor();
    error WitnessFeeMismatch();
    error WitnessFeeTooLow();
    error ZeroXMRAmount();
    error ZeroXMRnAmount();

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;

    function oraclePx(uint32 index) external view returns (uint64);
    function updateCachedOraclePx(uint32 index) external returns (bool);

    function requestWrap(WrapRequest calldata _request) external payable returns (uint256);
    function fulfillWrap(uint256 _orderId, bytes32 _xmrTxid, bytes32 _xmrTxSecretKey, bytes32 _salt)
        external
        returns (bool);

    function authorizedCallers(address c) external view returns (bool);
    function setAuthorizedCaller(address _caller, bool _authorized) external;
    function requestUnwrap(UnwrapRequest calldata _request) external returns (uint256);
    function requestUnwrapFor(address _orderer, UnwrapRequest calldata _request) external returns (uint256);
    function submitUnwrapIntent(uint256 _orderId, uint256 _witnessFee) external payable returns (bool);
    function removeUnwrapIntent(uint256 _orderId) external returns (bool);
    function fulfillUnwrap(uint256 _orderId, bytes32 _xmrTxid, bytes32 _xmrTxSecretKey, bytes32 _salt)
        external
        returns (bool);

    function commitFulfillment(uint256 _orderId, bytes32 _commitment) external returns (bool);
    function removeFulfillment(uint256 _orderId) external returns (bool);
    function cancel(uint256 _orderId) external returns (bool);
    function pendingETH(address who) external view returns (uint256);
    function claimETH() external returns (uint256 amount);
    function claimETHTo(address payable _receiver) external returns (uint256 amount);

    function registerLiquidityProvider(
        string calldata _xmrAddress,
        uint256 _fixedToll,
        uint256 _percentageToll,
        uint256 _minPerTxn
    ) external returns (bool);
    function addLiquidity(address _liquidityProvider, uint256 _amount) external returns (bool);
    function removeLiquidity(address _liquidityProvider, uint256 _amount) external returns (bool);
    function getLiquidityProviderConfig(address _lp) external view returns (LiquidityProviderConfig memory);
    function getNetLiquidity(address _lp) external view returns (uint256);
    function isLiquidityProvider(address _lp) external view returns (bool);
    function availableLiquidity(address _lp) external view returns (uint256);
    function heldLiquidity(address _lp) external view returns (uint256);
    function getAllLiquidityProviders() external view returns (address[] memory);
    function getLiquidityProviderCount() external view returns (uint256);
    function getProviderForAmount(
        uint256 _amount,
        uint256 _maxFixedToll,
        uint256 _maxPercentageToll,
        uint256 _cursor,
        uint256 _limit
    ) external view returns (address provider, uint256 nextCursor, bool done);

    function isActiveWitness(address a) external view returns (bool);
    function getWitnessCount() external view returns (uint256);
    function getWitnessBond(address a) external view returns (uint256);
    function getNetBond(address a) external view returns (uint256);
    function getGlobalMinFeeParameter() external view returns (uint256);
    function heldWitnessBond(uint256 _orderId) external view returns (uint256);
    function witnesses(address a) external view returns (address, uint256, uint256, bool);
    function upsertWitness(address _address, uint256 _bond) external returns (bool);
    function removeWitness(address _address) external returns (bool);
    function withdrawBond(address _witness, uint256 _amount) external returns (bool);
    function witnessOrder(uint256 _orderId, bool _confirmed) external returns (uint256);
    function releaseBond(uint256 _orderId) external returns (bool);

    function lastStatus(uint256 orderId) external view returns (OrderStatus);
    function dispute(uint256 _orderId) external returns (bool);
    function resolveDispute(uint256 _orderId, bool _isWitnessAtFault) external returns (bool);

    function getOrder(uint256 _orderId) external view returns (OrderData memory);
    function isTransactionUsed(bytes32 _txid, bytes32 _txSecretKey) external view returns (bool);
    function getMaxOrderId() external view returns (uint256);
    function MAX_PAGE_SIZE() external pure returns (uint256);
    function getOrderByOrdererPaginatedInclusive(address _orderer, uint256 _start, uint256 _end)
        external
        view
        returns (OrderData[] memory);
    function getOrderByStatusPaginatedInclusive(OrderStatus _status, uint256 _start, uint256 _end)
        external
        view
        returns (OrderData[] memory);
    function getOrderByStatusAndMakerPaginatedInclusive(
        OrderStatus _status,
        address _maker,
        uint256 _start,
        uint256 _end
    ) external view returns (OrderData[] memory);
    function getOrderByStatusAndTakerPaginatedInclusive(
        OrderStatus _status,
        address _taker,
        uint256 _start,
        uint256 _end
    ) external view returns (OrderData[] memory);
    function countByStatusInRange(OrderStatus status, uint256 firstOrder, uint256 lastOrder)
        external
        view
        returns (uint256);
    function getOrdersPagedInclusive(uint256 _startOrderId, uint256 _endOrderId)
        external
        view
        returns (uint256 count, OrderData[] memory result);

    function noihoMonero() external view returns (address);
    function hypePerpIndex() external view returns (uint32);
    function xmrPerpIndex() external view returns (uint32);
    function witnessBondHoldTime() external view returns (uint256);
    function orderCancellationTime() external view returns (uint256);
    function intentCancellationTime() external view returns (uint256);
    function stuckOrderTimeout() external view returns (uint256);
    function disputeBondThreshold() external view returns (uint256);
    function witnessSlashRatioBps() external view returns (uint256);
    function setHypePerpIndex(uint32 _i) external;
    function setXmrPerpIndex(uint32 _i) external;
    function setWitnessBondHoldTime(uint256 _t) external;
    function setOrderCancellationTime(uint256 _t) external;
    function setIntentCancellationTime(uint256 _t) external;
    function setStuckOrderTimeout(uint256 _timeout) external;
    function setDisputeBondThreshold(uint256 _threshold) external;
    function setWitnessSlashRatioBps(uint256 _bps) external;
    function paused() external view returns (bool);
    function pause() external;
    function unpause() external;
    function rescueToken(address _token, uint256 _amount) external returns (bool);
    function adminResolveStuckOrder(uint256 _orderId, bool _success) external returns (bool);

    function isSanctioned(address _address) external view returns (bool);
    function sanctionsAdmin(address _address) external view returns (bool);
    function sanctionsVault() external view returns (address);
    function setSanctionsAdmin(address _admin, bool _isAdmin) external;
    function setSanctionsVault(address _vault) external;
    function addSanctionedAddress(address _address) external;
    function removeSanctionedAddress(address _address) external;
    function addSanctionedAddresses(address[] calldata _addresses) external;
    function removeSanctionedAddresses(address[] calldata _addresses) external;
    function quarantineSanctionedStake(address _party) external returns (uint256 tokenAmount, uint256 ethAmount);
}
