// tester script for HelperLib.js

const { ethers, upgrades } = require("hardhat");


const ZERO_ADDRESS = '0x' + '0'.repeat(40);

async function deployContracts() {
    const [ owner, treasury, manager, user ] = await ethers.getSigners();

    // deploy tokens
    const MockToken = await ethers.getContractFactory("MockToken");
    const baseToken = await MockToken.deploy(ethers.parseUnits("100000000", 6), 6);
    const targetToken = await MockToken.deploy(ethers.parseUnits("100000000", 18), 18);

    // deploy lending pool
    const VariableInterestRateModel = await ethers.getContractFactory("VariableInterestRateModel");
    const variableInterestRateModel = await VariableInterestRateModel.deploy();

    const Pool = await ethers.getContractFactory("Pool");
    const poolBeacon = await upgrades.deployBeacon(Pool);

    const Router = await ethers.getContractFactory("Router");
    const router = await upgrades.deployProxy(
        Router,
        [ owner.address, poolBeacon.target, 200000 ]    // fee cap at 20%
    );

    // deploy trading core
    const SwapRelayer = await ethers.getContractFactory("SwapRelayer");
    const swapRelayer = await SwapRelayer.deploy(owner);

    const OracleSwapProcessor = await ethers.getContractFactory("OracleSwapProcessor");
    const oracleSwapProcessor = await OracleSwapProcessor.deploy();

    const MockOracle = await ethers.getContractFactory("MockOracle");
    const mockOracle = await MockOracle.deploy(owner, 36, baseToken);

    const MarketNFT = await ethers.getContractFactory("MarketNFT");
    const marketNFTBeacon = await upgrades.deployBeacon(MarketNFT);

    const TradingCore = await ethers.getContractFactory("TradingCore");
    const tradingCore = await upgrades.deployProxy(
        TradingCore,
        [
            owner.address,
            marketNFTBeacon.target,
            router.target,
            swapRelayer.target,
            200000,
            {
                treasury: treasury.address,
                tradingFee: 1000,       // 0.1%
                liquidationFee: 10000   // 1%
            },
            ZERO_ADDRESS
        ]
    );

    // config trading core
    await router.setInterestRateModel(2, variableInterestRateModel);
    await router.setFeeConfig(treasury, 20000);     // 2% borrowing fee
    await router.setTradingCore(tradingCore);
    await router.setWhitelistedOperator([manager], [true]);
    await tradingCore.setWhitelistedOperator([manager], [true]);

    // set up oracle
    await mockOracle.setTokenPrice(baseToken, 10n ** 36n);
    const targetPrice = 2500n;
    await mockOracle.setTokenPrice(targetToken, targetPrice * 10n ** 36n * 10n ** 6n / 10n ** 18n);

    // set up lending pool
    await router.createLendingPool(
        baseToken,
        2,
        ethers.parseUnits("100000000", 6),
        ethers.parseUnits("200000", 6),
        50000   // 5%
    );

    await router.createLendingPool(
        targetToken,
        2,
        ethers.parseUnits("100000000", 18),
        ethers.parseUnits("200000", 18),
        50000   // 5%
    );

    // set up market
    const token0margin = baseToken.target < targetToken.target;
    const token0 = token0margin ? baseToken : targetToken;
    const token1 = token0margin ? targetToken : baseToken;
    await tradingCore.createMarket(
        mockOracle,
        token0,
        token1,
        token0margin,
        100000,     // 10X
        50000,      // open position loss ratio < 5%
        50000,      // 5%
        20000,      // 2%
        ethers.parseEther("100000", 6),
        ethers.parseEther("100000", 18)
    );
}

async function main() {

    await deployContracts();
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
