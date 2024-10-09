// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import {IRouter} from "../lending/IRouter.sol";
import {IMarketNFT} from "./IMarketNFT.sol";

interface ITradingCore {

    error ExceedsFeeCap();
    error ZeroNotAllowed();
    error AssetNotEnabled();
    error PairNotCreated();
    error NotPositionOwner();
    error PriceConditionNotMet();
    error IdenticalAddress();
    error SlippageTooLarge();
    error AmountExceedsLimit();
    error NotInWhitelist();

    event CreateMarket(address indexed sender, IMarketNFT indexed market, ERC20Upgradeable token0, ERC20Upgradeable token1);
    event SetFeeConfig(address indexed sender, uint256 timestamp, FeeConfig feeConfig);
    event CollectTradingFee(ERC20Upgradeable token, FeeConfig feeConfig, uint256 fee);
    event OpenPosition(IMarketNFT indexed market, uint256 indexed positionId);
    event AddMargin(IMarketNFT indexed market, uint256 indexed positionId, uint256 addedAmount);
    event ClosePosition(IMarketNFT indexed market, uint256 indexed positionId, bool indexed isFullyClosed, uint256 decreasedAssetAmount, uint256 decreasedDebtAmount);
    event TakeProfit(IMarketNFT indexed market, uint256 indexed positionId, bool indexed isFullyClosed, uint256 decreasedAssetAmount, uint256 decreasedDebtAmount);
    event StopLoss(IMarketNFT indexed market, uint256 indexed positionId, bool indexed isFullyClosed, uint256 decreasedAssetAmount, uint256 decreasedDebtAmount);
    event Liquidate(IMarketNFT indexed market, uint256 indexed positionId, bool indexed isFullyClosed, uint256 decreasedAssetAmount, uint256 decreasedDebtAmount);

    struct FeeConfig {
        address treasury;
        uint32 tradingFee;
        uint32 liquidationFee;
    }

    function pause() external;
    function unpause() external;
    function isAllMarketPaused() external view returns (bool);
    function createMarket(
        ERC20Upgradeable token0,
        ERC20Upgradeable token1,
        bool isToken0Margin,
        uint24 maxLeverage,
        uint24 openPositionLossRatioThreshold,
        uint24 liquidateLossRatioThreshold,
        uint24 liquidationDiscount,
        uint256 positionSizeCap
    ) external returns (
        address marketAddress
    );
    function openPosition(
        ERC20Upgradeable token0,
        ERC20Upgradeable token1,
        IRouter.InterestRateModelType interestRateModelType,
        bool isToken0Debt,
        uint256 marginAmount,
        uint256 borrowAmount,
        uint256 minAssetAmount,
        uint256 takeProfit,
        uint256 stopLoss,
        address swapRouter,
        bytes calldata data
    ) external returns (
        IMarketNFT market,
        uint256 positionId
    );
    function addMargin(
        ERC20Upgradeable token0,
        ERC20Upgradeable token1,
        uint256 positionId,
        uint24 newLiquidationAssetDebtRatio
    ) external;
    function closePosition(
        ERC20Upgradeable token0,
        ERC20Upgradeable token1,
        uint256 positionId,
        uint256 assetAmountToDecrease,
        uint256 minDecreasedDebtAmount,
        address swapRouter,
        bytes calldata data
    ) external returns (
        bool isFullyClosed,
        uint256 decreasedAssetAmount,
        uint256 decreasedDebtAmount,
        uint256 owedAsset,
        uint256 owedDebt
    );
    function takeProfit(
        ERC20Upgradeable token0,
        ERC20Upgradeable token1,
        uint256 positionId,
        uint256 assetAmountToDecrease,
        uint256 minDecreasedDebtAmount,
        address swapRouter,
        bytes calldata data
    ) external returns (
        bool isFullyClosed,
        uint256 decreasedAssetAmount,
        uint256 decreasedDebtAmount,
        uint256 owedAsset,
        uint256 owedDebt
    );
    function stopLoss(
        ERC20Upgradeable token0,
        ERC20Upgradeable token1,
        uint256 positionId,
        uint256 assetAmountToDecrease,
        uint256 minDecreasedDebtAmount,
        address swapRouter,
        bytes calldata data
    ) external returns (
        bool isFullyClosed,
        uint256 decreasedAssetAmount,
        uint256 decreasedDebtAmount,
        uint256 owedAsset,
        uint256 owedDebt
    );
    function liquidate(
        ERC20Upgradeable token0,
        ERC20Upgradeable token1,
        uint256 positionId,
        uint256 assetAmountToDecrease,
        uint256 minDecreasedDebtAmount,
        address swapRouter,
        bytes calldata data
    ) external returns (
        bool isFullyClosed,
        uint256 decreasedAssetAmount,
        uint256 decreasedDebtAmount,
        uint256 owedAsset,
        uint256 owedDebt
    );
    function getPositionTokens(address market, uint256 positionId) external returns (ERC20Upgradeable asset, ERC20Upgradeable debt);
    function debtOfPosition(address market, uint256 positionId) external returns (ERC20Upgradeable debtUnderlying, uint256 amount);
    function liquidateAuctionPrice(
        ERC20Upgradeable token0,
        ERC20Upgradeable token1,
        bool isLongToken0
    ) external view returns (
        uint256 price
    );
    function getLiquidationPrice(
        ERC20Upgradeable token0,
        ERC20Upgradeable token1,
        uint256 positionId
    ) external view returns (
        uint256 price
    );

}