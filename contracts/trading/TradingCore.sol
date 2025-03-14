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
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ITradingCore} from "../interfaces/trading/ITradingCore.sol";
import {IMarketNFT} from "../interfaces/trading/IMarketNFT.sol";
import {IFeePlugin} from "../interfaces/trading/IFeePlugin.sol";
import {IRouter} from "../interfaces/lending/IRouter.sol";
import {IAssetOracle} from "../interfaces/trading/IAssetOracle.sol";
import {ICalldataProcessor} from "../interfaces/trading/ICalldataProcessor.sol";
import {MarketNFT} from "./MarketNFT.sol";
import {SwapRelayer} from "./SwapRelayer.sol";
import {Percent} from "../libraries/Percent.sol";

//import "hardhat/console.sol";

contract TradingCore is
    ITradingCore,
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using Math for uint256;
    using SafeERC20 for ERC20PermitUpgradeable;

    uint32 public FEE_CAP;

    address public marketBeacon;
    IRouter public router;
    FeeConfig public feeConfig;
    IFeePlugin public feePlugin;
    SwapRelayer public swapRelayer;
    bool enableWhitelist;
    
    mapping(ERC20PermitUpgradeable => mapping(ERC20PermitUpgradeable => MarketNFT)) public pairMarket;
    mapping(address => bool) public whitelistedOperator;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function initialize(
        address _owner,
        address _beacon,
        IRouter _router,
        SwapRelayer _swapRelayer,
        uint32 _feeCap,
        FeeConfig calldata _feeConfig,
        address _feePlugin
    ) public initializer {
        _zeroAddressNotAllowed(_beacon);
        _zeroAddressNotAllowed(address(_router));
        _zeroAddressNotAllowed(address(_swapRelayer));

        __UUPSUpgradeable_init();
        __Ownable_init(_owner);
        __Pausable_init();
        __ReentrancyGuard_init();

        FEE_CAP = _feeCap;
        _setFeeConfig(_feeConfig);
        _setFeePlugin(_feePlugin);

        marketBeacon = _beacon;
        router = _router;
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
        IAssetOracle _oracle,
        ERC20PermitUpgradeable _token0,
        ERC20PermitUpgradeable _token1,
        bool _isToken0Margin,
        uint32 _maxLeverage,
        uint24 _openPositionLossRatioThreshold,
        uint24 _liquidateLossRatioThreshold,
        uint24 _liquidationDiscount,
        uint256 _longPositionSizeCap,
        uint256 _shortPositionSizeCap
    ) external override nonReentrant onlyOwner returns (
        address marketAddress
    ) {
        IRouter _router = router;
        if (!_router.isAssetEnabled(_token0)) revert AssetNotEnabled();
        if (!_router.isAssetEnabled(_token1)) revert AssetNotEnabled();
        if (_token0 >= _token1) revert WrongTokenOrder();
        if (pairMarket[_token0][_token1] != MarketNFT(address(0))) revert MarketAlreadyCreated();

        marketAddress = address(new BeaconProxy(
            marketBeacon,
            abi.encodeWithSelector(
                MarketNFT.initialize.selector,
                owner(),
                _oracle,
                _token0,
                _token1,
                _isToken0Margin,
                _maxLeverage,
                _openPositionLossRatioThreshold,
                _liquidateLossRatioThreshold,
                _liquidationDiscount,
                _longPositionSizeCap,
                _shortPositionSizeCap
            )
        ));
        pairMarket[_token0][_token1] = MarketNFT(marketAddress);

        emit CreateMarket(msg.sender, IMarketNFT(marketAddress), _token0, _token1);
    }

    function openPositionPermit(
        address _market,
        IRouter.InterestRateModelType _interestRateModelType,
        ERC20PermitUpgradeable _longTarget,
        uint256 _marginAmount,
        uint256 _borrowAmount,
        uint256 _minAssetAmount,
        uint256 _takeProfit,
        uint256 _stopLoss,
        uint24 _stopLossRateTolerance,
        address _swapRouter,
        bytes calldata _data,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external override nonReentrant whenNotPaused returns (
        uint256 positionId
    ) {
        (ERC20PermitUpgradeable token0, ERC20PermitUpgradeable token1) = _getMarketPair(_market);
        MarketNFT market = MarketNFT(_market);
        ERC20PermitUpgradeable margin = market.isToken0Margin() ? token0 : token1;
        margin.permit(msg.sender, address(this), _marginAmount, _deadline, _v, _r, _s);

        positionId = _openPosition(
            market,
            _interestRateModelType,
            token0,
            token1,
            margin,
            _longTarget,
            _marginAmount,
            _borrowAmount,
            _minAssetAmount,
            _takeProfit,
            _stopLoss,
            _stopLossRateTolerance,
            _swapRouter,
            _data
        );
    }

    function openPosition(
        address _market,
        IRouter.InterestRateModelType _interestRateModelType,
        ERC20PermitUpgradeable _longTarget,
        uint256 _marginAmount,
        uint256 _borrowAmount,
        uint256 _minAssetAmount,
        uint256 _takeProfit,
        uint256 _stopLoss,
        uint24 _stopLossRateTolerance,
        address _swapRouter,
        bytes calldata _data
    ) external override nonReentrant whenNotPaused returns (
        uint256 positionId
    ) {
        (ERC20PermitUpgradeable token0, ERC20PermitUpgradeable token1) = _getMarketPair(_market);
        MarketNFT market = MarketNFT(_market);
        ERC20PermitUpgradeable margin = market.isToken0Margin() ? token0 : token1;

        positionId = _openPosition(
            market,
            _interestRateModelType,
            token0,
            token1,
            margin,
            _longTarget,
            _marginAmount,
            _borrowAmount,
            _minAssetAmount,
            _takeProfit,
            _stopLoss,
            _stopLossRateTolerance,
            _swapRouter,
            _data
        );
    }

    function _openPosition(
        MarketNFT _market,
        IRouter.InterestRateModelType _interestRateModelType,
        ERC20PermitUpgradeable _token0,
        ERC20PermitUpgradeable _token1,
        ERC20PermitUpgradeable _margin,
        ERC20PermitUpgradeable _longTarget,
        uint256 _marginAmount,
        uint256 _borrowAmount,
        uint256 _minAssetAmount,
        uint256 _takeProfit,
        uint256 _stopLoss,
        uint24 _stopLossRateTolerance,
        address _swapRouter,
        bytes calldata _data
    ) internal returns (
        uint256 positionId
    ) {
        if (_longTarget != _token0 && _longTarget != _token1) revert InvalidAsset();

        (bool isLongToken0, ERC20PermitUpgradeable asset, ERC20PermitUpgradeable debt) = _longTarget == _token0 ? 
            (true, _token0, _token1) :
            (false, _token1, _token0);
        
        IRouter _router = router;
        address pool = _router.borrow(debt, _interestRateModelType, _borrowAmount);
        FeeConfig memory _feeConfig = _getFeeForAccount(msg.sender);
        uint256 tradingFee = _calculateTradingFee(false, _borrowAmount, _feeConfig);
        _collectTradingFee(debt, tradingFee, _feeConfig);

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
        _margin.safeTransferFrom(msg.sender, address(this), _marginAmount);
        positionId = _market.openPosition(
            msg.sender,
            _interestRateModelType,
            borrowId, 
            isLongToken0,
            _marginAmount,
            debtAmount,
            assetAmount,
            _takeProfit,
            _stopLoss,
            _stopLossRateTolerance
        );

        emit OpenPosition(_market, positionId);
        emit ModifyPassiveClosePrice(_market, positionId, _takeProfit, _stopLoss, _stopLossRateTolerance);
    }

    function modifyPassiveClosePrice(
        address _market,
        uint256 _positionId,
        uint256 _takeProfit,
        uint256 _stopLoss,
        uint24 _stopLossRateTolerance
    ) external override nonReentrant whenNotPaused {
        (, , , MarketNFT market, , address positionOwner) = _beforeModifyOpeningPosition(_market, _positionId);
        if (positionOwner != msg.sender) revert NotPositionOwner();

        market.modifyPassiveClosePrice(_positionId, _takeProfit, _stopLoss, _stopLossRateTolerance);
    
        emit ModifyPassiveClosePrice(market, _positionId, _takeProfit, _stopLoss, _stopLossRateTolerance);
    }
    
    function addMarginPermit(
        address _market,
        uint256 _positionId,
        uint256 _addedAmount,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external override nonReentrant whenNotPaused {
        (
            ERC20PermitUpgradeable token0,
            ERC20PermitUpgradeable token1,
            ,
            MarketNFT market,
            IMarketNFT.Position memory position,

        ) = _beforeModifyOpeningPosition(_market, _positionId);

        (ERC20PermitUpgradeable asset, ERC20PermitUpgradeable debt) = _getPositionTokens(token0, token1, position);
        (position.isMarginAsset ? asset : debt).permit(msg.sender, address(this), _addedAmount, _deadline, _v, _r, _s);

        _addMargin(market, asset, debt, _positionId, position, _addedAmount);
    }

    function addMargin(
        address _market,
        uint256 _positionId,
        uint256 _addedAmount
    ) external override nonReentrant whenNotPaused {
        (
            ERC20PermitUpgradeable token0,
            ERC20PermitUpgradeable token1,
            ,
            MarketNFT market,
            IMarketNFT.Position memory position,

        ) = _beforeModifyOpeningPosition(_market, _positionId);

        (ERC20PermitUpgradeable asset, ERC20PermitUpgradeable debt) = _getPositionTokens(token0, token1, position);

        _addMargin(market, asset, debt, _positionId, position, _addedAmount);
    }
    
    function _addMargin(
        MarketNFT _market,
        ERC20PermitUpgradeable _asset,
        ERC20PermitUpgradeable _debt,
        uint256 _positionId,
        IMarketNFT.Position memory _position,
        uint256 _addedAmount
    ) internal {
        if (_addedAmount == 0) revert ZeroNotAllowed();
        
        _market.addMargin(_positionId, _addedAmount);
        (_position.isMarginAsset ? _asset : _debt).safeTransferFrom(msg.sender, address(this), _addedAmount);

        emit AddMargin(_market, _positionId, _addedAmount);
    }

    function _closePosition(
        IMarketNFT.CloseMode _mode,
        address _market,
        uint256 _positionId,
        uint256 _assetTokenToSwap,
        uint256 _minDecreasedDebtAmount,
        ICalldataProcessor _calldataProcessor,
        address _swapRouter,
        bytes memory _data
    ) internal returns (
        bool isFullyClosed,
        uint256 swappedAssetToken,
        uint256 decreasedDebtAmount,
        uint256 decreasedMarginAmount,
        uint256 owedAsset,
        uint256 owedDebt
    ) {
        (
            ERC20PermitUpgradeable token0,
            ERC20PermitUpgradeable token1,
            IRouter _router,
            MarketNFT market,
            IMarketNFT.Position memory position,
            address positionOwner
        ) = _beforeModifyOpeningPosition(_market, _positionId);
        if (_mode == IMarketNFT.CloseMode.Close && positionOwner != msg.sender) revert NotPositionOwner();

        FeeConfig memory _feeConfig = _getFeeForAccount(positionOwner);
        (uint256 swappableAfterFee, uint256 tradingFee) = _getSwappableAfterFee(
            _mode == IMarketNFT.CloseMode.TakeProfit ? position.assetAmount : position.swappableAmount,
            _feeConfig,
            _mode == IMarketNFT.CloseMode.Liquidate
        );
        _assetTokenToSwap = _updateAssetTokenToSwap(_assetTokenToSwap, swappableAfterFee);
        (ERC20PermitUpgradeable asset, ERC20PermitUpgradeable debt) = _getPositionTokens(token0, token1, position);
        if (address(_calldataProcessor) != address(0)) {
            _data = _calldataProcessor.processCalldata(
                _router.debtOfUnderlying(debt, position.interestRateModelType, position.borrowId),
                _data
            );
        }
        
        (swappedAssetToken, decreasedDebtAmount) = _swap(
            asset,
            debt,
            _assetTokenToSwap,
            _minDecreasedDebtAmount,
            _swapRouter,
            _data
        );

        if (swappedAssetToken == _assetTokenToSwap) {
            // To prevent from remaining small amount of asset in a position after mulDiv floor + ceil calculation
            _collectTradingFee(asset, tradingFee, _feeConfig);
        }
        else {
            tradingFee = _calculateAndCollectTradingFee(_mode == IMarketNFT.CloseMode.Liquidate, asset, swappedAssetToken, _feeConfig);
        }
        (isFullyClosed, decreasedMarginAmount, owedAsset, owedDebt) = market.closePosition(
            _mode,
            _positionId,
            swappedAssetToken,
            decreasedDebtAmount,
            tradingFee,
            _router.debtOfUnderlying(debt, position.interestRateModelType, position.borrowId)
        );
        _pay(asset, address(this), positionOwner, owedAsset);
        _pay(debt, address(this), positionOwner, owedDebt);
        _repay(
            _router,
            debt,
            position.interestRateModelType,
            position.borrowId,
            position.isMarginAsset ? decreasedDebtAmount : decreasedDebtAmount + decreasedMarginAmount,
            market.getPosition(_positionId).swappableAmount == 0
        );

        if (_mode == IMarketNFT.CloseMode.Close) {
            emit ClosePosition(market, _positionId, isFullyClosed, owedAsset, owedDebt, swappedAssetToken, decreasedDebtAmount, decreasedMarginAmount);
        }
        else if (_mode == IMarketNFT.CloseMode.TakeProfit) {
            emit TakeProfit(market, _positionId, isFullyClosed, owedAsset, owedDebt, swappedAssetToken, decreasedDebtAmount, decreasedMarginAmount);
        }
        else if (_mode == IMarketNFT.CloseMode.StopLoss) {
            emit StopLoss(market, _positionId, isFullyClosed, owedAsset, owedDebt, swappedAssetToken, decreasedDebtAmount, decreasedMarginAmount);
        }
        else if (_mode == IMarketNFT.CloseMode.Liquidate) {
            emit Liquidate(market, _positionId, isFullyClosed, owedAsset, owedDebt, swappedAssetToken, decreasedDebtAmount, decreasedMarginAmount);
        }
    }

    function closePosition(
        address _market,
        uint256 _positionId,
        uint256 _assetTokenToSwap,
        uint256 _minDecreasedDebtAmount,
        ICalldataProcessor _calldataProcessor,
        address _swapRouter,
        bytes calldata _data
    ) external override nonReentrant whenNotPaused returns (
        bool isFullyClosed,
        uint256 swappedAssetToken,
        uint256 decreasedDebtAmount,
        uint256 decreasedMarginAmount,
        uint256 owedAsset,
        uint256 owedDebt
    ) {
        return _closePosition(
            IMarketNFT.CloseMode.Close,
            _market,
            _positionId,
            _assetTokenToSwap,
            _minDecreasedDebtAmount,
            _calldataProcessor,
            _swapRouter,
            _data
        );
    }

    function takeProfit(
        address _market,
        uint256 _positionId,
        uint256 _assetTokenToSwap,
        uint256 _minDecreasedDebtAmount,
        ICalldataProcessor _calldataProcessor,
        address _swapRouter,
        bytes calldata _data
    ) external override nonReentrant whenNotPaused onlyWhitelistedOperator(msg.sender) returns (
        bool isFullyClosed,
        uint256 swappedAssetToken,
        uint256 decreasedDebtAmount,
        uint256 decreasedMarginAmount,
        uint256 owedAsset,
        uint256 owedDebt
    ) {
        return _closePosition(
            IMarketNFT.CloseMode.TakeProfit,
            _market,
            _positionId,
            _assetTokenToSwap,
            _minDecreasedDebtAmount,
            _calldataProcessor,
            _swapRouter,
            _data
        );
    }

    function stopLoss(
        address _market,
        uint256 _positionId,
        uint256 _assetTokenToSwap,
        uint256 _minDecreasedDebtAmount,
        ICalldataProcessor _calldataProcessor,
        address _swapRouter,
        bytes calldata _data
    ) external override nonReentrant whenNotPaused onlyWhitelistedOperator(msg.sender) returns (
        bool isFullyClosed,
        uint256 swappedAssetToken,
        uint256 decreasedDebtAmount,
        uint256 decreasedMarginAmount,
        uint256 owedAsset,
        uint256 owedDebt
    ) {
        return _closePosition(
            IMarketNFT.CloseMode.StopLoss,
            _market,
            _positionId,
            _assetTokenToSwap,
            _minDecreasedDebtAmount,
            _calldataProcessor,
            _swapRouter,
            _data
        );
    }

    function liquidate(
        address _market,
        uint256 _positionId,
        uint256 _assetTokenToSwap,
        uint256 _minDecreasedDebtAmount,
        ICalldataProcessor _calldataProcessor,
        address _swapRouter,
        bytes calldata _data
    ) external override nonReentrant whenNotPaused onlyWhitelistedOperator(msg.sender) returns (
        bool isFullyClosed,
        uint256 swappedAssetToken,
        uint256 decreasedDebtAmount,
        uint256 decreasedMarginAmount,
        uint256 owedAsset,
        uint256 owedDebt
    ) {
        return _closePosition(
            IMarketNFT.CloseMode.Liquidate,
            _market,
            _positionId,
            _assetTokenToSwap,
            _minDecreasedDebtAmount,
            _calldataProcessor,
            _swapRouter,
            _data
        );
    }
    
    function debtOfPosition(
        address _market,
        uint256 _positionId
    ) external override view returns (
        ERC20PermitUpgradeable asset,
        ERC20PermitUpgradeable debt,
        uint256 debtAmount
    ) {
        (ERC20PermitUpgradeable token0, ERC20PermitUpgradeable token1) = _getMarketPair(_market);
        IMarketNFT.Position memory position = MarketNFT(_market).getPosition(_positionId);

        (asset, debt) = _getPositionTokens(token0, token1, position);
        debtAmount = router.debtOfUnderlying(debt, position.interestRateModelType, position.borrowId);
    }

    function liquidateAuctionPrice(
        address _market,
        ERC20PermitUpgradeable _longTarget
    ) external view returns (
        uint256 price
    ) {
        (ERC20PermitUpgradeable token0, ERC20PermitUpgradeable token1) = _getMarketPair(_market);
        if (_longTarget != token0 && _longTarget != token1) revert InvalidAsset();

        price = MarketNFT(_market).liquidateAuctionPrice(_longTarget == token0);
    }

    function getLiquidationPrice(
        address _market,
        uint256 _positionId
    ) external view returns (
        uint256 price
    ) {
        (ERC20PermitUpgradeable token0, ERC20PermitUpgradeable  token1) = _getMarketPair(_market);
        MarketNFT market = MarketNFT(_market);
        IMarketNFT.Position memory position = market.getPosition(_positionId);
        ERC20PermitUpgradeable debt = position.isLongToken0 ? token1 : token0;
        uint256 debtAmount = router.debtOfUnderlying(debt, position.interestRateModelType, position.borrowId);
        
        price = market.getLiquidationPrice(_positionId, debtAmount);
    }

    function getClosePositionSwappableAfterFee(
        address _market,
        uint256 _positionId,
        IMarketNFT.CloseMode _mode
    ) external view override returns (
        uint256 swappableAfterFee
    ) {
        MarketNFT market = MarketNFT(_market);
        IMarketNFT.Position memory position = market.getPosition(_positionId);
        address positionOwner = market.ownerOf(_positionId);
        FeeConfig memory _feeConfig = _getFeeForAccount(positionOwner);

        (swappableAfterFee, ) = _getSwappableAfterFee(
            _mode == IMarketNFT.CloseMode.TakeProfit ? position.assetAmount : position.swappableAmount,
            _feeConfig,
            _mode == IMarketNFT.CloseMode.Liquidate
        ); 
    }

    function calculateTradingFee(
        address _account,
        bool _isLiquidation,
        uint256 _amount
    ) external override view returns (
        uint256 tradingFee
    ) {
        tradingFee = _calculateTradingFee(_isLiquidation, _amount, _getFeeForAccount(_account));
    }

    function _getMarketPair(
        address _market
    ) internal view returns (
        ERC20PermitUpgradeable token0,
        ERC20PermitUpgradeable token1
    ) {
        token0 = ERC20PermitUpgradeable(MarketNFT(_market).token0());
        token1 = ERC20PermitUpgradeable(MarketNFT(_market).token1());
        if (pairMarket[token0][token1] != IMarketNFT(_market)) revert InvalidMarketPair();
    }

    function _getPositionTokens(
        ERC20PermitUpgradeable _token0,
        ERC20PermitUpgradeable _token1,
        IMarketNFT.Position memory _position
    ) internal pure returns (
        ERC20PermitUpgradeable asset,
        ERC20PermitUpgradeable debt
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
            Percent.MULTIPLIER,
            Math.Rounding.Ceil
        );
    }

    function _collectTradingFee(ERC20PermitUpgradeable _token, uint256 _fee, FeeConfig memory _feeConfig) internal {
        _token.safeTransfer(_feeConfig.treasury, _fee);

        emit CollectTradingFee(_token, _feeConfig, _fee);
    }

    function _calculateAndCollectTradingFee(
        bool _isLiquidation,
        ERC20PermitUpgradeable _token,
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
        uint256 swappableAmount,
        uint256 fee
    ) {
        swappableAmount = isLiquidation ? 
            _amount.mulDiv(Percent.MULTIPLIER, Percent.MULTIPLIER + _feeConfig.tradingFee + _feeConfig.liquidationFee) : 
            _amount.mulDiv(Percent.MULTIPLIER, Percent.MULTIPLIER + _feeConfig.tradingFee);
        fee = _amount - swappableAmount;
    }

    function _swap(
        ERC20PermitUpgradeable _src,
        ERC20PermitUpgradeable _dst,
        uint256 _srcAmount,
        uint256 _minDstAmount,
        address _swapRouter,
        bytes memory _data
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
        ERC20PermitUpgradeable _underlyingAsset,
        IRouter.InterestRateModelType _modelType,
        uint256 _id,
        uint256 _underlyingAmount,
        bool _forceClose
    ) internal {
        address pool = address(_router.getLendingPool(_underlyingAsset, _modelType));
        _underlyingAsset.approve(pool, _underlyingAmount);
        _router.repay(_underlyingAsset, _modelType, address(this), _id, _underlyingAmount, _forceClose);
        _underlyingAsset.approve(pool, 0);
    }

    function _beforeModifyOpeningPosition(
        address _market,
        uint256 _positionId
    ) internal returns (
        ERC20PermitUpgradeable token0,
        ERC20PermitUpgradeable token1,
        IRouter _router,
        MarketNFT market,
        IMarketNFT.Position memory position,
        address positionOwner
    ) {
        (token0, token1) = _getMarketPair(_market);
        _router = router;
        market = MarketNFT(_market);
        position = market.getPosition(_positionId);
        positionOwner = market.ownerOf(_positionId);

        ERC20PermitUpgradeable debt = position.isLongToken0 ? token1 : token0;
        _router.collectInterestFeeAndCommit(debt, position.interestRateModelType);
    }

    function _updateAssetTokenToSwap(
        uint256 _assetTokenToSwap,
        uint256 swappableAfterFee
    ) internal pure returns (
        uint256
    ) {
        if (_assetTokenToSwap > swappableAfterFee) {
            _assetTokenToSwap = swappableAfterFee;
        }

        return _assetTokenToSwap;
    }

    function _pay(ERC20PermitUpgradeable _token, address _from, address _to, uint256 _amount) internal {
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
        for (uint256 i; i < length; ) {
            whitelistedOperator[_accounts[i]] = _isWhitelisted[i];

            unchecked { ++i; }
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