// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import {IAssetOracle} from "./IAssetOracle.sol";
import {IRouter} from "../lending/IRouter.sol";

interface IMarketNFT {

    error InvalidLeverage();
    error InvalidThreshold();
    error ZeroCapNotAllowed();
    error InvalidDiscountRate();
    error InvalidTakeProfit();
    error InvalidStopLoss();
    error HighLossRatio();
    error ExceedsMaxTotalPositionSize();
    error InvalidPositionStatus();
    error InvalidAssetDebtRatio();
    error CallerIsNotTradingCore();
    error PassivelyCloseConditionNotMet();
    error NoTakeProfit();
    error NoStopLoss();
    error WorsePrice();

    enum PositionStatus {
        Inactive,
        Open,
        Closed
    }

    enum CloseMode {
        Close,
        StopLoss,
        TakeProfit,
        Liquidate
    }

    struct Position {
        PositionStatus status;
        bool isLongToken0;
        bool isMarginAsset;
        uint24 initialLeverage;
        uint24 liquidationAssetDebtRatio;
        uint256 marginAmount;
        IRouter.InterestRateModelType interestRateModelType;
        uint256 borrowId;
        uint256 assetAmount;
        uint256 swappableAmount;
        uint256 takeProfit;
        uint256 stopLoss;
    }

    function pause() external;
    function unpause() external;
    function isToken0Margin() external view returns (bool);
    function getPosition(uint256 positionId) external view returns (Position memory position);
    function openPosition(
        address account,
        IRouter.InterestRateModelType interestRateModelType,
        uint256 borrowId,
        bool isLongToken0,
        uint256 marginAmount,
        uint256 debtAmount,
        uint256 assetAmount,
        uint256 takeProfit,
        uint256 stopLoss
    ) external returns (
        uint256 positionId
    );
    function addMargin(
        uint256 positionId,
        uint256 debtAmount,
        uint24 newLiquidationAssetDebtRatio
    ) external returns (
        uint256 requiredAmount
    );
    function closePosition(
        CloseMode mode,
        uint256 positionId,
        uint256 decreasedAssetAmount,
        uint256 decreasedDebtAmount,
        uint256 tradingFee,
        uint256 debtAmount
    ) external returns (
        bool isFullyClosed,
        uint256 owedAsset,
        uint256 owedDebt
    );
    function getTokenPrices() external view returns (uint256 price0, uint256 price1);
    function liquidateAuctionPrice(bool isLongToken0) external view returns (uint256 price);
    function getLiquidationPrice(
        uint256 _positionId,
        uint256 _debtAmount
    ) external view returns (uint256 price);

}