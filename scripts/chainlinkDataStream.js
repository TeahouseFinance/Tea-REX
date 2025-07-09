// test Chainlink Data Stream

const { ethers } = require("hardhat");
const crypto = require('crypto');
const { bigint } = require("hardhat/internal/core/params/argumentTypes");

function loadEnvVar(env, errorMsg) {
    if (env == undefined) {
        throw errorMsg;
    }

    return env;
}

const ZERO_ADDRESS = '0x' + '0'.repeat(40);
const UINT256_MAX = '0x' + 'f'.repeat(64);


// mainnet
// const CHAINLINK_FQDN = 'https://api.dataengine.chain.link';
// const FEED_ID_BASE = '0x00038f83323b6b08116d1614cf33a9bd71ab5e0abf0c9f1b783a74a43e7bd992';  // USDC/USD
// const FEED_ID = '0x00026ec2b9c5b1d759b0116a90290a0d5e7c1c121d2c88fc15a26df188d8a4ae';  // SEIYAN/USD
// const ASSET_ADDRESS = '0x5f0E07dFeE5832Faa00c63F2D33A0D79150E8598'; // SEIYAN
// //const FEED_ID = '0x0003487e79423ea3c34f4edfc8bb112b0d0fbe054906644912b04bd5a3c6243b';  // SEI/USD
// //const ASSET_ADDRESS = '0xE30feDd158A2e3b13e9badaeABaFc5516e95e8C7'; // WSEI
// //const FEED_ID = '0x000415814a5915a37e6338e7626fee14392afe7cb65739d151966329c8935064';  // XAU/USD

// const ORACLE_ADDRESS = '0x532E08B5316bf5bC240d6251ff2b278a4f125B41';

// const chainlinkApiKey = loadEnvVar(process.env.CHAINLINK_API_KEY, "No CHAINLINK_API_KEY");
// const chainlinkApiSecret = loadEnvVar(process.env.CHAINLINK_API_SECRET, "No CHAINLINK_API_SECRET");

// const TRADING_CORE = '0x99c2901d2883F8D295A989544f118e31eC21823e';
// const AGGREGATOR_HELPER = '0x0a1E08fF15aD49203dd2566e40623C12380bd1eD';
// const AGGREGATOR_HELPER_PROCESSOR = '0x11F10a29080A6159628fF8a2587Dd7065ABeE1A6';

// const BASE_TOKEN = '0x3894085Ef7Ff0f0aeDf52E2A2704928d1Ec074F1';
// const TARGET_TOKEN = '0xE30feDd158A2e3b13e9badaeABaFc5516e95e8C7';    // WSEI


// testnet
const CHAINLINK_FQDN = 'https://api.testnet-dataengine.chain.link';

const ORACLE_ADDRESS = '0x1e97eb36FdCa3B0705fAB71228E2c92683147B39';

const chainlinkApiKey = loadEnvVar(process.env.CHAINLINK_TEST_API_KEY, "No CHAINLINK_TEST_API_KEY");
const chainlinkApiSecret = loadEnvVar(process.env.CHAINLINK_TEST_API_SECRET, "No CHAINLINK_TEST_API_SECRET");

const TRADING_CORE = '0xF31900132dFf544Cfe536e76C38a357FF08183D9';
const SWAP_ROUTER = '0x216d3e7520B09605B7c4243b59aD02Cc6E052F52';
const SWAP_ROUTER_PROCESSOR = '0x4F922F65EAB9315464420A3C7107AA5E65cAd728';
//const AGGREGATOR_HELPER = '0xcE489F9de3542b308e9049eD17d0a9321e036010';
const AGGREGATOR_HELPER = '0x60Bc0e6fa7D968F4d26D5E050f6f90004116d886';
const AGGREGATOR_HELPER_PROCESSOR = '0x9f8630a3e8Ae62C57840ceD376E017A0458924A0';

const BASE_TOKEN = '0x2ed994Fd3DC53bd4010652BFc00D980580823664';
const TARGET_TOKEN = '0x878aD0bD8DB80A8C6Cc650EdEEd4B9941b571c5F';    // WSEI

const TEST_AMOUNT = 1000000n;


function generateHMAC(method, path, body, apiKey, apiSecret) {
    // Generate timestamp (milliseconds since Unix epoch)
    const timestamp = Date.now()

    // Create body hash (empty for GET request)
    const bodyHash = crypto
        .createHash("sha256")
        .update(body || "")
        .digest("hex")

    // Create string to sign
    const stringToSign = `${method} ${path} ${bodyHash} ${apiKey} ${timestamp}`

    // Generate HMAC-SHA256 signature
    const signature = crypto.createHmac("sha256", apiSecret).update(stringToSign).digest("hex")

    return { signature, timestamp }
}


function generateAuthHeaders(method, path, apiKey, apiSecret) {
    const { signature, timestamp } = generateHMAC(method, path, "", apiKey, apiSecret)

    return {
        Authorization: apiKey,
        "X-Authorization-Timestamp": timestamp.toString(),
        "X-Authorization-Signature-SHA256": signature,
    }
}


async function fetchChainlink(path, queryString, apiKey, apiSecret) {

    const fullPath = `${path}?${queryString}`;
    const options = {
        headers: generateAuthHeaders('GET', fullPath, apiKey, apiSecret),
    };

    try {
        const url = `${CHAINLINK_FQDN}${fullPath}`;
        const response = await fetch(url, options);

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


function decodeReport(report) {
    const data = ethers.AbiCoder.defaultAbiCoder().decode([ "bytes32[3]", "bytes" ], report);
    const reportData = data[1];

    const reportVersion = parseInt(reportData.slice(0, 6), 16);
    //console.log(reportVersion);

    if (reportVersion == 2) {
        const decodedData = ethers.AbiCoder.defaultAbiCoder().decode(
            [ "bytes32", "uint32", "uint32", "uint192", "uint192", "uint32", "int192" ],
            reportData);

        return {
            feedID: decodedData[0],
            validFromTimestamp: decodedData[1],
            observationsTimestamp: decodedData[2],
            nativeFee: decodedData[3],
            linkFee: decodedData[4],
            expiresAt: decodedData[5],
            price: decodedData[6],
        };
    }
    else if (reportVersion == 3) {
        const decodedData = ethers.AbiCoder.defaultAbiCoder().decode(
            [ "bytes32", "uint32", "uint32", "uint192", "uint192", "uint32", "int192", "int192", "int192" ],
            reportData);

        return {
            feedID: decodedData[0],
            validFromTimestamp: decodedData[1],
            observationsTimestamp: decodedData[2],
            nativeFee: decodedData[3],
            linkFee: decodedData[4],
            expiresAt: decodedData[5],
            price: decodedData[6],
            bid: decodedData[7],
            ask: decodedData[8],
        };
    }
    else if (reportVersion == 4) {
        const decodedData = ethers.AbiCoder.defaultAbiCoder().decode(
            [ "bytes32", "uint32", "uint32", "uint192", "uint192", "uint32", "int192", "uint32" ],
            reportData);

        return {
            feedID: decodedData[0],
            validFromTimestamp: decodedData[1],
            observationsTimestamp: decodedData[2],
            nativeFee: decodedData[3],
            linkFee: decodedData[4],
            expiresAt: decodedData[5],
            price: decodedData[6],
            marketStatus: decodedData[7],
        };
    }
    else {
        throw new Error("Unknown report version");
    }
}


async function fetchSingleReportLatest(feedId, apiKey, apiSecret) {

    const path = '/api/v1/reports/latest';

    // Construct the URL
    const queryParams = new URLSearchParams({
        feedID: feedId,
    });

    const response = await fetchChainlink(path, queryParams.toString(), apiKey, apiSecret);
    return {
        response: response,
        decodedReport: decodeReport(response.report.fullReport),
    }
}


async function fetchSingleReportTimestamp(feedId, timestamp, apiKey, apiSecret) {

    const path = '/api/v1/reports';

    // Construct the URL
    const queryParams = new URLSearchParams({
        feedID: feedId,
        timestamp: timestamp,
    });

    const response = await fetchChainlink(path, queryParams.toString(), apiKey, apiSecret);
    return {
        response: response,
        decodedReport: decodeReport(response.report.fullReport),
    }
}


async function fetchReportsTimestamp(feedIds, timestamp, apiKey, apiSecret) {

    const path = '/api/v1/reports/bulk';

    // convert feedIds from array to comma separated string
    const feedIdString = feedIds.join(',');

    // Construct the URL
    const queryParams = new URLSearchParams({
        feedIDs: feedIdString,
        timestamp: timestamp,
    });

    const response = await fetchChainlink(path, queryParams.toString(), apiKey, apiSecret);
    return response.reports.map(report => {
        return {
            response: report,
            decodedReport: decodeReport(report.fullReport),
        };
    });
}


async function initContracts() {

    const tradingCore = await ethers.getContractAt("TradingCore", TRADING_CORE);
    const baseToken = await ethers.getContractAt("MockToken", BASE_TOKEN);
    const targetToken = await ethers.getContractAt("MockToken", TARGET_TOKEN);

    return { tradingCore, baseToken, targetToken };
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
    const allowance = await baseToken.allowance(user, tradingCore);
    if (allowance < marginAmount) {
        const tx = await baseToken.connect(user).approve(tradingCore, marginAmount);
        await tx.wait();
    }

    const market = await getMarket(tradingCore, baseToken, targetToken);
    const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(user, false, borrowAmount));
    const { swapContract, swapProcessor, swapData } = await swapFunction(true, tradingCore.target, baseToken, targetToken, receivedAmount);
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
    const allowance = await baseToken.allowance(user, tradingCore);
    if (allowance < marginAmount) {
        const tx = await baseToken.connect(user).approve(tradingCore, marginAmount);
        await tx.wait();
    }

    const market = await getMarket(tradingCore, baseToken, targetToken);
    const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(user, false, borrowAmount));
    const { swapContract, swapProcessor, swapData } = await swapFunction(true, tradingCore.target, targetToken, baseToken, receivedAmount);
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


async function testLongPosition(tradingCore, user, baseToken, targetToken, swapper) {
    console.log("Test long position:");
    
    const market = await getMarket(tradingCore, baseToken, targetToken);

    // open position to long targetToken
    const marginAmount = TEST_AMOUNT;
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
    const targetDecimals = await targetToken.decimals();
    const market = await getMarket(tradingCore, baseToken, targetToken);

    // open position to short targetToken
    const timestamp = Math.floor(Date.now() / 1000) - 2;    // give it a 5 seconds window
    const oracle = await ethers.getContractAt("ChainlinkDataStreamOracle", ORACLE_ADDRESS);
    const baseInfo = await oracle.oracleInfo(baseToken);
    const targetInfo = await oracle.oracleInfo(targetToken);
    const prices = await fetchReportsTimestamp([ baseInfo.feedId, targetInfo.feedId ], timestamp, chainlinkApiKey, chainlinkApiSecret);
    const marginAmount = TEST_AMOUNT;
    const leverage = 5n;
    const borrowAmount = marginAmount * leverage * 10n ** BigInt(targetInfo.totalDecimals) * prices[0].decodedReport.price / prices[1].decodedReport.price / 10n ** BigInt(baseInfo.totalDecimals);
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


// swap data for OracleSwap
async function oracleCalldata(input, fromToken, toToken, amount, receiver) {
    const swapContract = await ethers.getContractAt("OracleSwap", SWAP_ROUTER);
    if (input) {
        const swapProcessor = "";
        const swapData = swapContract.interface.encodeFunctionData("swapExactInput", [
            fromToken,
            toToken,
            amount,
            receiver,
            0n
        ]);
        const amountOut = await swapContract.calculateOutAmount(fromToken, toToken, amount);

        return { swapContract, swapProcessor, swapData, amountOut };
    }
    else {
        const swapProcessor = SWAP_ROUTER_PROCESSOR;
        const swapData = swapContract.interface.encodeFunctionData("swapExactOutput", [
            fromToken,
            toToken,
            amount,
            receiver,
            UINT256_MAX
        ]);

        return { swapContract, swapProcessor, swapData };
    }
}


// Chainlink report data
async function verifierCalldata(baseToken, targetToken) {
    // fetch multiple reports at a specific timestamp
    const oracle = await ethers.getContractAt("ChainlinkDataStreamOracle", ORACLE_ADDRESS);
    const baseInfo = await oracle.oracleInfo(baseToken);
    const targetInfo = await oracle.oracleInfo(targetToken);

    const timestamp = Math.floor(Date.now() / 1000) - 2;    // give it a 2 seconds window
    const result = await fetchReportsTimestamp([ baseInfo.feedId, targetInfo.feedId ], timestamp, chainlinkApiKey, chainlinkApiSecret);

    const calldata = oracle.interface.encodeFunctionData("verifyReports",
        [[
            result[0].response.fullReport,
            result[1].response.fullReport,
        ]]
    );

    return { oracle, calldata };
}


// generate swapData for OracleSwap
async function oracleSwapper(input, receiver, fromToken, toToken, amount, debtAmount = 0n) {
    if (input) {
        const verifierInfo = await verifierCalldata(fromToken, toToken);
        const swapContract = await ethers.getContractAt("AggregatorHelper", AGGREGATOR_HELPER);
        const swapInfo = await oracleCalldata(true, fromToken.target, toToken.target, amount, swapContract.target);
        const swapProcessor = "";
        const swapData = swapContract.interface.encodeFunctionData("swapExactInput",
            [
                fromToken.target,
                toToken.target,
                amount,
                verifierInfo.oracle.target,
                verifierInfo.calldata,
                swapInfo.swapContract.target,
                swapInfo.swapData
            ]);
        return { swapContract, swapProcessor, swapData };
    }
    else {
        const verifierInfo = await verifierCalldata(fromToken, toToken);
        const swapContract = await ethers.getContractAt("AggregatorHelper", AGGREGATOR_HELPER);
        const swapProcessor = await ethers.getContractAt("AggregatorHelperProcessor", AGGREGATOR_HELPER_PROCESSOR);

        // // trying to estimate how much fromToken is required to received required amount
        // const swapInfo = await oracleCalldata(true, fromToken.target, toToken.target, amount, swapContract.target);
        // const finalOutputMin = BigInt(swapInfo.amountOut);
        // const aggregatorRouter = swapInfo.swapContract.target;

        // // add 2% for safe margin
        // let newAmountIn = amount * 102n * debtAmount / finalOutputMin / 100n;
        // if (newAmountIn > amount) {
        //     // should not be over amount
        //     newAmountIn = amount;
        // }
        // const newSwapInfo = await oracleCalldata(true, fromToken.target, toToken.target, newAmountIn, swapContract.target);
        // const newfinalOutputMin = BigInt(newSwapInfo.amountOut);

        // if (newfinalOutputMin < debtAmount) {
        //     throw Error("Not enough amount in");
        // }

        // // use a OracleSwap contract as scrap router
        // const scrapRouter = await ethers.getContractAt("OracleSwap", SWAP_ROUTER);
        // const scrapSwapData = scrapRouter.interface.encodeFunctionData("swapExactInput",
        //      [
        //         toToken.target,
        //         fromToken.target,
        //         0,  // amountIn
        //         swapContract.target, // receiver
        //         0,  // amountOutMin
        //     ]);

        // const swapData = swapContract.interface.encodeFunctionData("swapExactOutput",
        // [
        //     fromToken.target,
        //     toToken.target,
        //     amount,
        //     debtAmount,
        //     verifierInfo.oracle.target,
        //     verifierInfo.calldata,
        //     swapInfo.swapContract.target,
        //     swapInfo.swapData,
        //     ZERO_ADDRESS,
        //     scrapRouter.target,
        //     scrapSwapData,
        //     32 * 2 + 4      // amountIn is the 3th parameter
        // ]);

        const swapInfo = await oracleCalldata(false, fromToken.target, toToken.target, amount, swapContract.target);
        const swapData = swapContract.interface.encodeFunctionData("swapExactOutput",
            [
                fromToken.target,
                toToken.target,
                amount,
                debtAmount,
                verifierInfo.oracle.target,
                verifierInfo.calldata,
                swapInfo.swapContract.target,
                swapInfo.swapData,
                swapInfo.swapProcessor,
                SWAP_ROUTER,
                "0x",
                32 * 2 + 4      // amountIn is the 3th parameter
            ]);

        return { swapContract, swapProcessor, swapData };
    }
}


async function main() {

    // test fetch latest single report
    // const result = await fetchSingleReportLatest(FEED_ID, chainlinkApiKey, chainlinkApiSecret);
    // console.log(result);

    // test fetch single report at a specific timestamp
    // const timestamp = Math.floor(Date.now() / 1000) - 5;    // give it a 5 seconds window
    // console.log(timestamp);
    // const result = await fetchSingleReportTimestamp(FEED_ID, timestamp, chainlinkApiKey, chainlinkApiSecret);
    // console.log(result);

    // test fetch multiple reports at a specific timestamp
    // const timestamp = Math.floor(Date.now() / 1000) - 5;    // give it a 5 seconds window
    // console.log(timestamp);
    // const result = await fetchReportsTimestamp([ FEED_ID_BASE, FEED_ID ], timestamp, chainlinkApiKey, chainlinkApiSecret);
    // console.log(result);

    // // verify reports
    // const oracle = await ethers.getContractAt("ChainlinkDataStreamOracle", ORACLE_ADDRESS);
    // const tx = await oracle.verifyReports([
    //     result[0].response.fullReport,
    //     result[1].response.fullReport,
    // ]);
    // await tx.wait();

    // // get price from oracle
    // const price = await oracle.getPrice(ASSET_ADDRESS);
    // console.log("Price:", price);

    // test open/close positions using Chainlink price reports
    const [user] = await ethers.getSigners();
    const { tradingCore, baseToken, targetToken } = await initContracts();

    // test open and close long position
    await testLongPosition(tradingCore, user, baseToken, targetToken, oracleSwapper);

    // test open and close short position
    await testShortPosition(tradingCore, user, baseToken, targetToken, oracleSwapper);
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
