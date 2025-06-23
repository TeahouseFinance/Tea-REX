// test Chainlink Data Stream

const { ethers } = require("hardhat");
const crypto = require('crypto');

function loadEnvVar(env, errorMsg) {
    if (env == undefined) {
        throw errorMsg;
    }

    return env;
}


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


// testnet
const CHAINLINK_FQDN = 'https://api.testnet-dataengine.chain.link';
const FEED_ID_BASE = '0x0003dc85e8b01946bf9dfd8b0db860129181eb6105a8c8981d9f28e00b6f60d9';  // USDC/USD
const FEED_ID = '0x0003dba2d8553dfd7afe35c2bfe217ef5106d7805e5272c04a08940ddb868117';  // SEI/USD
const ASSET_ADDRESS = '0x878aD0bD8DB80A8C6Cc650EdEEd4B9941b571c5F'; // WSEI

const ORACLE_ADDRESS = '0x1e97eb36FdCa3B0705fAB71228E2c92683147B39';

const chainlinkApiKey = loadEnvVar(process.env.CHAINLINK_TEST_API_KEY, "No CHAINLINK_TEST_API_KEY");
const chainlinkApiSecret = loadEnvVar(process.env.CHAINLINK_TEST_API_SECRET, "No CHAINLINK_TEST_API_SECRET");


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


async function main() {

    // const result = await fetchSingleReportLatest(FEED_ID, chainlinkApiKey, chainlinkApiSecret);
    // console.log(result);

    // const timestamp = Math.floor(Date.now() / 1000) - 5;    // give it a 5 seconds window
    // console.log(timestamp);
    // const result = await fetchSingleReportTimestamp(FEED_ID, timestamp, chainlinkApiKey, chainlinkApiSecret);
    // console.log(result);

    const timestamp = Math.floor(Date.now() / 1000) - 5;    // give it a 5 seconds window
    console.log(timestamp);
    const result = await fetchReportsTimestamp([ FEED_ID_BASE, FEED_ID ], timestamp, chainlinkApiKey, chainlinkApiSecret);
    console.log(result);

    // verify reports
    const oracle = await ethers.getContractAt("ChainlinkDataStreamOracle", ORACLE_ADDRESS);
    const tx = await oracle.verifyReports([
        result[0].response.fullReport,
        result[1].response.fullReport,
    ]);
    await tx.wait();

    // get price from oracle
    const price = await oracle.getPrice(ASSET_ADDRESS);
    console.log("Price:", price);
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
