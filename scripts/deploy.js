const { ethers, upgrades } = require("hardhat");

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


async function main() {
    const [deployer] = await ethers.getSigners();

    console.log("1. Deploy lending contracts...");

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



    console.log("2. Deploy trading contracts...");

    const SwapRelayer = await ethers.getContractFactory("SwapRelayer");
    const swapRelayer = await SwapRelayer.deploy(owner);
    console.log("SwapRelayer deployed to:", swapRelayer.target);

    const UniswapV3Processor = await ethers.getContractFactory("UniswapV3Processor");
    const uniswapV3Processor = await UniswapV3Processor.deploy();
    console.log("UniswapV3Processor deployed to:", uniswapV3Processor.target);

    const UniswapV3TwapOracle = await ethers.getContractFactory("UniswapV3TwapOracle");
    const uniswapV3TwapOracle = await UniswapV3TwapOracle.deploy(owner, baseAsset);
    console.log("UniswapV3TwapOracle deployed to:", uniswapV3TwapOracle.target);

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
            "200000",
            {
                treasury: tradingTreasury,
                tradingFee: tradingFee,
                liquidationFee: liquidationFee
            },
            "0x0000000000000000000000000000000000000000"
        ]
    );
    console.log("TradingCore proxy deployed to:", tradingCore.target);



    console.log("3. Configure contracts...");

    await router.setInterestRateModel(2, variableInterestRateModel.target);
    console.log("Router - set variableInterestRateModel to:", variableInterestRateModel.target);

    await router.setFeeConfig(routerTreasury, borrowFee);
    console.log("Router - set fee config.");

    await router.setTradingCore(tradingCore.target);
    console.log("Router - set trading core to:", tradingCore.target);

    await router.setWhitelistedOperator([routerOperator], [true]);
    console.log("Router - enable operator:", routerOperator);

    await router.transferOwnership(owner);
    console.log("Router - transfer ownership of router to:", owner);

    await tradingCore.setWhitelistedOperator([tradingOperator], [true]);
    console.log("TradingCore - enable operator:", tradingOperator);

    await tradingCore.transferOwnership(owner);
    console.log("TradingCore - transfer ownership of router to:", owner);
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
