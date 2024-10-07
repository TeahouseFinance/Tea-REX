// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity =0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ITradingCore} from "../interfaces/trading/ITradingCore.sol";
import {IMarketNFT} from "../interfaces/trading/IMarketNFT.sol";
import {IFeePlugin} from "../interfaces/trading/IFeePlugin.sol";
import {IRouter} from "../interfaces/lending/IRouter.sol";
import {IAssetOracle} from "../interfaces/trading/IAssetOracle.sol";
import {MarketNFT} from "./MarketNFT.sol";
import {SwapRelayer} from "./SwapRelayer.sol";
import {Percent} from "../libraries/Percent.sol";

contract TradingCore is
    ITradingCore,
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using Math for uint256;
    using SafeERC20 for ERC20Upgradeable;

    uint32 public FEE_CAP;

    address public marketBeacon;
    IRouter public router;
    IAssetOracle public oracle;
    FeeConfig public feeConfig;
    IFeePlugin public feePlugin;
    SwapRelayer public swapRelayer;
    bool enableWhitelist;
    
    mapping(ERC20Upgradeable => mapping(ERC20Upgradeable => MarketNFT)) public pairMarket;
    mapping(address => bool) public whitelistedOperator;

    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function initialize(
        address _owner,
        address _beacon,
        IRouter _router,
        IAssetOracle _oracle,
        SwapRelayer _swapRelayer,
        FeeConfig calldata _feeConfig,
        address _feePlugin
    ) public initializer {
        _zeroAddressNotAllowed(_beacon);
        _zeroAddressNotAllowed(address(_router));
        _zeroAddressNotAllowed(address(_oracle));
        _zeroAddressNotAllowed(address(_swapRelayer));
        _zeroAddressNotAllowed(address(_feePlugin));

        __UUPSUpgradeable_init();
        __Ownable_init(_owner);
        __ReentrancyGuard_init();

        _setFeeConfig(_feeConfig);
        _setFeePlugin(_feePlugin);

        marketBeacon = _beacon;
        router = _router;
        oracle = _oracle;
        swapRelayer = _swapRelayer;
        enableWhitelist = true;
    }

    function pause() external override onlyOwner {
        _pause();
    }

    function unpause() external override onlyOwner {
        _unpause();
    }

    function setFeeConfig(FeeConfig calldata _feeConfig) external onlyOwner {
        _setFeeConfig(_feeConfig);
    }

    function _setFeeConfig(FeeConfig calldata _feeConfig) internal {
        _zeroAddressNotAllowed(_feeConfig.treasury);
        if (
            _feeConfig.tradingFee > FEE_CAP ||
            _feeConfig.liquidationFee > FEE_CAP
        ) revert ExceedsFeeCap();

        feeConfig = _feeConfig;

        emit SetFeeConfig(msg.sender, block.timestamp, _feeConfig);
    }

    function setFeePlugin(address _feePlugin) external onlyOwner {
        _setFeePlugin(_feePlugin);
    }

    function _setFeePlugin(address _feePlugin) internal {
        feePlugin = IFeePlugin(_feePlugin);
    }

    function getFeeForAccount(address _account) external view returns (FeeConfig memory) {
        return _getFeeForAccount(_account);
    }

    function _getFeeForAccount(address _account) internal view returns (FeeConfig memory) {
        IFeePlugin _feePlugin = feePlugin;
        FeeConfig memory _feeConfig = feeConfig;
        
        return address(_feePlugin) == address(0) ? _feeConfig : feePlugin.getFeeForAccount(_account, _feeConfig);
    }

    function createMarket(
        ERC20Upgradeable _token0,
        ERC20Upgradeable _token1,
        bool _isToken0Margin,
        uint24 _maxLeverage,
        uint24 _openPositionLossRatioThreshold,
        uint24 _liquidateLossRatioThreshold,
        uint24 _liquidationDiscount,
        uint256 _positionSizeCap
    ) external override nonReentrant onlyOwner returns (
        address marketAddress
    ) {
        IRouter _router = router;
        if (!_router.isAssetEnabled(_token0)) revert AssetNotEnabled();
        if (!_router.isAssetEnabled(_token1)) revert AssetNotEnabled();

        (, _token0, _token1) = _sortToken(_token0, _token1);
        marketAddress = address(new BeaconProxy(
            marketBeacon,
            abi.encodeWithSelector(
                MarketNFT.initialize.selector,
                owner(),
                _token0,
                _token1,
                _isToken0Margin,
                _maxLeverage,
                _openPositionLossRatioThreshold,
                _liquidateLossRatioThreshold,
                _liquidationDiscount,
                _positionSizeCap
            )
        ));
        pairMarket[_token0][_token1] = MarketNFT(marketAddress);

        emit CreateMarket(msg.sender, _token0, _token1, marketAddress);
    }

    function openPosition(
        ERC20Upgradeable _token0,
        ERC20Upgradeable _token1,
        IRouter.InterestRateModelType _interestRateModelType,
        bool _isToken0Debt,
        uint256 _marginAmount,
        uint256 _borrowAmount,
        uint256 _minAssetAmount,
        uint256 _takeProfit,
        uint256 _stopLoss,
        address _swapRouter,
        bytes calldata _data
    ) external override nonReentrant returns (
        IMarketNFT market,
        uint256 positionId
    ) {
        bool orderChanged;
        (orderChanged, _token0, _token1) = _sortToken(_token0, _token1);
        market = _getMarket(_token0, _token1);

        ERC20Upgradeable margin = market.isToken0Margin() ? _token0 : _token1;
        (bool isLongToken0, ERC20Upgradeable asset, ERC20Upgradeable debt) = orderChanged && _isToken0Debt ? 
            (true, _token0, _token1) :
            (false, _token1, _token0);
        
        IRouter _router = router;
        address pool = _router.borrow(debt, _interestRateModelType, _borrowAmount);
        FeeConfig memory _feeConfig = _getFeeForAccount(msg.sender);
        uint256 tradingFee = _calculateTradingFee(false, _borrowAmount, _feeConfig);

        (uint256 debtAmount, uint256 assetAmount) = _swap(
            debt,
            asset,
            _borrowAmount - tradingFee,
            _minAssetAmount,
            _swapRouter,
            _data
        );
        debtAmount = debtAmount + tradingFee;
        uint256 unusedAmount = _borrowAmount - debtAmount;
        if (unusedAmount > 0) {
            debt.safeTransfer(pool, unusedAmount);
        }
        uint256 borrowId = _router.commitBorrow(debt, _interestRateModelType, debtAmount);
        margin.safeTransferFrom(msg.sender, address(this), _marginAmount);
        positionId = market.openPosition(
            msg.sender,
            oracle,
            _interestRateModelType,
            borrowId, 
            isLongToken0,
            _marginAmount,
            debtAmount,
            assetAmount,
            _takeProfit,
            _stopLoss
        );

        emit OpenPosition(msg.sender, _token0, _token1, positionId);
    }
    
    function addMargin(
        ERC20Upgradeable _token0,
        ERC20Upgradeable _token1,
        uint256 _positionId,
        uint24 _newLiquidationAssetDebtRatio
    ) external override nonReentrant {
        (
            ERC20Upgradeable token0,
            ERC20Upgradeable token1,
            IRouter _router,
            MarketNFT market,
            IMarketNFT.Position memory position,

        ) = _beforeModifyOpeningPosition(_token0, _token1, _positionId);

        (ERC20Upgradeable asset, ERC20Upgradeable debt) = _getPositionTokens(token0, token1, position);
        uint256 requiredAmount = market.addMargin(
            oracle,
            _positionId,
            _router.debtOfUnderlying(debt, position.interestRateModelType, position.borrowId),
            _newLiquidationAssetDebtRatio
        );
        (position.isMarginAsset ? asset : debt).safeTransferFrom(msg.sender, address(this), requiredAmount);

        emit AddMargin(msg.sender, token0, token1, _positionId, requiredAmount);
    }

    function _closePosition(
        IMarketNFT.CloseMode _mode,
        ERC20Upgradeable _token0,
        ERC20Upgradeable _token1,
        uint256 _positionId,
        uint256 _assetAmountToDecrease,
        uint256 _minDecreasedDebtAmount,
        address _swapRouter,
        bytes calldata _data
    ) internal returns (
        uint256 decreasedAssetAmount,
        uint256 decreasedDebtAmount,
        uint256 owedAsset,
        uint256 owedDebt
    ) {
        (
            ERC20Upgradeable token0,
            ERC20Upgradeable token1,
            IRouter _router,
            MarketNFT market,
            IMarketNFT.Position memory position,
            address positionOwner
        ) = _beforeModifyOpeningPosition(_token0, _token1, _positionId);
        if (_mode == IMarketNFT.CloseMode.Close && positionOwner != msg.sender) revert NotPositionOwner();

        FeeConfig memory _feeConfig = _getFeeForAccount(positionOwner);
        uint256 swappableAfterFee = _getSwappableAfterFee(
            _mode == IMarketNFT.CloseMode.TakeProfit ? position.assetAmount : position.swappableAmount,
            _feeConfig,
            _mode == IMarketNFT.CloseMode.Liquidate
        );
        _assetAmountToDecrease = _updateAssetAmountToDecrease(_assetAmountToDecrease, swappableAfterFee);

        (ERC20Upgradeable asset, ERC20Upgradeable debt) = _getPositionTokens(token0, token1, position);
        (decreasedAssetAmount, decreasedDebtAmount) = _swap(
            asset,
            debt,
            _assetAmountToDecrease,
            _minDecreasedDebtAmount,
            _swapRouter,
            _data
        );
    
        (owedAsset, owedDebt) = market.closePosition(
            _mode,
            oracle,
            _positionId,
            decreasedAssetAmount,
            decreasedDebtAmount,
            _calculateAndCollectTradingFee(_mode == IMarketNFT.CloseMode.Liquidate, asset, decreasedAssetAmount, _feeConfig),
            _router.debtOfUnderlying(debt, position.interestRateModelType, position.borrowId)
        );
        _pay(asset, address(this), positionOwner, owedAsset);
        _pay(debt, address(this), positionOwner, owedDebt);
        _repay(
            _router,
            debt,
            position.interestRateModelType,
            position.borrowId,
            decreasedDebtAmount
        );

        if (_mode == IMarketNFT.CloseMode.Close) {
            emit ClosePosition(msg.sender, token0, token1, _positionId, decreasedAssetAmount, decreasedDebtAmount);
        }
        else if (_mode == IMarketNFT.CloseMode.TakeProfit) {
            emit TakeProfit(msg.sender, token0, token1, _positionId, decreasedAssetAmount, decreasedDebtAmount);
        }
        else if (_mode == IMarketNFT.CloseMode.StopLoss) {
            emit StopLoss(msg.sender, token0, token1, _positionId, decreasedAssetAmount, decreasedDebtAmount);
        }
        else if (_mode == IMarketNFT.CloseMode.Liquidate) {
            emit Liquidate(msg.sender, token0, token1, _positionId, decreasedAssetAmount, decreasedDebtAmount);
        }
    }

    function closePosition(
        ERC20Upgradeable _token0,
        ERC20Upgradeable _token1,
        uint256 _positionId,
        uint256 _assetAmountToDecrease,
        uint256 _minDecreasedDebtAmount,
        address _swapRouter,
        bytes calldata _data
    ) external override nonReentrant returns (
        uint256 decreasedAssetAmount,
        uint256 decreasedDebtAmount,
        uint256 owedAsset,
        uint256 owedDebt
    ) {
        return _closePosition(
            IMarketNFT.CloseMode.Close,
            _token0,
            _token1,
            _positionId,
            _assetAmountToDecrease,
            _minDecreasedDebtAmount,
            _swapRouter,
            _data
        );
    }

    function takeProfit(
        ERC20Upgradeable _token0,
        ERC20Upgradeable _token1,
        uint256 _positionId,
        uint256 _assetAmountToDecrease,
        uint256 _minDecreasedDebtAmount,
        address _swapRouter,
        bytes calldata _data
    ) external override nonReentrant onlyWhitelistedOperator(msg.sender) returns (
        uint256 decreasedAssetAmount,
        uint256 decreasedDebtAmount,
        uint256 owedAsset,
        uint256 owedDebt
    ) {
        return _closePosition(
            IMarketNFT.CloseMode.TakeProfit,
            _token0,
            _token1,
            _positionId,
            _assetAmountToDecrease,
            _minDecreasedDebtAmount,
            _swapRouter,
            _data
        );
    }

    function stopLoss(
        ERC20Upgradeable _token0,
        ERC20Upgradeable _token1,
        uint256 _positionId,
        uint256 _assetAmountToDecrease,
        uint256 _minDecreasedDebtAmount,
        address _swapRouter,
        bytes calldata _data
    ) external override nonReentrant onlyWhitelistedOperator(msg.sender) returns (
        uint256 decreasedAssetAmount,
        uint256 decreasedDebtAmount,
        uint256 owedAsset,
        uint256 owedDebt
    ) {
        return _closePosition(
            IMarketNFT.CloseMode.StopLoss,
            _token0,
            _token1,
            _positionId,
            _assetAmountToDecrease,
            _minDecreasedDebtAmount,
            _swapRouter,
            _data
        );
    }

    function liquidate(
        ERC20Upgradeable _token0,
        ERC20Upgradeable _token1,
        uint256 _positionId,
        uint256 _assetAmountToDecrease,
        uint256 _minDecreasedDebtAmount,
        address _swapRouter,
        bytes calldata _data
    ) external override nonReentrant onlyWhitelistedOperator(msg.sender) returns (
        uint256 decreasedAssetAmount,
        uint256 decreasedDebtAmount,
        uint256 owedAsset,
        uint256 owedDebt
    ) {
        return _closePosition(
            IMarketNFT.CloseMode.Liquidate,
            _token0,
            _token1,
            _positionId,
            _assetAmountToDecrease,
            _minDecreasedDebtAmount,
            _swapRouter,
            _data
        );
    }

    function liquidateAuctionPrice(
        ERC20Upgradeable _token0,
        ERC20Upgradeable _token1,
        bool _isLongToken0
    ) external view returns (
        uint256 price
    ) {
        (, _token0, _token1) = _sortToken(_token0, _token1);
        price = _getMarket(_token0, _token1).liquidateAuctionPrice(oracle, _isLongToken0);
    }

    function getLiquidationPrice(
        ERC20Upgradeable _token0,
        ERC20Upgradeable _token1,
        uint256 _positionId
    ) external view returns (
        uint256 price
    ) {
        (, _token0, _token1) = _sortToken(_token0, _token1);
        MarketNFT market = _getMarket(_token0, _token1);
        IMarketNFT.Position memory position = market.getPosition(_positionId);
        ERC20Upgradeable debt = position.isLongToken0 ? _token1 : _token0;
        uint256 debtAmount = router.debtOfUnderlying(debt, position.interestRateModelType, position.borrowId);
        
        price = market.getLiquidationPrice(oracle, _positionId, debtAmount);
    }

    function _sortToken(
        ERC20Upgradeable _token0,
        ERC20Upgradeable _token1
    ) internal pure returns (
        bool orderChanged,
        ERC20Upgradeable token0,
        ERC20Upgradeable token1
    ) {
        if (_token0 == _token1) revert IdenticalAddress();

        orderChanged = _token0 > _token1;
        (token0, token1) = orderChanged ? (_token1, _token0) : (_token0, _token1);
    }

    function _getMarket(
        ERC20Upgradeable _token0,
        ERC20Upgradeable _token1
    ) internal view returns (
        MarketNFT market
    ) {
        market = pairMarket[_token0][_token1];
        if (address(market) == address(0)) revert PairNotCreated();
    }

    function _getPositionTokens(
        ERC20Upgradeable _token0,
        ERC20Upgradeable _token1,
        IMarketNFT.Position memory _position
    ) internal pure returns (
        ERC20Upgradeable asset,
        ERC20Upgradeable debt
    ) {
        (asset, debt) = _position.isLongToken0 ? (_token0, _token1) : (_token1, _token0);
    }

    function _calculateTradingFee(
        bool _isLiquidation,
        uint256 _amount,
        FeeConfig memory _feeConfig
    ) internal pure returns (
        uint256 fee
    ) {
        fee = _amount.mulDiv(
            _isLiquidation ? _feeConfig.tradingFee + _feeConfig.liquidationFee : _feeConfig.tradingFee,
            Percent.MULTIPLIER
        );
    }

    function _collectTradingFee(ERC20Upgradeable _token, uint256 _fee, FeeConfig memory _feeConfig) internal {
        _token.safeTransfer(_feeConfig.treasury, _fee);

        emit CollectTradingFee(_token, _feeConfig, _fee);
    }

    function _calculateAndCollectTradingFee(
        bool _isLiquidation,
        ERC20Upgradeable _token,
        uint256 _amount,
        FeeConfig memory _feeConfig
    ) internal returns (
        uint256 fee
    ) {
        fee = _calculateTradingFee(_isLiquidation, _amount, _feeConfig);
        _collectTradingFee(_token, fee, _feeConfig);
    }

    function _getSwappableAfterFee(
        uint256 _amount,
        FeeConfig memory _feeConfig,
        bool isLiquidation
    ) internal pure returns (
        uint256 swappableAmount
    ) {
        swappableAmount = isLiquidation ? 
            _amount.mulDiv(Percent.MULTIPLIER, Percent.MULTIPLIER + _feeConfig.tradingFee + _feeConfig.liquidationFee) : 
            _amount.mulDiv(Percent.MULTIPLIER, Percent.MULTIPLIER + _feeConfig.tradingFee);
    }

    function _swap(
        ERC20Upgradeable _src,
        ERC20Upgradeable _dst,
        uint256 _srcAmount,
        uint256 _minDstAmount,
        address _swapRouter,
        bytes calldata _data
    ) internal returns (
        uint256 srcAmount,
        uint256 dstAmount 
    ) {
        SwapRelayer _swapRelayer = swapRelayer;
        uint256 srcBalanceBefore = _src.balanceOf(address(this));
        uint256 dstBalanceBefore = _dst.balanceOf(address(this));
        _src.safeTransfer(address(_swapRelayer), _srcAmount);
        _swapRelayer.swap(_src, _dst, _srcAmount, _swapRouter, _data);
        uint256 srcBalanceAfter = _src.balanceOf(address(this));
        uint256 dstBalanceAfter = _dst.balanceOf(address(this));

        srcAmount = srcBalanceBefore - srcBalanceAfter;
        dstAmount = dstBalanceAfter - dstBalanceBefore;
        if (_minDstAmount != 0 && dstAmount < _minDstAmount) revert SlippageTooLarge();
    }

    function _repay(
        IRouter _router,
        ERC20Upgradeable _underlyingAsset,
        IRouter.InterestRateModelType _modelType,
        uint256 _id,
        uint256 _underlyingAmount
    ) internal {
        address pool = address(_router.getLendingPool(_underlyingAsset, _modelType));
        _underlyingAsset.approve(pool, _underlyingAmount);
        _router.repay(_underlyingAsset, _modelType, msg.sender, _id, _underlyingAmount);
        _underlyingAsset.approve(pool, 0);
    }

    function _beforeModifyOpeningPosition(
        ERC20Upgradeable _token0,
        ERC20Upgradeable _token1,
        uint256 _positionId
    ) internal returns (
        ERC20Upgradeable token0,
        ERC20Upgradeable token1,
        IRouter _router,
        MarketNFT market,
        IMarketNFT.Position memory position,
        address positionOwner
    ) {
        (, token0, token1) = _sortToken(_token0, _token1);
        _router = router;
        market = _getMarket(token0, token1);
        position = market.getPosition(_positionId);
        positionOwner = market.ownerOf(_positionId);

        ERC20Upgradeable debt = position.isLongToken0 ? token1 : token0;
        _router.collectInterestFeeAndCommit(debt, position.interestRateModelType);
    }

    function _updateAssetAmountToDecrease(
        uint256 _assetAmountToDecrease,
        uint256 swappableAfterFee
    ) internal pure returns (
        uint256
    ) {
        if (_assetAmountToDecrease > swappableAfterFee) {
            _assetAmountToDecrease = swappableAfterFee;
        }

        return _assetAmountToDecrease;
    }

    function _afterPassivelyModifyPosition(
        ERC20Upgradeable _asset,
        ERC20Upgradeable _debt,
        IRouter _router,
        FeeConfig memory _feeConfig,
        IMarketNFT.Position memory _position,
        address _positionOwner,
        uint256 _decreasedAssetAmount,
        uint256 _decreasedDebtAmount,
        uint256 _owedAsset,
        uint256 _owedDebt,
        uint256 _tradingFee
    ) internal {
        _collectTradingFee(_asset, _tradingFee, _feeConfig);
        _pay(_debt, msg.sender, address(this), _decreasedDebtAmount);
        _pay(_asset, address(this), msg.sender, _decreasedAssetAmount);
        _pay(_asset, address(this), _positionOwner, _owedAsset);
        _pay(_debt, address(this), _positionOwner, _owedDebt);
        _repay(
            _router,
            _debt,
            _position.interestRateModelType,
            _position.borrowId,
            _decreasedDebtAmount
        );
    }

    function _pay(ERC20Upgradeable _token, address _from, address _to, uint256 _amount) internal {
        if (_amount > 0) {
            _from == address(this) ? 
                _token.safeTransfer(_to, _amount) : 
                _token.safeTransferFrom(_from, _to, _amount);
        }
    }

    function isAllMarketPaused() external view override returns (bool) {
        return paused();
    }

    function _zeroAddressNotAllowed(address _address) internal pure {
        if (_address == address(0)) revert ZeroNotAllowed();
    }

    function setEnableWhitelist(bool _enableWhitelist) external onlyOwner {
        enableWhitelist = _enableWhitelist;
    }

    function setWhitelistedOperator(address[] calldata _accounts, bool[] calldata _isWhitelisted) external onlyOwner {
        uint256 length = _accounts.length;
        for (uint256 i; i < length; i = i + 1) {
            whitelistedOperator[_accounts[i]] = _isWhitelisted[i];
        }
    }

    function _onlyWhitelistedOperator(address _account) internal view {
        if (enableWhitelist && !whitelistedOperator[_account]) revert NotInWhitelist();
    }

    modifier onlyWhitelistedOperator(address _account) {
        _onlyWhitelistedOperator(_account);
        _;
    }
}