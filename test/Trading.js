const { ethers, upgrades } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { before } = require("mocha");

const ZERO_ADDRESS = '0x' + '0'.repeat(40);
const UINT256_MAX = '0x' + 'f'.repeat(64);

const FEE_CAP = 300000;
const interestRateModelType = 2;
const reserveRatio = 50000;

describe("TeaRex Trading Core", function () {
    // 全域tokens - 部署一次，所有測試重用
    let globalTokens = null;
    
    before(async function () {
        console.log("🚀 部署全域tokens以確保穩定的地址順序...");
        globalTokens = await deployTokenFixture();
        console.log(`📍 Token地址順序: token0=${await globalTokens.token0.getAddress()}, token1=${await globalTokens.token1.getAddress()}`);
        console.log(`📍 BaseToken(6 decimals)=${await globalTokens.baseToken.getAddress()}, TargetToken(18 decimals)=${await globalTokens.targetToken.getAddress()}`);
    });

    async function getPermitSignature(user, token, spenderAddress, value, deadline) {
        const name = await token.name();
        const version = "1";  // Usually "1" for ERC2612
        const chainId = (await user.provider.getNetwork()).chainId;
        const verifyingContract = await token.getAddress();
        const nonce = await token.nonces(user.address);
        
        const domain = {
            name,
            version,
            chainId,
            verifyingContract
        };

        const types = {
            Permit: [
                { name: "owner", type: "address" },
                { name: "spender", type: "address" },
                { name: "value", type: "uint256" },
                { name: "nonce", type: "uint256" },
                { name: "deadline", type: "uint256" }
            ]
        };

        const currentDeadline = deadline === UINT256_MAX ? deadline : (deadline || Math.floor(Date.now() / 1000) + 3600);

        const message = {
            owner: user.address,
            spender: spenderAddress,
            value: value,
            nonce: nonce,
            deadline: currentDeadline
        };

        try {
            const signature = await user.signTypedData(
                domain,
                types,
                message
            );

            const sig = ethers.Signature.from(signature);

            return {
                v: sig.v,
                r: sig.r,
                s: sig.s
            };
        } catch (error) {
            console.error("Signing failed:", error);
            throw error;
        }
    }

    async function deployContractsFixture(options = {}) {
        const {
            maxToken0Leverage = 10 * 1e6,
            maxToken1Leverage = 10 * 1e6,
            openPositionLossRatioThreshold = 50000,  // 5%
            liquidateLossRatioThreshold = 500000,   // 50%
            liquidationDiscount = 20000,
            token0PositionSizeCap = null,  // 將根據實際token的decimals動態設置
            token1PositionSizeCap = null,  // 將根據實際token的decimals動態設置
            minToken0PositionSize = 0,
            minToken1PositionSize = 0,
            useGlobalTokens = true  // 新選項：是否使用全域tokens
        } = options;
        const [owner, feeTreasury, manager, user] = await ethers.getSigners();

        const feeConfig = {
            treasury: await feeTreasury.getAddress(),
            tradingFee: 1000,
            liquidationFee: 10000,
        }

        const Pool = await ethers.getContractFactory("Pool");
        const pool = await upgrades.deployBeacon(Pool);

        const Router = await ethers.getContractFactory("Router");
        const router = await upgrades.deployProxy(Router, [await owner.getAddress(), await pool.getAddress(), FEE_CAP]);

        const MarketNFT = await ethers.getContractFactory("MarketNFT");
        const marketNFT = await upgrades.deployBeacon(MarketNFT);

        const interestRateModel = await ethers.deployContract("VariableInterestRateModel", [
            await owner.getAddress(), 
            { baseRate: 10000, hikedRate: 240000 }
        ]);
        const swapRelayer = await ethers.deployContract("SwapRelayer", [await owner.getAddress()]);

        const TradingCore = await ethers.getContractFactory("TradingCore");
        const tradingCore = await upgrades.deployProxy(
            TradingCore, 
            [
                await owner.getAddress(),
                await marketNFT.getAddress(),
                await router.getAddress(),
                await swapRelayer.getAddress(),
                "200000",
                {
                    treasury: feeConfig.treasury,
                    tradingFee: feeConfig.tradingFee,
                    liquidationFee: feeConfig.liquidationFee
                },
                ZERO_ADDRESS
            ]);

        await swapRelayer.setTradingCore(await tradingCore.getAddress());
        
        // 使用全域tokens或重新部署
        let baseToken, targetToken, token0, token1;
        if (useGlobalTokens && globalTokens) {
            ({ baseToken, targetToken, token0, token1 } = globalTokens);
        } else {
            ({ baseToken, targetToken, token0, token1 } = await deployTokenFixture());
        }
        
        // 確保user有足夠的tokens給每個測試
        const userBaseBalance = await baseToken.balanceOf(await user.getAddress());
        const userTargetBalance = await targetToken.balanceOf(await user.getAddress());
        
        // 如果餘額不足，補充到足夠的數量
        const minBaseRequired = ethers.parseUnits("50000", 6);
        const minTargetRequired = ethers.parseUnits("50000", 18);
        
        if (userBaseBalance < minBaseRequired) {
            await baseToken.transfer(user, minBaseRequired - userBaseBalance);
        }
        if (userTargetBalance < minTargetRequired) {
            await targetToken.transfer(user, minTargetRequired - userTargetBalance);
        }
        
        const assetOracle = await ethers.deployContract("MockOracle", [await owner.getAddress(), 36, await baseToken.getAddress()]);
        const oracleSwapRouter = await ethers.deployContract("OracleSwap", [await owner.getAddress(), 1]); // set price spread default as 1%
        const oracleSwapProcessor = await ethers.deployContract("OracleSwapProcessor", []);

        const borrow_fee = 20000;
        const withdraw_fee = 1000;
        await router.setInterestRateModel(interestRateModelType, await interestRateModel.getAddress());
        await router.setTradingCore(await tradingCore.getAddress());
        await router.setDefaultFeeConfig(await feeTreasury.getAddress(), borrow_fee, withdraw_fee);
        await router.setWhitelistedOperator([manager, owner], [true, true]);
        await tradingCore.setWhitelistedOperator([manager, owner], [true, true]);
        await swapRelayer.setCheckWhitelist(true);
        await swapRelayer.setWhitelist([await oracleSwapRouter.getAddress()], [true]);
        
        await router.createLendingPool(
            await baseToken.getAddress(),
            interestRateModelType,
            ethers.parseUnits("10000000", 6),
            ethers.parseUnits("5000000", 6),
            reserveRatio   // 5%
        )

        await router.createLendingPool(
            await targetToken.getAddress(),
            interestRateModelType,
            ethers.parseUnits("10000000", 18),
            ethers.parseUnits("5000000", 18),
            reserveRatio   // 5%
        )

        const basePool = await router.getLendingPool(await baseToken.getAddress(), interestRateModelType);
        const targetPool = await router.getLendingPool(await targetToken.getAddress(), interestRateModelType);

        const baseSupplyAmount = ethers.parseUnits("1000000", 6);
        const targetSupplyAmount = ethers.parseUnits("1000000", 18)

        await baseToken.approve(basePool, baseSupplyAmount);
        await targetToken.approve(targetPool, targetSupplyAmount);

        await router.supply(
            await baseToken.getAddress(),
            interestRateModelType,
            await owner.getAddress(),
            baseSupplyAmount
        )

        await router.supply(
            await targetToken.getAddress(),
            interestRateModelType,
            await owner.getAddress(),
            targetSupplyAmount
        )

        // set up oracle
        await assetOracle.setTokenPrice(await baseToken.getAddress(), 10n ** 36n);
        const targetPrice = 3000n;
        await assetOracle.setTokenPrice(await targetToken.getAddress(), targetPrice * 10n ** 36n * 10n ** 6n / 10n ** 18n);
        // console.log("Oracle set up");

        await oracleSwapRouter.setToken(await baseToken.getAddress(), assetOracle);
        await oracleSwapRouter.setToken(await targetToken.getAddress(), assetOracle);
        await baseToken.transfer(await oracleSwapRouter.getAddress(), ethers.parseUnits("10000000", 6));
        await targetToken.transfer(await oracleSwapRouter.getAddress(), ethers.parseUnits("10000000", 18));
        
        // Determine which token is the margin token (6 decimals token should be margin)
        const token0Decimals = await token0.decimals();
        const token1Decimals = await token1.decimals();
        const isToken0Margin = Number(token0Decimals) === 6;  // 6 decimals = USDC-like token
        
        // Set position size caps based on actual token decimals if not provided
        const finalToken0PositionSizeCap = token0PositionSizeCap || 
            (token0Decimals === 6 ? ethers.parseUnits("1000000", 6) : ethers.parseUnits("100000", 18));
        const finalToken1PositionSizeCap = token1PositionSizeCap || 
            (token1Decimals === 6 ? ethers.parseUnits("1000000", 6) : ethers.parseUnits("100000", 18));
        
        // v2 createMarket with 20 parameters - token0 and token1 are already ordered correctly
        await tradingCore.createMarket(
            await assetOracle.getAddress(),
            await token0.getAddress(),
            await token1.getAddress(),
            false,  // onlyAllowedToken0LendingTypes
            false,  // onlyAllowedToken1LendingTypes
            isToken0Margin,  // isToken0Margin
            maxToken0Leverage,
            maxToken1Leverage,
            openPositionLossRatioThreshold,
            liquidateLossRatioThreshold,
            liquidationDiscount,
            finalToken0PositionSizeCap,  // token0PositionSizeCap
            finalToken1PositionSizeCap,  // token1PositionSizeCap
            minToken0PositionSize,  // minToken0PositionSize
            minToken1PositionSize,  // minToken1PositionSize
            [interestRateModelType],  // token0LendingTypes
            [interestRateModelType],  // token1LendingTypes
            [true],                   // isToken0LendingTypesAllowed
            [true]                    // isToken1LendingTypesAllowed
        );
        // console.log("Market created");

        const marketAddress = await tradingCore.pairMarket(await token0.getAddress(), await token1.getAddress());
        const market = await ethers.getContractAt("MarketNFT", marketAddress);
        
        return { 
            baseToken, targetToken, token0, token1, isToken0Margin, 
            token0Decimals, token1Decimals, 
            finalToken0PositionSizeCap, finalToken1PositionSizeCap,
            owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, oracleSwapProcessor, market 
        };
    }

    async function deployTokenFixture() {
        const [owner] = await ethers.getSigners();
        const MockToken = await ethers.getContractFactory("MockToken");
        
        // Deploy two tokens with different characteristics - 增加初始發行量以支持所有測試
        const tokenA = await MockToken.deploy(await owner.getAddress(), "TokenA", "TKA", ethers.parseUnits("10000000000", 6), 6);   // 6 decimals (USDC-like) - 100億
        const tokenB = await MockToken.deploy(await owner.getAddress(), "TokenB", "TKB", ethers.parseUnits("10000000000", 18), 18); // 18 decimals (ETH-like) - 100億
        
        // Determine token0/token1 order based on addresses (token0 < token1)
        const addrA = await tokenA.getAddress();
        const addrB = await tokenB.getAddress();
        const token0 = addrA < addrB ? tokenA : tokenB;
        const token1 = addrA < addrB ? tokenB : tokenA;
        
        // For backward compatibility, assign baseToken and targetToken
        // baseToken = 6 decimals token, targetToken = 18 decimals token
        const baseToken = tokenA;   // Always 6 decimals
        const targetToken = tokenB; // Always 18 decimals
    
        return { baseToken, targetToken, token0, token1 };
    }
    
    async function openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, takeProfitPrice, stopLossPrice, stopLossRateTolerance) {
        const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(await market.getAddress(), await user.getAddress(), false, borrowAmount));
        const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
            await baseToken.getAddress(),
            await targetToken.getAddress(),
            receivedAmount,
            await tradingCore.getAddress(),
            0n
        ]);
        await baseToken.connect(user).approve(tradingCore, UINT256_MAX);
        await tradingCore.connect(user).openPosition(
            await market.getAddress(),
            interestRateModelType,
            await targetToken.getAddress(),  // longTarget is targetToken for long position
            marginAmount,
            borrowAmount,
            0,
            takeProfitPrice,
            stopLossPrice,
            stopLossRateTolerance,
            await oracleSwapRouter.getAddress(),
            swapCalldata
        )

        const events = await tradingCore.queryFilter("OpenPosition");
        const lastEvent = events[events.length - 1];
        const positionId = lastEvent.args[1];

        return { positionId };
    }
    
    async function openShortPosition( baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, takeProfitPrice, stopLossPrice) {
        const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(await market.getAddress(), await user.getAddress(), false, borrowAmount));
        const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
            await targetToken.getAddress(),
            await baseToken.getAddress(),
            receivedAmount,
            await tradingCore.getAddress(),
            0n
        ]);
        
        await baseToken.connect(user).approve(tradingCore, UINT256_MAX);
        await tradingCore.connect(user).openPosition(
            await market.getAddress(),
            interestRateModelType,
            await baseToken.getAddress(),
            marginAmount,
            borrowAmount,
            0,
            takeProfitPrice,
            stopLossPrice,
            0,
            await oracleSwapRouter.getAddress(),
            swapCalldata
        )

        const events = await tradingCore.queryFilter("OpenPosition");
        const lastEvent = events[events.length - 1];
        const positionId = lastEvent.args[1];

        return { positionId}; 
    }

    describe("Functionality", function () {
        it("Should not be able to open position when market is paused", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, market } = await deployContractsFixture();
            
            await market.connect(owner).pause();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = marginAmount * 5n;
            const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(await market.getAddress(), await user.getAddress(), false, borrowAmount));
            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                await baseToken.getAddress(),
                await targetToken.getAddress(),
                receivedAmount,
                await tradingCore.getAddress(),
                0n
            ]);

            await baseToken.connect(user).approve(tradingCore, UINT256_MAX);
            await expect(tradingCore.connect(user).openPosition(
                await market.getAddress(),
                interestRateModelType,
                await targetToken.getAddress(),
                marginAmount,
                borrowAmount,
                0,
                UINT256_MAX,
                0,
                0,
                await oracleSwapRouter.getAddress(),
                swapCalldata
            )).to.be.reverted;    
        });

        it("Should open long position correctly", async function () {
            const { baseToken, targetToken, token0, token1, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = marginAmount * 5n;
            const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(await market.getAddress(), await user.getAddress(), false, borrowAmount));
            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                await baseToken.getAddress(),
                await targetToken.getAddress(),
                receivedAmount,
                await tradingCore.getAddress(),
                0n
            ]);

            const beforeBaseBalance = await baseToken.balanceOf(await user.getAddress());
            await baseToken.connect(user).approve(tradingCore, UINT256_MAX);
            await targetToken.connect(user).approve(tradingCore, UINT256_MAX);
            await tradingCore.connect(user).openPosition(
                await market.getAddress(),
                interestRateModelType,
                await targetToken.getAddress(),
                marginAmount,
                borrowAmount,
                0,
                UINT256_MAX,
                0,
                0,
                await oracleSwapRouter.getAddress(),
                swapCalldata
            )
            const afterBaseBalance = await baseToken.balanceOf(await user.getAddress());
            expect(beforeBaseBalance - afterBaseBalance).to.equal(marginAmount);

            const positionId = await market.tokenOfOwnerByIndex(user, 0);
            const positionInfo = await market.getPosition(positionId);
            const debtInfo = await tradingCore.debtOfPosition(await market.getAddress(), positionId);

            expect(positionInfo.marginAmount).to.equal(marginAmount);
            expect(debtInfo[2]).to.equal(borrowAmount.toString());
        });

        it("Should open short position correctly", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, market } = await deployContractsFixture();

            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("2", 18);
            const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(await market.getAddress(), await user.getAddress(), false, borrowAmount));
            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                await targetToken.getAddress(),
                await baseToken.getAddress(),
                receivedAmount,
                await tradingCore.getAddress(),
                0n
            ]);

            const beforeTargetBalance = await baseToken.balanceOf(await user.getAddress());
            await baseToken.connect(user).approve(tradingCore, UINT256_MAX);
            await tradingCore.connect(user).openPosition(
                await market.getAddress(),
                interestRateModelType,
                await baseToken.getAddress(),
                marginAmount,
                borrowAmount,
                0,
                UINT256_MAX,
                0,
                0,
                await oracleSwapRouter.getAddress(),
                swapCalldata
            )
            const afterTargetBalance = await baseToken.balanceOf(await user.getAddress());
            expect(beforeTargetBalance - afterTargetBalance).to.equal(marginAmount);

            const positionId = await market.tokenOfOwnerByIndex(user, 0);            
            const debtInfo = await tradingCore.debtOfPosition(await market.getAddress(), positionId);
            const positionInfo = await market.getPosition(positionId);

            expect(positionInfo.marginAmount).to.equal(marginAmount);
            expect(debtInfo[2]).to.equal(borrowAmount.toString());
        });

        it("Should be able to open long position with permit", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, market } = await deployContractsFixture();
            
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = marginAmount * 5n;
            const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(await market.getAddress(), await user.getAddress(), false, borrowAmount));
            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                await baseToken.getAddress(),
                await targetToken.getAddress(),
                receivedAmount,
                await tradingCore.getAddress(),
                0n
            ]);

            const beforeBaseBalance = await baseToken.balanceOf(await user.getAddress());
            const deadline = UINT256_MAX;
            const { v, r, s } = await getPermitSignature(
                user,
                baseToken,
                await tradingCore.getAddress(),
                marginAmount,
                deadline
              )

            await tradingCore.connect(user).openPositionPermit(
                await market.getAddress(),
                interestRateModelType,
                await targetToken.getAddress(),
                marginAmount,
                borrowAmount,
                0,
                UINT256_MAX,
                0,
                0,
                await oracleSwapRouter.getAddress(),
                swapCalldata,
                deadline,
                v,r,s
            )
            const afterBaseBalance = await baseToken.balanceOf(await user.getAddress());
            expect(beforeBaseBalance - afterBaseBalance).to.equal(marginAmount);

            const positionId = await market.tokenOfOwnerByIndex(user, 0);
            const positionInfo = await market.getPosition(positionId);
            const debtInfo = await tradingCore.debtOfPosition(await market.getAddress(), positionId);

            expect(positionInfo.marginAmount).to.equal(marginAmount);
            expect(debtInfo[2]).to.equal(borrowAmount.toString());
        });

        it("Should be able to open short position with permit", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, market } = await deployContractsFixture();

            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("2", 18);
            const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(await market.getAddress(), await user.getAddress(), false, borrowAmount));
            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                await targetToken.getAddress(),
                await baseToken.getAddress(),
                receivedAmount,
                await tradingCore.getAddress(),
                0n
            ]);

            const beforeTargetBalance = await baseToken.balanceOf(await user.getAddress());
            const deadline = UINT256_MAX;
            const { v, r, s } = await getPermitSignature(
                user,
                baseToken,
                await tradingCore.getAddress(),
                marginAmount,
                deadline
              );

            await tradingCore.connect(user).openPositionPermit(
                await market.getAddress(),
                interestRateModelType,
                await baseToken.getAddress(),
                marginAmount,
                borrowAmount,
                0,
                UINT256_MAX,
                0,
                0,
                await oracleSwapRouter.getAddress(),
                swapCalldata,
                deadline,
                v,r,s
            )
            const afterTargetBalance = await baseToken.balanceOf(await user.getAddress());
            expect(beforeTargetBalance - afterTargetBalance).to.equal(marginAmount);

            const positionId = await market.tokenOfOwnerByIndex(user, 0);            
            const debtInfo = await tradingCore.debtOfPosition(await market.getAddress(), positionId);
            const positionInfo = await market.getPosition(positionId);

            expect(positionInfo.marginAmount).to.equal(marginAmount);
            expect(debtInfo[2]).to.equal(borrowAmount.toString());
        });

        it("Should revert if open position exceed leverage limit", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, market } = await deployContractsFixture();

            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = marginAmount * 15n;
            const receivedAmount = borrowAmount - (await tradingCore.calculateTradingFee(await market.getAddress(), await user.getAddress(), false, borrowAmount));
            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                await baseToken.getAddress(),
                await targetToken.getAddress(),
                receivedAmount,
                await tradingCore.getAddress(),
                0n
            ]);

            await baseToken.connect(user).approve(tradingCore, UINT256_MAX);
            await expect(tradingCore.connect(user).openPosition(
                await market.getAddress(),
                interestRateModelType,
                await targetToken.getAddress(),
                marginAmount,
                borrowAmount,
                0,
                UINT256_MAX,
                0,
                0,
                await oracleSwapRouter.getAddress(),
                swapCalldata
            )).to.be.revertedWithCustomError(market, "InvalidLeverage");
        });

        it("Should be able to close long position correctly", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, 0, 0);
            await time.increase(86400);

            const positionInfo = await market.getPosition(positionId);
            const assetAmount = positionInfo.assetAmount;
            const swappableAmount = await tradingCore.getClosePositionSwappableAfterFee(await market.getAddress(), positionId, 0); // for normal close position
            // console.log("Swappable amount", swappableAmount.toString());

            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                await targetToken.getAddress(),
                await baseToken.getAddress(),
                swappableAmount,
                await tradingCore.getAddress(),
                0n
            ]);

            await tradingCore.connect(user).closePosition(
                await market.getAddress(),
                positionId,
                assetAmount,
                0,
                ZERO_ADDRESS,
                await oracleSwapRouter.getAddress(),
                swapCalldata
            );
            
            const debtInfo = await tradingCore.debtOfPosition(await market.getAddress(), positionId);
            expect(debtInfo[2]).to.equal(0);
        });

        it("Should be able to close long position which has unrealized pnl loss", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, 0, 0);
            
            await time.increase(86400);
            await assetOracle.setTokenPrice(await targetToken.getAddress(), 2700n * 10n ** 36n * 10n ** 6n / 10n ** 18n);

            const positionInfo = await market.getPosition(positionId);
            const assetAmount = positionInfo.assetAmount;
            // console.log("Position info", positionInfo);
            const swappableAmount = await tradingCore.getClosePositionSwappableAfterFee(await market.getAddress(), positionId, 0); // for normal close position
            // console.log("Swappable amount", swappableAmount.toString());

            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                await targetToken.getAddress(),
                await baseToken.getAddress(),
                swappableAmount,
                await tradingCore.getAddress(),
                0n
            ]);

            await tradingCore.connect(user).closePosition(
                await market.getAddress(),
                positionId,
                assetAmount,
                0,
                ZERO_ADDRESS,
                await oracleSwapRouter.getAddress(),
                swapCalldata
            );
            
            const debtInfo = await tradingCore.debtOfPosition(await market.getAddress(), positionId);
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
            const debt = await tradingCore.debtOfPosition(await market.getAddress(), positionId);
            const debtAmount = debt.debtAmount;
            // console.log("Debt amount", debtAmount.toString());
            
            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactOutput", [
                await baseToken.getAddress(),
                await targetToken.getAddress(),
                debtAmount,
                await tradingCore.getAddress(),
                UINT256_MAX
            ]);

            const assets = assetAmount + positionInfo.marginAmount;
            await tradingCore.connect(user).closePosition(
                await market.getAddress(),
                positionId,
                assets,
                0,
                oracleSwapProcessor,
                await oracleSwapRouter.getAddress(),
                swapCalldata
            );
            
            const debtInfo = await tradingCore.debtOfPosition(await market.getAddress(), positionId);
            // const afterBaseBalance = await baseToken.balanceOf(user.address);
            expect(debtInfo[2]).to.equal(0);
        });

        it("Should be able to close short position which has unrealized pnl loss", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, oracleSwapProcessor, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("2", 18);
            const { positionId } = await openShortPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, 0);
        
            await time.increase(86400);
            await assetOracle.setTokenPrice(await targetToken.getAddress(), 2700n * 10n ** 36n * 10n ** 6n / 10n ** 18n);

            const positionInfo = await market.getPosition(positionId);
            const assetAmount = positionInfo.assetAmount;
            // console.log("Position info", positionInfo);
            const debt = await tradingCore.debtOfPosition(await market.getAddress(), positionId);
            const debtAmount = debt.debtAmount;
            // console.log("Debt amount", debtAmount.toString());
            
            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactOutput", [
                await baseToken.getAddress(),
                await targetToken.getAddress(),
                debtAmount,
                await tradingCore.getAddress(),
                UINT256_MAX
            ]);

            const assets = assetAmount + positionInfo.marginAmount;
            await tradingCore.connect(user).closePosition(
                await market.getAddress(),
                positionId,
                assets,
                0,
                oracleSwapProcessor,
                await oracleSwapRouter.getAddress(),
                swapCalldata
            );
            
            const debtInfo = await tradingCore.debtOfPosition(await market.getAddress(), positionId);
            // const afterBaseBalance = await baseToken.balanceOf(user.address);
            expect(debtInfo[2]).to.equal(0);
        });

        it("Should not be able to call closePosition if margin amount is less than zero", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, 0, 0);
            await time.increase(86400);
            await assetOracle.setTokenPrice(await targetToken.getAddress(), 2500n * 10n ** 36n * 10n ** 6n / 10n ** 18n);

            const positionInfo = await market.getPosition(positionId);
            const assetAmount = positionInfo.assetAmount;
            const swappableAmount = await tradingCore.getClosePositionSwappableAfterFee(await market.getAddress(), positionId, 0); // for normal close position

            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                await targetToken.getAddress(),
                await baseToken.getAddress(),
                swappableAmount,
                await tradingCore.getAddress(),
                0n
            ]);

            await expect(tradingCore.connect(user).closePosition(
                await market.getAddress(),
                positionId,
                assetAmount,
                0,
                ZERO_ADDRESS,
                await oracleSwapRouter.getAddress(),
                swapCalldata
            )).to.be.reverted;
        });

        it("Should add margin correctly", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, oracleSwapProcessor, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, 0, 0);
            const positionInfo = await market.getPosition(positionId);
            const beforeMarginAmount = positionInfo.marginAmount;
            const beforeLiqPrice = await tradingCore.getLiquidationPrice(await market.getAddress(), positionId);
            // console.log("Before liquidation price", beforeLiqPrice.toString());
            const addAmount = ethers.parseUnits("500", 6);

            await baseToken.connect(user).approve(tradingCore, UINT256_MAX);
            await expect(tradingCore.connect(user).addMargin(
                await market.getAddress(),
                positionId,
                addAmount
            )).to.changeTokenBalances(baseToken, [user, tradingCore], [-addAmount, addAmount]);

            const afterMarginAmount = (await market.getPosition(positionId)).marginAmount;
            const afterLiqPrice = await tradingCore.getLiquidationPrice(await market.getAddress(), positionId);
            // console.log("After liquidation price", afterLiqPrice.toString());
            expect(afterLiqPrice).to.be.lt(beforeLiqPrice);
            expect(afterMarginAmount).to.equal(beforeMarginAmount + addAmount);
        });

        it("Should be able to add margin with permit", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, oracleSwapProcessor, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, 0, 0);
            const positionInfo = await market.getPosition(positionId);
            const beforeMarginAmount = positionInfo.marginAmount;
            const beforeLiqPrice = await tradingCore.getLiquidationPrice(await market.getAddress(), positionId);
            // console.log("Before liquidation price", beforeLiqPrice.toString());
            const addAmount = ethers.parseUnits("500", 6);
            
            const deadline = UINT256_MAX;
            const { v, r, s } = await getPermitSignature(
                user,
                baseToken,
                await tradingCore.getAddress(),
                addAmount,
                deadline
              );

            await expect(tradingCore.connect(user).addMarginPermit(
                await market.getAddress(),
                positionId,
                addAmount,
                deadline,
                v,r,s                
            )).to.changeTokenBalances(baseToken, [user, tradingCore], [-addAmount, addAmount]);

            const afterMarginAmount = (await market.getPosition(positionId)).marginAmount;
            const afterLiqPrice = await tradingCore.getLiquidationPrice(await market.getAddress(), positionId);
            // console.log("After liquidation price", afterLiqPrice.toString());
            expect(afterLiqPrice).to.be.lt(beforeLiqPrice);
            expect(afterMarginAmount).to.equal(beforeMarginAmount + addAmount);
        });

        it("Should revert if adding margin to non-exist position", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, oracleSwapProcessor, market } = await deployContractsFixture();
            const addAmount = ethers.parseUnits("500", 6);

            await baseToken.connect(user).approve(tradingCore, UINT256_MAX);
            await expect(tradingCore.connect(user).addMargin(
                await market.getAddress(),
                0,
                addAmount
            )).to.be.revertedWithCustomError(market, "ERC721NonexistentToken");
        });

        it("Should not be able to add zero amount to position", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, oracleSwapProcessor, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, 0, 0);

            await baseToken.connect(user).approve(tradingCore, 0);
            await expect(tradingCore.connect(user).addMargin(
                await market.getAddress(),
                positionId,
                0
            )).to.be.revertedWithCustomError(market, "ZeroNotAllowed");
        });

        it("Should be able to take profit correctly", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, oracleSwapProcessor, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const takeProfitPrice = 3250n * 10n ** 36n * 10n ** 6n / 10n ** 18n;
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, takeProfitPrice, 0, 0);
            const positionInfo = await market.getPosition(positionId);
            const assetAmount = positionInfo.assetAmount;
            await assetOracle.setTokenPrice(await targetToken.getAddress(), 3300n * 10n ** 36n * 10n ** 6n / 10n ** 18n);
            const takeProfitAmount = ethers.parseUnits("1", 18);
            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                await targetToken.getAddress(),
                await baseToken.getAddress(),
                takeProfitAmount,
                await tradingCore.getAddress(),
                0n
            ]);

            expect(await tradingCore.connect(manager).takeProfit(
                await market.getAddress(),
                positionId,
                assetAmount,
                0,
                ZERO_ADDRESS,
                await oracleSwapRouter.getAddress(),
                swapCalldata
            )).to.be.emit(tradingCore, "TakeProfit");
        });
        
        it("Should be able to stop loss correctly", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, oracleSwapProcessor, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const stopLossPrice = 2850n * 10n ** 36n * 10n ** 6n / 10n ** 18n;
            const stopLossRateTolerance = 10000;
            
            console.log("🔍 Stop Loss Test Debug:");
            console.log("  openPositionLossRatioThreshold:", await market.openPositionLossRatioThreshold());
            console.log("  liquidateLossRatioThreshold:", await market.liquidateLossRatioThreshold());
            console.log("  marginAmount:", marginAmount.toString());
            console.log("  borrowAmount:", borrowAmount.toString());
            console.log("  stopLossPrice:", stopLossPrice.toString());
            
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, stopLossPrice, stopLossRateTolerance);
            const positionInfo = await market.getPosition(positionId);
            const assetAmount = positionInfo.assetAmount;

            await assetOracle.setTokenPrice(await targetToken.getAddress(), 2860n * 10n ** 36n * 10n ** 6n / 10n ** 18n);
            const stopLossAmount = ethers.parseUnits("1", 18);

            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                await targetToken.getAddress(),
                await baseToken.getAddress(),
                stopLossAmount,
                await tradingCore.getAddress(),
                0n
            ]);

            await expect(tradingCore.connect(manager).stopLoss(
                await market.getAddress(),
                positionId,
                assetAmount,
                0,
                ZERO_ADDRESS,
                await oracleSwapRouter.getAddress(),
                swapCalldata
            )).to.be.revertedWithCustomError(market, "PassivelyCloseConditionNotMet");

            await assetOracle.setTokenPrice(await targetToken.getAddress(), 2850n * 10n ** 36n * 10n ** 6n / 10n ** 18n);
            
            // Debug: 檢查執行stopLoss前的狀態
            const positionInfoBefore = await market.getPosition(positionId);
            const debtInfo = await tradingCore.debtOfPosition(await market.getAddress(), positionId);
            const prices = await market.getTokenPrices();
            
            console.log("  Before stopLoss:");
            console.log("    positionInfo.marginAmount:", positionInfoBefore.marginAmount.toString());
            console.log("    positionInfo.assetAmount:", positionInfoBefore.assetAmount.toString());
            console.log("    debtAmount:", debtInfo[2].toString());
            console.log("    oracle decimals:", prices[0]);
            console.log("    token0 price:", prices[1].toString());
            console.log("    token1 price:", prices[2].toString());
            console.log("    isLongToken0:", positionInfoBefore.isLongToken0);
            console.log("    isToken0Margin:", await market.isToken0Margin());
            
            expect(await tradingCore.connect(manager).stopLoss(
                await market.getAddress(),
                positionId,
                assetAmount,
                0,
                ZERO_ADDRESS,
                await oracleSwapRouter.getAddress(),
                swapCalldata
            )).to.be.emit(tradingCore, "StopLoss");
        });

        it("Should not be able to stop loss if loss more than rate tolerance", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, oracleSwapProcessor, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const stopLossPrice = 2850n * 10n ** 36n * 10n ** 6n / 10n ** 18n;
            const stopLossRateTolerance = 0;
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, stopLossPrice, stopLossRateTolerance);
            const positionInfo = await market.getPosition(positionId);
            const assetAmount = positionInfo.assetAmount;

            await assetOracle.setTokenPrice(await targetToken.getAddress(), 2860n * 10n ** 36n * 10n ** 6n / 10n ** 18n);
            const stopLossAmount = ethers.parseUnits("1", 18);

            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                await targetToken.getAddress(),
                await baseToken.getAddress(),
                stopLossAmount,
                await tradingCore.getAddress(),
                0n
            ]);

            await expect(tradingCore.connect(manager).stopLoss(
                await market.getAddress(),
                positionId,
                assetAmount,
                0,
                ZERO_ADDRESS,
                await oracleSwapRouter.getAddress(),
                swapCalldata
            )).to.be.revertedWithCustomError(market, "PassivelyCloseConditionNotMet");

            await assetOracle.setTokenPrice(await targetToken.getAddress(), 2850n * 10n ** 36n * 10n ** 6n / 10n ** 18n);
            await expect(tradingCore.connect(manager).stopLoss(
                await market.getAddress(),
                positionId,
                assetAmount,
                0,
                ZERO_ADDRESS,
                await oracleSwapRouter.getAddress(),
                swapCalldata
            )).to.be.revertedWithCustomError(market, "WorsePrice");
        });

        it("Should liquidate long position correctly", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, oracleSwapProcessor, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, 0, 0);

            const liqPrice = await tradingCore.getLiquidationPrice(await market.getAddress(), positionId);
            
            await assetOracle.setTokenPrice(await targetToken.getAddress(), liqPrice);
            const swappableAmount = await tradingCore.getClosePositionSwappableAfterFee(await market.getAddress(), positionId, 3); // for normal close position
            // console.log("Swappable amount", swappableAmount.toString());
            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                await targetToken.getAddress(),
                await baseToken.getAddress(),
                swappableAmount,
                await tradingCore.getAddress(),
                0n
            ]);

            expect(await tradingCore.connect(manager).liquidate(
                await market.getAddress(),
                positionId,
                swappableAmount,
                0,
                ZERO_ADDRESS,
                await oracleSwapRouter.getAddress(),
                swapCalldata
            )).to.be.emit(tradingCore, "Liquidate");
            
            const debtInfo = await tradingCore.debtOfPosition(await market.getAddress(), positionId);
            expect(debtInfo[2]).to.equal(0);
        });

        it("Should be able to adjust passive close price", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, 0, 0);

            const newTakeProfitPrice = 3500n * 10n ** 36n * 10n ** 6n / 10n ** 18n;
            const newStopLossPrice = 2800n * 10n ** 36n * 10n ** 6n / 10n ** 18n;
            const stopLossRateTolerance = 5000; // 0.5%

            expect(await tradingCore.connect(user).adjustPassiveClosePrice(
                await market.getAddress(),
                positionId,
                newTakeProfitPrice,
                newStopLossPrice,
                stopLossRateTolerance
            )).to.emit(tradingCore, "AdjustPassiveClosePrice");

            const positionInfo = await market.getPosition(positionId);
            expect(positionInfo.takeProfit).to.equal(newTakeProfitPrice);
            expect(positionInfo.stopLoss).to.equal(newStopLossPrice);
            expect(positionInfo.stopLossRateTolerance).to.equal(stopLossRateTolerance);
        });

        it("Should not be able to adjust passive close price if not position owner", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, 0, 0);

            const newTakeProfitPrice = 3500n * 10n ** 36n * 10n ** 6n / 10n ** 18n;
            const newStopLossPrice = 2800n * 10n ** 36n * 10n ** 6n / 10n ** 18n;
            const stopLossRateTolerance = 5000;

            await expect(tradingCore.connect(manager).adjustPassiveClosePrice(
                await market.getAddress(),
                positionId,
                newTakeProfitPrice,
                newStopLossPrice,
                stopLossRateTolerance
            )).to.be.revertedWithCustomError(tradingCore, "NotPositionOwner");
        });

        it("Should be able to test manager close functionality", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, 0, 0);

            // Set manager as position manager
            await tradingCore.setPositionManager([manager], [true]);

            const positionInfo = await market.getPosition(positionId);
            const assetAmount = positionInfo.assetAmount;
            const swappableAmount = await tradingCore.getClosePositionSwappableAfterFee(await market.getAddress(), positionId, 4); // for manager close

            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                await targetToken.getAddress(),
                await baseToken.getAddress(),
                swappableAmount,
                await tradingCore.getAddress(),
                0n
            ]);

            expect(await tradingCore.connect(manager).managerClose(
                await market.getAddress(),
                positionId,
                assetAmount,
                0,
                ZERO_ADDRESS,
                await oracleSwapRouter.getAddress(),
                swapCalldata
            )).to.emit(tradingCore, "AdjustPosition");

            const debtInfo = await tradingCore.debtOfPosition(await market.getAddress(), positionId);
            expect(debtInfo[2]).to.equal(0);
        });

        it("Should not be able to manager close if not position manager", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, market } = await deployContractsFixture();
            const marginAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("6000", 6);
            const { positionId } = await openLongPosition(baseToken, targetToken, user, tradingCore, oracleSwapRouter, market, marginAmount, borrowAmount, UINT256_MAX, 0, 0);

            const positionInfo = await market.getPosition(positionId);
            const assetAmount = positionInfo.assetAmount;
            const swappableAmount = await tradingCore.getClosePositionSwappableAfterFee(await market.getAddress(), positionId, 4);

            const swapCalldata = oracleSwapRouter.interface.encodeFunctionData("swapExactInput", [
                await targetToken.getAddress(),
                await baseToken.getAddress(),
                swappableAmount,
                await tradingCore.getAddress(),
                0n
            ]);

            await expect(tradingCore.connect(user).managerClose(
                await market.getAddress(),
                positionId,
                assetAmount,
                0,
                ZERO_ADDRESS,
                await oracleSwapRouter.getAddress(),
                swapCalldata
            )).to.be.revertedWithCustomError(tradingCore, "NotPositionManager");
        });
    });

    describe("V2 New Features", function () {
        it("Should be able to create market with lending type restrictions", async function () {
            const { baseToken, targetToken, owner, manager, feeTreasury, user, tradingCore, interestRateModel, router, swapRelayer, assetOracle, oracleSwapRouter, market } = await deployContractsFixture();
            const reserveRatio = 50000; // 5%
            
            // Create a new market with lending type restrictions
            const newTargetToken = await ethers.deployContract("MockToken", [await owner.getAddress(), "NewToken", "NEW", ethers.parseUnits("100000000", 18), 18]);
            
            // Enable the new token in oracle by setting its price
            await assetOracle.setTokenPrice(await newTargetToken.getAddress(), 2000n * 10n ** 36n * 10n ** 6n / 10n ** 18n); // 2000 USD price
            
            // Create lending pool for the new token to enable it
            await router.createLendingPool(
                await newTargetToken.getAddress(),
                interestRateModelType,
                ethers.parseUnits("10000000", 18),
                ethers.parseUnits("5000000", 18),
                reserveRatio
            );
            
            // Determine token order for the new market
            const baseAddr = await baseToken.getAddress();
            const newTargetAddr = await newTargetToken.getAddress();
            const token0 = baseAddr < newTargetAddr ? baseToken : newTargetToken;
            const token1 = baseAddr < newTargetAddr ? newTargetToken : baseToken;
            
            // Get actual decimals for proper position size caps
            const token0Decimals = await token0.decimals();
            const token1Decimals = await token1.decimals();
            const newToken0PositionSizeCap = token0Decimals === 6 ? ethers.parseUnits("1000000", 6) : ethers.parseUnits("100000", 18);
            const newToken1PositionSizeCap = token1Decimals === 6 ? ethers.parseUnits("1000000", 6) : ethers.parseUnits("100000", 18);

            await tradingCore.createMarket(
                await assetOracle.getAddress(),
                await token0.getAddress(),
                await token1.getAddress(),
                true,   // onlyAllowedToken0LendingTypes
                true,   // onlyAllowedToken1LendingTypes
                token0Decimals === 6,   // isToken0Margin - based on actual decimals
                10 * 1e6,  // maxToken0Leverage
                10 * 1e6,  // maxToken1Leverage
                50000,     // openPositionLossRatioThreshold
                500000,    // liquidateLossRatioThreshold
                20000,     // liquidationDiscount
                newToken0PositionSizeCap,  // token0PositionSizeCap
                newToken1PositionSizeCap,  // token1PositionSizeCap
                0,  // minToken0PositionSize
                0,  // minToken1PositionSize
                [interestRateModelType],          // token0LendingTypes
                [interestRateModelType],          // token1LendingTypes
                [true],                           // isToken0LendingTypesAllowed
                [false]                           // isToken1LendingTypesAllowed (restricted)
            );

            const newMarketAddress = await tradingCore.pairMarket(await token0.getAddress(), await token1.getAddress());
            expect(newMarketAddress).to.not.equal(ZERO_ADDRESS);
        });

        it("Should test asset enabled functionality", async function () {
            const { baseToken, targetToken, owner, tradingCore, router } = await deployContractsFixture();
            
            // Check that assets are enabled after pool creation
            expect(await router.isAssetEnabled(await baseToken.getAddress())).to.equal(true);
            expect(await router.isAssetEnabled(await targetToken.getAddress())).to.equal(true);
            
            // Create a new token that hasn't been used in any pool
            const newToken = await ethers.deployContract("MockToken", [await owner.getAddress(), "UnusedToken", "UNUSED", ethers.parseUnits("100000000", 18), 18]);
            expect(await router.isAssetEnabled(await newToken.getAddress())).to.equal(false);
        });
    });
});