// tester script for HelperLib.js

const helpers = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { ethers, upgrades } = require("hardhat");


const ZERO_ADDRESS = '0x' + '0'.repeat(40);
const UINT256_MAX = '0x' + 'f'.repeat(64);

async function deployContracts() {
    const [ owner, treasury, manager, user ] = await ethers.getSigners();

    // deploy tokens
    const MockToken = await ethers.getContractFactory("MockToken");
    const baseToken = await MockToken.deploy(ethers.parseUnits("100000000", 6), 6);
    const targetToken = await MockToken.deploy(ethers.parseUnits("100000000", 18), 18);

    await baseToken.transfer(user, ethers.parseUnits("100000", 6));
    await targetToken.transfer(user, ethers.parseUnits("10000", 18));

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

    const OracleSwap = await ethers.getContractFactory("OracleSwap");
    const oracleSwap = await OracleSwap.deploy(owner, 2000);    // price spread at 0.2%

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

    // set up lending pools
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

    // supply to the lending pools
    const baseSupplyAmount = ethers.parseUnits("10000000", 6);
    await baseToken.approve(await router.pool(baseToken, 2), baseSupplyAmount)
    await router.supply(baseToken, 2, owner, baseSupplyAmount);

    const targetSupplyAmount = ethers.parseUnits("1000000", 18)
    await targetToken.approve(await router.pool(targetToken, 2), targetSupplyAmount);
    await router.supply(targetToken, 2, owner, targetSupplyAmount);

    // set up market
    const token0margin = baseToken.target < targetToken.target;
    const token0 = token0margin ? baseToken : targetToken;
    const token1 = token0margin ? targetToken : baseToken;
    await tradingCore.createMarket(
        mockOracle,
        token0,
        token1,
        token0margin,
        10000000,   // 10X
        50000,      // open position loss ratio < 5%
        500000,     // allow max 50% loss on margin
        20000,      // 2%
        ethers.parseEther("1000000", 6),
        ethers.parseEther("100000", 18)
    );

    const marketAddress = await tradingCore.pairMarket(token0, token1);
    const market = await ethers.getContractAt("MarketNFT", marketAddress);

    // setup oracleSwap
    await oracleSwap.setToken(baseToken, mockOracle);
    await oracleSwap.setToken(targetToken, mockOracle);

    await baseToken.transfer(oracleSwap, ethers.parseUnits("1000000", 6));
    await targetToken.transfer(oracleSwap, ethers.parseUnits("1000000", 18));

    await swapRelayer.setWhitelist([ oracleSwap.target ], [ true ]);

    return { owner, treasury, manager, user, baseToken, targetToken, router, tradingCore, market, oracleSwapProcessor, mockOracle, oracleSwap };
}

async function main() {

    const { owner, treasury, manager, user, baseToken, targetToken, router, tradingCore, market, oracleSwapProcessor, mockOracle, oracleSwap } = await deployContracts();

    // open position to long targetToken
    const marginAmount = ethers.parseUnits("1000", 6);
    const borrowAmount = marginAmount * 5n;
    const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(user, false, borrowAmount));
    const swapData = oracleSwap.interface.encodeFunctionData("swapExactInput", [
        baseToken.target,
        targetToken.target,
        receivedAmount,
        tradingCore.target,
        0n
    ]);
    await baseToken.connect(user).approve(tradingCore, marginAmount);
    const tokensBeforeOpen = await baseToken.balanceOf(user);
    await tradingCore.connect(user).openPosition(
        market,
        2,
        targetToken,
        marginAmount,
        borrowAmount,
        0,
        UINT256_MAX,
        0,
        oracleSwap,
        swapData
    );
    const tokensAfterOpen = await baseToken.balanceOf(user);
    console.log("token used for open:", tokensBeforeOpen - tokensAfterOpen);

    // get positionId
    const positionId = await market.tokenOfOwnerByIndex(user, 0);
    console.log("Position TokenID:", positionId);
    const positionInfo = await market.getPosition(positionId);
    console.log(positionInfo);
    const debtOfPosition = await tradingCore.debtOfPosition(market, positionId);
    console.log("Debt of position:", debtOfPosition[2]);
    const liquidationPrice = await tradingCore.getLiquidationPrice(market, positionId);
    console.log("Liquidation price:", liquidationPrice);

    // wait for some time
    await helpers.time.increase(86400);
    
    const debtOfPosition2 = await tradingCore.debtOfPosition(market, positionId);
    console.log("Debt of position (after a day):", debtOfPosition2[2]);

    // adjust price
    const newPrice = 2600n;
    await mockOracle.setTokenPrice(targetToken, newPrice * 10n ** 36n * 10n ** 6n / 10n ** 18n);

    // close position
    const debtAmount = debtOfPosition2[2];
    const assetAmount = positionInfo[8];
    const swapData2 = oracleSwap.interface.encodeFunctionData("swapExactOutput", [
        targetToken.target,
        baseToken.target,
        debtAmount,
        tradingCore.target,
        assetAmount
    ]);    
    const tokensBeforeClose = await baseToken.balanceOf(user);    
    await tradingCore.connect(user).closePosition(
        market,
        positionId,
        assetAmount,
        0,
        oracleSwapProcessor,
        oracleSwap,
        swapData2
    );
    const tokensAfterClose = await baseToken.balanceOf(user);
    console.log("token received after close:", tokensAfterClose - tokensBeforeClose);
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
