// Some utility functions for Tea-Rex
// Teahouse Finance

const ZERO_ADDRESS = '0x' + '0'.repeat(40);
const UINT256_MAX = '0x' + 'f'.repeat(64);

// generate swapData for UniswapV3Router
export function uniswapV3Swapper(swapContract, swapRouterFee, swapProcessor) {
    return async function(input, receiver, fromToken, toToken, amount, debtAmount) {
        const router = await ethers.getContractAt("IV3SwapRouter", swapContract);
        if (input) {
            // use exact input single
            const swapData = router.interface.encodeFunctionData("exactInputSingle",
                [[
                    fromToken,
                    toToken,
                    swapRouterFee,
                    receiver,
                    amount, // amountIn
                    0,      // amountOutMin
                    0       // sqrtPriceLimitX96, set to 0 to ignore
                 ]]);

            return { swapContract, swapProcessor, swapData };
        }
        else {
            // use exact output single
            const swapData = router.interface.encodeFunctionData("exactOutputSingle",
                [[
                    fromToken,
                    toToken,
                    swapRouterFee,
                    receiver,
                    amount,         // amountOut
                    UINT256_MAX,    // amountInMax
                    0               // sqrtPriceLimitX96, set to 0 to ignore
                 ]]);

            return { swapContract, swapProcessor, swapData };
        }
    }
}

// get market contract from baseToken/targetToken pair
export async function getMarket(tradingCore, baseToken, targetToken) {
    const isBaseToken0 = baseToken < targetToken;
    const token0 = isBaseToken0 ? baseToken : targetToken;
    const token1 = isBaseToken0 ? targetToken : baseToken;
    const marketAddr = await tradingCore.pairMarket(token0, token1);
    if (marketAddr == ZERO_ADDRESS) {
        throw new Error("Incorrect token pair");
    }
    return await ethers.getContractAt("MarketNFT", marketAddr);
}

// open position to long targetToken
export async function openLongPosition(tradingCore, user, baseToken, targetToken, marginAmount, leverage, minAssetAmount, swapFunction) {
    const market = await getMarket(tradingCore, baseToken, targetToken);

    const borrowAmount = BigInt(marginAmount) * BigInt(leverage) / 1000n;
    const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(user, false, borrowAmount));
    const { swapContract, swapProcessor, swapData } = await swapFunction(true, tradingCore.target, baseToken, targetToken, receivedAmount, 0n);
    return await tradingCore.connect(user).openPosition(
        market,
        2,
        targetToken,
        marginAmount,
        borrowAmount,
        minAssetAmount,
        UINT256_MAX,    // take profit
        0,              // stop loos
        0,              // stop loss tolerance
        swapContract,
        swapData
    );
}

// open position to short targetToken
export async function openShortPosition(tradingCore, user, baseToken, targetToken, marginAmount, leverage, minAssetAmount, swapFunction) {
    const market = await getMarket(tradingCore, baseToken, targetToken);

    const prices = await market.getTokenPrices();
    const isToken0Margin = await market.isToken0Margin();
    const borrowAmount = isToken0Margin ? 
        BigInt(marginAmount) * BigInt(leverage) * prices.price0 / prices.price1 / 1000n:
        BigInt(marginAmount) * BigInt(leverage) * prices.price1 / prices.price0 / 1000n;

    const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(user, false, borrowAmount));
    const { swapContract, swapProcessor, swapData } = await swapFunction(true, tradingCore.target, targetToken, baseToken, receivedAmount, 0n);
    return await tradingCore.connect(user).openPosition(
        market,
        2,
        baseToken,
        marginAmount,
        borrowAmount,
        minAssetAmount,
        UINT256_MAX,    // take profit
        0,              // stop loss
        0,              // stop loss tolerance
        swapContract,
        swapData
    );
}

// close position
export async function closePosition(tradingCore, user, baseToken, targetToken, positionId, minDecreasedDebtAmount, swapFunction) {
    const market = await getMarket(tradingCore, baseToken, targetToken);
    const isToken0Margin = await market.isToken0Margin();

    const positionInfo = await market.getPosition(positionId);
    const assetAmount = positionInfo.assetAmount;

    const longPosition = positionInfo.isLongToken0 ^ isToken0Margin;
    if (longPosition) {
        // for long positions, sell all assets
        const swappableAmount = await tradingCore.getClosePositionSwappableAfterFee(market, positionId, 0); // for normal closing position
        const debtOfPosition = await tradingCore.debtOfPosition(market, positionId);
        const { swapContract, swapProcessor, swapData } = await swapFunction(true, tradingCore.target, targetToken, baseToken, swappableAmount, debtOfPosition.debtAmount);
        return await tradingCore.connect(user).closePosition(
            market,
            positionId,
            assetAmount,
            minDecreasedDebtAmount,
            ZERO_ADDRESS,
            swapContract,
            swapData
        );
    }
    else {
        // for short positions, use all swappableAmount to repay all debts
        const swappableAmount = await tradingCore.getClosePositionSwappableAfterFee(market, positionId, 0);
        const debtOfPosition = await tradingCore.debtOfPosition(market, positionId);
        const { swapContract, swapProcessor, swapData } = await swapFunction(false, tradingCore.target, baseToken, targetToken, swappableAmount, debtOfPosition.debtAmount);
        const assets = assetAmount + positionInfo.marginAmount;
        return await tradingCore.connect(user).closePosition(
            market,
            positionId,
            assets,
            minDecreasedDebtAmount,
            swapProcessor,
            swapContract,
            swapData
        );
    }
}

// estimate position current value
// note that if this position has no enough assets to repay all debts, closePosition call will revert as it needs to be liquidated
// in this case, the value of the position should be treated as zero
export async function estimatePositionValue(tradingCore, baseToken, targetToken, positionId, swapFunction) {
    const market = await getMarket(tradingCore, baseToken, targetToken);
    const isToken0Margin = await market.isToken0Margin();

    const positionInfo = await market.getPosition(positionId);
    const assetAmount = positionInfo.assetAmount;

    // if position is not currently open, return zero
    if (positionInfo.status != 1n) {
        return 0n;
    }

    const owner = await market.ownerOf(positionId);

    const longPosition = positionInfo.isLongToken0 ^ isToken0Margin;
    if (longPosition) {
        // for long positions, sell all assets
        const swappableAmount = await tradingCore.getClosePositionSwappableAfterFee(market, positionId, 0); // for normal closing position
        const debtOfPosition = await tradingCore.debtOfPosition(market, positionId);
        const { swapContract, swapProcessor, swapData } = await swapFunction(true, tradingCore.target, targetToken, baseToken, swappableAmount, debtOfPosition.debtAmount);
        const results = await tradingCore.closePosition.staticCall(
            market,
            positionId,
            assetAmount,
            0,
            ZERO_ADDRESS,
            swapContract,
            swapData
        , { from: owner });

        return results.owedDebt;
    }
    else {
        // for short positions, use all swappableAmount to repay all debts
        const swappableAmount = await tradingCore.getClosePositionSwappableAfterFee(market, positionId, 0);
        const debtOfPosition = await tradingCore.debtOfPosition(market, positionId);
        const { swapContract, swapProcessor, swapData } = await swapFunction(false, tradingCore.target, baseToken, targetToken, swappableAmount, debtOfPosition.debtAmount);
        const assets = assetAmount + positionInfo.marginAmount;
        const results = await tradingCore.closePosition.staticCall(
            market,
            positionId,
            assets,
            0,
            swapProcessor,
            swapContract,
            swapData
        , { from: owner });

        return results.owedAsset;
    }
}
