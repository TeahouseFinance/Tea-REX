// SPDX-License-Identifier: BUSL-1.1
// Teahouse Finance
pragma solidity ^0.8.0;

// this interface includes all error declaration in this project
// this can be used to decode custom contract error codes
interface ITeaRexError {

    // IPool
    error InvalidCap();
    error InvalidPercentage();
    error DebtPositionIsClosed();
    error ZeroAmountNotAllowed();
    error ExceedsCap();
    error NoUnborrowedUnderlying();
    error CallerIsNotRouter();

    // IRouter
    error ExceedsFeeCap();
    error InvalidInterestRateModelType();
    error ModelNotSet();
    error PoolAlreadyExists();
    error PoolNotExists();
    error CallerIsNotTradingCore();
    error NotInWhitelist();

    // IAggregatorHelper
    error LengthMismatch();
    error NotWhitelisted();
    error InputAmountNotCleared();
    error OutputScrapNotCleared();
    error IncorrectScrapAmountSize();
    error IncorrectScrapAmountOffset();
    error NoTokenReceived();
    error NotEnoughAmountOut();
    error AmountInTooSmall();
    error AmountOutTooSmall();

    // IAssetOracle
    error AssetNotEnabled();

    // IMarketNFT
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
    // error CallerIsNotTradingCore();
    error PassivelyCloseConditionNotMet();
    error NoTakeProfit();
    error NoStopLoss();
    error WorsePrice();

    // ISwapRelayer
    // error LengthMismatch();
    // error NotWhitelisted();

    // ITradingCore
    // error ExceedsFeeCap();
    // error ZeroNotAllowed();
    error WrongTokenOrder();
    // error AssetNotEnabled();
    error MarketAlreadyCreated();
    error PairNotCreated();
    error NotPositionOwner();
    error PriceConditionNotMet();
    error IdenticalAddress();
    error SlippageTooLarge();
    error AmountExceedsLimit();
    // error NotInWhitelist();
    error InvalidAsset();
    error InvalidMarketPair();

    // AggregatorHelperProcessor
    error InvalidCalldata();

    // ChainlinkOracle
    error InvalidAssetAddress();
    error OraclePriceIsInvalid();
    error OraclePriceIsTooOld();

    // SEINativeOracle
    // error InvalidAssetAddress();
    error UnknownToken();
    error InvalidPriceString();
    error InvalidOraclePriceTime();
    // error OraclePriceIsTooOld();

    // UniswapV3TwapOracle
    error AssetNotInPool();
    error ZeroTwapIntervalNotAllowed();  
    error ConfigLengthMismatch();
    error BaseAssetCannotBeReenabled();
    error BaseAssetMismatch();
}
