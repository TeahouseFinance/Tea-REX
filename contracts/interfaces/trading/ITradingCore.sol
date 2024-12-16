// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

import {IAssetOracle} from "./IAssetOracle.sol";
import {IRouter} from "../lending/IRouter.sol";
import {IMarketNFT} from "./IMarketNFT.sol";
import {ICalldataProcessor} from "./ICalldataProcessor.sol";


interface ITradingCore {

    error ExceedsFeeCap();
    error ZeroNotAllowed();
    error WrongTokenOrder();
    error AssetNotEnabled();
    error MarketAlreadyCreated();
    error PairNotCreated();
    error NotPositionOwner();
    error PriceConditionNotMet();
    error IdenticalAddress();
    error SlippageTooLarge();
    error AmountExceedsLimit();
    error NotInWhitelist();
    error InvalidAsset();

    event CreateMarket(address indexed sender, IMarketNFT indexed market, ERC20PermitUpgradeable token0, ERC20PermitUpgradeable token1);
    event SetFeeConfig(address indexed sender, uint256 timestamp, FeeConfig feeConfig);
    event CollectTradingFee(ERC20PermitUpgradeable token, FeeConfig feeConfig, uint256 fee);
    event OpenPosition(IMarketNFT indexed market, uint256 indexed positionId);
    event ModifyPassiveClosePrice(IMarketNFT indexed market, uint256 indexed positionId, uint256 takeProfit, uint256 stopLoss, uint24 stopLossRateTolerance);
    event AddMargin(IMarketNFT indexed market, uint256 indexed positionId, uint256 addedAmount);
    event ClosePosition(IMarketNFT indexed market, uint256 indexed positionId, bool indexed isFullyClosed, uint256 assetReceived, uint256 debtReceived, uint256 swappedAssetToken, uint256 decreasedDebtAmount, uint256 decreasedMarginAmount);
    event TakeProfit(IMarketNFT indexed market, uint256 indexed positionId, bool indexed isFullyClosed, uint256 assetReceived, uint256 debtReceived, uint256 swappedAssetToken, uint256 decreasedDebtAmount, uint256 decreasedMarginAmount);
    event StopLoss(IMarketNFT indexed market, uint256 indexed positionId, bool indexed isFullyClosed, uint256 assetReceived, uint256 debtReceived, uint256 swappedAssetToken, uint256 decreasedDebtAmount, uint256 decreasedMarginAmount);
    event Liquidate(IMarketNFT indexed market, uint256 indexed positionId, bool indexed isFullyClosed, uint256 assetReceived, uint256 debtReceived, uint256 swappedAssetToken, uint256 decreasedDebtAmount, uint256 decreasedMarginAmount);

    /// @notice Fee config structure
    /// @param treasury Fees go to this address
    /// @param tradingFee Trading fee rate
    /// @param liquidationFee Liquidation fee rate
    struct FeeConfig {
        address treasury;
        uint32 tradingFee;
        uint32 liquidationFee;
    }

    /// @notice Pause operations for the trading core and all the markets
    /// @notice Only owner can call this function
    function pause() external;

    /// @notice Unpause operations for the trading core and all the markets
    /// @notice Only owner can call this function
    function unpause() external;

    /// @notice Get if all markets are paused or not
    /// return isPaused All markets are paused or not
    function isAllMarketPaused() external view returns (bool);

    /// @notice Create a new trading pair market
    /// @notice Only owner can call this function
    /// @param oracle Oracle to be used
    /// @param token0 token0 of the trading pair
    /// @param token1 token1 of the trading pair
    /// @param isToken0Margin Whether token0 is margin or not
    /// @param maxLeverage Max leverage of the market
    /// @param openPositionLossRatioThreshold Tolerance of loss ratio when opening position which loss ratio equals to [value(asset) - value(debt)] / value(margin)
    /// @param liquidateLossRatioThreshold Liquidation threshold of loss ratio, position can be liquidated after the loss ratio is greater than the threshold
    /// @param liquidationDiscount Position asset will be in auction mode with a discount ratio in order to liquidate in time if the liquidation condition is met
    /// @param longPositionSizeCap Size cap of longing token0
    /// @param shortPositionSizeCap Size cap of shorting token0
    /// @return marketAddress Address of the created market
    function createMarket(
        IAssetOracle oracle,
        ERC20PermitUpgradeable token0,
        ERC20PermitUpgradeable token1,
        bool isToken0Margin,
        uint32 maxLeverage,
        uint24 openPositionLossRatioThreshold,
        uint24 liquidateLossRatioThreshold,
        uint24 liquidationDiscount,
        uint256 longPositionSizeCap,
        uint256 shortPositionSizeCap
    ) external returns (
        address marketAddress
    );

    /// @notice Open a position with user's signature
    /// @param market Market address
    /// @param interestRateModelType Type of the interest rate model
    /// @param longTarget Long target, must be one of token0 or token1
    /// @param marginAmount Margin amount for the position
    /// @param borrowAmount Amount of borrowed token for swapping to asset token
    /// @param minAssetAmount Minimum asset swap after swap, a slippage protection
    /// @param takeProfit Take profit price, the price is asset price in debt
    /// @param stopLoss Stop loss price, the price is asset price in debt
    /// @param stopLossRateTolerance Stop loss price slippage or market rate tolerance
    /// @param swapRouter Swap router to be used
    /// @param data Calldata for the assigned swap router
    /// @param deadline ERC20Permit deadline of approval
    /// @param v Secp256k1 signature from the token owner over the EIP712-formatted function argument
    /// @param r Secp256k1 signature from the token owner over the EIP712-formatted function argument
    /// @param s Secp256k1 signature from the token owner over the EIP712-formatted function argument
    /// @return positionId Position id, same as ERC721 token id
    function openPositionPermit(
        address market,
        IRouter.InterestRateModelType interestRateModelType,
        ERC20PermitUpgradeable longTarget,
        uint256 marginAmount,
        uint256 borrowAmount,
        uint256 minAssetAmount,
        uint256 takeProfit,
        uint256 stopLoss,
        uint24 stopLossRateTolerance,
        address swapRouter,
        bytes calldata data,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (
        uint256 positionId
    );

    /// @notice Open a position
    /// @param market Market address
    /// @param interestRateModelType Type of the interest rate model
    /// @param longTarget Long target, must be one of token0 or token1
    /// @param marginAmount Margin amount for the position
    /// @param borrowAmount Amount of borrowed token for swapping to asset token
    /// @param minAssetAmount Minimum asset swap after swap, a slippage protection
    /// @param takeProfit Take profit price, the price is asset price in debt
    /// @param stopLoss Stop loss price, the price is asset price in debt
    /// @param stopLossRateTolerance Stop loss price slippage or market rate tolerance
    /// @param swapRouter Swap router to be used
    /// @param data Calldata for the assigned swap router
    /// @return positionId Position id, same as ERC721 token id
    function openPosition(
        address market,
        IRouter.InterestRateModelType interestRateModelType,
        ERC20PermitUpgradeable longTarget,
        uint256 marginAmount,
        uint256 borrowAmount,
        uint256 minAssetAmount,
        uint256 takeProfit,
        uint256 stopLoss,
        uint24 stopLossRateTolerance,
        address swapRouter,
        bytes calldata data
    ) external returns (
        uint256 positionId
    );

    /// @notice Set take profit and stop loss price for the position
    /// @param market Market address
    /// @param positionId Position id
    /// @param takeProfit Take profit price, the price is asset price in debt
    /// @param stopLoss Stop loss price, the price is asset price in debt
    /// @param stopLossRateTolerance Stop loss price slippage or market rate tolerance
    function modifyPassiveClosePrice(
        address market,
        uint256 positionId,
        uint256 takeProfit,
        uint256 stopLoss,
        uint24 stopLossRateTolerance
    ) external;

    /// @notice Add margin for a position in order to prevent getting liquidated with user's signature
    /// @param market Market address
    /// @param positionId Position id
    /// @param addedAmount Amount of margin asset to add
    /// @param deadline ERC20Permit deadline of approval
    /// @param v Secp256k1 signature from the token owner over the EIP712-formatted function argument
    /// @param r Secp256k1 signature from the token owner over the EIP712-formatted function argument
    /// @param s Secp256k1 signature from the token owner over the EIP712-formatted function argument
    function addMarginPermit(
        address market,
        uint256 positionId,
        uint256 addedAmount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /// @notice Add margin for a position in order to prevent getting liquidated
    /// @param market Market address
    /// @param positionId Position id
    /// @param addedAmount Amount of margin asset to add
    function addMargin(
        address market,
        uint256 positionId,
        uint256 addedAmount
    ) external;

    /// @notice Close a positiom actively
    /// @notice Only position owner can do this
    /// @param market Market address
    /// @param positionId Position id
    /// @param assetTokenToSwap Amount of asset token to swap
    /// @param minDecreasedDebtAmount Minimum amount of debt token after swap, a slippage protection
    /// @param calldataProcessor Address of the calldata modifier for modifying the swap calldata
    /// @param swapRouter Swap router to be used
    /// @param data Calldata for the assigned swap router
    /// @return isFullyClosed Whether a position is fully closed or not, fully closed if asset or debt of a position go to zero
    /// @return swappedAssetToken Amount of the comsumed asset token
    /// @return decreasedDebtAmount Amount of debt token from swapped asset token
    /// @return decreasedMarginAmount Amount of decreased margin amount, greater than zero when a position is closed with loss
    /// @return owedAsset Asset tokens the position owner is owed
    /// @return owedDebt Debt tokens the position owner is owed
    function closePosition(
        address market,
        uint256 positionId,
        uint256 assetTokenToSwap,
        uint256 minDecreasedDebtAmount,
        ICalldataProcessor calldataProcessor,
        address swapRouter,
        bytes calldata data
    ) external returns (
        bool isFullyClosed,
        uint256 swappedAssetToken,
        uint256 decreasedDebtAmount,
        uint256 decreasedMarginAmount,
        uint256 owedAsset,
        uint256 owedDebt
    );
    
    /// @notice Passively close position if the take profit condition is met
    /// @notice Exchange rate without trading fee needs to be not less than the pre-set take profit price
    /// @param market Market address
    /// @param positionId Position id
    /// @param assetTokenToSwap Amount of asset token to swap
    /// @param minDecreasedDebtAmount Minimum amount of debt token after swap, a slippage protection
    /// @param calldataProcessor Address of the calldata modifier for modifying the swap calldata
    /// @param swapRouter Swap router to be used
    /// @param data Calldata for the assigned swap router
    /// @return isFullyClosed Whether a position is fully closed or not, fully closed if asset or debt of a position go to zero
    /// @return swappedAssetToken Amount of the comsumed asset token
    /// @return decreasedDebtAmount Amount of debt token from swapped asset token
    /// @return decreasedMarginAmount Amount of decreased margin amount, greater than zero when a position is closed with loss
    /// @return owedAsset Asset tokens the position owner is owed
    /// @return owedDebt Debt tokens the position owner is owed
    function takeProfit(
        address market,
        uint256 positionId,
        uint256 assetTokenToSwap,
        uint256 minDecreasedDebtAmount,
        ICalldataProcessor calldataProcessor,
        address swapRouter,
        bytes calldata data
    ) external returns (
        bool isFullyClosed,
        uint256 swappedAssetToken,
        uint256 decreasedDebtAmount,
        uint256 decreasedMarginAmount,
        uint256 owedAsset,
        uint256 owedDebt
    );

    /// @notice Passively close position if the stop loss condition is met
    /// @notice Exchange rate without trading fee needs to be not less than the oracle price
    /// @param market Market address
    /// @param positionId Position id
    /// @param assetTokenToSwap Amount of asset token to swap
    /// @param minDecreasedDebtAmount Minimum amount of debt token after swap, a slippage protection
    /// @param calldataProcessor Address of the calldata modifier for modifying the swap calldata
    /// @param swapRouter Swap router to be used
    /// @param data Calldata for the assigned swap router
    /// @return isFullyClosed Whether a position is fully closed or not, fully closed if asset or debt of a position go to zero
    /// @return swappedAssetToken Amount of the comsumed asset token
    /// @return decreasedDebtAmount Amount of debt token from swapped asset token
    /// @return decreasedMarginAmount Amount of decreased margin amount, greater than zero when a position is closed with loss
    /// @return owedAsset Asset tokens the position owner is owed
    /// @return owedDebt Debt tokens the position owner is owed
    function stopLoss(
        address market,
        uint256 positionId,
        uint256 assetTokenToSwap,
        uint256 minDecreasedDebtAmount,
        ICalldataProcessor calldataProcessor,
        address swapRouter,
        bytes calldata data
    ) external returns (
        bool isFullyClosed,
        uint256 swappedAssetToken,
        uint256 decreasedDebtAmount,
        uint256 decreasedMarginAmount,
        uint256 owedAsset,
        uint256 owedDebt
    );

    /// @notice Passively close position if the liquidation condition is met
    /// @notice Exchange rate without trading fee needs to be not less than the oracle price with a discount ratio of liquidationDiscount
    /// @param market Market address
    /// @param positionId Position id
    /// @param assetTokenToSwap Amount of asset token to swap
    /// @param minDecreasedDebtAmount Minimum amount of debt token after swap, a slippage protection
    /// @param calldataProcessor Address of the calldata modifier for modifying the swap calldata
    /// @param swapRouter Swap router to be used
    /// @param data Calldata for the assigned swap router
    /// @return isFullyClosed Whether a position is fully closed or not, fully closed if asset or debt of a position go to zero
    /// @return swappedAssetToken Amount of the comsumed asset token
    /// @return decreasedDebtAmount Amount of debt token from swapped asset token
    /// @return decreasedMarginAmount Amount of decreased margin amount, greater than zero when a position is closed with loss
    /// @return owedAsset Asset tokens the position owner is owed
    /// @return owedDebt Debt tokens the position owner is owed
    function liquidate(
        address market,
        uint256 positionId,
        uint256 assetTokenToSwap,
        uint256 minDecreasedDebtAmount,
        ICalldataProcessor calldataProcessor,
        address swapRouter,
        bytes calldata data
    ) external returns (
        bool isFullyClosed,
        uint256 swappedAssetToken,
        uint256 decreasedDebtAmount,
        uint256 decreasedMarginAmount,
        uint256 owedAsset,
        uint256 owedDebt
    );

    /// @notice Get the amount of the position's debt
    /// @param market Market address
    /// @param positionId Position id
    /// @return asset Address of the position asset token
    /// @return debt Address of the position debt token
    /// @return debtAmount Amount of the position's debt
    function debtOfPosition(
        address market,
        uint256 positionId
    ) external returns (
        ERC20PermitUpgradeable asset,
        ERC20PermitUpgradeable debt,
        uint256 debtAmount
    );

    /// @notice Get current liquidation auction price for all positions that meet the liquidation condition
    /// @param market Market address
    /// @param longTarget Long target of the market
    /// @return price Position asset auction price in debt
    function liquidateAuctionPrice(
        address market,
        ERC20PermitUpgradeable longTarget
    ) external view returns (
        uint256 price
    );

    /// @notice Get liquidation price of the position
    /// @param market Market address
    /// @param positionId Position id
    /// @return price Liquidation price in debt
    function getLiquidationPrice(
        address market,
        uint256 positionId
    ) external view returns (
        uint256 price
    );

    /// @notice Get position swappable asset token in consideration of trading fee when closing position
    /// @param market Market address
    /// @param positionId Position id
    /// @param mode Mode of closing mode
    /// @return swappableAfterFee Amount of position swappable asset token in consideration of trading fee
    function getClosePositionSwappableAfterFee(
        address market,
        uint256 positionId,
        IMarketNFT.CloseMode mode
    ) external view returns (
        uint256 swappableAfterFee
    );

    /// @notice Calculate trading fee
    /// @param account Account of the position owner
    /// @param isLiquidation Whether close mode is liquidation or not
    /// @param amount Amount of asset token to swap
    /// @return tradingFee Amount of trading fee
    function calculateTradingFee(
        address account,
        bool isLiquidation,
        uint256 amount
    ) external view returns (
        uint256 tradingFee
    );

}