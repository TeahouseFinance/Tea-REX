// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity =0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC721EnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IMarketNFT} from "../interfaces/trading/IMarketNFT.sol";
import {ITradingCore} from "../interfaces/trading/ITradingCore.sol";
import {IAssetOracle} from "../interfaces/trading/IAssetOracle.sol";
import {IRouter} from "../interfaces/lending/IRouter.sol";
import {Percent} from "../libraries/Percent.sol";

contract MarketNFT is IMarketNFT, Initializable, OwnableUpgradeable, ERC721Upgradeable, ERC721EnumerableUpgradeable, PausableUpgradeable, ReentrancyGuard {
    using Math for uint256;
    using SafeCast for uint256;


    ITradingCore public tradingCore;
    address public token0;
    address public token1;
    uint8 public token0Decimals;
    uint8 public token1Decimals;
    bool public isToken0Margin;
    uint24 public maxLeverage;
    uint24 public openPositionLossRatioThreshold;
    uint24 public liquidateLossRatioThreshold;
    uint24 public liquidationDiscount;
    uint256 public positionSizeCap;
    uint256 public totalToken0PositionAmount;
    uint256 public totalToken1PositionAmount;

    mapping(uint256 => Position) public positions;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        ERC20Upgradeable _token0,
        ERC20Upgradeable _token1,
        bool _isToken0Margin,
        uint24 _maxLeverage,
        uint24 _openPositionLossRatioThreshold,
        uint24 _liquidateLossRatioThreshold,
        uint24 _liquidationDiscount,
        uint256 _positionSizeCap
    ) public initializer {
        if (_maxLeverage > 100 * Percent.MULTIPLIER) revert InvalidLeverage();
        if (_openPositionLossRatioThreshold > _liquidateLossRatioThreshold) revert InvalidThreshold();
        if (_liquidateLossRatioThreshold >= Percent.MULTIPLIER) revert InvalidThreshold();
        if (_liquidationDiscount >= _liquidateLossRatioThreshold) revert InvalidDiscountRate();
        if (_positionSizeCap == 0) revert ZeroCapNotAllowed();

        __Ownable_init(_owner);
        __ERC721_init(
            string.concat("TeaREX Market: ", _token0.name() , " - ", _token1.name()), 
            string.concat("TeaREX: ", _token0.symbol(), "/", _token1.symbol())
        );
        __ERC721Enumerable_init();
        __Pausable_init();

        tradingCore = ITradingCore(msg.sender);
        token0 = address(_token0);
        token1 = address(_token1);
        token0Decimals = _token0.decimals();
        token1Decimals = _token1.decimals();
        isToken0Margin = _isToken0Margin;
        maxLeverage = _maxLeverage;
        openPositionLossRatioThreshold = _openPositionLossRatioThreshold;
        liquidateLossRatioThreshold = _liquidateLossRatioThreshold;
        liquidationDiscount = _liquidationDiscount;
        positionSizeCap = _positionSizeCap;
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

    function getPosition(uint256 _positionId) external view override returns (Position memory position) {
        return positions[_positionId];
    }

    function openPosition(
        address _account,
        IAssetOracle _oracle,
        IRouter.InterestRateModelType _interestRateModelType,
        uint256 _borrowId, 
        bool _isLongToken0,
        uint256 _marginAmount,
        uint256 _debtAmount,
        uint256 _assetAmount,
        uint256 _takeProfit,
        uint256 _stopLoss
    ) external override nonReentrant onlyNotPaused onlyTradingCore returns (
        uint256 positionId
    ) {
        (
            uint8 oracleDecimals,
            uint8 assetDecimals,
            uint8 debtDecimals,
            uint8 marginDecimals,
            address asset,       
            ,
            address margin,
            uint256 assetPrice,
            uint256 debtPrice,
            uint256 marginPrice
        ) = _getTokensInfo(_oracle, _isLongToken0);

        uint256 assetPriceInDebt = _getRelativePrice(assetPrice, debtPrice, oracleDecimals);
        if (_takeProfit != 0 && _takeProfit <= assetPriceInDebt) revert InvalidTakeProfit();
        if (_stopLoss != 0 && _stopLoss >= assetPriceInDebt) revert InvalidStopLoss();

        uint256 debtValue = _getTokenValue(oracleDecimals, debtDecimals, _debtAmount, debtPrice);
        uint256 assetValue = _getTokenValue(oracleDecimals, assetDecimals, _assetAmount, assetPrice);
        uint256 marginValue = _getTokenValue(oracleDecimals, marginDecimals, _marginAmount, marginPrice);
        
        uint256 lossRatio = _calculateLossRatio(marginValue, assetValue, debtValue);
        if (lossRatio > openPositionLossRatioThreshold) revert HighLossRatio();
        uint24 leverage = debtValue.mulDiv(Percent.MULTIPLIER, assetValue).toUint24();
        if (leverage > maxLeverage) revert InvalidLeverage();

        _updateMarketStatus(
            _isLongToken0,
            true,
            _assetAmount,
            assetDecimals,
            oracleDecimals,
            assetPrice
        );

        positionId = totalSupply() + 1;
        _mint(_account, positionId);
        bool isMarginAsset = margin == asset;
        positions[positionId] = Position({
            status: PositionStatus.Open,
            isLongToken0: _isLongToken0,
            isMarginAsset: isMarginAsset,
            liquidationAssetDebtRatio: _getLiquidationAssetDebtRatio(leverage),
            marginAmount: _marginAmount,
            interestRateModelType: _interestRateModelType,
            borrowId: _borrowId,
            assetAmount: _assetAmount,
            swappableAmount: isMarginAsset ? _assetAmount + _marginAmount : _assetAmount,
            takeProfit: _takeProfit,
            stopLoss: _stopLoss
        });
    }

    function addMargin(
        IAssetOracle _oracle,
        uint256 _positionId,
        uint256 _debtAmount,
        uint24 _newLiquidationAssetDebtRatio
    ) external override nonReentrant onlyNotPaused onlyTradingCore returns (
        uint256 requiredAmount
    ) {
        Position storage position = positions[_positionId];
        if (position.status != PositionStatus.Open) revert InvalidPositionStatus();
        if(_newLiquidationAssetDebtRatio >= position.liquidationAssetDebtRatio) revert InvalidAssetDebtRatio();

        (
            uint8 oracleDecimals,
            ,
            uint8 debtDecimals,
            uint8 marginDecimals,
            ,       
            ,
            ,
            ,
            uint256 debtPrice,
            uint256 marginPrice
        ) = _getTokensInfo(_oracle, position.isLongToken0);

        uint256 debtValue = _getTokenValue(oracleDecimals, debtDecimals, _debtAmount, debtPrice);
        uint256 marginAmount = uint256(Percent.MULTIPLIER - _newLiquidationAssetDebtRatio).mulDiv(
            debtValue * 10 ** (oracleDecimals + marginDecimals),
            liquidateLossRatioThreshold * marginPrice,
            Math.Rounding.Ceil
        );
        requiredAmount = marginAmount - position.marginAmount;
        position.marginAmount = position.marginAmount + marginAmount;
    }

    function closePosition(
        IAssetOracle _oracle,
        uint256 _positionId,
        uint256 _decreasedAssetAmount,
        uint256 _decreasedDebtAmount,
        uint256 _tradingFee,
        uint256 _debtAmount
    ) external override nonReentrant onlyNotPaused onlyTradingCore returns (
        uint256 owedAsset,
        uint256 owedDebt
    ) {
        Position memory position = positions[_positionId];
        if (position.status != PositionStatus.Open) revert InvalidPositionStatus();

        (
            uint8 oracleDecimals,
            uint8 assetDecimals,
            uint8 debtDecimals,
            uint8 marginDecimals,
            ,
            ,
            ,
            uint256 assetPrice,
            uint256 debtPrice,
            uint256 marginPrice
        ) = _getTokensInfo(_oracle, position.isLongToken0);

        (owedAsset, owedDebt) = _afterFlatPosition(
            _positionId,
            position,
            _decreasedAssetAmount,
            _decreasedDebtAmount,
            _tradingFee,
            _debtAmount,
            true,
            oracleDecimals,
            assetDecimals,
            debtDecimals,
            marginDecimals,
            assetPrice,
            debtPrice,
            marginPrice
        );
    }

    function takeProfit(
        IAssetOracle _oracle,
        uint256 _positionId,
        uint256 _assetAmountToDecrease,
        uint256 _tradingFee,
        uint256 _debtAmount
    ) external override nonReentrant onlyNotPaused onlyTradingCore returns (
        uint256 decreasedAssetAmount,
        uint256 decreasedDebtAmount,
        uint256 owedAsset,
        uint256 owedDebt,
        uint256 tradingFee
    ) {
        Position memory position = positions[_positionId];
        if (position.status != PositionStatus.Open) revert InvalidPositionStatus();
        if (position.takeProfit == 0) revert NoTakeProfit();

        (
            uint8 oracleDecimals,
            uint8 assetDecimals,
            uint8 debtDecimals,
            uint8 marginDecimals,
            ,
            ,
            ,
            uint256 assetPrice,
            uint256 debtPrice,
            uint256 marginPrice
        ) = _getTokensInfo(_oracle, position.isLongToken0);

        (decreasedAssetAmount, decreasedDebtAmount, tradingFee) = _checkAndUpdateAmount(
            position,
            false,
            oracleDecimals,
            position.takeProfit,
            _assetAmountToDecrease,
            _debtAmount,
            _tradingFee
        );

        (owedAsset, owedDebt) = _afterFlatPosition(
            _positionId,
            position,
            decreasedAssetAmount,
            decreasedDebtAmount,
            tradingFee,
            _debtAmount,
            true,
            oracleDecimals,
            assetDecimals,
            debtDecimals,
            marginDecimals,
            assetPrice,
            debtPrice,
            marginPrice
        );
    }

    function stopLoss(
        IAssetOracle _oracle,
        uint256 _positionId,
        uint256 _assetAmountToDecrease,
        uint256 _tradingFee,
        uint256 _debtAmount
    ) external override nonReentrant onlyNotPaused onlyTradingCore returns (
        uint256 decreasedAssetAmount,
        uint256 decreasedDebtAmount,
        uint256 owedAsset,
        uint256 owedDebt,
        uint256 tradingFee
    ) {
        Position memory position = positions[_positionId];
        if (position.status != PositionStatus.Open) revert InvalidPositionStatus();
        if (position.stopLoss == 0) revert NoStopLoss();

        (
            uint8 oracleDecimals,
            uint8 assetDecimals,
            uint8 debtDecimals,
            uint8 marginDecimals,
            ,
            ,
            ,
            uint256 assetPrice,
            uint256 debtPrice,
            uint256 marginPrice
        ) = _getTokensInfo(_oracle, position.isLongToken0);
        uint256 assetPriceInDebt = _getRelativePrice(assetPrice, debtPrice, oracleDecimals);
        if (assetPriceInDebt > position.stopLoss) revert PassivelyCloseConditionNotMet();

        (decreasedAssetAmount, decreasedDebtAmount, tradingFee) = _checkAndUpdateAmount(
            position,
            false,
            oracleDecimals,
            assetPriceInDebt,
            _assetAmountToDecrease,
            _debtAmount,
            _tradingFee
        );

        (owedAsset, owedDebt) = _afterFlatPosition(
            _positionId,
            position,
            decreasedAssetAmount,
            decreasedDebtAmount,
            tradingFee,
            _debtAmount,
            true,
            oracleDecimals,
            assetDecimals,
            debtDecimals,
            marginDecimals,
            assetPrice,
            debtPrice,
            marginPrice
        );
    }

    function liquidate(
        IAssetOracle _oracle,
        uint256 _positionId,
        uint256 _assetAmountToDecrease,
        uint256 _tradingFee,
        uint256 _debtAmount
    ) external override nonReentrant onlyNotPaused onlyTradingCore returns (
        uint256 decreasedAssetAmount,
        uint256 decreasedDebtAmount,
        uint256 owedAsset,
        uint256 owedDebt,
        uint256 tradingFee
    ) {
        Position memory position = positions[_positionId];
        if (position.status != PositionStatus.Open) revert InvalidPositionStatus();

        (
            uint8 oracleDecimals,
            uint8 assetDecimals,
            uint8 debtDecimals,
            uint8 marginDecimals,
            ,
            ,
            ,
            uint256 assetPrice,
            uint256 debtPrice,
            uint256 marginPrice
        ) = _getTokensInfo(_oracle, position.isLongToken0);

        uint256 debtValue = _getTokenValue(oracleDecimals, debtDecimals, _debtAmount, debtPrice);
        uint256 assetValue = _getTokenValue(oracleDecimals, assetDecimals, position.assetAmount, assetPrice);
        uint256 marginValue = _getTokenValue(oracleDecimals, marginDecimals, position.marginAmount, marginPrice);
        uint256 lossRatio = _calculateLossRatio(marginValue, assetValue, debtValue);
        if (lossRatio < openPositionLossRatioThreshold) revert PassivelyCloseConditionNotMet();

        uint256 assetPriceInDebt = _getRelativePrice(assetPrice, debtPrice, oracleDecimals);
        uint256 liquidatePrice = assetPriceInDebt.mulDiv(
            Percent.MULTIPLIER,
            Percent.MULTIPLIER - liquidationDiscount,
            Math.Rounding.Ceil
        );

        (decreasedAssetAmount, decreasedDebtAmount, tradingFee) = _checkAndUpdateAmount(
            position,
            false,
            oracleDecimals,
            liquidatePrice,
            _assetAmountToDecrease,
            _debtAmount,
            _tradingFee
        );

        (owedAsset, owedDebt) = _afterFlatPosition(
            _positionId,
            position,
            decreasedAssetAmount,
            decreasedDebtAmount,
            _tradingFee,
            _debtAmount,
            false,
            oracleDecimals,
            assetDecimals,
            debtDecimals,
            marginDecimals,
            assetPrice,
            debtPrice,
            marginPrice
        );
    }

    function _checkAndUpdateAmount(
        Position memory _position,
        bool _isLiquidation,
        uint8 _oracleDecimals,
        uint256 _assetPriceInDebt,
        uint256 _assetAmountToDecrease,
        uint256 _debtAmount,
        uint256 _tradingFee
    ) internal pure returns (
        uint256 decreasedAssetAmount,
        uint256 decreasedDebtAmount,
        uint256 tradingFee
    ) {
        uint256 maxDecreasedAssetAmount = _debtAmount.mulDiv(10 ** _oracleDecimals, _assetPriceInDebt);
        if (maxDecreasedAssetAmount > _position.swappableAmount) {
            if (!_isLiquidation) revert ShouldUseLiquidation(); 

            maxDecreasedAssetAmount = _position.swappableAmount;
        }
        (decreasedAssetAmount, tradingFee) = _assetAmountToDecrease > maxDecreasedAssetAmount ? 
            (maxDecreasedAssetAmount, _tradingFee.mulDiv(maxDecreasedAssetAmount, _assetAmountToDecrease, Math.Rounding.Ceil)) : 
            (_assetAmountToDecrease, _tradingFee);
        decreasedDebtAmount = decreasedAssetAmount.mulDiv(_assetPriceInDebt, decreasedAssetAmount, Math.Rounding.Ceil);
    }

    function _afterFlatPosition(
        uint256 _positionId,
        Position memory _position,
        uint256 _decreasedAssetAmount,
        uint256 _decreasedDebtAmount,
        uint256 _tradingFee,
        uint256 _debtAmount,
        bool _ensureNotLiquidated,
        uint8 oracleDecimals,
        uint8 assetDecimals,
        uint8 debtDecimals,
        uint8 marginDecimals,
        uint256 assetPrice,
        uint256 debtPrice,
        uint256 marginPrice
    ) internal returns (
        uint256 owedAsset,
        uint256 owedDebt
    ) {
        _position.swappableAmount = _position.swappableAmount - _decreasedAssetAmount;
        if (_decreasedAssetAmount > _position.assetAmount) {
            _position.marginAmount = _position.swappableAmount;
            _position.assetAmount = 0;
        }
        else {
            _position.assetAmount = _position.assetAmount - _decreasedAssetAmount;
        }

        bool isAllRepaid;
        uint256 overRepaidDebt;
        uint256 newDebtAmount;
        if (_decreasedDebtAmount >= _debtAmount) {
            isAllRepaid = true;
            overRepaidDebt = _decreasedDebtAmount - _debtAmount;
            newDebtAmount = 0;
        }
        else {
            newDebtAmount = _debtAmount - _decreasedDebtAmount;
            if (!_position.isMarginAsset && _position.marginAmount >= newDebtAmount) {
                isAllRepaid = true;
                _position.marginAmount = _position.marginAmount - newDebtAmount;
                newDebtAmount = 0;
            }
        }

        if (isAllRepaid) {
            (owedAsset, owedDebt) = _position.isMarginAsset ? 
                (_position.assetAmount + _position.marginAmount, overRepaidDebt) : 
                (_position.assetAmount, _position.marginAmount + overRepaidDebt);
            _position.status = PositionStatus.Closed;
        }
        else if (_ensureNotLiquidated) {
            uint256 debtValue = _getTokenValue(oracleDecimals, debtDecimals, newDebtAmount, debtPrice);
            uint256 assetValue = _getTokenValue(oracleDecimals, assetDecimals, _position.assetAmount, assetPrice);
            uint256 marginValue = _getTokenValue(oracleDecimals, marginDecimals, _position.marginAmount, marginPrice);
            uint256 lossRatio = _calculateLossRatio(marginValue, assetValue, debtValue);
            if (lossRatio > liquidateLossRatioThreshold) revert HighLossRatio();
        }

        _updateMarketStatus(
            _position.isLongToken0,
            false,
            _decreasedAssetAmount + _tradingFee,
            assetDecimals,
            oracleDecimals,
            assetPrice
        );
        positions[_positionId] = _position;
    }

    function _getTokensInfo(
        IAssetOracle _oracle,
        bool _isLongToken0
    ) internal view returns (
        uint8 oracleDecimals,
        uint8 assetDecimals,
        uint8 debtDecimals,
        uint8 marginDecimals,
        address asset,       
        address debt,
        address margin,
        uint256 assetPrice,
        uint256 debtPrice,
        uint256 marginPrice
    ) {
        oracleDecimals = _oracle.decimals();
        (asset, debt, assetDecimals, debtDecimals) = _isLongToken0 ? 
            (token0, token1, token0Decimals, token1Decimals) : 
            (token1, token0, token1Decimals, token0Decimals);
            
        debtPrice = _oracle.getPrice(debt);
        assetPrice = _oracle.getPrice(asset);

        (margin, marginPrice, marginDecimals) = _isLongToken0 == isToken0Margin ? 
            (asset, assetPrice, assetDecimals) : 
            (debt, debtPrice, debtDecimals);
    }

    function _getTokenValue(
        uint8 _oracleDecimals,
        uint8 _tokenDecimals,
        uint256 _tokenAmount,
        uint256 _tokenPrice
    ) internal pure returns (
        uint256 value
    ) {
        value = _tokenAmount.mulDiv(_tokenPrice, 10 ** (_oracleDecimals + _tokenDecimals));
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

    function _getLiquidationAssetDebtRatio(uint24 _leverage) internal view returns (uint24 liquidationAssetDebtRatio) {
        liquidationAssetDebtRatio = Percent.MULTIPLIER - liquidateLossRatioThreshold / _leverage;
    }

    function _updateMarketStatus(
        bool _isAssetToken0,
        bool _isIncrease,
        uint256 _changeAmount,
        uint8 _assetDecimals,
        uint8 _oracleDecimals,
        uint256 _assetPrice
    ) internal {
        if (_isIncrease) {
            uint256 totalPositionAmount;
            if (_isAssetToken0) {
                totalToken0PositionAmount = totalToken0PositionAmount + _changeAmount;
                totalPositionAmount = totalToken0PositionAmount;
            }
            else {
                totalToken1PositionAmount = totalToken1PositionAmount + _changeAmount;
                totalPositionAmount = totalToken1PositionAmount;
            }
            if (
                totalPositionAmount.mulDiv(_assetPrice, 10 ** (_assetDecimals + _oracleDecimals)) > positionSizeCap
            ) revert ExceedsMaxTotalPositionSize();
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