// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

import {IAssetOracle} from "./IAssetOracle.sol";
import {IRouter} from "../lending/IRouter.sol";

interface IMarketNFT {

    error InvalidLeverage();
    error InvalidThreshold();
    error ZeroNotAllowed();
    error InvalidDiscountRate();
    error InvalidTakeProfit();
    error InvalidStopLoss();
    error InvalidStopLossRateTolerance();
    error HighLossRatio();
    error BadCloseRate();
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
    /// @param stopLossRateTolerance Stop loss price slippage or market rate tolerance
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
        uint24 stopLossRateTolerance;
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
    /// @notice Only owner can call this function
    function pause() external;

    /// @notice Unpause operations for this market
    /// @notice Only owner can call this function
    function unpause() external;

    /// @notice Change oracle for price feed
    /// @notice Only owner can call this function
    function changeOracle(IAssetOracle oracle) external;

    /// @notice Set max leverage of the market
    /// @param maxLeverage Max leverage of the market
    function setMaxLeverage(uint24 maxLeverage) external;

    /// @notice Set market params
    /// @param openPositionLossRatioThreshold Tolerance of loss ratio when opening position which loss ratio equals to [value(asset) - value(debt)] / value(margin)
    /// @param liquidateLossRatioThreshold Liquidation threshold of loss ratio, position can be liquidated after the loss ratio is greater than the threshold
    /// @param liquidationDiscount Position asset will be in auction mode with a discount ratio in order to liquidate in time if the liquidation condition is met
    function setMarketRatioParams(
        uint24 openPositionLossRatioThreshold,
        uint24 liquidateLossRatioThreshold,
        uint24 liquidationDiscount
    ) external;

    /// @notice Set position size cap for the market
    /// @notice Only owner can call this function
    /// @param token0PositionSizeCap Size cap of token0
    /// @param token1PositionSizeCap Size cap of token1
    function setPositionSizeCap(uint256 token0PositionSizeCap, uint256 token1PositionSizeCap) external;
    
    /// @notice Return whether token0 is set as the margin
    /// @return isToken0Margin whether token0 is the margin
    function isToken0Margin() external view returns (bool);
    
    /// @notice Get position by the given id
    /// @param positionId Position id, same as ERC721 token id
    /// @return position Position of the given id
    function getPosition(uint256 positionId) external view returns (Position memory position);
    
    /// @notice Open a position
    /// @notice Loss ratio must be not greater than openPositionLossRatioThreshold
    /// @param account Position owner
    /// @param interestRateModelType Position lending mode
    /// @param borrowId Position lending id
    /// @param isLongToken0 Position trading direction, long token0/short token1 or not
    /// @param marginAmount Margin amount of the position
    /// @param debtAmount Debt amount of the position
    /// @param assetAmount Asset amount of the position
    /// @param takeProfit Take profit price, the price is asset price in debt
    /// @param stopLoss Stop loss price, the price is asset price in debt
    /// @param stopLossRateTolerance Stop loss price slippage or market rate tolerance
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
        uint256 stopLoss,
        uint24 stopLossRateTolerance
    ) external returns (
        uint256 positionId
    );

    /// @notice Set take profit and stop loss price for the position
    /// @param positionId Position id
    /// @param takeProfit Take profit price, the price is asset price in debt
    /// @param stopLoss Stop loss price, the price is asset price in debt
    /// @param stopLossRateTolerance Stop loss price slippage or market rate tolerance
    function modifyPassiveClosePrice(
        uint256 positionId,
        uint256 takeProfit,
        uint256 stopLoss,
        uint24 stopLossRateTolerance
    ) external;
    
    /// @notice Add margin for a position in order to prevent getting liquidated
    /// @param positionId Position id
    /// @param addedAmount Amount of margin asset to add
    function addMargin(uint256 positionId, uint256 addedAmount) external;
    
    /// @notice Close a position
    /// @notice Should not close with potentional risk of being not able to repay the debt, unless liquidation
    /// @notice When not liquidation, the decreased ratio of debt needs not to be less than the ratio of consumed asset token plus the same ratio of margin
    /// @dev If margin token is same as asset token, require consumed / swappable < decreasedDebt / totalDebt
    /// @dev If margin token is same as debt token, require consumed / swappable < [decreasedDebt + (consumed / swappable) * margin] / totalDebt
    /// @dev Swappable equals to asset amount plus margin amount if margin token is same as asset token, asset amount otherwise
    /// @dev Consumed asset token equals to swapped asset token plus trading fee
    /// @param mode Close mode, refer to CloseMode structure
    /// @param positionId Position id
    /// @param swappedAssetToken Amount of the comsumed asset token
    /// @param decreasedDebtAmount Amount of debt token from swapped asset token
    /// @param tradingFee Plateform trading fee in form of asset token
    /// @param debtAmount Amount of debt before closing position
    /// @return isFullyClosed Whether a position is fully closed or not, fully closed if asset or debt of a position go to zero
    /// @return decreasedMarginAmount Amount of decreased margin amount, greater than zero when a position is closed with loss
    /// @return owedAsset Asset tokens the position owner is owed
    /// @return owedDebt Debt tokens the position owner is owed
    function closePosition(
        CloseMode mode,
        uint256 positionId,
        uint256 swappedAssetToken,
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
    /// @return price0 Token0 oracle price
    /// @return price1 Token1 oracle price
    function getTokenPrices() external view returns (uint8 decimals, uint256 price0, uint256 price1);
    
    /// @notice Get current liquidation auction price for all positions that meet the liquidation condition
    /// @param isLongToken0 Whether position is longing token0 or not
    /// @return price Position asset auction price in debt
    function liquidateAuctionPrice(bool isLongToken0) external view returns (uint256 price);
    
    /// @notice Get liquidation price of the position
    /// @param positionId Position id
    /// @param debtAmount Position debt amount
    /// @return price Liquidation price in debt
    function getLiquidationPrice(
        uint256 positionId,
        uint256 debtAmount
    ) external view returns (uint256 price);

}