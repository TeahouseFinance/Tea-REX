const { ethers, upgrades } = require("hardhat");
// const helpers = require("@nomicfoundation/hardhat-network-helpers");

function loadEnvVar(env, errorMsg) {
    if (env == undefined) {
        throw errorMsg;
    }

    return env;
}

function loadEnvVarInt(env, errorMsg) {
    if (env == undefined) {
        throw errorMsg;
    }

    return parseInt(env);
}

const owner = loadEnvVar(process.env.OWNER, "No OWNER");
const baseAsset = loadEnvVar(process.env.BASE_ASSET, "No BASE_ASSET");
const routerOperator = loadEnvVar(process.env.ROUTER_OPERATOR, "No ROUTER_OPERATOR");
const routerTreasury = loadEnvVar(process.env.ROUTER_TREASURY, "No ROUTER_TREASURY");
const borrowFee = loadEnvVarInt(process.env.BORROW_FEE, "No BORROW_FEE");
const tradingOperator = loadEnvVar(process.env.TRADING_OPERATOR, "No TRADING_OPERATOR");
const tradingTreasury = loadEnvVar(process.env.TRADING_TREASURY, "No TRADING_TREASURY");
const tradingFee = loadEnvVarInt(process.env.TRADING_FEE, "No TRADING_FEE");
const liquidationFee = loadEnvVarInt(process.env.LIQUIDATION_FEE, "No LIQUIDATION_FEE");

const rewardBook = "0x49F5F1B5e78690Ad62Dd2c2FBb3cE4defD75f8D4"
const oracleSwapSpread = 1000
const oracleLookBackSec = 0
const oracleDecimals = 36
const withdrawalFee = 0


async function main() {
    // await helpers.reset("https://evm-rpc.sei-apis.com", 122178806);

    const [deployer] = await ethers.getSigners();
    const verifyCmds = [];

    console.log("1. Deploy tokens for trading contest...")
    const MockToken = await ethers.getContractFactory("MockToken");
    const usdc = await MockToken.deploy(deployer, "tREX", "tREX", ethers.parseUnits("100000000", 6), 6);
    console.log("USDC deployed to:", usdc.target);
    const btc = await MockToken.deploy(deployer, "tREXbtc", "tREXbtc", ethers.parseUnits("10000", 8), 8);
    console.log("BTC deployed to:", btc.target);
    const eth = await MockToken.deploy(deployer, "tREXeth", "tREXeth", ethers.parseUnits("100000", 18), 18);
    console.log("ETH deployed to:", eth.target); 
    const sei = await MockToken.deploy(deployer, "tREXsei", "tREXsei", ethers.parseUnits("100000000", 18), 18);
    console.log("SEI deployed to:", sei.target);



    console.log("2. Deploy lending contracts...");

    const VariableInterestRateModel = await ethers.getContractFactory("VariableInterestRateModel");
    const variableInterestRateModel = await VariableInterestRateModel.deploy();
    console.log("VariableInterestRateModel deployed to:", variableInterestRateModel.target);

    const Pool = await ethers.getContractFactory("Pool");
    const poolBeacon = await upgrades.deployBeacon(Pool);
    console.log("Pool beacon deployed to:", poolBeacon.target);

    const Router = await ethers.getContractFactory("Router");
    const router = await upgrades.deployProxy(
        Router,
        [deployer.address, poolBeacon.target, 200000]
    );
    console.log("Router proxy deployed to:", router.target);



    console.log("3. Deploy trading contracts...");

    const SwapRelayer = await ethers.getContractFactory("SwapRelayer");
    const swapRelayer = await SwapRelayer.deploy(deployer);
    console.log("SwapRelayer deployed to:", swapRelayer.target);

    const OracleSwapProcessor = await ethers.getContractFactory("OracleSwapProcessor");
    const oracleSwapProcessor = await OracleSwapProcessor.deploy();
    console.log("SwapProcessor deployed to:", oracleSwapProcessor.target);

    const OracleSwap = await ethers.getContractFactory("OracleSwap");
    const oracleSwap = await OracleSwap.deploy(deployer, oracleSwapSpread);
    console.log("OracleSwap deployed to:", oracleSwap.target);

    const SEINativeOracle = await ethers.getContractFactory("SEINativeOracle");
    const oracle = await SEINativeOracle.deploy(deployer, 36, oracleLookBackSec, usdc.target, "uusdc");
    console.log("Oracle deployed to:", oracle.target)

    const MarketNFT = await ethers.getContractFactory("MarketNFT");
    const marketNFTBeacon = await upgrades.deployBeacon(MarketNFT);
    console.log("MarketNFT beacon deployed to:", marketNFTBeacon.target);

    const TradingCore = await ethers.getContractFactory("TradingCore");
    const tradingCore = await upgrades.deployProxy(
        TradingCore,
        [
            deployer.address,
            marketNFTBeacon.target,
            router.target,
            swapRelayer.target,
            200000,
            {
                treasury: tradingTreasury,
                tradingFee: tradingFee,
                liquidationFee: liquidationFee
            },
            "0x0000000000000000000000000000000000000000"
        ]
    );
    console.log("TradingCore proxy deployed to:", tradingCore.target);



    console.log("4. Configure contracts...");

    await oracle.setAsset(btc.target, "ubtc");
    // console.log("Oracle - BTC enabled");
    
    await oracle.setAsset(eth.target, "ueth");
    // console.log("Oracle - ETH enabled");
    
    await oracle.setAsset(sei.target, "usei");
    // console.log("Oracle - SEI enabled");

    await oracleSwap.setToken(usdc, oracle);
    // console.log("OracleSwap - USDC set");

    await oracleSwap.setToken(btc, oracle);
    // console.log("OracleSwap - BTC set");

    await oracleSwap.setToken(eth, oracle);
    // console.log("OracleSwap - ETH set");

    await oracleSwap.setToken(sei, oracle);
    // console.log("OracleSwap - SEI set");

    await usdc.transfer(rewardBook, ethers.parseUnits("10000000", 6));
    // console.log("USDC transfered to reward book")

    await usdc.transfer(oracleSwap, ethers.parseUnits("30000000", 6));
    // console.log("USDC transfered to oracle swap");
    
    await usdc.transfer(owner, ethers.parseUnits("30000000", 6));
    // console.log("USDC transfered to owner");

    await btc.transfer(oracleSwap, ethers.parseUnits("3000", 8));
    // console.log("BTC transfered to oracle swap");

    await btc.transfer(owner, ethers.parseUnits("4000", 8));
    // console.log("BTC transfered to owner");

    await eth.transfer(oracleSwap, ethers.parseUnits("30000", 18));
    // console.log("ETH transfered to oracle swap");

    await eth.transfer(owner, ethers.parseUnits("40000", 18));
    // console.log("ETH transfered to owner");

    await sei.transfer(oracleSwap, ethers.parseUnits("30000000", 18));
    // console.log("SEI transfered to oracle swap");

    await sei.transfer(owner, ethers.parseUnits("40000000", 18));
    // console.log("SEI transfered to owner");

    await swapRelayer.setWhitelist([ oracleSwap.target ], [ true ]);
    // console.log("SwapRelayer - oracle swap whitelisted");

    await router.setWhitelistedOperator([ deployer ], [ true ]);
    // console.log("Router - enable operator:", deployer);

    await router.setInterestRateModel(2, variableInterestRateModel.target);
    // console.log("Router - set variableInterestRateModel to:", variableInterestRateModel.target);

    await router.setFeeConfig(routerTreasury, borrowFee, withdrawalFee);
    // console.log("Router - set fee config.");

    await router.setTradingCore(tradingCore.target);
    // console.log("Router - set trading core to:", tradingCore.target);

    await router.createLendingPool(
        usdc,
        2,
        ethers.parseUnits("100000000", 6),
        ethers.parseUnits("100000000", 6),
        50000
    );
    const usdcSupplyAmount = ethers.parseUnits("30000000", 6);
    await usdc.approve(await router.pool(usdc.target, 2), usdcSupplyAmount);
    await router.supply(usdc.target, 2, owner, usdcSupplyAmount);
    console.log("USDC lending pool created:", router.pool(usdc.target, 2));


    await router.createLendingPool(
        btc,
        2,
        ethers.parseUnits("10000", 8),
        ethers.parseUnits("10000", 8),
        50000
    );

    const btcSupplyAmount = ethers.parseUnits("3000", 8);
    await btc.approve(await router.pool(btc.target, 2), btcSupplyAmount);
    await router.supply(btc.target, 2, owner, btcSupplyAmount);
    console.log("BTC lending pool created:", router.pool(btc.target, 2));

    await router.createLendingPool(
        eth,
        2,
        ethers.parseUnits("100000", 18),
        ethers.parseUnits("100000", 18),
        50000
    );

    const ethSupplyAmount = ethers.parseUnits("30000", 18);
    await eth.approve(await router.pool(eth.target, 2), ethSupplyAmount);
    await router.supply(eth.target, 2, owner, ethSupplyAmount);
    console.log("ETH lending pool created:", router.pool(eth.target, 2));

    await router.createLendingPool(
        sei,
        2,
        ethers.parseUnits("100000000", 18),
        ethers.parseUnits("100000000", 18),
        50000
    );

    const seiSupplyAmount = ethers.parseUnits("30000000", 18);
    await sei.approve(await router.pool(sei.target, 2), seiSupplyAmount);
    await router.supply(sei.target, 2, owner, seiSupplyAmount);
    console.log("SEI lending pool created:", router.pool(sei.target, 2));

    let token0Margin = usdc.target < btc.target;
    let token0 = token0Margin ? usdc : btc;
    let token1 = token0Margin ? btc : usdc;
    await tradingCore.createMarket(
        oracle,
        token0,
        token1,
        token0Margin,
        10000000,   // max leverage 10X
        50000,      // open position loss ratio < 5%
        500000,     // allow max 50% loss on margin
        20000,      // liquidation discount 2%
        ethers.parseUnits("10000000", 6),
        ethers.parseUnits("10000000", 6)
    );
    console.log("BTC/USDC market created:", await tradingCore.pairMarket(token0, token1));

    token0Margin = usdc.target < eth.target;
    token0 = token0Margin ? usdc : eth;
    token1 = token0Margin ? eth : usdc;
    await tradingCore.createMarket(
        oracle,
        token0,
        token1,
        token0Margin,
        10000000,   // max leverage 10X
        50000,      // open position loss ratio < 5%
        500000,     // allow max 50% loss on margin
        20000,      // liquidation discount 2%
        ethers.parseUnits("10000000", 6),
        ethers.parseUnits("10000000", 6)
    );
    console.log("ETH/USDC market created:", await tradingCore.pairMarket(token0, token1));

    token0Margin = usdc.target < sei.target;
    token0 = token0Margin ? usdc : sei;
    token1 = token0Margin ? sei : usdc;
    await tradingCore.createMarket(
        oracle,
        token0,
        token1,
        token0Margin,
        10000000,   // max leverage 10X
        50000,      // open position loss ratio < 5%
        500000,     // allow max 50% loss on margin
        20000,      // liquidation discount 2%
        ethers.parseUnits("10000000", 6),
        ethers.parseUnits("10000000", 6)
    );
    console.log("SEI/USDC market created:", await tradingCore.pairMarket(token0, token1));


    await router.setWhitelistedOperator([routerOperator], [true]);
    // console.log("Router - enable operator:", routerOperator);

    await tradingCore.setWhitelistedOperator([tradingOperator], [true]);
    // console.log("TradingCore - enable operator:", tradingOperator);

    await router.setWhitelistedOperator([routerOperator, deployer], [true, false]);
    // console.log("Router - enable operator:", routerOperator);

    await tradingCore.setWhitelistedOperator([tradingOperator], [true]);
    // console.log("TradingCore - enable operator:", tradingOperator);

    await router.transferOwnership(owner);
    // console.log("Router - transfer ownership of router to:", owner);

    await tradingCore.transferOwnership(owner);
    // console.log("TradingCore - transfer ownership of router to:", owner);

    await usdc.transferOwnership(owner);
    await btc.transferOwnership(owner);
    await eth.transferOwnership(owner);
    await sei.transferOwnership(owner);
    await swapRelayer.transferOwnership(owner);
    await oracle.transferOwnership(owner);
    await oracleSwap.transferOwnership(owner);


}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
