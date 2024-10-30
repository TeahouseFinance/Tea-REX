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
    const oracleSwap = await OracleSwap.deploy(owner, 1000);    // price spread at 0.1%

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

// generate swapData for OracleSwap
function oracleSwapper(swapContract, swapProcessor) {
    return function(input, receiver, fromToken, toToken, amount) {
        if (input) {
            const swapData = swapContract.interface.encodeFunctionData("swapExactInput", [
                fromToken,
                toToken,
                amount,
                receiver,
                0n
            ]);

            return { swapContract, swapProcessor, swapData };
        }
        else {
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
}

// open position to long targetToken
async function openLongPosition(tradingCore, user, baseToken, targetToken, marginAmount, borrowAmount, swapFunction) {
    const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(user, false, borrowAmount));
    const { swapContract, swapProcessor, swapData } = swapFunction(true, tradingCore.target, baseToken.target, targetToken.target, receivedAmount);
    await baseToken.connect(user).approve(tradingCore, marginAmount);
    const token0 = baseToken.target < targetToken.target ? baseToken : targetToken;
    const token1 = baseToken.target < targetToken.target ? targetToken : baseToken;
    const market = await tradingCore.pairMarket(token0, token1);
    await tradingCore.connect(user).openPosition(
        market,
        2,
        targetToken,
        marginAmount,
        borrowAmount,
        0,
        UINT256_MAX,
        0,
        swapContract,
        swapData
    );
}


// open position to short targetToken
async function openShortPosition(tradingCore, user, baseToken, targetToken, marginAmount, borrowAmount, swapFunction) {
    const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(user, false, borrowAmount));
    const { swapContract, swapProcessor, swapData } = swapFunction(true, tradingCore.target, targetToken.target, baseToken.target, receivedAmount);
    await baseToken.connect(user).approve(tradingCore, marginAmount);
    const token0 = baseToken.target < targetToken.target ? baseToken : targetToken;
    const token1 = baseToken.target < targetToken.target ? targetToken : baseToken;
    const market = await tradingCore.pairMarket(token0, token1);
    await tradingCore.connect(user).openPosition(
        market,
        2,
        baseToken,
        marginAmount,
        borrowAmount,
        0,
        UINT256_MAX,
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
    const baseToken = isToken0Margin ? token0 : token1;
    const targetToken = isToken0Margin ? token1 : token0;

    const positionInfo = await market.getPosition(positionId);
    const assetAmount = positionInfo[8];

    const longPosition = positionInfo[1] ^ isToken0Margin;
    if (longPosition) {
        // for long positions, sell all assets
        const swappableAmount = await tradingCore.getClosePositionSwappableAfterFee(market, positionId, 0); // for normal closing position
        const { swapContract, swapProcessor, swapData } = swapFunction(true, tradingCore.target, targetToken, baseToken, swappableAmount);
        await tradingCore.connect(user).closePosition(
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
        // for short positions, repay all debts
        const debtOfPosition = await tradingCore.debtOfPosition(market, positionId);
        const { swapContract, swapProcessor, swapData } = swapFunction(false, tradingCore.target, baseToken, targetToken, debtOfPosition[2]);
        const assets = assetAmount + positionInfo[5];
        await tradingCore.connect(user).closePosition(
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

// liquidate position
async function liquidatePosition(tradingCore, manager, market, positionId, swapFunction) {
    const token0 = await market.token0();
    const token1 = await market.token1();
    const isToken0Margin = await market.isToken0Margin();
    const baseToken = isToken0Margin ? token0 : token1;
    const targetToken = isToken0Margin ? token1 : token0;

    const positionInfo = await market.getPosition(positionId);
    const assetAmount = positionInfo[8];

    const longPosition = positionInfo[1] ^ isToken0Margin;
    if (longPosition) {
        // for long positions, sell all assets
        const swappableAmount = await tradingCore.getClosePositionSwappableAfterFee(market, positionId, 3); // for liquidating position
        const { swapContract, swapProcessor, swapData } = swapFunction(true, tradingCore.target, targetToken, baseToken, swappableAmount);
        await tradingCore.connect(manager).liquidate(
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
        // for short positions, repay all debts
        const debtOfPosition = await tradingCore.debtOfPosition(market, positionId);
        const { swapContract, swapProcessor, swapData } = swapFunction(false, tradingCore.target, baseToken, targetToken, debtOfPosition[2]);
        await tradingCore.connect(manager).liquidate(
            market,
            positionId,
            assetAmount,
            0,
            swapProcessor,
            swapContract,
            swapData
        );
    }
}


async function testLongPositionProfit(tradingCore, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap) {
    console.log("Test long position with profit:");

    // adjust price
    const price = 2500n;
    await mockOracle.setTokenPrice(targetToken, price * 10n ** 36n * 10n ** 6n / 10n ** 18n);

    // open position to long targetToken
    const marginAmount = ethers.parseUnits("1000", 6);
    const borrowAmount = marginAmount * 5n;
    const tokensBeforeOpen = await baseToken.balanceOf(user);
    await openLongPosition(tradingCore, user, baseToken, targetToken, marginAmount, borrowAmount, oracleSwapper(oracleSwap, oracleSwapProcessor));
    const tokensAfterOpen = await baseToken.balanceOf(user);
    console.log("token used for open:", tokensBeforeOpen - tokensAfterOpen);

    // get positionId
    const positions = await market.balanceOf(user);
    const positionId = await market.tokenOfOwnerByIndex(user, positions - 1n);
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

    // add margin
    const addMarginAmount = ethers.parseUnits("500", 6);
    await baseToken.connect(user).approve(tradingCore, addMarginAmount);
    await tradingCore.connect(user).addMargin(market, positionId, addMarginAmount);

    const liquidationPrice2 = await tradingCore.getLiquidationPrice(market, positionId);
    console.log("Liquidation price after add margin:", liquidationPrice2);

    // close position
    const tokensBeforeClose = await baseToken.balanceOf(user);
    const targetBeforeClose = await targetToken.balanceOf(user);
    await closePosition(tradingCore, user, market, positionId, oracleSwapper(oracleSwap, oracleSwapProcessor));
    const tokensAfterClose = await baseToken.balanceOf(user);
    const targetAfterClose = await targetToken.balanceOf(user);
    console.log("token received after close:", tokensAfterClose - tokensBeforeClose);
    console.log("target token received after close:", targetAfterClose - targetBeforeClose);
    console.log("");
}

async function testLongPositionLoss(tradingCore, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap) {
    console.log("Test long position with loss:");

    // adjust price
    const price = 2500n;
    await mockOracle.setTokenPrice(targetToken, price * 10n ** 36n * 10n ** 6n / 10n ** 18n);

    // open position to long targetToken
    const marginAmount = ethers.parseUnits("1000", 6);
    const borrowAmount = marginAmount * 5n;
    const tokensBeforeOpen = await baseToken.balanceOf(user);
    await openLongPosition(tradingCore, user, baseToken, targetToken, marginAmount, borrowAmount, oracleSwapper(oracleSwap, oracleSwapProcessor));
    const tokensAfterOpen = await baseToken.balanceOf(user);
    console.log("token used for open:", tokensBeforeOpen - tokensAfterOpen);

    // get positionId
    const positions = await market.balanceOf(user);
    const positionId = await market.tokenOfOwnerByIndex(user, positions - 1n);
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
    const newPrice = 2400n;
    await mockOracle.setTokenPrice(targetToken, newPrice * 10n ** 36n * 10n ** 6n / 10n ** 18n);

    // close position
    const tokensBeforeClose = await baseToken.balanceOf(user);
    const targetBeforeClose = await targetToken.balanceOf(user);
    await closePosition(tradingCore, user, market, positionId, oracleSwapper(oracleSwap, oracleSwapProcessor));
    const tokensAfterClose = await baseToken.balanceOf(user);
    const targetAfterClose = await targetToken.balanceOf(user);
    console.log("token received after close:", tokensAfterClose - tokensBeforeClose);
    console.log("target token received after close:", targetAfterClose - targetBeforeClose);
    console.log("");
}

async function testShortPositionProfit(tradingCore, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap) {
    console.log("Test short position with profit:");

    // adjust price
    const price = 2500n;
    await mockOracle.setTokenPrice(targetToken, price * 10n ** 36n * 10n ** 6n / 10n ** 18n);

    // open position to long targetToken
    const marginAmount = ethers.parseUnits("1000", 6);
    const borrowAmount = marginAmount * 5n * 10n ** 18n / (price * 10n ** 6n);
    const tokensBeforeOpen = await baseToken.balanceOf(user);
    await openShortPosition(tradingCore, user, baseToken, targetToken, marginAmount, borrowAmount, oracleSwapper(oracleSwap, oracleSwapProcessor));
    const tokensAfterOpen = await baseToken.balanceOf(user);
    console.log("token used for open:", tokensBeforeOpen - tokensAfterOpen);

    // get positionId
    const positions = await market.balanceOf(user);
    const positionId = await market.tokenOfOwnerByIndex(user, positions - 1n);
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
    const newPrice = 2400n;
    await mockOracle.setTokenPrice(targetToken, newPrice * 10n ** 36n * 10n ** 6n / 10n ** 18n);

    // close position
    const tokensBeforeClose = await baseToken.balanceOf(user);
    const targetBeforeClose = await targetToken.balanceOf(user);
    await closePosition(tradingCore, user, market, positionId, oracleSwapper(oracleSwap, oracleSwapProcessor));
    const tokensAfterClose = await baseToken.balanceOf(user);
    const targetAfterClose = await targetToken.balanceOf(user);
    console.log("token received after close:", tokensAfterClose - tokensBeforeClose);
    console.log("target token received after close:", targetAfterClose - targetBeforeClose);
    console.log("");
}

async function testShortPositionLoss(tradingCore, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap) {
    console.log("Test short position with loss:");

    // adjust price
    const price = 2500n;
    await mockOracle.setTokenPrice(targetToken, price * 10n ** 36n * 10n ** 6n / 10n ** 18n);

    // open position to long targetToken
    const marginAmount = ethers.parseUnits("1000", 6);
    const borrowAmount = marginAmount * 5n * 10n ** 18n / (price * 10n ** 6n);
    const tokensBeforeOpen = await baseToken.balanceOf(user);
    await openShortPosition(tradingCore, user, baseToken, targetToken, marginAmount, borrowAmount, oracleSwapper(oracleSwap, oracleSwapProcessor));
    const tokensAfterOpen = await baseToken.balanceOf(user);
    console.log("token used for open:", tokensBeforeOpen - tokensAfterOpen);

    // get positionId
    const positions = await market.balanceOf(user);
    const positionId = await market.tokenOfOwnerByIndex(user, positions - 1n);
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
    const tokensBeforeClose = await baseToken.balanceOf(user);
    const targetBeforeClose = await targetToken.balanceOf(user);
    await closePosition(tradingCore, user, market, positionId, oracleSwapper(oracleSwap, oracleSwapProcessor));
    const tokensAfterClose = await baseToken.balanceOf(user);
    const targetAfterClose = await targetToken.balanceOf(user);
    console.log("token received after close:", tokensAfterClose - tokensBeforeClose);
    console.log("target token received after close:", targetAfterClose - targetBeforeClose);
    console.log("");
}

async function testLongPositionLiquidate(tradingCore, manager, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap) {
    console.log("Test long position liquidation:");

    // adjust price
    const price = 2500n;
    await mockOracle.setTokenPrice(targetToken, price * 10n ** 36n * 10n ** 6n / 10n ** 18n);

    // open position to long targetToken
    const marginAmount = ethers.parseUnits("1000", 6);
    const borrowAmount = marginAmount * 5n;
    const tokensBeforeOpen = await baseToken.balanceOf(user);
    await openLongPosition(tradingCore, user, baseToken, targetToken, marginAmount, borrowAmount, oracleSwapper(oracleSwap, oracleSwapProcessor));
    const tokensAfterOpen = await baseToken.balanceOf(user);
    console.log("token used for open:", tokensBeforeOpen - tokensAfterOpen);

    // get positionId
    const positions = await market.balanceOf(user);
    const positionId = await market.tokenOfOwnerByIndex(user, positions - 1n);
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
    const newPrice = 2200n;
    await mockOracle.setTokenPrice(targetToken, newPrice * 10n ** 36n * 10n ** 6n / 10n ** 18n);

    // close position
    const tokensBeforeClose = await baseToken.balanceOf(user);
    const targetBeforeClose = await targetToken.balanceOf(user);
    await liquidatePosition(tradingCore, manager, market, positionId, oracleSwapper(oracleSwap, oracleSwapProcessor));
    const tokensAfterClose = await baseToken.balanceOf(user);
    const targetAfterClose = await targetToken.balanceOf(user);
    console.log("token received after close:", tokensAfterClose - tokensBeforeClose);
    console.log("target token received after close:", targetAfterClose - targetBeforeClose);
    console.log("");
}

async function testShortPositionLiquidate(tradingCore, manager, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap) {
    console.log("Test short position liquidation:");

    // adjust price
    const price = 2500n;
    await mockOracle.setTokenPrice(targetToken, price * 10n ** 36n * 10n ** 6n / 10n ** 18n);

    // open position to long targetToken
    const marginAmount = ethers.parseUnits("1000", 6);
    const borrowAmount = marginAmount * 5n * 10n ** 18n / (price * 10n ** 6n);
    const tokensBeforeOpen = await baseToken.balanceOf(user);
    await openShortPosition(tradingCore, user, baseToken, targetToken, marginAmount, borrowAmount, oracleSwapper(oracleSwap, oracleSwapProcessor));
    const tokensAfterOpen = await baseToken.balanceOf(user);
    console.log("token used for open:", tokensBeforeOpen - tokensAfterOpen);

    // get positionId
    const positions = await market.balanceOf(user);
    const positionId = await market.tokenOfOwnerByIndex(user, positions - 1n);
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
    const newPrice = 2800n;
    await mockOracle.setTokenPrice(targetToken, newPrice * 10n ** 36n * 10n ** 6n / 10n ** 18n);

    // liquidate position
    const tokensBeforeClose = await baseToken.balanceOf(user);
    const targetBeforeClose = await targetToken.balanceOf(user);
    await liquidatePosition(tradingCore, manager, market, positionId, oracleSwapper(oracleSwap, oracleSwapProcessor));
    const tokensAfterClose = await baseToken.balanceOf(user);
    const targetAfterClose = await targetToken.balanceOf(user);
    console.log("token received after close:", tokensAfterClose - tokensBeforeClose);
    console.log("target token received after close:", targetAfterClose - targetBeforeClose);
    console.log("");
}

async function main() {
    const { owner, treasury, manager, user, baseToken, targetToken, router, tradingCore, market, oracleSwapProcessor, mockOracle, oracleSwap } = await deployContracts();

    await testLongPositionProfit(tradingCore, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap);
    // await testLongPositionLoss(tradingCore, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap);
    // await testShortPositionProfit(tradingCore, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap);
    // await testShortPositionLoss(tradingCore, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap);
    // await testLongPositionLiquidate(tradingCore, manager, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap);
    // await testShortPositionLiquidate(tradingCore, manager, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap);
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
