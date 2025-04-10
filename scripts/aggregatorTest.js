// test script for using aggregators

const { ethers } = require("hardhat");

const ZERO_ADDRESS = '0x' + '0'.repeat(40);
const UINT256_MAX = '0x' + 'f'.repeat(64);

const TRADING_CORE = '0x99c2901d2883F8D295A989544f118e31eC21823e';
const AGGREGATOR_HELPER = '0x5E87CCdb5aF23F1C1300B030998F376f968Ed452';
const AGGREGATOR_HELPER_PROCESSOR = '0xcEB69875F0485BBb182997daBd30e1c39920A60a';

const AGGREGATOR_FQDN = 'https://goapi.symphony.ag/route';
const AGGREGATOR_ROUTER = '0xAD3DF981018149CD90e5869d14Efe2516b108270';
const SCRAP_ROUTER = '0x11DA6463D6Cb5a03411Dbf5ab6f6bc3997Ac7428';  // UniswapV3 Router
const SCRAP_ROUTER_FEE = 3000;

const BASE_TOKEN = '0x3894085Ef7Ff0f0aeDf52E2A2704928d1Ec074F1';
const TARGET_TOKEN = '0x0555E30da8f98308EdB960aa94C0Db47230d2B9c';

const TEST_AMOUNT = '1';


async function symphonyCalldata(fromToken, toToken, amountIn) {
    const slippage = '15';
    const decimals = await fromToken.decimals();
    const amountInUnits = ethers.formatUnits(amountIn, decimals);
    
    // Construct the URL
    const queryParams = new URLSearchParams({
        tokenIn: fromToken.target,
        tokenOut: toToken.target,
        amountIn: amountInUnits,
        calldata: 'true',
        slippage: slippage
    });

    const url = `${AGGREGATOR_FQDN}?${queryParams.toString()}`;

    try {
        const response = await fetch(url);

        // Check if the request was successful (status code 2xx)
        if (!response.ok) {
            // Try to get more details from the response body if possible
            let errorBody = '';
            try {
                errorBody = await response.text();
            } catch (e) {
                // Ignore if reading body fails
            }

            throw new Error(`HTTP error! Status: ${response.status}. Body: ${errorBody}`);
        }

        return await response.json();

    } catch (error) {
        console.error("Failed to fetch aggregator data:", error);
        throw error;
    }    
}

// generate swapData for Symphony aggregator
async function symphonySwapper(input, receiver, fromToken, toToken, amount, debtAmount = 0n) {
    if (input) {
        const swapContract = AGGREGATOR_ROUTER;
        const swapProcessor = "";
        const swapData = (await symphonyCalldata(fromToken, toToken, amount)).calldata;
        return { swapContract, swapProcessor, swapData };
    }
    else {
        const swapContract = await ethers.getContractAt("AggregatorHelper", AGGREGATOR_HELPER);
        const swapProcessor = await ethers.getContractAt("AggregatorHelperProcessor", AGGREGATOR_HELPER_PROCESSOR);

        // trying to estimate how much fromToken is required to received required amount
        const swapInfo = await symphonyCalldata(fromToken, toToken, amount);
        const finalOutputMin = BigInt(swapInfo.data[0][swapInfo.data[0].length - 1].amountOutMin);

        // add 5% for safe margin
        const newAmountIn = amount * 105n * debtAmount / finalOutputMin / 100n;
        const newSwapInfo = await symphonyCalldata(fromToken, toToken, newAmountIn);
        const newfinalOutputMin = BigInt(newSwapInfo.data[0][newSwapInfo.data[0].length - 1].amountOutMin);

        if (newfinalOutputMin < debtAmount) {
            throw Error("Not enough amount in");
        }

        // use a Uniswap V3SwapRouter contract as scrap router
        const scrapRouter = await ethers.getContractAt("IV3SwapRouter", SCRAP_ROUTER);
        const scrapSwapData = scrapRouter.interface.encodeFunctionData("exactInputSingle",
             [[
                toToken.target,
                fromToken.target,
                SCRAP_ROUTER_FEE,
                swapContract.target,
                0,  // amountIn
                0,  // amountOutMin
                0   // sqrtPriceLimitX96, set to 0 to ignore
             ]]);

        const swapData = swapContract.interface.encodeFunctionData("swapExactOutput",
            [
                fromToken.target,
                toToken.target,
                newAmountIn,
                debtAmount,
                AGGREGATOR_ROUTER,
                newSwapInfo.calldata,
                SCRAP_ROUTER,
                scrapSwapData,
                32 * 4 + 4      // amountIn is the 5th parameter
            ]);

        return { swapContract, swapProcessor, swapData };
    }
}

// get market contract from baseToken/targetToken pair
async function getMarket(tradingCore, baseToken, targetToken) {
    const isBaseToken0 = baseToken.target < targetToken.target;
    const token0 = isBaseToken0 ? baseToken : targetToken;
    const token1 = isBaseToken0 ? targetToken : baseToken;
    const marketAddr = await tradingCore.pairMarket(token0, token1);
    return await ethers.getContractAt("MarketNFT", marketAddr);
}

// open position to long targetToken
async function openLongPosition(tradingCore, user, baseToken, targetToken, marginAmount, borrowAmount, swapFunction) {
    const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(user, false, borrowAmount));
    const { swapContract, swapProcessor, swapData } = await swapFunction(true, tradingCore.target, baseToken, targetToken, receivedAmount);
    const allowance = await baseToken.allowance(user, tradingCore);
    if (allowance < marginAmount) {
        await baseToken.connect(user).approve(tradingCore, marginAmount);
    }

    const market = await getMarket(tradingCore, baseToken, targetToken);
    return await tradingCore.connect(user).openPosition(
        market,
        2,
        targetToken,
        marginAmount,
        borrowAmount,
        0,
        UINT256_MAX,
        0,
        0,
        swapContract,
        swapData
    );
}

// open position to short targetToken
async function openShortPosition(tradingCore, user, baseToken, targetToken, marginAmount, borrowAmount, swapFunction) {
    const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(user, false, borrowAmount));
    const { swapContract, swapProcessor, swapData } = await swapFunction(true, tradingCore.target, targetToken, baseToken, receivedAmount);
    const allowance = await baseToken.allowance(user, tradingCore);
    if (allowance < marginAmount) {
        await baseToken.connect(user).approve(tradingCore, marginAmount);
    }

    const market = await getMarket(tradingCore, baseToken, targetToken);
    return await tradingCore.connect(user).openPosition(
        market,
        2,
        baseToken,
        marginAmount,
        borrowAmount,
        0,
        UINT256_MAX,
        0,
        0,
        swapContract,
        swapData
    );
}

// close position
async function closePosition(tradingCore, user, market, positionId, swapFunction) {
    const token0 = await market.token0();
    const token1 = await market.token1();
    const isToken0Margin = await market.isToken0Margin();
    const baseToken = await ethers.getContractAt("MockToken", isToken0Margin ? token0 : token1);
    const targetToken = await ethers.getContractAt("MockToken", isToken0Margin ? token1 : token0);

    const positionInfo = await market.getPosition(positionId);
    const assetAmount = positionInfo.assetAmount;

    const longPosition = positionInfo.isLongToken0 ^ isToken0Margin;
    if (longPosition) {
        // for long positions, sell all assets
        const swappableAmount = await tradingCore.getClosePositionSwappableAfterFee(market, positionId, 0); // for normal closing position
        const { swapContract, swapProcessor, swapData } = await swapFunction(true, tradingCore.target, targetToken, baseToken, swappableAmount);
        return await tradingCore.connect(user).closePosition(
            market,
            positionId,
            assetAmount,
            0,
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
            0,
            swapProcessor,
            swapContract,
            swapData
        );
    }
}

async function initContracts() {

    const tradingCore = await ethers.getContractAt("TradingCore", TRADING_CORE);
    const baseToken = await ethers.getContractAt("MockToken", BASE_TOKEN);
    const targetToken = await ethers.getContractAt("MockToken", TARGET_TOKEN);

    return { tradingCore, baseToken, targetToken };
}

async function testLongPosition(tradingCore, user, baseToken, targetToken, swapper) {
    console.log("Test long position:");
    
    const baseDecimals = await baseToken.decimals();
    const market = await getMarket(tradingCore, baseToken, targetToken);

    // open position to long targetToken
    const marginAmount = ethers.parseUnits(TEST_AMOUNT, baseDecimals);
    const leverage = 5n;
    const borrowAmount = marginAmount * leverage;
    const txOpen = await openLongPosition(tradingCore, user, baseToken, targetToken, marginAmount, borrowAmount, swapper);
    await txOpen.wait();

    // get positionId
    const positions = await market.balanceOf(user);
    const positionId = await market.tokenOfOwnerByIndex(user, positions - 1n);
    console.log("Position TokenID:", positionId);
    const positionInfo = await market.getPosition(positionId);
    console.log("PositionInfo after open:");
    console.log(positionInfo);
    const debtOfPosition = await tradingCore.debtOfPosition(market, positionId);
    console.log("Debt of position:", debtOfPosition.debtAmount);
    const liquidationPrice = await tradingCore.getLiquidationPrice(market, positionId);
    console.log("Liquidation price:", liquidationPrice);

    // close position
    const txClose = await closePosition(tradingCore, user, market, positionId, swapper);
    await txClose.wait();

    const positionInfoAfterClose = await market.getPosition(positionId);
    console.log("PositionInfo after close:");
    console.log(positionInfoAfterClose);
    console.log("----------------");
}

async function testShortPosition(tradingCore, user, baseToken, targetToken, swapper) {
    console.log("Test short position:");

    const baseDecimals = await baseToken.decimals();
    const market = await getMarket(tradingCore, baseToken, targetToken);

    // open position to short targetToken
    const prices = await market.getTokenPrices();
    const isToken0Margin = await market.isToken0Margin();
    const marginAmount = ethers.parseUnits(TEST_AMOUNT, baseDecimals);
    const leverage = 5n;
    const borrowAmount = isToken0Margin ? 
        marginAmount * leverage * prices.price0 / prices.price1 :
        marginAmount * leverage * prices.price1 / prices.price0;
    const txOpen = await openShortPosition(tradingCore, user, baseToken, targetToken, marginAmount, borrowAmount, swapper);
    await txOpen.wait();

    // get positionId
    const positions = await market.balanceOf(user);
    const positionId = await market.tokenOfOwnerByIndex(user, positions - 1n);
    console.log("Position TokenID:", positionId);
    const positionInfo = await market.getPosition(positionId);
    console.log("PositionInfo after open:");
    console.log(positionInfo);
    const debtOfPosition = await tradingCore.debtOfPosition(market, positionId);
    console.log("Debt of position:", debtOfPosition.debtAmount);
    const liquidationPrice = await tradingCore.getLiquidationPrice(market, positionId);
    console.log("Liquidation price:", liquidationPrice);

    // close position
    const txClose = await closePosition(tradingCore, user, market, positionId, swapper);
    await txClose.wait();

    const positionInfoAfterClose = await market.getPosition(positionId);
    console.log("PositionInfo after close:");
    console.log(positionInfoAfterClose);    
    console.log("----------------");
}

async function main() {
    
    const [user] = await ethers.getSigners();
    const { tradingCore, baseToken, targetToken } = await initContracts();

    // test open and close long position
    await testLongPosition(tradingCore, user, baseToken, targetToken, symphonySwapper);

    // test open and close short position
    await testShortPosition(tradingCore, user, baseToken, targetToken, symphonySwapper);
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
