// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import {IAssetOracle} from "./IAssetOracle.sol";
import {IRouter} from "../lending/IRouter.sol";

interface IMarketNFT {

    error InvalidLeverage();
    error InvalidThreshold();
    error ZeroNotAllowed();
    error InvalidDiscountRate();
    error InvalidTakeProfit();
    error InvalidStopLoss();
    error HighLossRatio();
    error ExceedsMaxTotalPositionSize();
    error InvalidPositionStatus();
    error CallerIsNotTradingCore();
    error PassivelyCloseConditionNotMet();
    error NoTakeProfit();
    error NoStopLoss();
    error WorsePrice();

    /// @notice Position status
    /// @param Inactive Default inactive type
    /// @param Open Opened position
    /// @param Closed Closed position
    enum PositionStatus {
        Inactive,
        Open,
        Closed
    }

    /// @notice Position close mode
    /// @param Close Actively closed by position owner
    /// @param StopLoss Passively closed when the stop loss price is hit
    /// @param TakeProfit Passively closed when the take profit price is hit
    /// @param Liquidate Passively closed when the liquidation condition is met
    enum CloseMode {
        Close,
        StopLoss,
        TakeProfit,
        Liquidate
    }

    /// @notice Position related data
    /// @param status Position status, refer to enum of PositionStatus
    /// @param isLongToken0 Position trading direction, long token0/short token1 or not
    /// @param isMarginAsset Whether margin is same as position asset, depending on the trading direction
    /// @param initialLeverage Initial leverage, equals to the debt vaule divided by the margin value 
    /// @param marginAmount Margin amount of the position
    /// @param interestRateModelType Position lending mode, refer to enum of IRouter.InterestRateModelType
    /// @param borrowId Position lending id
    /// @param assetAmount Asset amount of the position
    /// @param swappableAmount Swappable amount of the position when closing position, depending on the trading direction
    /// @param takeProfit Take profit price
    /// @param stopLoss Stop loss price
    struct Position {
        PositionStatus status;
        bool isLongToken0;
        bool isMarginAsset;
        uint24 initialLeverage;
        uint256 marginAmount;
        IRouter.InterestRateModelType interestRateModelType;
        uint256 borrowId;
        uint256 assetAmount;
        uint256 swappableAmount;
        uint256 takeProfit;
        uint256 stopLoss;
    }

    /// @notice Pause operations for this market
    function pause() external;

    /// @notice Unpause operations for this market
    function unpause() external;


    function setMaxLeverage(uint24 maxLeverage) external;

    function setMarketRatioParams(
        uint24 openPositionLossRatioThreshold,
        uint24 liquidateLossRatioThreshold,
        uint24 liquidationDiscount
    ) external;

    function setPositionSizeCap(uint256 token0PositionSizeCap, uint256 token1PositionSizeCap) external;
    
    /// @notice Return whether token0 is set as the margin
    /// @return isToken0Margin whether token0 is the margin
    function isToken0Margin() external view returns (bool);
    
    /// @notice Get position by the given id
    /// @param positionId Position id, same as ERC721 token id
    /// @return position Position of the given id
    function getPosition(uint256 positionId) external view returns (Position memory position);
    
    /// @notice TODO
    /// @param account Position owner
    /// @param interestRateModelType Position lending mode
    /// @param borrowId Position lending id
    /// @param isLongToken0 Position trading direction, long token0/short token1 or not
    /// @param marginAmount Margin amount of the position
    /// @param debtAmount Debt amount of the position
    /// @param assetAmount Asset amount of the position
    /// @param takeProfit Take profit price
    /// @param stopLoss Stop loss price
    /// @return positionId Position id
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
    
    /// @notice TODO
    /// @param positionId Position id
    /// @param addedAmount TODO
    function addMargin(uint256 positionId, uint256 addedAmount) external;
    
    /// @notice TODO
    /// @param mode TODO
    /// @param positionId TODO
    /// @param decreasedAssetAmount TODO
    /// @param decreasedDebtAmount TODO
    /// @param tradingFee TODO
    /// @param debtAmount TODO
    /// @return isFullyClosed TODO
    /// @return decreasedMarginAmount TODO
    /// @return owedAsset TODO
    /// @return owedDebt TODO
    function closePosition(
        CloseMode mode,
        uint256 positionId,
        uint256 decreasedAssetAmount,
        uint256 decreasedDebtAmount,
        uint256 tradingFee,
        uint256 debtAmount
    ) external returns (
        bool isFullyClosed,
        uint256 decreasedMarginAmount,
        uint256 owedAsset,
        uint256 owedDebt
    );
    
    /// @notice get token prices
    /// @return decimals Oracle decimals
    /// @return price0 Token0 price
    /// @return price1 Token1 price
    function getTokenPrices() external view returns (uint8 decimals, uint256 price0, uint256 price1);
    
    /// @notice TODO
    /// @param isLongToken0 TODO
    /// @return price TODO
    function liquidateAuctionPrice(bool isLongToken0) external view returns (uint256 price);
    
    /// @notice Get liquidation price of the position
    /// @param positionId Position id
    /// @param debtAmount Position debt amount
    /// @return price Liquidation price
    function getLiquidationPrice(
        uint256 positionId,
        uint256 debtAmount
    ) external view returns (uint256 price);

}