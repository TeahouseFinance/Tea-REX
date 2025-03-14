// tester script for HelperLib.js

const helpers = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { ethers, upgrades } = require("hardhat");


const ZERO_ADDRESS = '0x' + '0'.repeat(40);
const UINT256_MAX = '0x' + 'f'.repeat(64);

async function deployContracts() {
    const [ owner, treasury, manager, user ] = await ethers.getSigners();

    // deploy tokens
    const MockToken = await ethers.getContractFactory("MockToken");
    const baseToken = await MockToken.deploy(owner, "Mock", "Mock", ethers.parseUnits("100000000", 6), 6);
    const targetToken = await MockToken.deploy(owner, "Mock", "Mock", ethers.parseUnits("100000000", 18), 18);

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
    await router.setFeeConfig(treasury, 20000, 0);     // 2% borrowing fee, no withdraw fee
    await router.setTradingCore(tradingCore);
    await router.setWhitelistedOperator([owner], [true]);
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

    const targetSupplyAmount = ethers.parseUnits("1000000", 18);
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
        ethers.parseUnits("1000000", 6),
        ethers.parseUnits("100000", 18)
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

// get event
async function getEvent(contract, tx, eventName) {
    return await contract.queryFilter(eventName, tx.blockNumber, tx.blockNumber);
}

// generate ERC 2612 permit
async function generatePermit(token, user, spender, amount, deadline) {
    const name = await token.name();
    // it's recommended to try to call ".version()" function of a token to get the latest version number,
    // but it's not a standard function so it's not guaranteed to exist
    const version = "1"; 
    const chainId = (await ethers.provider.getNetwork()).chainId;
    const nonce = await token.nonces(user);
    const signature = await user.signTypedData(
        {
            name: name,
            version: version,
            chainId: chainId,
            verifyingContract: token.target,
        },
        {
            Permit: [
                { name: "owner", type: "address" },
                { name: "spender", type: "address" },
                { name: "value", type: "uint256" },
                { name: "nonce", type: "uint256" },
                { name: "deadline", type: "uint256" },
            ],
        },
        {
            "owner": user.address,
            "spender": spender.target,
            "value": amount,
            "nonce": nonce,
            "deadline": deadline,
        }
    );

    // split signature
    const r = `0x${signature.slice(2, 66)}`;
    const s = `0x${signature.slice(66, 130)}`;
    const v = ethers.toNumber(`0x${signature.slice(130, 132)}`);

    return { r, s, v };
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

// open position to long targetToken using ERC-2612 permit
async function openLongPositionPermit(tradingCore, user, baseToken, targetToken, marginAmount, borrowAmount, swapFunction) {
    const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(user, false, borrowAmount));
    const { swapContract, swapProcessor, swapData } = swapFunction(true, tradingCore.target, baseToken.target, targetToken.target, receivedAmount);
    const block = await ethers.provider.getBlock();
    const deadline = block.timestamp + 1000;
    const { r, s, v } = await generatePermit(baseToken, user, tradingCore, marginAmount, deadline);
    const token0 = baseToken.target < targetToken.target ? baseToken : targetToken;
    const token1 = baseToken.target < targetToken.target ? targetToken : baseToken;
    const market = await tradingCore.pairMarket(token0, token1);
    return await tradingCore.connect(user).openPositionPermit(
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
        swapData,
        deadline,
        v,
        r,
        s
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
    const baseToken = isToken0Margin ? token0 : token1;
    const targetToken = isToken0Margin ? token1 : token0;

    const positionInfo = await market.getPosition(positionId);
    const assetAmount = positionInfo.assetAmount;

    const longPosition = positionInfo.isLongToken0 ^ isToken0Margin;
    if (longPosition) {
        // for long positions, sell all assets
        const swappableAmount = await tradingCore.getClosePositionSwappableAfterFee(market, positionId, 0); // for normal closing position
        const { swapContract, swapProcessor, swapData } = swapFunction(true, tradingCore.target, targetToken, baseToken, swappableAmount);
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
        // for short positions, repay all debts
        const debtOfPosition = await tradingCore.debtOfPosition(market, positionId);
        const { swapContract, swapProcessor, swapData } = swapFunction(false, tradingCore.target, baseToken, targetToken, debtOfPosition.debtAmount);
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

// liquidate position
async function liquidatePosition(tradingCore, manager, market, positionId, swapFunction) {
    const token0 = await market.token0();
    const token1 = await market.token1();
    const isToken0Margin = await market.isToken0Margin();
    const baseToken = isToken0Margin ? token0 : token1;
    const targetToken = isToken0Margin ? token1 : token0;

    const positionInfo = await market.getPosition(positionId);
    const assetAmount = positionInfo.assetAmount;

    const longPosition = positionInfo.isLongToken0 ^ isToken0Margin;
    const swappableAmount = await tradingCore.getClosePositionSwappableAfterFee(market, positionId, 3); // for liquidating position
    if (longPosition) {
        // for long positions, sell all assets
        const { swapContract, swapProcessor, swapData } = swapFunction(true, tradingCore.target, targetToken, baseToken, swappableAmount);
        return await tradingCore.connect(manager).liquidate(
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
        const assets = assetAmount + positionInfo.marginAmount;

        // it's possible that the amount of all assets are not enough to repay all debts, so do a static call testing selling all assets first
        // note that there's a small chance that when the actual transaction was sent, the result could be different from the testing
        // so it could sell all assets in some situation when it's not necessary, but the only downside is a little extra target tokens in the user's wallet
        // or the liquidation call could revert, so in the production system, liquidation call should be attempted again if it failed
        const { swapContract, swapProcessor, swapData } = swapFunction(true, tradingCore.target, baseToken, targetToken, swappableAmount);
        const results = await tradingCore.connect(manager).liquidate.staticCall(
            market,
            positionId,
            assets,
            0,
            ZERO_ADDRESS,
            swapContract,
            swapData
        );

        if (results.decreasedDebtAmount < debtOfPosition.debtAmount) {
            // not enough assets to repay all debts, just sell all assets
            return await tradingCore.connect(manager).liquidate(
                market,
                positionId,
                assets,
                0,
                ZERO_ADDRESS,
                swapContract,
                swapData
            );  
        }
        else {
            // there are enough assets, swap just enough amount to repay debts
            const { swapContract, swapProcessor, swapData } = swapFunction(false, tradingCore.target, baseToken, targetToken, debtOfPosition.debtAmount);
            return await tradingCore.connect(manager).liquidate(
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
}


async function testLongPosition(tradingCore, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap, startPrice, endPrice, moreMargin, timespan) {
    console.log("Test long position:");

    // get lending pool
    const router = await ethers.getContractAt("Router", await tradingCore.router());
    const pool = await ethers.getContractAt("Pool", await router.pool(baseToken, 2));
    const tokensInPoolBefore = await baseToken.balanceOf(pool);

    // adjust price
    console.log("Start price:", startPrice);
    await mockOracle.setTokenPrice(targetToken, startPrice);

    // open position to long targetToken
    const marginAmount = ethers.parseUnits("1000", 6);
    const leverage = 5n;
    const borrowAmount = marginAmount * leverage;
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
    console.log("Debt of position:", debtOfPosition.debtAmount);
    const liquidationPrice = await tradingCore.getLiquidationPrice(market, positionId);
    console.log("Liquidation price:", liquidationPrice);

    // wait for some time
    await helpers.time.increase(timespan);
    
    const debtOfPosition2 = await tradingCore.debtOfPosition(market, positionId);
    console.log("Debt of position (after " + timespan + " seconds):", debtOfPosition2.debtAmount);

    // adjust price
    console.log("End price:", endPrice);
    await mockOracle.setTokenPrice(targetToken, endPrice);

    if (moreMargin) {
        // add margin
        const addMarginAmount = ethers.parseUnits("500", 6);
        await baseToken.connect(user).approve(tradingCore, addMarginAmount);
        await tradingCore.connect(user).addMargin(market, positionId, addMarginAmount);    

        const liquidationPrice2 = await tradingCore.getLiquidationPrice(market, positionId);
        console.log("Liquidation price after add margin:", liquidationPrice2);
    
        const positionInfo2 = await market.getPosition(positionId);
        console.log(positionInfo2);    
    }

    // close position
    const tokensBeforeClose = await baseToken.balanceOf(user);
    const targetBeforeClose = await targetToken.balanceOf(user);
    const tx = await closePosition(tradingCore, user, market, positionId, oracleSwapper(oracleSwap, oracleSwapProcessor));
    const tokensAfterClose = await baseToken.balanceOf(user);
    const targetAfterClose = await targetToken.balanceOf(user);
    const event = await getEvent(tradingCore, tx, "ClosePosition");
    console.log("ClosePosition event:", event[0].args);

    console.log("token received after close:", tokensAfterClose - tokensBeforeClose);
    console.log("target token received after close:", targetAfterClose - targetBeforeClose);
    const tokensInPoolAfter = await baseToken.balanceOf(pool);
    console.log("token diff in pool:", tokensInPoolAfter - tokensInPoolBefore);
    const positionInfo3 = await market.getPosition(positionId);
    console.log(positionInfo3);
    console.log("----------------");
}

async function testLongPositionPermit(tradingCore, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap, startPrice, endPrice, moreMargin, timespan) {
    console.log("Test long position (permit):");

    // get lending pool
    const router = await ethers.getContractAt("Router", await tradingCore.router());
    const pool = await ethers.getContractAt("Pool", await router.pool(baseToken, 2));
    const tokensInPoolBefore = await baseToken.balanceOf(pool);

    // adjust price
    console.log("Start price:", startPrice);
    await mockOracle.setTokenPrice(targetToken, startPrice);

    // open position to long targetToken
    const marginAmount = ethers.parseUnits("1000", 6);
    const leverage = 5n;
    const borrowAmount = marginAmount * leverage;
    const tokensBeforeOpen = await baseToken.balanceOf(user);
    await openLongPositionPermit(tradingCore, user, baseToken, targetToken, marginAmount, borrowAmount, oracleSwapper(oracleSwap, oracleSwapProcessor));
    const tokensAfterOpen = await baseToken.balanceOf(user);
    console.log("token used for open:", tokensBeforeOpen - tokensAfterOpen);

    // get positionId
    const positions = await market.balanceOf(user);
    const positionId = await market.tokenOfOwnerByIndex(user, positions - 1n);
    console.log("Position TokenID:", positionId);
    const positionInfo = await market.getPosition(positionId);
    console.log(positionInfo);
    const debtOfPosition = await tradingCore.debtOfPosition(market, positionId);
    console.log("Debt of position:", debtOfPosition.debtAmount);
    const liquidationPrice = await tradingCore.getLiquidationPrice(market, positionId);
    console.log("Liquidation price:", liquidationPrice);

    // wait for some time
    await helpers.time.increase(timespan);
    
    const debtOfPosition2 = await tradingCore.debtOfPosition(market, positionId);
    console.log("Debt of position (after " + timespan + " seconds):", debtOfPosition2.debtAmount);

    // adjust price
    console.log("End price:", endPrice);
    await mockOracle.setTokenPrice(targetToken, endPrice);

    if (moreMargin) {
        // add margin
        const addMarginAmount = ethers.parseUnits("500", 6);
        const block = await ethers.provider.getBlock();
        const deadline = block.timestamp + 1000;
        const { r, s, v } = await generatePermit(baseToken, user, tradingCore, addMarginAmount, deadline);
        await tradingCore.connect(user).addMarginPermit(market, positionId, addMarginAmount, deadline, v, r, s);

        const liquidationPrice2 = await tradingCore.getLiquidationPrice(market, positionId);
        console.log("Liquidation price after add margin:", liquidationPrice2);
    
        const positionInfo2 = await market.getPosition(positionId);
        console.log(positionInfo2);    
    }

    // close position
    const tokensBeforeClose = await baseToken.balanceOf(user);
    const targetBeforeClose = await targetToken.balanceOf(user);
    const tx = await closePosition(tradingCore, user, market, positionId, oracleSwapper(oracleSwap, oracleSwapProcessor));
    const tokensAfterClose = await baseToken.balanceOf(user);
    const targetAfterClose = await targetToken.balanceOf(user);
    const event = await getEvent(tradingCore, tx, "ClosePosition");
    console.log("ClosePosition event:", event[0].args);

    console.log("token received after close:", tokensAfterClose - tokensBeforeClose);
    console.log("target token received after close:", targetAfterClose - targetBeforeClose);
    const tokensInPoolAfter = await baseToken.balanceOf(pool);
    console.log("token diff in pool:", tokensInPoolAfter - tokensInPoolBefore);
    const positionInfo3 = await market.getPosition(positionId);
    console.log(positionInfo3);
    console.log("----------------");
}

async function testShortPosition(tradingCore, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap, startPrice, endPrice, moreMargin, timespan) {
    console.log("Test short position:");

    // get lending pool
    const router = await ethers.getContractAt("Router", await tradingCore.router());
    const pool = await ethers.getContractAt("Pool", await router.pool(targetToken, 2));
    const tokensInPoolBefore = await targetToken.balanceOf(pool);

    // adjust price
    console.log("Start price:", startPrice);
    await mockOracle.setTokenPrice(targetToken, startPrice);

    // open position to long targetToken
    const marginAmount = ethers.parseUnits("1000", 6);
    const leverage = 5n;
    const borrowAmount = marginAmount * leverage * 10n ** 36n / startPrice;
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
    console.log("Debt of position:", debtOfPosition.debtAmount);
    const liquidationPrice = await tradingCore.getLiquidationPrice(market, positionId);
    console.log("Liquidation price:", liquidationPrice);

    // wait for some time
    await helpers.time.increase(timespan);
    
    const debtOfPosition2 = await tradingCore.debtOfPosition(market, positionId);
    console.log("Debt of position (after " + timespan + " seconds):", debtOfPosition2.debtAmount);

    // adjust price
    console.log("End price:", endPrice);
    await mockOracle.setTokenPrice(targetToken, endPrice);

    if (moreMargin) {
        // add margin
        const addMarginAmount = ethers.parseUnits("500", 6);
        await baseToken.connect(user).approve(tradingCore, addMarginAmount);
        await tradingCore.connect(user).addMargin(market, positionId, addMarginAmount);

        const liquidationPrice2 = await tradingCore.getLiquidationPrice(market, positionId);
        console.log("Liquidation price after add margin:", liquidationPrice2);
    
        const positionInfo2 = await market.getPosition(positionId);
        console.log(positionInfo2);        
    }

    // close position
    const tokensBeforeClose = await baseToken.balanceOf(user);
    const targetBeforeClose = await targetToken.balanceOf(user);
    const tx = await closePosition(tradingCore, user, market, positionId, oracleSwapper(oracleSwap, oracleSwapProcessor));
    const tokensAfterClose = await baseToken.balanceOf(user);
    const targetAfterClose = await targetToken.balanceOf(user);
    const event = await getEvent(tradingCore, tx, "ClosePosition");
    console.log("ClosePosition event:", event[0].args);

    console.log("token received after close:", tokensAfterClose - tokensBeforeClose);
    console.log("target token received after close:", targetAfterClose - targetBeforeClose);
    const tokensInPoolAfter = await targetToken.balanceOf(pool);
    console.log("token diff in pool:", tokensInPoolAfter - tokensInPoolBefore);
    const positionInfo2 = await market.getPosition(positionId);
    console.log(positionInfo2);    
    console.log("----------------");
}

async function testLongPositionLiquidate(tradingCore, manager, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap, startPrice, endPrice, timespan) {
    console.log("Test long position liquidation:");

    // get lending pool
    const router = await ethers.getContractAt("Router", await tradingCore.router());
    const pool = await ethers.getContractAt("Pool", await router.pool(baseToken, 2));
    const tokensInPoolBefore = await baseToken.balanceOf(pool);

    // adjust price
    console.log("Start price:", startPrice);
    await mockOracle.setTokenPrice(targetToken, startPrice);

    // open position to long targetToken
    const marginAmount = ethers.parseUnits("1000", 6);
    const leverage = 5n;
    const borrowAmount = marginAmount * leverage;
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
    console.log("Debt of position:", debtOfPosition.debtAmount);
    const liquidationPrice = await tradingCore.getLiquidationPrice(market, positionId);
    console.log("Liquidation price:", liquidationPrice);

    // wait for some time
    await helpers.time.increase(timespan);
    
    const debtOfPosition2 = await tradingCore.debtOfPosition(market, positionId);
    console.log("Debt of position (after " + timespan + " seconds):", debtOfPosition2.debtAmount);

    // adjust price
    console.log("End price:", endPrice);
    await mockOracle.setTokenPrice(targetToken, endPrice);

    // close position
    const tokensBeforeClose = await baseToken.balanceOf(user);
    const targetBeforeClose = await targetToken.balanceOf(user);
    const tx = await liquidatePosition(tradingCore, manager, market, positionId, oracleSwapper(oracleSwap, oracleSwapProcessor));
    const tokensAfterClose = await baseToken.balanceOf(user);
    const targetAfterClose = await targetToken.balanceOf(user);
    const event = await getEvent(tradingCore, tx, "Liquidate");
    console.log("Liquidate event:", event[0].args);

    console.log("token received after close:", tokensAfterClose - tokensBeforeClose);
    console.log("target token received after close:", targetAfterClose - targetBeforeClose);
    const tokensInPoolAfter = await baseToken.balanceOf(pool);
    console.log("token diff in pool:", tokensInPoolAfter - tokensInPoolBefore);    
    const positionInfo2 = await market.getPosition(positionId);
    console.log(positionInfo2);    
    console.log("----------------");
}

async function testShortPositionLiquidate(tradingCore, manager, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap, startPrice, endPrice, timespan) {
    console.log("Test short position liquidation:");

    // get lending pool
    const router = await ethers.getContractAt("Router", await tradingCore.router());
    const pool = await ethers.getContractAt("Pool", await router.pool(targetToken, 2));
    const tokensInPoolBefore = await targetToken.balanceOf(pool);
    
    // adjust price
    console.log("Start price:", startPrice);
    await mockOracle.setTokenPrice(targetToken, startPrice);

    // open position to long targetToken
    const marginAmount = ethers.parseUnits("1000", 6);
    const leverage = 5n;
    const borrowAmount = marginAmount * leverage * 10n ** 36n / startPrice;
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
    console.log("Debt of position:", debtOfPosition.debtAmount);
    const liquidationPrice = await tradingCore.getLiquidationPrice(market, positionId);
    console.log("Liquidation price:", liquidationPrice);

    // wait for some time
    await helpers.time.increase(timespan);
    
    const debtOfPosition2 = await tradingCore.debtOfPosition(market, positionId);
    console.log("Debt of position (after " + timespan + " seconds):", debtOfPosition2.debtAmount);

    // adjust price
    console.log("End price:", endPrice);
    await mockOracle.setTokenPrice(targetToken, endPrice);

    // liquidate position
    const tokensBeforeClose = await baseToken.balanceOf(user);
    const targetBeforeClose = await targetToken.balanceOf(user);
    const tx = await liquidatePosition(tradingCore, manager, market, positionId, oracleSwapper(oracleSwap, oracleSwapProcessor));
    const tokensAfterClose = await baseToken.balanceOf(user);
    const targetAfterClose = await targetToken.balanceOf(user);
    const event = await getEvent(tradingCore, tx, "Liquidate");
    console.log("Liquidate event:", event[0].args);

    console.log("token received after close:", tokensAfterClose - tokensBeforeClose);
    console.log("target token received after close:", targetAfterClose - targetBeforeClose);
    const tokensInPoolAfter = await targetToken.balanceOf(pool);
    console.log("token diff in pool:", tokensInPoolAfter - tokensInPoolBefore);    
    const positionInfo2 = await market.getPosition(positionId);
    console.log(positionInfo2);    
    console.log("----------------");
}

async function main() {
    const { owner, treasury, manager, user, baseToken, targetToken, tradingCore, market, oracleSwapProcessor, mockOracle, oracleSwap } = await deployContracts();

    // test long position with profit
    await testLongPosition(tradingCore, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap,
        2500n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        2600n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        true,
        86400
    );
    // test long position with permit
    await testLongPositionPermit(tradingCore, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap,
        2500n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        2600n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        true,
        86400
    );
    // test long position with loss
    await testLongPosition(tradingCore, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap,
        2500n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        2400n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        true,        
        86400
    );
    // test long position with large loss
    await testLongPosition(tradingCore, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap,
        2500n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        2050n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        false,
        86400
    );
    // test short position with profit
    await testShortPosition(tradingCore, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap,
        2500n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        2400n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        true,
        86400
    );
    // test short position with loss
    await testShortPosition(tradingCore, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap,
        2500n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        2600n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        true,
        86400
    );
    // test short position with large loss
    await testShortPosition(tradingCore, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap,
        2500n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        2950n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        false,
        86400
    );


    // test long position with loss to be liquidated
    await testLongPositionLiquidate(tradingCore, manager, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap,
        2500n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        2200n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        86400
    );
    // test short position with loss to be liquidated
    await testShortPositionLiquidate(tradingCore, manager, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap,
        2500n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        2800n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        86400
    );

    // test long position with loss to be liquidated covered by fee
    await testLongPositionLiquidate(tradingCore, manager, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap,
        2500n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        2050n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        86400 * 180
    );

    // test short position with loss to be liquidated covered by fee
    await testShortPositionLiquidate(tradingCore, manager, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap,
        2500n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        2950n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        86400 * 180
    );

    // test long position with loss to be liquidated not covered by fee
    await testLongPositionLiquidate(tradingCore, manager, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap,
        2500n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        1900n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        86400 * 180
    );

    // test short position with loss to be liquidated not covered by fee
    await testShortPositionLiquidate(tradingCore, manager, user, baseToken, targetToken, market, oracleSwapProcessor, mockOracle, oracleSwap,
        2500n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        3100n * 10n ** 36n * 10n ** 6n / 10n ** 18n,
        86400 * 180
    );
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
