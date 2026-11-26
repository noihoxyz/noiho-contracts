// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {
    OrderType,
    OrderStatus,
    Order,
    OrderData,
    LiquidityProviderConfig,
    WitnessData,
    WrapRequest,
    UnwrapRequest,
    FilterType,
    OrderFilter
} from "./BridgeTypes.sol";
import {INoihoBridge} from "./interfaces/INoihoBridge.sol";
import {IXMRn} from "./interfaces/IXMRn.sol";
import {MoneroProofLib} from "./libraries/MoneroProofLib.sol";
import {FulfillmentHashLib} from "./libraries/FulfillmentHashLib.sol";
import {BridgeMath} from "./libraries/BridgeMath.sol";
import {OracleReaderLib} from "./libraries/OracleReaderLib.sol";

contract NoihoBridge is INoihoBridge {
    uint256 private constant PAGE_SIZE_LIMIT = 250;
    uint256 private constant MAX_PROVIDER_SEARCH_PAGE_SIZE = 250;

    uint256 private constant MIN_SLASH_RATIO_BPS = 10_000;
    uint256 private constant MAX_SLASH_RATIO_BPS = 100_000;

    uint256 private constant MIN_WITNESS_FEE = 1 gwei;

    uint256 private constant FEE_PUSH_GAS = 30_000;

    address private immutable _noihoMonero;

    address private _bridgeOwner;
    bool private _paused;
    uint32 private _hypePerpIndex;
    uint32 private _xmrPerpIndex;

    address private _pendingOwner;

    address private _sanctionsVault;

    uint256 private _witnessBondHoldTime;
    uint256 private _orderCancellationTime;
    uint256 private _intentCancellationTime;
    uint256 private _disputeBondThreshold;

    uint256 private _stuckOrderTimeout;

    uint256 private _witnessSlashRatioBps;

    uint256 private _nonce;
    mapping(uint256 => Order) private _orders;

    mapping(bytes32 => bool) private _usedTransactionIds;

    mapping(address => LiquidityProviderConfig) private _lpConfigs;
    mapping(address => uint256) private _availableLiquidity;
    mapping(address => uint256) private _heldLiquidity;
    address[] private _lpArray;

    mapping(address => WitnessData) private _witnesses;
    address[] private _witnessesArray;
    mapping(address => uint256) private _witnessIndexPlusOne;

    mapping(address => bool) private _authorizedCallers;
    mapping(address => bool) private _sanctioned;
    mapping(address => bool) private _sanctionsAdmin;

    mapping(address => uint256) private _pendingETH;
    mapping(uint32 => uint64) private _cachedOraclePx;

    bool private transient _entered;

    modifier onlyOwner() {
        require(msg.sender == _bridgeOwner, OnlyBridgeOwner());
        _;
    }

    modifier whenNotPaused() {
        require(!_paused, ContractPaused());
        _;
    }

    modifier whenPaused() {
        require(_paused, ContractNotPaused());
        _;
    }

    modifier nonReentrant() {
        require(!_entered, ReentrantCall());
        _entered = true;
        _;
        _entered = false;
    }

    modifier notSanctioned(address account) {
        require(!_sanctioned[account], SanctionedAddress());
        _;
    }

    modifier onlySanctionsAdmin() {
        require(_sanctionsAdmin[msg.sender], NotASanctionsAdmin());
        require(!_sanctioned[msg.sender], SanctionedAddress());
        _;
    }

    modifier onlyWitness() {
        require(_witnesses[msg.sender].active, OnlyActiveWitness());
        _;
    }

    modifier onlyOrderer(uint256 orderId) {
        require(msg.sender == _orders[orderId].orderer, OnlyOrderer());
        _;
    }

    modifier onlyTaker(uint256 orderId) {
        require(msg.sender == _orders[orderId].taker, OnlyTaker());
        _;
    }

    modifier onlyOpenOrder(uint256 orderId) {
        _requireOrderStatus(orderId, OrderStatus.open);
        _;
    }

    modifier onlyIntendedOrder(uint256 orderId) {
        _requireOrderStatus(orderId, OrderStatus.intended);
        _;
    }

    modifier onlyFilledOrder(uint256 orderId) {
        _requireOrderStatus(orderId, OrderStatus.filled);
        _;
    }

    constructor(address owner_, address token_, address sanctionsVault_) {
        require(owner_ != address(0), InvalidOwner());
        require(token_ != address(0), InvalidDependency());
        require(sanctionsVault_ != address(0) && sanctionsVault_ != address(this), InvalidSanctionsVault());
        require(block.chainid == 998 || block.chainid == 999, UnsupportedChain());
        _bridgeOwner = owner_;
        _noihoMonero = token_;
        _sanctionsVault = sanctionsVault_;
        bool testnet = block.chainid == 998;
        _hypePerpIndex = testnet ? 135 : 159;
        _xmrPerpIndex = testnet ? 202 : 224;
        _witnessBondHoldTime = 7 days;
        _orderCancellationTime = 4 hours;
        _intentCancellationTime = 4 hours;
        _disputeBondThreshold = 1e12;
        _stuckOrderTimeout = 30 days;
        _witnessSlashRatioBps = 12_000;
        emit OwnershipTransferred(address(0), owner_);
    }

    function owner() external view returns (address) {
        return _bridgeOwner;
    }

    function pendingOwner() external view returns (address) {
        return _pendingOwner;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), InvalidOwner());
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(_bridgeOwner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == _pendingOwner, NotPendingOwner());
        emit OwnershipTransferred(_bridgeOwner, msg.sender);
        _bridgeOwner = msg.sender;
        delete _pendingOwner;
    }

    function oraclePx(uint32 index) external view returns (uint64) {
        return _cachedPrice(index);
    }

    function updateCachedOraclePx(uint32 index) external returns (bool) {
        return _refreshPrice(index, true);
    }

    function requestWrap(WrapRequest calldata _request)
        external
        payable
        whenNotPaused
        nonReentrant
        notSanctioned(msg.sender)
        notSanctioned(_request.liquidityProviderAddress)
        notSanctioned(_request.recipient)
        returns (uint256 orderId)
    {
        uint256 amountXMRn = _quoteWrap(_request);

        require(msg.value == _request.witnessFee, WitnessFeeMismatch());
        _tryRefreshPrices();

        address maker = _request.liquidityProviderAddress;
        _holdLiquidity(maker, amountXMRn);
        Order storage o;
        (orderId, o) =
            _newOrder(msg.sender, OrderType.wrap, OrderStatus.intended, maker, amountXMRn, _request.amountXMR);
        o.taker = _request.recipient;
        o.witnessFee = _toUint96(_request.witnessFee);
        o.takerIntentTime = _now();
        o.xmrAddress = _lpConfigs[maker].xmrAddress;
        emit intentSubmitted(orderId, msg.sender);
    }

    function fulfillWrap(uint256 _orderId, bytes32 _xmrTxid, bytes32 _xmrTxSecretKey, bytes32 _salt)
        external
        onlyIntendedOrder(_orderId)
        onlyOrderer(_orderId)
        nonReentrant
        whenNotPaused
        returns (bool)
    {
        _fulfill(_orderId, _xmrTxid, _xmrTxSecretKey, _salt);
        return true;
    }

    function authorizedCallers(address c) external view returns (bool) {
        return _authorizedCallers[c];
    }

    function setAuthorizedCaller(address _caller, bool _authorized) external onlyOwner {
        _authorizedCallers[_caller] = _authorized;
        emit AuthorizedCallerUpdated(_caller, _authorized);
    }

    function requestUnwrap(UnwrapRequest calldata _request)
        external
        nonReentrant
        whenNotPaused
        notSanctioned(msg.sender)
        returns (uint256)
    {
        _validateAndPull(_request);
        return _placeUnwrap(msg.sender, _request);
    }

    function requestUnwrapFor(address _orderer, UnwrapRequest calldata _request)
        external
        nonReentrant
        whenNotPaused
        notSanctioned(_orderer)
        returns (uint256)
    {
        require(_authorizedCallers[msg.sender], NotAuthorizedCaller());
        _validateAndPull(_request);
        return _placeUnwrap(_orderer, _request);
    }

    function submitUnwrapIntent(uint256 _orderId, uint256 _witnessFee)
        external
        payable
        onlyOpenOrder(_orderId)
        whenNotPaused
        nonReentrant
        notSanctioned(msg.sender)
        returns (bool)
    {
        require(msg.value == _witnessFee, InsufficientFees());

        Order storage o = _orders[_orderId];
        require(!_sanctioned[o.orderer], SanctionedOrderParty());
        _requireWitnessFee(o.amountXMRn, _witnessFee);
        _tryRefreshPrices();

        o.taker = msg.sender;
        o.witnessFee = _toUint96(_witnessFee);
        o.takerIntentTime = _now();
        o.orderStatus = OrderStatus.intended;
        emit intentSubmitted(_orderId, msg.sender);
        return true;
    }

    function removeUnwrapIntent(uint256 _orderId)
        external
        onlyIntendedOrder(_orderId)
        nonReentrant
        whenNotPaused
        returns (bool)
    {
        Order storage o = _orders[_orderId];
        require(o.orderType == OrderType.unwrap, OrderNotUnwrapping());
        address taker = o.taker;
        require(msg.sender == o.maker || msg.sender == taker, OnlyOrderParty());

        if (block.timestamp <= o.takerIntentTime + _intentCancellationTime) {
            require(msg.sender == taker, OnlyTakerDuringIntentWindow());
        }

        uint256 fee = o.witnessFee;
        o.taker = address(0);
        o.witnessFee = 0;
        o.takerIntentTime = 0;
        o.orderStatus = OrderStatus.open;
        _clearCommitment(o);

        _payETHOrCredit(o.orderer, fee);
        emit orderReset(_orderId);
        return true;
    }

    function fulfillUnwrap(uint256 _orderId, bytes32 _xmrTxid, bytes32 _xmrTxSecretKey, bytes32 _salt)
        external
        onlyIntendedOrder(_orderId)
        onlyTaker(_orderId)
        nonReentrant
        whenNotPaused
        returns (bool)
    {
        _fulfill(_orderId, _xmrTxid, _xmrTxSecretKey, _salt);
        return true;
    }

    function commitFulfillment(uint256 _orderId, bytes32 _commitment)
        external
        nonReentrant
        whenNotPaused
        onlyIntendedOrder(_orderId)
        returns (bool)
    {
        Order storage o = _orders[_orderId];
        _requireFulfiller(o);
        require(_commitment != bytes32(0), InvalidFulfillmentCommitment());
        require(o.fulfillmentCommitment == bytes32(0), FulfillmentAlreadyCommitted());
        require(block.timestamp <= _fulfillmentDeadline(o), FulfillmentCommitmentWindowExpired());

        o.fulfillmentCommitment = _commitment;
        o.fulfillmentCommitmentBlock = _blockNumber();
        emit FulfillmentCommitted(_orderId, msg.sender, _commitment, block.number);
        return true;
    }

    function removeFulfillment(uint256 _orderId)
        external
        nonReentrant
        whenNotPaused
        onlyIntendedOrder(_orderId)
        returns (bool)
    {
        Order storage o = _orders[_orderId];
        _requireFulfiller(o);
        require(o.fulfillmentCommitment != bytes32(0), FulfillmentNotCommitted());
        require(block.timestamp <= _fulfillmentDeadline(o), FulfillmentRemovalWindowExpired());

        _clearCommitment(o);
        emit FulfillmentRemoved(_orderId, msg.sender);
        return true;
    }

    function cancel(uint256 _orderId) external nonReentrant whenNotPaused notSanctioned(msg.sender) returns (bool) {
        Order storage o = _orders[_orderId];
        address orderer = o.orderer;
        address maker = o.maker;
        require(msg.sender == maker || msg.sender == o.taker || msg.sender == orderer, OnlyOrderParty());

        if (o.orderType == OrderType.wrap) {
            require(o.orderStatus == OrderStatus.intended, OrderNotIntended());

            if (block.timestamp <= o.takerIntentTime + _orderCancellationTime) {
                require(msg.sender == orderer, OnlyOrdererDuringCancellationWindow());
            }
            o.orderStatus = OrderStatus.cancelled;
            _clearCommitment(o);
            _releaseLiquidity(maker, o.amountXMRn);

            _payETHOrCredit(maker, o.witnessFee);
        } else {
            require(o.orderStatus == OrderStatus.open, OrderNotOpen());
            require(msg.sender == orderer, OnlyOrdererCanCancel());
            o.orderStatus = OrderStatus.cancelled;
            _payToken(orderer, o.amountXMRn);
        }
        emit orderCancelled(_orderId);
        return true;
    }

    function pendingETH(address who) external view returns (uint256) {
        return _pendingETH[who];
    }

    function claimETH() external nonReentrant notSanctioned(msg.sender) returns (uint256 amount) {
        return _claimETH(payable(msg.sender));
    }

    function claimETHTo(address payable _receiver)
        external
        nonReentrant
        notSanctioned(msg.sender)
        notSanctioned(_receiver)
        returns (uint256 amount)
    {
        require(_receiver != address(0) && _receiver != address(this), InvalidReceiver());
        return _claimETH(_receiver);
    }

    function registerLiquidityProvider(
        string calldata _xmrAddress,
        uint256 _fixedToll,
        uint256 _percentageToll,
        uint256 _minPerTxn
    ) external whenNotPaused nonReentrant notSanctioned(msg.sender) returns (bool) {
        MoneroProofLib.validateXmrAddress(_xmrAddress);
        require(_percentageToll < BridgeMath.BPS, InvalidTollConfiguration());
        bool registered = _lpConfigs[msg.sender].isLiquidityProvider;
        _lpConfigs[msg.sender] = LiquidityProviderConfig(_xmrAddress, _fixedToll, _percentageToll, _minPerTxn, true);
        if (registered) {
            emit liquidityProviderUpdated(msg.sender);
        } else {
            _lpArray.push(msg.sender);
            emit liquidityProviderRegistered(msg.sender);
        }
        return true;
    }

    function addLiquidity(address _liquidityProvider, uint256 _amount)
        external
        whenNotPaused
        nonReentrant
        notSanctioned(msg.sender)
        notSanctioned(_liquidityProvider)
        returns (bool)
    {
        _pullToken(msg.sender, _amount);
        _availableLiquidity[_liquidityProvider] += _amount;
        emit liquidityAdded(_liquidityProvider, _amount);
        return true;
    }

    function removeLiquidity(address _liquidityProvider, uint256 _amount)
        external
        whenNotPaused
        nonReentrant
        notSanctioned(msg.sender)
        returns (bool)
    {
        require(msg.sender == _liquidityProvider, CanOnlyRemoveOwnLiquidity());
        require(_amount > 0, AmountMustBeGreaterThan0());
        require(_netLiquidity(_liquidityProvider) >= _amount, InsufficientLiquidity());
        _removeLiquidity(_liquidityProvider, _amount);
        _payToken(_liquidityProvider, _amount);
        return true;
    }

    function getLiquidityProviderConfig(address _lp) external view returns (LiquidityProviderConfig memory) {
        return _lpConfigs[_lp];
    }

    function getNetLiquidity(address _lp) external view returns (uint256) {
        return _netLiquidity(_lp);
    }

    function isLiquidityProvider(address _lp) external view returns (bool) {
        return _lpConfigs[_lp].isLiquidityProvider;
    }

    function availableLiquidity(address _lp) external view returns (uint256) {
        return _availableLiquidity[_lp];
    }

    function heldLiquidity(address _lp) external view returns (uint256) {
        return _heldLiquidity[_lp];
    }

    function getAllLiquidityProviders() external view returns (address[] memory) {
        return _lpArray;
    }

    function getLiquidityProviderCount() external view returns (uint256) {
        return _lpArray.length;
    }

    function getProviderForAmount(
        uint256 _amount,
        uint256 _maxFixedToll,
        uint256 _maxPercentageToll,
        uint256 _cursor,
        uint256 _limit
    ) external view returns (address provider, uint256 nextCursor, bool done) {
        require(_limit > 0 && _limit <= MAX_PROVIDER_SEARCH_PAGE_SIZE, InvalidPageSize());

        uint256 length = _lpArray.length;
        uint256 upper = _cursor == 0 ? length : _cursor;
        require(upper <= length, InvalidCursor());

        uint256 lower = upper > _limit ? upper - _limit : 0;
        for (uint256 i = upper; i > lower; i--) {
            address candidate = _lpArray[i - 1];
            LiquidityProviderConfig storage config = _lpConfigs[candidate];
            if (
                !_sanctioned[candidate] && _netLiquidity(candidate) >= _amount && _amount >= config.minPerTxn
                    && config.fixedToll <= _maxFixedToll && config.percentageToll <= _maxPercentageToll
            ) {
                nextCursor = i - 1;
                return (candidate, nextCursor, nextCursor == 0);
            }
        }

        return (address(0), lower, lower == 0);
    }

    function isActiveWitness(address a) external view returns (bool) {
        return _witnesses[a].active;
    }

    function getWitnessCount() external view returns (uint256) {
        return _witnessesArray.length;
    }

    function getWitnessBond(address a) external view returns (uint256) {
        return _witnesses[a].bond;
    }

    function getNetBond(address a) external view returns (uint256) {
        return _netWitnessBond(a);
    }

    function getGlobalMinFeeParameter() external view returns (uint256) {
        return _minimumWitnessFeeRate();
    }

    function heldWitnessBond(uint256 _orderId) external view returns (uint256) {
        return _orders[_orderId].heldWitnessBond;
    }

    function witnesses(address a) external view returns (address, uint256, uint256, bool) {
        WitnessData storage w = _witnesses[a];
        return (w.witnessAddress, w.bond, w.bondHeld, w.active);
    }

    function upsertWitness(address _address, uint256 _bond)
        external
        nonReentrant
        whenNotPaused
        notSanctioned(msg.sender)
        notSanctioned(_address)
        returns (bool)
    {
        require(_address != address(0), InvalidWitnessAddress());
        require(_bond > 0, BondMustBeGreaterThan0());
        _pullToken(msg.sender, _bond);

        if (_witnessIndexPlusOne[_address] == 0) {
            _witnessesArray.push(_address);
            _witnessIndexPlusOne[_address] = _witnessesArray.length;
            emit WitnessAdded(_address);
        }
        WitnessData storage w = _witnesses[_address];
        w.witnessAddress = _address;
        w.bond += _bond;
        w.active = true;
        emit WitnessBondPaid(_address, _bond);
        return true;
    }

    function removeWitness(address _address)
        external
        nonReentrant
        whenNotPaused
        notSanctioned(msg.sender)
        notSanctioned(_address)
        returns (bool)
    {
        require(msg.sender == _address || msg.sender == _bridgeOwner, OnlyOwnerOrAccount());
        WitnessData storage w = _witnesses[_address];
        require(w.active, AddressIsNotAnActiveWitness());
        require(w.bondHeld == 0, BondHeldByWitness());

        uint256 bond = w.bond;
        uint256 index = _witnessIndexPlusOne[_address] - 1;
        address last = _witnessesArray[_witnessesArray.length - 1];
        _witnessesArray[index] = last;
        _witnessIndexPlusOne[last] = index + 1;
        _witnessesArray.pop();
        delete _witnessIndexPlusOne[_address];
        delete _witnesses[_address];

        _payToken(_address, bond);
        emit WitnessRemoved(_address);
        return true;
    }

    function withdrawBond(address _witness, uint256 _amount)
        external
        whenNotPaused
        nonReentrant
        notSanctioned(msg.sender)
        notSanctioned(_witness)
        returns (bool)
    {
        require(msg.sender == _witness || msg.sender == _bridgeOwner, OnlyOwnerOrAccount());
        require(_netWitnessBond(_witness) >= _amount, InsufficientUnheldBond());
        _witnesses[_witness].bond -= _amount;
        _payToken(_witness, _amount);
        emit WitnessBondWithdrawn(_amount, _witness);
        return true;
    }

    function witnessOrder(uint256 _orderId, bool _confirmed)
        external
        onlyWitness
        nonReentrant
        whenNotPaused
        onlyFilledOrder(_orderId)
        notSanctioned(msg.sender)
        returns (uint256)
    {
        Order storage o = _orders[_orderId];
        uint256 held = BridgeMath.requiredWitnessBond(o.amountXMRn, _witnessSlashRatioBps);
        require(_netWitnessBond(msg.sender) >= held, WitnessBondInsufficient());

        o.orderStatus = _confirmed ? OrderStatus.witnessedSuccess : OrderStatus.witnessedFail;
        o.witnessAddress = msg.sender;
        o.witnessTime = _now();
        o.heldWitnessBond = _toUint96(held);
        _witnesses[msg.sender].bondHeld += held;
        _settlePrincipal(o, _confirmed);
        emit WitnessBondHeld(_orderId, held, msg.sender);

        _payETHOrCredit(msg.sender, o.witnessFee);
        emit orderWitnessed(_orderId);
        return _orderId;
    }

    function releaseBond(uint256 _orderId) external whenNotPaused nonReentrant returns (bool) {
        Order storage o = _orders[_orderId];
        require(msg.sender == o.witnessAddress || msg.sender == _bridgeOwner, OnlyOwnerOrAccount());
        require(_isWitnessed(o.orderStatus), OrderNotReleasable());
        require(block.timestamp > o.witnessTime + _witnessBondHoldTime, BondReleaseNotAvailableYet());

        _finalize(o, _orderId, OrderStatus.finalizedNoDispute);
        return true;
    }

    function lastStatus(uint256 orderId) external view returns (OrderStatus) {
        return _orders[orderId].statusBeforeDispute;
    }

    function dispute(uint256 _orderId) external nonReentrant whenNotPaused notSanctioned(msg.sender) returns (bool) {
        Order storage o = _orders[_orderId];
        OrderStatus status = o.orderStatus;
        require(_isWitnessed(status), OrderNotDisputable());
        require(block.timestamp <= o.witnessTime + _witnessBondHoldTime, DisputePeriodExpired());

        address beneficiary = _authorizeDisputer(o, status);

        uint256 amountXMRn = o.amountXMRn;
        uint256 bond = amountXMRn > _disputeBondThreshold ? amountXMRn / 10 : 0;

        o.statusBeforeDispute = status;
        o.disputer = beneficiary;
        o.disputeBond = _toUint96(bond);
        o.orderStatus = OrderStatus.disputed;
        if (bond > 0) _pullToken(msg.sender, bond);
        emit orderDisputed(_orderId);
        return true;
    }

    function resolveDispute(uint256 _orderId, bool _isWitnessAtFault)
        external
        whenNotPaused
        onlyOwner
        nonReentrant
        returns (bool)
    {
        Order storage o = _orders[_orderId];
        require(o.orderStatus == OrderStatus.disputed, OrderNotDisputed());

        _settleDispute(o, _orderId, _isWitnessAtFault);
        _finalize(
            o,
            _orderId,
            _isWitnessAtFault ? OrderStatus.finalizedInFavorOfDisputer : OrderStatus.finalizedInFavorOfWitness
        );
        return true;
    }

    function getOrder(uint256 _orderId) external view returns (OrderData memory) {
        return _orderData(_orderId);
    }

    function isTransactionUsed(bytes32 _txid, bytes32 _txSecretKey) external view returns (bool) {
        MoneroProofLib.requireCanonicalTxSecretKey(_txSecretKey);
        return _usedTransactionIds[MoneroProofLib.transactionKey(_txid, _txSecretKey)];
    }

    function getMaxOrderId() external view returns (uint256) {
        return _maxOrderId();
    }

    function MAX_PAGE_SIZE() external pure returns (uint256) {
        return PAGE_SIZE_LIMIT;
    }

    function getOrderByOrdererPaginatedInclusive(address _orderer, uint256 _start, uint256 _end)
        external
        view
        returns (OrderData[] memory)
    {
        return _filterPaginated(OrderFilter(FilterType.Orderer, OrderStatus.uninitiated, _orderer), _start, _end);
    }

    function getOrderByStatusPaginatedInclusive(OrderStatus _status, uint256 _start, uint256 _end)
        external
        view
        returns (OrderData[] memory)
    {
        return _filterPaginated(OrderFilter(FilterType.Status, _status, address(0)), _start, _end);
    }

    function getOrderByStatusAndMakerPaginatedInclusive(
        OrderStatus _status,
        address _maker,
        uint256 _start,
        uint256 _end
    ) external view returns (OrderData[] memory) {
        return _filterPaginated(OrderFilter(FilterType.StatusAndMaker, _status, _maker), _start, _end);
    }

    function getOrderByStatusAndTakerPaginatedInclusive(
        OrderStatus _status,
        address _taker,
        uint256 _start,
        uint256 _end
    ) external view returns (OrderData[] memory) {
        return _filterPaginated(OrderFilter(FilterType.StatusAndTaker, _status, _taker), _start, _end);
    }

    function countByStatusInRange(OrderStatus status, uint256 firstOrder, uint256 lastOrder)
        external
        view
        returns (uint256 count)
    {
        require(firstOrder <= lastOrder, InvalidOrderRange());
        if (_nonce == 0 || firstOrder >= _nonce) return 0;
        uint256 last = lastOrder >= _nonce ? _nonce - 1 : lastOrder;
        require(last - firstOrder + 1 <= PAGE_SIZE_LIMIT, OrderPageTooLarge());
        for (uint256 i = firstOrder; i <= last; i++) {
            if (_orders[i].orderStatus == status) count++;
        }
    }

    function getOrdersPagedInclusive(uint256 _startOrderId, uint256 _endOrderId)
        external
        view
        returns (uint256 count, OrderData[] memory result)
    {
        require(_startOrderId <= _endOrderId, InvalidOrderRange());
        if (_nonce == 0) return (0, new OrderData[](0));
        uint256 max = _maxOrderId();
        if (_startOrderId > max) return (0, new OrderData[](0));
        uint256 last = _endOrderId > max ? max : _endOrderId;
        count = last - _startOrderId + 1;
        require(count <= PAGE_SIZE_LIMIT, OrderPageTooLarge());
        result = new OrderData[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = _orderData(_startOrderId + i);
        }
    }

    function noihoMonero() external view returns (address) {
        return _noihoMonero;
    }

    function hypePerpIndex() external view returns (uint32) {
        return _hypePerpIndex;
    }

    function xmrPerpIndex() external view returns (uint32) {
        return _xmrPerpIndex;
    }

    function witnessBondHoldTime() external view returns (uint256) {
        return _witnessBondHoldTime;
    }

    function orderCancellationTime() external view returns (uint256) {
        return _orderCancellationTime;
    }

    function intentCancellationTime() external view returns (uint256) {
        return _intentCancellationTime;
    }

    function stuckOrderTimeout() external view returns (uint256) {
        return _stuckOrderTimeout;
    }

    function disputeBondThreshold() external view returns (uint256) {
        return _disputeBondThreshold;
    }

    function witnessSlashRatioBps() external view returns (uint256) {
        return _witnessSlashRatioBps;
    }

    function setHypePerpIndex(uint32 _i) external onlyOwner {
        _hypePerpIndex = _i;
        emit HypePerpIndexUpdated(_i);
    }

    function setXmrPerpIndex(uint32 _i) external onlyOwner {
        _xmrPerpIndex = _i;
        emit XmrPerpIndexUpdated(_i);
    }

    function setWitnessBondHoldTime(uint256 _t) external onlyOwner {
        _witnessBondHoldTime = _t;
        emit WitnessBondHoldTimeUpdated(_t);
    }

    function setOrderCancellationTime(uint256 _t) external onlyOwner {
        _orderCancellationTime = _t;
        emit OrderCancellationTimeUpdated(_t);
    }

    function setIntentCancellationTime(uint256 _t) external onlyOwner {
        _intentCancellationTime = _t;
        emit IntentCancellationTimeUpdated(_t);
    }

    function setStuckOrderTimeout(uint256 _timeout) external onlyOwner {
        _stuckOrderTimeout = _timeout;
        emit StuckOrderTimeoutUpdated(_timeout);
    }

    function setDisputeBondThreshold(uint256 _threshold) external onlyOwner {
        _disputeBondThreshold = _threshold;
        emit DisputeBondThresholdUpdated(_threshold);
    }

    function setWitnessSlashRatioBps(uint256 _bps) external onlyOwner {
        require(_bps >= MIN_SLASH_RATIO_BPS && _bps <= MAX_SLASH_RATIO_BPS, SlashRatioOutOfBounds());
        _witnessSlashRatioBps = _bps;
        emit WitnessSlashRatioUpdated(_bps);
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    function pause() external onlyOwner whenNotPaused {
        _paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner whenPaused {
        _paused = false;
        emit Unpaused(msg.sender);
    }

    function rescueToken(address _token, uint256 _amount) external onlyOwner returns (bool) {
        require(_token != _noihoMonero, CoreTokenRescueProhibited());
        _safeTransfer(_token, _bridgeOwner, _amount);
        return true;
    }

    function adminResolveStuckOrder(uint256 _orderId, bool _success)
        external
        onlyOwner
        whenNotPaused
        nonReentrant
        returns (bool)
    {
        Order storage o = _orders[_orderId];
        require(o.orderStatus == OrderStatus.filled, OrderNotFilled());
        require(block.timestamp > o.fulfillmentTime + _stuckOrderTimeout, NotYetStuck());

        o.orderStatus = OrderStatus.finalizedNoDispute;
        _settlePrincipal(o, _success);

        _payETHOrCredit(o.orderType == OrderType.wrap ? o.orderer : o.taker, o.witnessFee);
        emit orderFinalized(_orderId);
        emit StuckOrderResolved(_orderId, _success, msg.sender);
        return true;
    }

    function isSanctioned(address _address) external view returns (bool) {
        return _sanctioned[_address];
    }

    function sanctionsAdmin(address _address) external view returns (bool) {
        return _sanctionsAdmin[_address];
    }

    function sanctionsVault() external view returns (address) {
        return _sanctionsVault;
    }

    function setSanctionsAdmin(address _admin, bool _isAdmin) external onlyOwner {
        require(!_isAdmin || !_sanctioned[_admin], SanctionedAddress());
        _sanctionsAdmin[_admin] = _isAdmin;
        emit SanctionsAdminUpdated(_admin, _isAdmin);
    }

    function setSanctionsVault(address _vault) external onlyOwner whenPaused {
        require(_vault != address(0) && _vault != address(this), InvalidSanctionsVault());
        require(!_sanctioned[_vault], SanctionsVaultIsSanctioned());
        address previous = _sanctionsVault;
        _sanctionsVault = _vault;
        emit SanctionsVaultUpdated(previous, _vault);
    }

    function addSanctionedAddress(address _address) external onlySanctionsAdmin {
        _sanction(_address);
    }

    function removeSanctionedAddress(address _address) external onlySanctionsAdmin {
        _sanctioned[_address] = false;
        emit AddressUnsanctioned(_address);
    }

    function addSanctionedAddresses(address[] calldata _addresses) external onlySanctionsAdmin {
        for (uint256 i = 0; i < _addresses.length; i++) {
            _sanction(_addresses[i]);
        }
    }

    function removeSanctionedAddresses(address[] calldata _addresses) external onlySanctionsAdmin {
        for (uint256 i = 0; i < _addresses.length; i++) {
            _sanctioned[_addresses[i]] = false;
            emit AddressUnsanctioned(_addresses[i]);
        }
    }

    function quarantineSanctionedStake(address _party)
        external
        onlyOwner
        whenPaused
        nonReentrant
        returns (uint256 tokenAmount, uint256 ethAmount)
    {
        require(_sanctioned[_party], AddressIsNotSanctioned());
        address vault = _sanctionsVault;

        uint256 reservedLiquidity = _heldLiquidity[_party];
        uint256 freeLiquidity = _availableLiquidity[_party] - reservedLiquidity;
        _availableLiquidity[_party] = reservedLiquidity;

        WitnessData storage w = _witnesses[_party];
        uint256 bondHeld = w.bondHeld;
        uint256 freeWitnessBond = w.bond - bondHeld;
        w.bond = bondHeld;

        tokenAmount = freeLiquidity + freeWitnessBond;
        _payToken(vault, tokenAmount);

        ethAmount = _pendingETH[_party];
        if (ethAmount > 0) {
            _pendingETH[_party] = 0;
            _pendingETH[vault] += ethAmount;
        }
        emit SanctionedStakeQuarantined(_party, vault, freeLiquidity, freeWitnessBond, ethAmount);
    }

    function _requireOrderStatus(uint256 orderId, OrderStatus status) private view {
        require(orderId < _nonce, OrderDoesNotExist());
        if (_orders[orderId].orderStatus != status) {
            if (status == OrderStatus.open) revert OrderNotOpen();
            if (status == OrderStatus.intended) revert OrderNotIntended();
            revert OrderNotFilled();
        }
    }

    function _newOrder(
        address orderer,
        OrderType orderType,
        OrderStatus status,
        address maker,
        uint256 amountXMRn,
        uint256 amountXMR
    ) private returns (uint256 orderId, Order storage o) {
        orderId = _nonce++;
        o = _orders[orderId];
        o.orderer = orderer;
        o.orderType = orderType;
        o.orderStatus = status;
        o.orderCreationTime = _now();
        o.maker = maker;
        o.amountXMRn = _toUint96(amountXMRn);
        o.amountXMR = _toUint96(amountXMR);
        emit orderPlaced(orderId);
    }

    function _orderData(uint256 orderId) private view returns (OrderData memory d) {
        Order storage o = _orders[orderId];
        d.orderType = o.orderType;

        if (d.orderType != OrderType.uninitiated) d.orderId = orderId;
        d.orderStatus = o.orderStatus;
        d.orderCreationTime = o.orderCreationTime;
        d.orderer = o.orderer;
        d.xmrAddress = o.xmrAddress;
        d.xmrTxid = o.xmrTxid;
        d.xmrTxSecretKey = o.xmrTxSecretKey;

        d.ethAddress = d.orderType == OrderType.wrap ? o.taker : o.orderer;
        d.amountXMR = o.amountXMR;
        d.amountXMRn = o.amountXMRn;
        d.witnessAddress = o.witnessAddress;
        d.witnessFee = o.witnessFee;
        d.maker = o.maker;
        d.taker = o.taker;
        d.takerIntentTime = o.takerIntentTime;
        d.fulfillmentTime = o.fulfillmentTime;
        d.witnessTime = o.witnessTime;
        d.disputer = o.disputer;
        d.fulfillmentCommitment = o.fulfillmentCommitment;
        d.fulfillmentCommitmentBlock = o.fulfillmentCommitmentBlock;
    }

    function _maxOrderId() private view returns (uint256) {
        uint256 n = _nonce;
        return n > 0 ? n - 1 : 0;
    }

    function _matchesFilter(uint256 orderId, OrderFilter memory f) private view returns (bool) {
        Order storage o = _orders[orderId];
        if (f.filterType == FilterType.Orderer) return o.orderer == f.addr;
        if (o.orderStatus != f.status) return false;
        if (f.filterType == FilterType.Status) return true;
        if (f.filterType == FilterType.StatusAndMaker) return o.maker == f.addr;
        return o.taker == f.addr;
    }

    function _filterPaginated(OrderFilter memory f, uint256 startOrderId, uint256 endOrderId)
        private
        view
        returns (OrderData[] memory result)
    {
        require(startOrderId <= endOrderId, InvalidOrderRange());
        if (_nonce == 0) return new OrderData[](0);
        uint256 max = _maxOrderId();
        if (startOrderId > max) return new OrderData[](0);
        uint256 last = endOrderId > max ? max : endOrderId;
        require(last - startOrderId + 1 <= PAGE_SIZE_LIMIT, OrderPageTooLarge());

        uint256 count = 0;
        for (uint256 i = startOrderId; i <= last; i++) {
            if (_matchesFilter(i, f)) count++;
        }
        result = new OrderData[](count);
        uint256 idx = 0;
        for (uint256 i = startOrderId; i <= last && idx < count; i++) {
            if (_matchesFilter(i, f)) result[idx++] = _orderData(i);
        }
    }

    function _isWitnessed(OrderStatus status) private pure returns (bool) {
        return status == OrderStatus.witnessedSuccess || status == OrderStatus.witnessedFail;
    }

    function _quoteWrap(WrapRequest calldata r) private view returns (uint256 amountXMRn) {
        LiquidityProviderConfig storage config = _lpConfigs[r.liquidityProviderAddress];
        require(config.isLiquidityProvider, InvalidLiquidityProvider());
        require(r.recipient != address(0), InvalidRecipient());
        uint256 fixedToll = config.fixedToll;
        require(r.amountXMR > fixedToll, InvalidAmount());

        amountXMRn = BridgeMath.wrapOutput(r.amountXMR, fixedToll, config.percentageToll);
        require(amountXMRn < r.amountXMR, InvalidTollConfiguration());
        _requireWitnessFee(r.amountXMR, r.witnessFee);
        require(amountXMRn >= fixedToll && amountXMRn >= config.minPerTxn, LessThanMinimumAmount());
        require(_netLiquidity(r.liquidityProviderAddress) >= amountXMRn, InsufficientLiquidity());

        require(amountXMRn >= r.minAmountXMRn, OutputBelowMinimum());
    }

    function _validateAndPull(UnwrapRequest calldata r) private {
        require(r.amountXMRn > 0, ZeroXMRnAmount());
        require(r.amountXMR > 0, ZeroXMRAmount());
        require(r.amountXMR <= r.amountXMRn, InvalidAmount());
        MoneroProofLib.validateXmrAddress(r.xmrAddress);
        _pullToken(msg.sender, r.amountXMRn);
    }

    function _placeUnwrap(address orderer, UnwrapRequest calldata r) private returns (uint256 orderId) {
        Order storage o;
        (orderId, o) = _newOrder(orderer, OrderType.unwrap, OrderStatus.open, orderer, r.amountXMRn, r.amountXMR);
        o.xmrAddress = r.xmrAddress;
    }

    function _requireFulfiller(Order storage o) private view {
        address fulfiller = o.orderType == OrderType.wrap ? o.orderer : o.taker;
        require(msg.sender == fulfiller, OnlyFulfiller());
    }

    function _fulfillmentDeadline(Order storage o) private view returns (uint256) {
        uint256 window = o.orderType == OrderType.wrap ? _orderCancellationTime : _intentCancellationTime;
        return o.takerIntentTime + window;
    }

    function _clearCommitment(Order storage o) private {
        o.fulfillmentCommitment = bytes32(0);
        o.fulfillmentCommitmentBlock = 0;
    }

    function _fulfill(uint256 orderId, bytes32 xmrTxid, bytes32 xmrTxSecretKey, bytes32 salt) private {
        Order storage o = _orders[orderId];
        _requireFulfiller(o);

        require(block.timestamp <= _fulfillmentDeadline(o), FulfillmentWindowExpired());
        require(xmrTxid != bytes32(0), InvalidTransactionId());
        require(salt != bytes32(0), InvalidFulfillmentSalt());
        bytes32 commitment = o.fulfillmentCommitment;
        require(commitment != bytes32(0), FulfillmentNotCommitted());
        require(block.number > o.fulfillmentCommitmentBlock, CommitmentMustBeFromAPriorBlock());
        require(
            commitment
                == FulfillmentHashLib.hash(
                    address(this), orderId, msg.sender, o.orderType, o.takerIntentTime, xmrTxid, xmrTxSecretKey, salt
                ),
            InvalidFulfillmentCommitment()
        );

        o.xmrTxid = xmrTxid;
        o.xmrTxSecretKey = xmrTxSecretKey;
        o.orderStatus = OrderStatus.filled;
        o.fulfillmentTime = _now();
        _clearCommitment(o);
        _recordTransaction(xmrTxid, xmrTxSecretKey);
        emit orderFulfilled(orderId);
    }

    function _recordTransaction(bytes32 txid, bytes32 txSecretKey) private {
        MoneroProofLib.requireCanonicalTxSecretKey(txSecretKey);
        bytes32 key = MoneroProofLib.transactionKey(txid, txSecretKey);
        require(!_usedTransactionIds[key], TransactionAlreadyUsed());
        _usedTransactionIds[key] = true;
    }

    function _settlePrincipal(Order storage o, bool success) private {
        uint256 amount = o.amountXMRn;
        bool isWrap = o.orderType == OrderType.wrap;
        if (success) {
            _payToken(o.taker, amount);
        } else if (!isWrap) {
            _payToken(o.maker, amount);
        }
        if (isWrap) {
            _releaseLiquidity(o.maker, amount);
            if (success) _removeLiquidity(o.maker, amount);
        }
    }

    function _finalize(Order storage o, uint256 orderId, OrderStatus status) private {
        o.orderStatus = status;
        emit orderFinalized(orderId);
        uint256 held = o.heldWitnessBond;
        address w = o.witnessAddress;
        _witnesses[w].bondHeld -= held;
        emit WitnessBondReleased(orderId, held, w);
    }

    function _authorizeDisputer(Order storage o, OrderStatus status) private view returns (address beneficiary) {
        if (status == OrderStatus.witnessedSuccess) {
            if (msg.sender == o.maker) return msg.sender;
            require(msg.sender == _bridgeOwner, OnlyMakerCanDispute());
            require(_sanctioned[o.maker], NoSanctionedDisputer());
            return o.maker;
        }

        address taker = o.taker;
        if (o.orderType == OrderType.wrap) {
            if (msg.sender == o.orderer || msg.sender == taker) return msg.sender;
            require(msg.sender == _bridgeOwner, OnlyOrdererOrTakerCanDispute());

            if (_sanctioned[taker]) return taker;
            require(_sanctioned[o.orderer], NoSanctionedDisputer());
            return o.orderer;
        }

        if (msg.sender == taker) return msg.sender;
        require(msg.sender == _bridgeOwner, OnlyTakerCanDispute());
        require(_sanctioned[taker], NoSanctionedDisputer());
        return taker;
    }

    function _settleDispute(Order storage o, uint256 orderId, bool witnessAtFault) private {
        uint256 disputeBond = o.disputeBond;
        address witness = o.witnessAddress;
        if (!witnessAtFault) {
            _payToken(witness, disputeBond);
            return;
        }

        uint256 slashAmount = o.heldWitnessBond;
        _witnesses[witness].bond -= slashAmount;
        emit WitnessBondSlashed(orderId, slashAmount, witness);

        address disputer = o.disputer;
        address taker = o.taker;
        if (o.statusBeforeDispute == OrderStatus.witnessedFail && o.orderType == OrderType.wrap && disputer != taker) {
            uint256 principal = o.amountXMRn;
            _payToken(taker, principal);
            _payToken(disputer, slashAmount - principal + disputeBond);
        } else {
            _payToken(disputer, slashAmount + disputeBond);
        }
    }

    function _netLiquidity(address lp) private view returns (uint256) {
        return _availableLiquidity[lp] - _heldLiquidity[lp];
    }

    function _holdLiquidity(address lp, uint256 amount) private {
        _heldLiquidity[lp] += amount;
        emit liquidityHeld(lp, amount);
    }

    function _releaseLiquidity(address lp, uint256 amount) private {
        _heldLiquidity[lp] -= amount;
        emit liquidityReleased(lp, amount);
    }

    function _removeLiquidity(address lp, uint256 amount) private {
        _availableLiquidity[lp] -= amount;
        emit liquidityRemoved(lp, amount);
    }

    function _netWitnessBond(address a) private view returns (uint256) {
        return _witnesses[a].bond - _witnesses[a].bondHeld;
    }

    function _requireWitnessFee(uint256 amount, uint256 fee) private view {
        require(fee >= amount * _minimumWitnessFeeRate(), WitnessFeeTooLow());
        require(fee >= MIN_WITNESS_FEE, WitnessFeeBelowFloor());
    }

    function _sanction(address account) private {
        require(account != address(0), InvalidSanctionedAddress());
        require(account != _sanctionsVault, CannotSanctionSanctionsVault());
        _sanctioned[account] = true;
        emit AddressSanctioned(account);
    }

    function _paymentRecipient(address intended, address asset, uint256 amount) private returns (address) {
        if (!_sanctioned[intended]) return intended;
        address vault = _sanctionsVault;
        emit PaymentQuarantined(intended, vault, asset, amount);
        return vault;
    }

    function _pullToken(address from, uint256 amount) private {
        require(IXMRn(_noihoMonero).transferFrom(from, address(this), amount), TokenTransferFromFailed());
    }

    function _payToken(address to, uint256 amount) private {
        if (amount == 0) return;
        address recipient = _paymentRecipient(to, _noihoMonero, amount);
        require(IXMRn(_noihoMonero).transfer(recipient, amount), TokenTransferFailed());
    }

    function _payETHOrCredit(address to, uint256 amount) private {
        if (amount == 0) return;
        address recipient = _paymentRecipient(to, address(0), amount);
        (bool ok,) = recipient.call{value: amount, gas: FEE_PUSH_GAS}("");
        if (!ok) {
            _pendingETH[recipient] += amount;
            emit ETHCredited(recipient, amount);
        }
    }

    function _claimETH(address payable receiver) private returns (uint256 amount) {
        amount = _pendingETH[msg.sender];
        require(amount > 0, NothingToClaim());
        _pendingETH[msg.sender] = 0;
        _safeTransferETH(receiver, amount);
    }

    function _minimumWitnessFeeRate() private view returns (uint256) {
        return
            BridgeMath.minimumWitnessFeeRate(_cachedPrice(_hypePerpIndex), _cachedPrice(_xmrPerpIndex), block.chainid);
    }

    function _tryRefreshPrices() private {
        _refreshPrice(_xmrPerpIndex, false);
        _refreshPrice(_hypePerpIndex, false);
    }

    function _cachedPrice(uint32 index) private view returns (uint64 price) {
        price = _cachedOraclePx[index];
        require(price != 0, OraclePriceNotInitialized());
    }

    function _refreshPrice(uint32 index, bool strict) private returns (bool) {
        (OracleReaderLib.ReadStatus status, uint64 price) = OracleReaderLib.readPrice(index);
        if (status == OracleReaderLib.ReadStatus.CallFailed) {
            require(!strict, OraclePrecompileFailed());
            return false;
        }
        if (status == OracleReaderLib.ReadStatus.InvalidPrice) {
            require(!strict, InvalidOraclePrice());
            return false;
        }
        _cachedOraclePx[index] = price;
        return true;
    }

    function _toUint96(uint256 value) private pure returns (uint96) {
        require(value <= type(uint96).max, InvalidAmount());

        return uint96(value);
    }

    function _now() private view returns (uint40) {
        return uint40(block.timestamp);
    }

    function _blockNumber() private view returns (uint40) {
        return uint40(block.number);
    }

    // _safeTransferETH and _safeTransfer derive from Solady SafeTransferLib v0.1.26
    // (acd959aa4bd04720d640bf4e6a5c71037510cc4b). MIT, Copyright (c) 2022-2025 Solady. See THIRD_PARTY_NOTICES.
    function _safeTransferETH(address to, uint256 amount) private {
        bool success;

        assembly ("memory-safe") {
            success := call(gas(), to, amount, codesize(), 0, codesize(), 0)
        }
        require(success, ETHTransferFailed());
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        bool transferSucceeded;

        assembly ("memory-safe") {
            mstore(0x14, to)
            mstore(0x34, amount)
            mstore(0, 0xa9059cbb000000000000000000000000)
            let success := call(gas(), token, 0, 0x10, 0x44, 0, 0x20)
            transferSucceeded := 1
            if iszero(and(eq(mload(0), 1), success)) {
                transferSucceeded := lt(or(iszero(extcodesize(token)), returndatasize()), success)
            }
            mstore(0x34, 0)
        }
        require(transferSucceeded, TransferFailed());
    }
}
