// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

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
        IAssetOracle _oracle,
        ERC20Upgradeable token0,
        ERC20Upgradeable token1,
        bool isToken0Margin,
        uint24 maxLeverage,
        uint24 openPositionLossRatioThreshold,
        uint24 liquidateLossRatioThreshold,
        uint24 liquidationDiscount,
        uint256 longPositionSizeCap,
        uint256 shortPositionSizeCap
    ) external returns (
        address marketAddress
    );
    function openPosition(
        address market,
        IRouter.InterestRateModelType interestRateModelType,
        ERC20Upgradeable longTarget,
        uint256 marginAmount,
        uint256 borrowAmount,
        uint256 minAssetAmount,
        uint256 takeProfit,
        uint256 stopLoss,
        address swapRouter,
        bytes calldata data
    ) external returns (
        uint256 positionId
    );
    function addMargin(
        address market,
        uint256 positionId,
        uint24 newLiquidationAssetDebtRatio
    ) external;
    function closePosition(
        address market,
        uint256 positionId,
        uint256 assetAmountToDecrease,
        uint256 minDecreasedDebtAmount,
        ICalldataProcessor calldataProcessor,
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
        address market,
        uint256 positionId,
        uint256 assetAmountToDecrease,
        uint256 minDecreasedDebtAmount,
        ICalldataProcessor calldataProcessor,
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
        address market,
        uint256 positionId,
        uint256 assetAmountToDecrease,
        uint256 minDecreasedDebtAmount,
        ICalldataProcessor calldataProcessor,
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
        address market,
        uint256 positionId,
        uint256 assetAmountToDecrease,
        uint256 minDecreasedDebtAmount,
        ICalldataProcessor calldataProcessor,
        address swapRouter,
        bytes calldata data
    ) external returns (
        bool isFullyClosed,
        uint256 decreasedAssetAmount,
        uint256 decreasedDebtAmount,
        uint256 owedAsset,
        uint256 owedDebt
    );
    function debtOfPosition(
        address market,
        uint256 positionId
    ) external returns (
        ERC20Upgradeable asset,
        ERC20Upgradeable debt,
        uint256 debtAmount
    );
    function liquidateAuctionPrice(
        address market,
        ERC20Upgradeable longTarget
    ) external view returns (
        uint256 price
    );
    function getLiquidationPrice(
        address market,
        uint256 positionId
    ) external view returns (
        uint256 price
    );
    function calculateTradingFee(
        address account,
        bool isLiquidation,
        uint256 amount
    ) external view returns (
        uint256 tradingFee
    );

}