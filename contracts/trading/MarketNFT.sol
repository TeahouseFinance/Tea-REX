// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity =0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC721EnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IMarketNFT} from "../interfaces/trading/IMarketNFT.sol";
import {ITradingCore} from "../interfaces/trading/ITradingCore.sol";
import {IAssetOracle} from "../interfaces/trading/IAssetOracle.sol";
import {IRouter} from "../interfaces/lending/IRouter.sol";
import {Percent} from "../libraries/Percent.sol";

//import "hardhat/console.sol";

contract MarketNFT is IMarketNFT, Initializable, OwnableUpgradeable, ERC721Upgradeable, ERC721EnumerableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using Math for uint256;
    using SafeCast for uint256;

    ITradingCore public tradingCore;
    IAssetOracle oracle;
    address public token0;
    address public token1;
    bool public isToken0Margin;
    uint32 public maxLeverage;
    uint24 public openPositionLossRatioThreshold;
    uint24 public liquidateLossRatioThreshold;
    uint24 public liquidationDiscount;
    uint256 public token0PositionSizeCap;
    uint256 public token1PositionSizeCap;
    uint256 public totalToken0PositionAmount;
    uint256 public totalToken1PositionAmount;

    mapping(uint256 => Position) public positions;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        IAssetOracle _oracle,
        ERC20PermitUpgradeable _token0,
        ERC20PermitUpgradeable _token1,
        bool _isToken0Margin,
        uint32 _maxLeverage,
        uint24 _openPositionLossRatioThreshold,
        uint24 _liquidateLossRatioThreshold,
        uint24 _liquidationDiscount,
        uint256 _token0PositionSizeCap,
        uint256 _token1PositionSizeCap
    ) public initializer {
        __Ownable_init(_owner);
        __ERC721_init(
            string.concat("TeaREX Market: ", _token0.name() , " - ", _token1.name()), 
            string.concat("TeaREX: ", _token0.symbol(), "/", _token1.symbol())
        );
        __ERC721Enumerable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        tradingCore = ITradingCore(msg.sender);
        token0 = address(_token0);
        token1 = address(_token1);
        isToken0Margin = _isToken0Margin;
        _changeOracle(_oracle);

        _setMaxLeverage(_maxLeverage);
        _setMarketRatioParams(_openPositionLossRatioThreshold, _liquidateLossRatioThreshold, _liquidationDiscount);
        _setPositionSizeCap(_token0PositionSizeCap, _token1PositionSizeCap);
    }

    function _update(
        address _to,
        uint256 _tokenId,
        address _auth
    ) internal override(ERC721Upgradeable, ERC721EnumerableUpgradeable) returns (
        address
    ) {
        return super._update(_to, _tokenId, _auth);
    }

    function _increaseBalance(address _account, uint128 _value) internal override(ERC721Upgradeable, ERC721EnumerableUpgradeable) {
        super._increaseBalance(_account, _value);
    }

    function supportsInterface(bytes4 _interfaceId) public view override(ERC721Upgradeable, ERC721EnumerableUpgradeable) returns (bool) {
        return super.supportsInterface(_interfaceId);
    }

    function pause() external override onlyOwner {
        _pause();
    }

    function unpause() external override onlyOwner {
        _unpause();
    }

    function changeOracle(IAssetOracle _oracle) external override onlyOwner {
        _changeOracle(_oracle);
    }


    function _changeOracle(IAssetOracle _oracle) internal {
        if (!_oracle.isOracleEnabled(address(token0))) revert IAssetOracle.AssetNotEnabled();
        if (!_oracle.isOracleEnabled(address(token1))) revert IAssetOracle.AssetNotEnabled();

        oracle = _oracle;
    }

    function setMaxLeverage(uint32 _maxLeverage) external override onlyOwner {
        _setMaxLeverage(_maxLeverage);
    }

    function _setMaxLeverage(uint32 _maxLeverage) internal {
        if (_maxLeverage == 0) revert ZeroNotAllowed();
        
        maxLeverage = _maxLeverage;
    }

    function setMarketRatioParams(
        uint24 _openPositionLossRatioThreshold,
        uint24 _liquidateLossRatioThreshold,
        uint24 _liquidationDiscount
    ) external override onlyOwner {
        _setMarketRatioParams(_openPositionLossRatioThreshold, _liquidateLossRatioThreshold, _liquidationDiscount);
    }

    function _setMarketRatioParams(
        uint24 _openPositionLossRatioThreshold,
        uint24 _liquidateLossRatioThreshold,
        uint24 _liquidationDiscount
    ) internal {
        if (_openPositionLossRatioThreshold > _liquidateLossRatioThreshold) revert InvalidThreshold();
        if (_liquidateLossRatioThreshold >= Percent.MULTIPLIER) revert InvalidThreshold();
        if (_liquidationDiscount >= _liquidateLossRatioThreshold) revert InvalidDiscountRate();

        openPositionLossRatioThreshold = _openPositionLossRatioThreshold;
        liquidateLossRatioThreshold = _liquidateLossRatioThreshold;
        liquidationDiscount = _liquidationDiscount;
    }

    function setPositionSizeCap(uint256 _token0PositionSizeCap, uint256 _token1PositionSizeCap) external override onlyOwner {
        _setPositionSizeCap(_token0PositionSizeCap, _token1PositionSizeCap);
    }

    function _setPositionSizeCap(uint256 _token0PositionSizeCap, uint256 _token1PositionSizeCap) internal {
        if (_token0PositionSizeCap == 0) revert ZeroNotAllowed();
        if (_token1PositionSizeCap == 0) revert ZeroNotAllowed();
        
        token0PositionSizeCap = _token0PositionSizeCap;
        token1PositionSizeCap = _token1PositionSizeCap;
    }

    function getPosition(uint256 _positionId) external view override returns (Position memory position) {
        return positions[_positionId];
    }

    function openPosition(
        address _account,
        IRouter.InterestRateModelType _interestRateModelType,
        uint256 _borrowId, 
        bool _isLongToken0,
        uint256 _marginAmount,
        uint256 _debtAmount,
        uint256 _assetAmount,
        uint256 _takeProfit,
        uint256 _stopLoss,
        uint24 _stopLossRateTolerance
    ) external override nonReentrant onlyNotPaused onlyTradingCore returns (
        uint256 positionId
    ) {
        (
            uint8 oracleDecimals,
            address asset,       
            ,
            address margin,
            uint256 assetPrice,
            uint256 debtPrice,
            uint256 marginPrice
        ) = _getTokensInfo(_isLongToken0);

        _checkPassiveCloseCondition(
            _takeProfit,
            _stopLoss,
            _stopLossRateTolerance,
            assetPrice,
            debtPrice,
            oracleDecimals
        );

        uint256 debtValue = _getTokenValue(oracleDecimals, _debtAmount, debtPrice);
        uint256 assetValue = _getTokenValue(oracleDecimals, _assetAmount, assetPrice);
        uint256 marginValue = _getTokenValue(oracleDecimals, _marginAmount, marginPrice);
        
        uint256 lossRatio = _calculateLossRatio(marginValue, assetValue, debtValue);
        if (lossRatio > openPositionLossRatioThreshold) revert HighLossRatio();
        uint32 leverage = debtValue.mulDiv(Percent.MULTIPLIER, marginValue).toUint32();
        if (leverage > maxLeverage) revert InvalidLeverage();

        _updateMarketStatus(
            _isLongToken0,
            true,
            _assetAmount,
            assetPrice,
            oracleDecimals
        );

        positionId = totalSupply() + 1;
        _mint(_account, positionId);
        bool isMarginAsset = margin == asset;
        positions[positionId] = Position({
            status: PositionStatus.Open,
            isLongToken0: _isLongToken0,
            isMarginAsset: isMarginAsset,
            stopLossRateTolerance: _stopLossRateTolerance,
            initialLeverage: leverage,
            marginAmount: _marginAmount,
            interestRateModelType: _interestRateModelType,
            borrowId: _borrowId,
            assetAmount: _assetAmount,
            swappableAmount: isMarginAsset ? _assetAmount + _marginAmount : _assetAmount,
            takeProfit: _takeProfit,
            stopLoss: _stopLoss
        });
    }

    function modifyPassiveClosePrice(
        uint256 _positionId,
        uint256 _takeProfit,
        uint256 _stopLoss,
        uint24 _stopLossRateTolerance
    ) external override nonReentrant onlyNotPaused onlyTradingCore {
        Position memory position = positions[_positionId];
        if (position.status != PositionStatus.Open) revert InvalidPositionStatus();

        (
            uint8 oracleDecimals,
            ,       
            ,
            ,
            uint256 assetPrice,
            uint256 debtPrice,
            
        ) = _getTokensInfo(position.isLongToken0);

        _checkPassiveCloseCondition(
            _takeProfit,
            _stopLoss,
            _stopLossRateTolerance,
            assetPrice,
            debtPrice,
            oracleDecimals
        );

        position.takeProfit = _takeProfit;
        position.stopLoss = _stopLoss;
        position.stopLossRateTolerance = _stopLossRateTolerance;
        positions[_positionId] = position;
    }

    function _checkPassiveCloseCondition(
        uint256 _takeProfit,
        uint256 _stopLoss,
        uint24 _stopLossRateTolerance,
        uint256 _assetPrice,
        uint256 _debtPrice,
        uint8 _oracleDecimals
    ) internal pure {
        uint256 assetPriceInDebt = _getRelativePrice(_assetPrice, _debtPrice, _oracleDecimals);
        if (_takeProfit != 0 && _takeProfit <= assetPriceInDebt) revert InvalidTakeProfit();
        if (_stopLoss != 0 && _stopLoss >= assetPriceInDebt) revert InvalidStopLoss();
        if (_stopLossRateTolerance >= Percent.MULTIPLIER) revert InvalidStopLossRateTolerance();
    }

    function addMargin(
        uint256 _positionId,
        uint256 _addedAmount
    ) external override nonReentrant onlyNotPaused onlyTradingCore {
        Position storage position = positions[_positionId];
        if (position.status != PositionStatus.Open) revert InvalidPositionStatus();

        position.marginAmount = position.marginAmount + _addedAmount;
    }


    function getLiquidationPrice(
        uint256 _positionId,
        uint256 _debtAmount
    ) external view returns (uint256 price) {
        Position memory position = positions[_positionId];
        if (position.status != PositionStatus.Open) revert InvalidPositionStatus();

        price = _getLiquidationPrice(position, _debtAmount, oracle.decimals());
    }

    function _getLiquidationPrice(
        Position memory _position,
        uint256 _debtAmount,
        uint8 _oracleDecimals
    ) internal view returns (uint256 price) {
        if (_position.isMarginAsset) {
            price = (10 ** _oracleDecimals).mulDiv(
                Percent.MULTIPLIER * _debtAmount,
                Percent.MULTIPLIER * _position.assetAmount + liquidateLossRatioThreshold * _position.marginAmount
            );
        }
        else {
            if (Percent.MULTIPLIER * _debtAmount <= liquidateLossRatioThreshold * _position.marginAmount) {
                price = 0;
            }
            else {
                price = (10 ** _oracleDecimals).mulDiv(
                    Percent.MULTIPLIER * _debtAmount - liquidateLossRatioThreshold * _position.marginAmount,
                    Percent.MULTIPLIER * _position.assetAmount
                );
            }
        }
    }

    function liquidateAuctionPrice(bool _isLongToken0) external view returns (uint256 price) {
        (
            uint8 oracleDecimals,
            ,
            ,
            ,
            uint256 assetPrice,
            uint256 debtPrice,

        ) = _getTokensInfo(_isLongToken0);

        price = _liquidateAuctionPrice(assetPrice, debtPrice, oracleDecimals);
    }

    function _liquidateAuctionPrice(
        uint256 _assetPrice,
        uint256 _debtPrice,
        uint8 _oracleDecimals
    ) internal view returns (
        uint256 price
    ) {
        price = _getRelativePrice(_assetPrice, _debtPrice, _oracleDecimals).mulDiv(
            Percent.MULTIPLIER - liquidationDiscount,
            Percent.MULTIPLIER,
            Math.Rounding.Ceil
        );
    }

    function _debtToAssetAmount(
        uint256 _debtAmount,
        uint256 _price,
        uint8 _oracleDecimals
    ) internal pure returns (
        uint256 assetAmount
    ) {
        assetAmount = _debtAmount.mulDiv(10 ** _oracleDecimals, _price);
    }

    function _assetToDebtAmount(
        uint256 _assetAmount,
        uint256 _price,
        uint8 _oracleDecimals
    ) internal pure returns (
        uint256 debtAmount
    ) {
        debtAmount = _assetAmount.mulDiv(_price, 10 ** _oracleDecimals);
    }

    function closePosition(
        CloseMode _mode,
        uint256 _positionId,
        uint256 _swappedAssetToken,
        uint256 _decreasedDebtAmount,
        uint256 _tradingFee,
        uint256 _debtAmount
    ) external override nonReentrant onlyNotPaused onlyTradingCore returns (
        bool isFullyClosed,
        uint256 decreasedMarginAmount,
        uint256 owedAsset,
        uint256 owedDebt
    ) {
        Position memory position = positions[_positionId];
        if (position.status != PositionStatus.Open) revert InvalidPositionStatus();

        (
            uint8 oracleDecimals,
            ,
            ,
            ,
            uint256 assetPrice,
            uint256 debtPrice,
            uint256 marginPrice
        ) = _getTokensInfo(position.isLongToken0);

        if (_mode != CloseMode.Liquidate) {
            uint256 totalConsumedAssetToken = _swappedAssetToken + _tradingFee;
            if (
                totalConsumedAssetToken * _debtAmount >= (
                    position.isMarginAsset ? 
                        // require: consumed / swappable < decreasedDebt / totalDebt
                        position.swappableAmount * _decreasedDebtAmount : 
                        // require: consumed / swappable < [decreasedDebt + (consumed / swappable) * m] / totalDebt
                        position.swappableAmount * _decreasedDebtAmount + position.marginAmount * totalConsumedAssetToken
                )
            ) revert BadCloseRate();
        }

        if (_mode == CloseMode.TakeProfit) {
            if (position.takeProfit == 0) revert NoTakeProfit();
            if (
                _decreasedDebtAmount < _assetToDebtAmount(_swappedAssetToken, position.takeProfit, oracleDecimals)
            ) revert WorsePrice();
        }
        else if (_mode == CloseMode.StopLoss) {
            if (position.stopLoss == 0) revert NoStopLoss();
            uint256 assetPriceInDebt = _getRelativePrice(assetPrice, debtPrice, oracleDecimals);
            if (position.stopLoss < assetPriceInDebt) revert PassivelyCloseConditionNotMet();
            if (
                _decreasedDebtAmount < _assetToDebtAmount(_swappedAssetToken, assetPriceInDebt, oracleDecimals).mulDiv(
                    Percent.MULTIPLIER - position.stopLossRateTolerance,
                    Percent.MULTIPLIER,
                    Math.Rounding.Ceil
                )
            ) revert WorsePrice();
        }
        else if (_mode == CloseMode.Liquidate) {
            uint256 assetPriceInDebt = _getRelativePrice(assetPrice, debtPrice, oracleDecimals);
            if (assetPriceInDebt > _getLiquidationPrice(position, _debtAmount, oracleDecimals)) revert PassivelyCloseConditionNotMet();
            if (
                _decreasedDebtAmount < _assetToDebtAmount(_swappedAssetToken, _liquidateAuctionPrice(assetPrice, debtPrice, oracleDecimals), oracleDecimals)
            ) revert WorsePrice();
        }

        (isFullyClosed, decreasedMarginAmount, owedAsset, owedDebt) = _afterFlatPosition(
            _positionId,
            position,
            _swappedAssetToken,
            _decreasedDebtAmount,
            _tradingFee,
            _debtAmount,
            _mode != CloseMode.Liquidate,
            oracleDecimals,
            assetPrice,
            debtPrice,
            marginPrice
        );
    }

    function _afterFlatPosition(
        uint256 _positionId,
        Position memory _position,
        uint256 _swappedAssetToken,
        uint256 _decreasedDebtAmount,
        uint256 _tradingFee,
        uint256 _debtAmount,
        bool _ensureNotLiquidated,
        uint8 oracleDecimals,
        uint256 assetPrice,
        uint256 debtPrice,
        uint256 marginPrice
    ) internal returns (
        bool isFullyClosed,
        uint256 decreasedMarginAmount,
        uint256 owedAsset,
        uint256 owedDebt
    ) {
        uint256 positionAssetAmount = _position.assetAmount;
        uint256 totalConsumedAssetToken = _swappedAssetToken + _tradingFee;
        _position.swappableAmount = _position.swappableAmount - totalConsumedAssetToken;
        if (totalConsumedAssetToken > _position.assetAmount) {
            decreasedMarginAmount = _position.marginAmount - _position.swappableAmount;
            _position.marginAmount = _position.swappableAmount;
            _position.assetAmount = 0;
        }
        else {
            _position.assetAmount = _position.assetAmount - totalConsumedAssetToken;
        }

        uint256 overRepaidDebt;
        uint256 newDebtAmount;
        if (_decreasedDebtAmount >= _debtAmount) {
            overRepaidDebt = _decreasedDebtAmount - _debtAmount;
            newDebtAmount = 0;
        }
        else {
            newDebtAmount = _debtAmount - _decreasedDebtAmount;
            if (_position.assetAmount == 0 && !_position.isMarginAsset) {
                decreasedMarginAmount = newDebtAmount > _position.marginAmount ? _position.marginAmount : newDebtAmount;
                _position.marginAmount = _position.marginAmount - decreasedMarginAmount;
                newDebtAmount = newDebtAmount - decreasedMarginAmount;
            }
        }
        if (_position.swappableAmount == 0 || newDebtAmount == 0) {
            isFullyClosed = true;
        }

        if (isFullyClosed) {
            (owedAsset, owedDebt) = _position.isMarginAsset ? 
                (_position.assetAmount + _position.marginAmount, overRepaidDebt) : 
                (_position.assetAmount, _position.marginAmount + overRepaidDebt);
            _position.status = PositionStatus.Closed;
        }
        else if (_ensureNotLiquidated) {
            uint256 debtValue = _getTokenValue(oracleDecimals, newDebtAmount, debtPrice);
            uint256 assetValue = _getTokenValue(oracleDecimals, _position.assetAmount, assetPrice);
            uint256 marginValue = _getTokenValue(oracleDecimals, _position.marginAmount, marginPrice);
            uint256 lossRatio = _calculateLossRatio(marginValue, assetValue, debtValue);
            if (lossRatio > liquidateLossRatioThreshold) revert HighLossRatio();
        }

        _updateMarketStatus(
            _position.isLongToken0,
            false,
            totalConsumedAssetToken > positionAssetAmount ? positionAssetAmount : totalConsumedAssetToken,
            assetPrice,
            oracleDecimals
        );
        positions[_positionId] = _position;
    }

    function getTokenPrices() external override view returns (uint8 decimals, uint256 price0, uint256 price1) {
        decimals = oracle.decimals();
        price0 = oracle.getPrice(token0);
        price1 = oracle.getPrice(token1);
    }

    function _getTokensInfo(
        bool _isLongToken0
    ) internal view returns (
        uint8 oracleDecimals,
        address asset,       
        address debt,
        address margin,
        uint256 assetPrice,
        uint256 debtPrice,
        uint256 marginPrice
    ) {
        IAssetOracle _oracle = oracle;
        oracleDecimals = _oracle.decimals();
        (asset, debt) = _isLongToken0 ? (token0, token1) : (token1, token0);
            
        debtPrice = _oracle.getPrice(debt);
        assetPrice = _oracle.getPrice(asset);

        (margin, marginPrice) = _isLongToken0 == isToken0Margin ? (asset, assetPrice) : (debt, debtPrice);
    }

    function _getTokenValue(
        uint8 _oracleDecimals,
        uint256 _tokenAmount,
        uint256 _tokenPrice
    ) internal pure returns (
        uint256 value
    ) {
        value = _tokenAmount.mulDiv(_tokenPrice, 10 ** _oracleDecimals );
    }

    function _getRelativePrice(
        uint256 _price0,
        uint256 _price1,
        uint8 _oracleDecimals
    ) internal pure returns (uint256 token0PriceInToken1) {
        token0PriceInToken1 = _price0.mulDiv(10 ** _oracleDecimals, _price1);
    }

    function _calculateLossRatio(
        uint256 _marginValue,
        uint256 _assetValue,
        uint256 _debtValue
    ) internal pure returns (uint256 lossRatio) {
        if (_debtValue > _assetValue) {
            lossRatio = (_debtValue - _assetValue).mulDiv(
                Percent.MULTIPLIER,
                _marginValue
            );
        }
    }

    function _updateMarketStatus(
        bool _isAssetToken0,
        bool _isIncrease,
        uint256 _changeAmount,
        uint256 _assetPrice,
        uint8 _oracleDecimals
    ) internal {
        if (_isIncrease) {
            if (_isAssetToken0) {
                totalToken0PositionAmount = totalToken0PositionAmount + _changeAmount;
                if (totalToken0PositionAmount.mulDiv(_assetPrice, 10 ** _oracleDecimals) > token0PositionSizeCap) revert ExceedsMaxTotalPositionSize();
            }
            else {
                totalToken1PositionAmount = totalToken1PositionAmount + _changeAmount;
                if (totalToken1PositionAmount.mulDiv(_assetPrice, 10 ** _oracleDecimals) > token1PositionSizeCap) revert ExceedsMaxTotalPositionSize();
            }
        }
        else {
            if (_isAssetToken0) {
                totalToken0PositionAmount = totalToken0PositionAmount - _changeAmount;
            }
            else {
                totalToken1PositionAmount = totalToken1PositionAmount - _changeAmount;
            }
        }
    }

    modifier onlyNotPaused() {
        _onlyNotPaused();
        _;
    }

    modifier onlyTradingCore() {
        _onlyTradingCore();
        _;
    }

    function _onlyNotPaused() internal view {
        if (paused() || tradingCore.isAllMarketPaused()) revert EnforcedPause();
    }

    function _onlyTradingCore() internal view {
        if (msg.sender != address(tradingCore)) revert CallerIsNotTradingCore();
    }
}