// compare using simulated exact output and real native output

const { ethers } = require("hardhat");


const ZERO_ADDRESS = '0x' + '0'.repeat(40);
const UINT256_MAX = '0x' + 'f'.repeat(64);

const AGGREGATOR_HELPER = '0x8e9176Ef05E2b7fE2f95081d098E5d0321518Fa5';

//const SYMPHONY_AGGREGATOR_FQDN = 'https://goapi.symphony.ag/route';
const SYMPHONY_AGGREGATOR_FQDN = 'https://routeapi.symphony.ag/route';
const KAME_AGGREGATOR_FQDN = 'https://pyxis-sei.kitelabs.io/v1/swap';
const SCRAP_ROUTER = '0x11DA6463D6Cb5a03411Dbf5ab6f6bc3997Ac7428';  // UniswapV3 Router
const SCRAP_ROUTER_FEE = 3000;

const BASE_TOKEN = '0x3894085Ef7Ff0f0aeDf52E2A2704928d1Ec074F1';
//const TARGET_TOKEN = '0x0555E30da8f98308EdB960aa94C0Db47230d2B9c';    // WBTC
const TARGET_TOKEN = '0x160345fC359604fC6e70E3c5fAcbdE5F7A9342d8';      // WETH
//const TARGET_TOKEN = '0xE30feDd158A2e3b13e9badaeABaFc5516e95e8C7';      // WSEI

const TEST_AMOUNT = '5';
const TEST_OUTPUT = '0.00125';


async function symphonyCalldata(fromToken, toToken, amountIn) {
    const slippage = '100';
    
    // Construct the URL
    const queryParams = new URLSearchParams({
        tokenIn: fromToken.target,
        tokenOut: toToken.target,
        amountIn: amountIn,
        calldata: 'true',
        isRawAmount: 'true',
        slippage: slippage
    });

    const url = `${SYMPHONY_AGGREGATOR_FQDN}?${queryParams.toString()}`;

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

        const results = await response.json();
        return {
            routerAddress: results.routerAddress,
            calldata: results.calldata,
            amountOut: results.amountOut,
        };

    } catch (error) {
        console.error("Failed to fetch aggregator data:", error);
        throw error;
    }    
}

async function kameCalldata(fromToken, toToken, amountIn) {
    const slippage = '15';
    
    // Construct the URL
    // kame's API requires addresses to be in lowercase
    const queryParams = new URLSearchParams({
        srcToken: fromToken.target.toLowerCase(),
        dstToken: toToken.target.toLowerCase(),
        amount: amountIn,
        origin: AGGREGATOR_HELPER.toLowerCase(),
        recipient: AGGREGATOR_HELPER.toLowerCase(),
        slippage: slippage
    });

    const url = `${KAME_AGGREGATOR_FQDN}?${queryParams.toString()}`;

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

        const results = await response.json();
        return {
            routerAddress: results.data.tx.to,
            calldata: results.data.tx.data,
            amountOut: results.data.dstAmount,
        };

    } catch (error) {
        console.error("Failed to fetch aggregator data:", error);
        throw error;
    }    
}

// generate swapData for aggregators
async function aggregatorSwapper(aggregatorCalldata, aggregatorHelper, fromToken, toToken, amount, debtAmount) {

    // trying to estimate how much fromToken is required to received required amount
    const swapInfo = await aggregatorCalldata(fromToken, toToken, amount);
    const finalOutputMin = BigInt(swapInfo.amountOut);
    const aggregatorRouter = swapInfo.routerAddress;

    // add 2% for safe margin
    let newAmountIn = amount * 102n * debtAmount / finalOutputMin / 100n;
    if (newAmountIn > amount) {
        // should not be over amount
        newAmountIn = amount;
    }
    const newSwapInfo = await aggregatorCalldata(fromToken, toToken, newAmountIn);
    const newfinalOutputMin = BigInt(newSwapInfo.amountOut);

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
            aggregatorHelper.target,
            0,  // amountIn
            0,  // amountOutMin
            0   // sqrtPriceLimitX96, set to 0 to ignore
        ]]);

    const amountIn = aggregatorHelper.swapExactOutput.staticCall(
        fromToken,
        toToken,
        newAmountIn,
        debtAmount,
        ZERO_ADDRESS,
        "0x",
        aggregatorRouter,
        newSwapInfo.calldata,
        ZERO_ADDRESS,
        SCRAP_ROUTER,
        scrapSwapData,
        32 * 4 + 4      // amountIn is the 5th parameter
    );

    return amountIn;
}


async function initContracts() {

    const aggregatorHelper = await ethers.getContractAt("AggregatorHelper", AGGREGATOR_HELPER);
    const baseToken = await ethers.getContractAt("MockToken", BASE_TOKEN);
    const targetToken = await ethers.getContractAt("MockToken", TARGET_TOKEN);

    return { aggregatorHelper, baseToken, targetToken };
}

async function main() {
    
    const [user] = await ethers.getSigners();
    const { aggregatorHelper, baseToken, targetToken } = await initContracts();

    const amountIn = ethers.parseUnits(TEST_AMOUNT, await baseToken.decimals());
    const amountOut = ethers.parseUnits(TEST_OUTPUT, await targetToken.decimals());
    
    console.log("Required output:", amountOut);

    const allowance = await baseToken.allowance(user, aggregatorHelper);
    if (allowance < amountIn) {
        const tx = await baseToken.approve(aggregatorHelper, amountIn);
        await tx.wait();
    }

    // test native output
    const scrapRouter = await ethers.getContractAt("IV3SwapRouter", SCRAP_ROUTER);
    const allowanceScrap = await baseToken.allowance(user, scrapRouter);
    if (allowanceScrap < amountIn) {
        const tx = await baseToken.approve(scrapRouter, amountIn);
        await tx.wait();
    }
    const nativeInput = await scrapRouter.exactOutputSingle.staticCall(
        {
            tokenIn: baseToken,
            tokenOut: targetToken,
            fee: SCRAP_ROUTER_FEE,
            recipient: user,
            amountOut: amountOut,
            amountInMaximum: amountIn,
            sqrtPriceLimitX96: 0   // set to 0 to ignore            
        }
    );
    console.log("nativeInput:", nativeInput);

    // test aggregator output
    const aggregatorInput = await aggregatorSwapper(symphonyCalldata, aggregatorHelper, baseToken, targetToken, amountIn, amountOut);
    //const aggregatorInput = await aggregatorSwapper(kameCalldata, aggregatorHelper, baseToken, targetToken, amountIn, amountOut);
    console.log("aggregatorInput:", aggregatorInput);

    console.log("Diff %:", Number(nativeInput - aggregatorInput) / Number(nativeInput) * 100);

}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
