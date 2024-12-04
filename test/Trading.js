const { ethers, upgrades } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { before } = require("mocha");
//const { base } = require("viem/chains");

const ZERO_ADDRESS = '0x' + '0'.repeat(40);
const UINT256_MAX = '0x' + 'f'.repeat(64);

const FEE_CAP = 300000;
const interestRateModelType = 2;
const reserveRatio = 50000;

describe("TeaRex Trading Core", function () {
    async function deployContractsFixture() {
        const [owner, feeTreasury, manager, user] = await ethers.getSigners();

        const feeConfig = {
            treasury: feeTreasury.address,
            tradingFee: 1000,
            liquidationFee: 10000,
        }

        const Pool = await ethers.getContractFactory("Pool");
        const pool = await upgrades.deployBeacon(Pool);

        const Router = await ethers.getContractFactory("Router");
        const router = await upgrades.deployProxy(Router, [owner.address, pool.target, FEE_CAP]);

        const MarketNFT = await ethers.getContractFactory("MarketNFT");
        const marketNFT = await upgrades.deployBeacon(MarketNFT);

        const interestRateModel = await ethers.deployContract("VariableInterestRateModel", []);
        const swapRelayer = await ethers.deployContract("SwapRelayer", [owner.address]);

        const TradingCore = await ethers.getContractFactory("TradingCore");
        const tradingCore = await upgrades.deployProxy(
            TradingCore, 
            [
                owner.address,
                marketNFT.target,
                router.target,
                swapRelayer.target,
                "200000",
                {
                    treasury: feeConfig.treasury,
                    tradingFee: feeConfig.tradingFee,
                    liquidationFee: feeConfig.liquidationFee
                },
                ZERO_ADDRESS
            ]);

        const { baseToken, targetToken }  = await deployTokenFixture();
        await baseToken.transfer(user, ethers.parseUnits("10000", 6));
        await targetToken.transfer(user, ethers.parseUnits("10000", 18));
        
        const assetOracle = await ethers.deployContract("MockOracle", [owner.address, 36, baseToken.target]);
        const oracleSwapRouter = await ethers.deployContract("OracleSwap", [owner.address, 0]); // set price spread default as 0%
        const oracleSwapProcessor = await ethers.deployContract("OracleSwapProcessor", []);

        const borrow_fee = 20000;
        await router.setInterestRateModel(interestRateModelType, interestRateModel);
        await router.setTradingCore(tradingCore);
        await router.setFeeConfig(feeTreasury.address, borrow_fee);
        await router.setWhitelistedOperator([manager], [true]);
        await tradingCore.setWhitelistedOperator([manager], [true]);
        await swapRelayer.setWhitelist([oracleSwapRouter.target], [true]);
        
        await router.createLendingPool(
            baseToken,
            interestRateModelType,
            ethers.parseUnits("100000000", 6),
            ethers.parseUnits("500000", 6),
            reserveRatio   // 5%
        )

        await router.createLendingPool(
            targetToken,
            interestRateModelType,
            ethers.parseUnits("100000000", 18),
            ethers.parseUnits("500000", 18),
            reserveRatio   // 5%
        )

        const basePool = await router.getLendingPool(baseToken.target, interestRateModelType);
        const targetPool = await router.getLendingPool(targetToken.target, interestRateModelType);

        const baseSupplyAmount = ethers.parseUnits("1000000", 6);
        const targetSupplyAmount = ethers.parseUnits("100000", 18)

        await baseToken.approve(basePool, baseSupplyAmount);
        await targetToken.approve(targetPool, targetSupplyAmount);

        await router.supply(
            baseToken.target,
            interestRateModelType,
            owner.address,
            baseSupplyAmount
        )

        await router.supply(
            targetToken.target,
            interestRateModelType,
            owner.address,
            targetSupplyAmount
        )

        // set up oracle
        await assetOracle.setTokenPrice(baseToken, 10n ** 36n);
        const targetPrice = 3000n;
        await assetOracle.setTokenPrice(targetToken, targetPrice * 10n ** 36n * 10n ** 6n / 10n ** 18n);
        // console.log("Oracle set up");

        await oracleSwapRouter.setToken(baseToken, assetOracle);
        await oracleSwapRouter.setToken(targetToken, assetOracle);
        await baseToken.transfer(oracleSwapRouter, ethers.parseUnits("10000000", 6));
        await targetToken.transfer(oracleSwapRouter, ethers.parseUnits("10000000", 18));
        
        const maxLeverge = 10 * 1e6;
        const openPositionLossRatioThreshold = 50000;
        const liquidateLossRatioThreshold = 500000;
        const liquidationDiscount = 20000;

        const token0margin = baseToken.target < targetToken.target;
        const token0 = token0margin ? baseToken : targetToken;
        const token1 = token0margin ? targetToken : baseToken;

        await tradingCore.createMarket(
            assetOracle,
            token0,
            token1,
            token0margin,
            maxLeverge,
            openPositionLossRatioThreshold,
            liquidateLossRatioThreshold,
            liquidationDiscount,
            ethers.parseEther("1000000", 6),
            ethers.parseEther("100000", 18)
        );
        // console.log("Market created");

        const marketAddress = await tradingCore.pairMarket(token0, token1);
        const market = await ethers.getContractAt("MarketNFT", marketAddress);

        return { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, oracleSwapProcessor, market };
    }

    async function deployTokenFixture() {
        const MockToken = await ethers.getContractFactory("MockToken");
        const baseToken = await MockToken.deploy("Mock", "Mock", ethers.parseUnits("100000000", 6), 6);
        const targetToken = await MockToken.deploy("Mock", "Mock", ethers.parseUnits("100000000", 18), 18);
    
        return { baseToken, targetToken };
    }
    
    async function openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, takeProfitPrice, stopLossPrice) {
        const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(user, false, borrowAmount));
        const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
            baseToken.target,
            targetToken.target,
            receivedAmount,
            tradingCore.target,
            0n
        ]);

        await baseToken.connect(user).approve(tradingCore, marginAmount);
        await tradingCore.connect(user).openPosition(
            market,
            interestRateModelType,
            targetToken,
            marginAmount,
            borrowAmount,
            0,
            takeProfitPrice,
            stopLossPrice,
            oracleSwapRouter,
            swapCalldata
        )

        const events = await tradingCore.queryFilter("OpenPosition");
        const lastEvent = events[events.length - 1];
        const positionId = lastEvent.args[1];

        return { positionId };
    }
    
    async function openShortPosition( baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, takeProfitPrice, stopLossPrice) {
        const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(user, true, borrowAmount));
        const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
            targetToken.target,
            baseToken.target,
            receivedAmount,
            tradingCore.target,
            0n
        ]);

        await baseToken.connect(user).approve(tradingCore, marginAmount);
        await tradingCore.connect(user).openPosition(
            market,
            interestRateModelType,
            baseToken,
            marginAmount,
            borrowAmount,
            0,
            takeProfitPrice,
            stopLossPrice,
            oracleSwapRouter,
            swapCalldata
        )

        const events = await tradingCore.queryFilter("OpenPosition");
        const lastEvent = events[events.length - 1];
        const positionId = lastEvent.args[1];

        return { positionId}; 
    }       

    describe("Functionality", function () {
        it("Should not be able to open position when market is paused", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, market } = await loadFixture(deployContractsFixture);
            
            await market.connect(owner).pause();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = marginAmount * 5n;
            const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(user, false, borrowAmount));
            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                baseToken.target,
                targetToken.target,
                receivedAmount,
                tradingCore.target,
                0n
            ]);

            await baseToken.connect(user).approve(tradingCore, marginAmount);
            await expect(tradingCore.connect(user).openPosition(
                market,
                interestRateModelType,
                targetToken,
                marginAmount,
                borrowAmount,
                0,
                UINT256_MAX,
                0,
                oracleSwapRouter,
                swapCalldata
            )).to.be.revertedWithCustomError(market, "EnforcedPause");    
        });

        it("Should open long position correctly", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, market } = await loadFixture(deployContractsFixture);
            
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = marginAmount * 5n;
            const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(user, false, borrowAmount));
            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                baseToken.target,
                targetToken.target,
                receivedAmount,
                tradingCore.target,
                0n
            ]);

            const beforeBaseBalance = await baseToken.balanceOf(user.address);
            await baseToken.connect(user).approve(tradingCore, marginAmount);
            await tradingCore.connect(user).openPosition(
                market,
                interestRateModelType,
                targetToken,
                marginAmount,
                borrowAmount,
                0,
                UINT256_MAX,
                0,
                oracleSwapRouter,
                swapCalldata
            )
            const afterBaseBalance = await baseToken.balanceOf(user.address);
            expect(beforeBaseBalance - afterBaseBalance).to.equal(marginAmount);

            const positionId = await market.tokenOfOwnerByIndex(user, 0);
            const positionInfo = await market.getPosition(positionId);
            const debtInfo = await tradingCore.debtOfPosition(market, positionId);

            expect(positionInfo.marginAmount).to.equal(marginAmount);
            expect(debtInfo[2]).to.equal(borrowAmount.toString());
            // Get liquidation price
            const liqPrice = await tradingCore.getLiquidationPrice(market, positionId);
            // console.log("Liquidation price", liqPrice.toString());
        });

        it("Should open short position correctly", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, market } = await loadFixture(deployContractsFixture);

            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("2", 18);
            const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(user, false, borrowAmount));
            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                targetToken.target,
                baseToken.target,
                receivedAmount,
                tradingCore.target,
                0n
            ]);

            const beforeTargetBalance = await baseToken.balanceOf(user.address);
            await baseToken.connect(user).approve(tradingCore, marginAmount);
            await tradingCore.connect(user).openPosition(
                market,
                interestRateModelType,
                baseToken,
                marginAmount,
                borrowAmount,
                0,
                UINT256_MAX,
                0,
                oracleSwapRouter,
                swapCalldata
            )
            const afterTargetBalance = await baseToken.balanceOf(user.address);
            expect(beforeTargetBalance - afterTargetBalance).to.equal(marginAmount);

            const positionId = await market.tokenOfOwnerByIndex(user, 0);            
            const debtInfo = await tradingCore.debtOfPosition(market, positionId);
            const positionInfo = await market.getPosition(positionId);

            expect(positionInfo.marginAmount).to.equal(marginAmount);
            expect(debtInfo[2]).to.equal(borrowAmount.toString());
            const liqPrice = await tradingCore.getLiquidationPrice(market, positionId);
            // console.log("Liquidation price", liqPrice.toString());

        });

        it("Should revert if open position exceed leverage limit", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, market } = await loadFixture(deployContractsFixture);

            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = marginAmount * 15n;
            const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(user, false, borrowAmount));
            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                baseToken.target,
                targetToken.target,
                receivedAmount,
                tradingCore.target,
                0n
            ]);

            await baseToken.connect(user).approve(tradingCore, marginAmount);
            await expect(tradingCore.connect(user).openPosition(
                market,
                interestRateModelType,
                targetToken,
                marginAmount,
                borrowAmount,
                0,
                UINT256_MAX,
                0,
                oracleSwapRouter,
                swapCalldata
            )).to.be.revertedWithCustomError(market, "InvalidLeverage");
        });

        it("Should be able to close long position correctly", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, 0);
            await time.increase(86400);

            const positionInfo = await market.getPosition(positionId);
            const assetAmount = positionInfo.assetAmount;
            const swappableAmount = await tradingCore.getClosePositionSwappableAfterFee(market, positionId, 0); // for normal close position
            // console.log("Swappable amount", swappableAmount.toString());

            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                targetToken.target,
                baseToken.target,
                swappableAmount,
                tradingCore.target,
                0n
            ]);

            await tradingCore.connect(user).closePosition(
                market,
                positionId,
                assetAmount,
                0,
                ZERO_ADDRESS,
                oracleSwapRouter,
                swapCalldata
            );
            
            const debtInfo = await tradingCore.debtOfPosition(market, positionId);
            expect(debtInfo[2]).to.equal(0);
        });

        it("Should be able to close long position which has unrealized pnl loss", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, 0);
            
            await time.increase(86400);
            await assetOracle.setTokenPrice(targetToken, 2700n * 10n ** 36n * 10n ** 6n / 10n ** 18n);

            const positionInfo = await market.getPosition(positionId);
            const assetAmount = positionInfo.assetAmount;
            // console.log("Position info", positionInfo);
            const swappableAmount = await tradingCore.getClosePositionSwappableAfterFee(market, positionId, 0); // for normal close position
            // console.log("Swappable amount", swappableAmount.toString());

            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                targetToken.target,
                baseToken.target,
                swappableAmount,
                tradingCore.target,
                0n
            ]);

            await tradingCore.connect(user).closePosition(
                market,
                positionId,
                assetAmount,
                0,
                ZERO_ADDRESS,
                oracleSwapRouter,
                swapCalldata
            );
            
            const debtInfo = await tradingCore.debtOfPosition(market, positionId);
            expect(debtInfo[2]).to.equal(0);
        });

        it("Should be able to close short position correctly", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, oracleSwapProcessor, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("2", 18);
            const { positionId } = await openShortPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, 0);
        
            await time.increase(86400);
            
            const positionInfo = await market.getPosition(positionId);
            const assetAmount = positionInfo.assetAmount;
            // console.log("Position info", positionInfo);
            const debt = await tradingCore.debtOfPosition(market, positionId);
            const debtAmount = debt.debtAmount;
            // console.log("Debt amount", debtAmount.toString());
            
            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactOutput", [
                baseToken.target,
                targetToken.target,
                debtAmount,
                tradingCore.target,
                UINT256_MAX
            ]);

            const assets = assetAmount + positionInfo.marginAmount;
            await tradingCore.connect(user).closePosition(
                market,
                positionId,
                assets,
                0,
                oracleSwapProcessor,
                oracleSwapRouter,
                swapCalldata
            );
            
            const debtInfo = await tradingCore.debtOfPosition(market, positionId);
            // const afterBaseBalance = await baseToken.balanceOf(user.address);
            expect(debtInfo[2]).to.equal(0);
        });

        it("Should be able to close short position which has unrealized pnl loss", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, oracleSwapProcessor, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("2", 18);
            const { positionId } = await openShortPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, 0);
        
            await time.increase(86400);
            await assetOracle.setTokenPrice(targetToken, 2700n * 10n ** 36n * 10n ** 6n / 10n ** 18n);

            const positionInfo = await market.getPosition(positionId);
            const assetAmount = positionInfo.assetAmount;
            // console.log("Position info", positionInfo);
            const debt = await tradingCore.debtOfPosition(market, positionId);
            const debtAmount = debt.debtAmount;
            // console.log("Debt amount", debtAmount.toString());
            
            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactOutput", [
                baseToken.target,
                targetToken.target,
                debtAmount,
                tradingCore.target,
                UINT256_MAX
            ]);

            const assets = assetAmount + positionInfo.marginAmount;
            await tradingCore.connect(user).closePosition(
                market,
                positionId,
                assets,
                0,
                oracleSwapProcessor,
                oracleSwapRouter,
                swapCalldata
            );
            
            const debtInfo = await tradingCore.debtOfPosition(market, positionId);
            // const afterBaseBalance = await baseToken.balanceOf(user.address);
            expect(debtInfo[2]).to.equal(0);
        });

        it("Should not be able to call closePosition if margin amount is less than zero", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, 0);
            await time.increase(86400);
            await assetOracle.setTokenPrice(targetToken, 2500n * 10n ** 36n * 10n ** 6n / 10n ** 18n);

            const positionInfo = await market.getPosition(positionId);
            const assetAmount = positionInfo.assetAmount;
            const swappableAmount = await tradingCore.getClosePositionSwappableAfterFee(market, positionId, 0); // for normal close position

            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                targetToken.target,
                baseToken.target,
                swappableAmount,
                tradingCore.target,
                0n
            ]);

            await expect(tradingCore.connect(user).closePosition(
                market,
                positionId,
                assetAmount,
                0,
                ZERO_ADDRESS,
                oracleSwapRouter,
                swapCalldata
            )).to.be.reverted;
        });

        it("Should add margin correctly", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, oracleSwapProcessor, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, 0);
            const positionInfo = await market.getPosition(positionId);
            const beforeMarginAmount = positionInfo.marginAmount;
            const beforeLiqPrice = await tradingCore.getLiquidationPrice(market, positionId);
            // console.log("Before liquidation price", beforeLiqPrice.toString());
            const addAmount = ethers.parseUnits("500", 6);

            await baseToken.connect(user).approve(tradingCore, addAmount);
            await expect(tradingCore.connect(user).addMargin(
                market,
                positionId,
                addAmount
            )).to.changeTokenBalances(baseToken, [user, tradingCore], [-addAmount, addAmount]);

            const afterMarginAmount = (await market.getPosition(positionId)).marginAmount;
            const afterLiqPrice = await tradingCore.getLiquidationPrice(market, positionId);
            // console.log("After liquidation price", afterLiqPrice.toString());
            expect(afterLiqPrice).to.be.lt(beforeLiqPrice);
            expect(afterMarginAmount).to.equal(beforeMarginAmount + addAmount);
        });

        it("Should revert if adding margin to non-exist position", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, oracleSwapProcessor, market } = await deployContractsFixture();
            const addAmount = ethers.parseUnits("500", 6);

            await baseToken.connect(user).approve(tradingCore, addAmount);
            await expect(tradingCore.connect(user).addMargin(
                market,
                0,
                addAmount
            )).to.be.revertedWithCustomError(market, "ERC721NonexistentToken");
        });

        it("Should not be able to add zero amount to position", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, oracleSwapProcessor, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, 0);

            await baseToken.connect(user).approve(tradingCore, 0);
            await expect(tradingCore.connect(user).addMargin(
                market,
                positionId,
                0
            )).to.be.revertedWithCustomError(market, "ZeroNotAllowed");
        });

        it("Should be able to take profit correctly", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, oracleSwapProcessor, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const takeProfitPrice = 3250n * 10n ** 36n * 10n ** 6n / 10n ** 18n;
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, takeProfitPrice, 0);
            const positionInfo = await market.getPosition(positionId);
            const assetAmount = positionInfo.assetAmount;
            await assetOracle.setTokenPrice(targetToken, 3300n * 10n ** 36n * 10n ** 6n / 10n ** 18n);
            const takeProfitAmount = ethers.parseUnits("1", 18);
            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                targetToken.target,
                baseToken.target,
                takeProfitAmount,
                tradingCore.target,
                0n
            ]);

            expect(await tradingCore.connect(manager).takeProfit(
                market,
                positionId,
                assetAmount,
                0,
                ZERO_ADDRESS,
                oracleSwapRouter,
                swapCalldata
            )).to.be.emit(tradingCore, "TakeProfit");
        });
        
        it("Should be able to stop loss correctly", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, oracleSwapProcessor, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const stopLossPrice = 2850n * 10n ** 36n * 10n ** 6n / 10n ** 18n;
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, stopLossPrice);
            const positionInfo = await market.getPosition(positionId);
            const assetAmount = positionInfo.assetAmount;

            await assetOracle.setTokenPrice(targetToken, 2860n * 10n ** 36n * 10n ** 6n / 10n ** 18n);
            const stopLossAmount = ethers.parseUnits("1", 18);

            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                targetToken.target,
                baseToken.target,
                stopLossAmount,
                tradingCore.target,
                0n
            ]);

            await expect(tradingCore.connect(manager).stopLoss(
                market,
                positionId,
                assetAmount,
                0,
                ZERO_ADDRESS,
                oracleSwapRouter,
                swapCalldata
            )).to.be.revertedWithCustomError(market, "PassivelyCloseConditionNotMet");

            await assetOracle.setTokenPrice(targetToken, 2850n * 10n ** 36n * 10n ** 6n / 10n ** 18n);
            expect(await tradingCore.connect(manager).stopLoss(
                market,
                positionId,
                assetAmount,
                0,
                ZERO_ADDRESS,
                oracleSwapRouter,
                swapCalldata
            )).to.be.emit(tradingCore, "StopLoss");
        });

        it("Should liquidate long position correctly", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, oracleSwapProcessor, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, 0);

            const liqPrice = await tradingCore.getLiquidationPrice(market, positionId);
            
            await assetOracle.setTokenPrice(targetToken, liqPrice);
            const swappableAmount = await tradingCore.getClosePositionSwappableAfterFee(market, positionId, 3); // for normal close position
            // console.log("Swappable amount", swappableAmount.toString());
            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                targetToken.target,
                baseToken.target,
                swappableAmount,
                tradingCore.target,
                0n
            ]);

            expect(await tradingCore.connect(manager).liquidate(
                market,
                positionId,
                swappableAmount,
                0,
                ZERO_ADDRESS,
                oracleSwapRouter,
                swapCalldata
            )).to.be.emit(tradingCore, "Liquidate");
            
            const debtInfo = await tradingCore.debtOfPosition(market, positionId);
            expect(debtInfo[2]).to.equal(0);
        });
    });
});