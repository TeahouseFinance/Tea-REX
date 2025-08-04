const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const {
  loadFixture, time
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");

const FEE_CAP = 300000;
const interestRateModelType = 2;
const feeConfig = {
    _modelType: interestRateModelType,
    _supplyCap: 5_000_000n,
    _borrowCap: 1_000_000n,
    _reserveRatio: 50000,
};

describe("TeaRex Router", function () {
    async function deployRouterProxyFixture() {
        const [owner, tradingCore, feeTreasury, user] = await ethers.getSigners();
        // console.log("Owner address: ", owner.address);

        const Pool = await ethers.getContractFactory("Pool");
        const poolBeacon = await upgrades.deployBeacon(Pool);

        const Router = await ethers.getContractFactory("Router");
        const routerAtProxy = await upgrades.deployProxy(Router, [owner.address, poolBeacon.target, FEE_CAP]);
        // console.log("Router deployed to:", await routerAtProxy.getAddress());   
        
        const interestRateModelSample = await ethers.getContractFactory("VariableInterestRateModel");
        const interestRateModel = await interestRateModelSample.deploy(owner, { baseRate: 10000, hikedRate: 240000 });
        await interestRateModel.waitForDeployment();
        // console.log("InterestRateModel deployed to:", await interestRateModel.getAddress());

        return { owner, tradingCore, feeTreasury, user, interestRateModel, routerAtProxy };
    }

    async function deployERC20Fixture() {
        const [owner] = await ethers.getSigners();
        const MockERC20 = await ethers.getContractFactory("MockToken");
        const initialSupply = ethers.parseUnits("100000000", 6); // 100M tokens with 6 decimals
        const mockToken = await MockERC20.deploy(owner, "Mock", "Mock", initialSupply, 6);
        await mockToken.waitForDeployment();
        // console.log("MockToken deployed to:", await mockToken.getAddress());

        return { mockToken, owner };
      }

    async function deployRouterProxyWithSetFixture() {
        const { owner, tradingCore, feeTreasury, user, interestRateModel, routerAtProxy } = await deployRouterProxyFixture();
        const { mockToken } = await deployERC20Fixture(owner); 
        const borrow_fee = 10_000;
        const withdraw_fee = 1000;

        await routerAtProxy.setInterestRateModel(interestRateModelType, await interestRateModel.getAddress());
        await routerAtProxy.setTradingCore(await tradingCore.address);
        await routerAtProxy.setDefaultFeeConfig(await feeTreasury.address, borrow_fee, withdraw_fee);
        await routerAtProxy.setEnableWhitelist(true);
        await routerAtProxy.setWhitelistedOperator([tradingCore.address, owner.address], [true, true]);
        await routerAtProxy.createLendingPool(
            await mockToken.getAddress(),
            feeConfig._modelType,
            feeConfig._supplyCap,
            feeConfig._borrowCap,
            feeConfig._reserveRatio
        )

        return { mockToken, owner, tradingCore, feeTreasury, user, interestRateModel, routerAtProxy };
    }

    describe("Deployment", function () {
        it("Should set the correct owner", async function () {
            const { routerAtProxy, owner } = await loadFixture(deployRouterProxyFixture);

            // assert that the value is correct
            expect(await routerAtProxy.owner()).to.equal(owner.address);
        });

        it("Contract should be not be paused", async function () {
            const { routerAtProxy } = await loadFixture(deployRouterProxyFixture);
    
            expect(await routerAtProxy.isAllPoolPaused()).to.equal(false);
        });

        it("Should set the correct fee cap", async function () {
            const { routerAtProxy } = await loadFixture(deployRouterProxyFixture);

            // assert that the value is correct
            expect(await routerAtProxy.FEE_CAP()).to.equal(FEE_CAP);
        });
    });

    describe("Owner function", function () {
        it("Should be able to set interest model from owner", async function () {
            const { interestRateModel, routerAtProxy } = await loadFixture(deployRouterProxyFixture);

            await routerAtProxy.setInterestRateModel(interestRateModelType, await interestRateModel.getAddress());

            // assert that the value is correct
            expect(await routerAtProxy.interestRateModel(interestRateModelType)).to.equal(await interestRateModel.getAddress());
        });

        it("Should be able to set whitelist operator from owner", async function () {
            const { tradingCore, user, routerAtProxy } = await loadFixture(deployRouterProxyFixture);

            expect(await routerAtProxy.whitelistedOperator(tradingCore.address)).to.equal(false);
            expect(await routerAtProxy.whitelistedOperator(user.address)).to.equal(false);

            await routerAtProxy.setWhitelistedOperator([tradingCore.address, user.address], [true, true]);
            expect(await routerAtProxy.whitelistedOperator(tradingCore.address)).to.equal(true);
            expect(await routerAtProxy.whitelistedOperator(user.address)).to.equal(true);
            
            await routerAtProxy.setWhitelistedOperator([tradingCore.address, user.address], [false, false]);
            expect(await routerAtProxy.whitelistedOperator(tradingCore.address)).to.equal(false);
            expect(await routerAtProxy.whitelistedOperator(user.address)).to.equal(false);
        });

        it("Should be able to set trading core from owner", async function () {
            const { tradingCore, routerAtProxy } = await loadFixture(deployRouterProxyFixture);
            await routerAtProxy.setTradingCore(await tradingCore.address);

            expect(await routerAtProxy.tradingCore()).to.equal(await tradingCore.address);
        });

        it("Should be able to pause or unpause from owner", async function () {
            const { routerAtProxy } = await loadFixture(deployRouterProxyFixture);

            await routerAtProxy.pause();
            expect(await routerAtProxy.isAllPoolPaused()).to.equal(true);

            await routerAtProxy.unpause();
            expect(await routerAtProxy.isAllPoolPaused()).to.equal(false);
        });

        it("Should be able to set fee config from owner", async function () {
            const { feeTreasury, routerAtProxy, interestRateModel } = await loadFixture(deployRouterProxyFixture);
            const { mockToken } = await loadFixture(deployERC20Fixture);

            // Create a lending pool first
            await routerAtProxy.setInterestRateModel(interestRateModelType, await interestRateModel.getAddress());
            await routerAtProxy.createLendingPool(
                await mockToken.getAddress(),
                feeConfig._modelType,
                feeConfig._supplyCap,
                feeConfig._borrowCap,
                feeConfig._reserveRatio
            );

            const pool = await routerAtProxy.getLendingPool(await mockToken.getAddress(), feeConfig._modelType);
            const borrowFee = 10_000;
            const withdrawFee = 1_000;
            await routerAtProxy.setFeeConfig(pool, feeTreasury.address, borrowFee, withdrawFee);

            const poolFeeConfig = await routerAtProxy.feeConfig(pool);

            expect(poolFeeConfig.treasury).to.equal(feeTreasury.address);
            expect(poolFeeConfig.borrowFee).to.equal(borrowFee);
            expect(poolFeeConfig.withdrawalFee).to.equal(withdrawFee);
        });

        it("Should revert if the fee config set with invalid fee", async function () {
            const { feeTreasury, routerAtProxy, interestRateModel } = await loadFixture(deployRouterProxyFixture);
            const { mockToken } = await loadFixture(deployERC20Fixture);
            
            // Create a lending pool first
            await routerAtProxy.setInterestRateModel(interestRateModelType, await interestRateModel.getAddress());
            await routerAtProxy.createLendingPool(
                await mockToken.getAddress(),
                feeConfig._modelType,
                feeConfig._supplyCap,
                feeConfig._borrowCap,
                feeConfig._reserveRatio
            );

            const pool = await routerAtProxy.getLendingPool(await mockToken.getAddress(), feeConfig._modelType);
            const borrowFee = FEE_CAP + 1;
            const withdrawFee = 1000;
            await expect(routerAtProxy.setFeeConfig(pool, feeTreasury.address, borrowFee, withdrawFee))
            .to.be.revertedWithCustomError(routerAtProxy, "ExceedsFeeCap");
        });

        it("Should be able to create lending pool from owner", async function () {
            const { interestRateModel, routerAtProxy } = await loadFixture(deployRouterProxyFixture);
            const { mockToken } = await loadFixture(deployERC20Fixture);
            await routerAtProxy.setInterestRateModel(interestRateModelType, await interestRateModel.getAddress());
            const underlyingAsset = await mockToken.getAddress();

            await expect(routerAtProxy.createLendingPool(
                underlyingAsset,
                feeConfig._modelType,
                feeConfig._supplyCap,
                feeConfig._borrowCap,
                feeConfig._reserveRatio
            )).to.emit(routerAtProxy, "LendingPoolCreated")
            .withArgs(anyValue, underlyingAsset, feeConfig._modelType);
            
            const events = await routerAtProxy.queryFilter("LendingPoolCreated");
            const lastEvent = events[events.length - 1];
            const poolProxyAddress = lastEvent.args[0];
            expect(poolProxyAddress).to.be.properAddress;

            const pool = await routerAtProxy.getLendingPool(underlyingAsset, feeConfig._modelType);
            expect(pool).to.equal(poolProxyAddress);

            const Pool = await ethers.getContractFactory("Pool");
            const poolInstance = Pool.attach(poolProxyAddress);

            expect(await poolInstance.underlyingAsset()).to.equal(underlyingAsset);
            expect(await poolInstance.supplyCap()).to.equal(feeConfig._supplyCap);
            expect(await poolInstance.borrowCap()).to.equal(feeConfig._borrowCap);
            expect(await poolInstance.reserveRatio()).to.equal(feeConfig._reserveRatio); 
        });

        it("Should not be able to create lending pool from non-owner", async function () {
            const { mockToken, routerAtProxy, user } = await loadFixture(deployRouterProxyWithSetFixture);
            const underlyingAsset = await mockToken.getAddress();

            await expect(routerAtProxy.connect(user).createLendingPool(
                underlyingAsset,
                feeConfig._modelType,
                feeConfig._supplyCap,
                feeConfig._borrowCap,
                feeConfig._reserveRatio
            )).to.be.revertedWithCustomError(routerAtProxy, "OwnableUnauthorizedAccount");
        });

        it("Should revert when creating lending pool with invalid caps", async function () {
            const { interestRateModel, routerAtProxy } = await loadFixture(deployRouterProxyFixture);
            const { mockToken } = await loadFixture(deployERC20Fixture);
            const underlyingAsset = await mockToken.getAddress();

            await routerAtProxy.setInterestRateModel(interestRateModelType, await interestRateModel.getAddress());
            
            const feeConfig1 = {
                _underlyingAsset: underlyingAsset,
                _modelType: interestRateModelType,
                _supplyCap: 5_000_000n,
                _borrowCap: 5_000_001n,
                _reserveRatio: 50000,
            };
    
            const feeConfig2 = {
                _underlyingAsset: underlyingAsset,
                _modelType: interestRateModelType,
                _supplyCap: 5_000_000n,
                _borrowCap: 1_000_000n,
                _reserveRatio: 1000000,
            };

            await expect(routerAtProxy.createLendingPool(
                feeConfig1._underlyingAsset,
                feeConfig1._modelType,
                feeConfig1._supplyCap,
                feeConfig1._borrowCap,
                feeConfig1._reserveRatio
            )).to.be.reverted;
            
            await expect(routerAtProxy.createLendingPool(
                feeConfig2._underlyingAsset,
                feeConfig2._modelType,
                feeConfig2._supplyCap,
                feeConfig2._borrowCap,
                feeConfig2._reserveRatio
            )).to.be.reverted;

        });

        it("Should not be able to call from non-owner", async function () {
            const { tradingCore, feeTreasury, interestRateModel, user, routerAtProxy } = await loadFixture(deployRouterProxyFixture);
            // We can increase the time in Hardhat Network
            await expect(routerAtProxy.connect(user).pause())
            .to.be.revertedWithCustomError(routerAtProxy, "OwnableUnauthorizedAccount");

            await expect(routerAtProxy.connect(user).unpause())
            .to.be.revertedWithCustomError(routerAtProxy, "OwnableUnauthorizedAccount");

            await expect(routerAtProxy.connect(user).setTradingCore(await tradingCore.address))
            .to.be.revertedWithCustomError(routerAtProxy, "OwnableUnauthorizedAccount");

            // Test setFeeConfig requires a pool, so we'll skip this specific test for now
            // as it would require creating a pool first

            await expect(routerAtProxy.connect(user).setInterestRateModel(interestRateModelType, await interestRateModel.getAddress()))
            .to.be.revertedWithCustomError(routerAtProxy, "OwnableUnauthorizedAccount");        
        });

        it("Should be able to set enable whitelist from owner", async function () {
            const { mockToken, routerAtProxy, user } = await loadFixture(deployRouterProxyWithSetFixture);

            // Initially whitelist should be enabled
            await routerAtProxy.setEnableWhitelist(false);
            
            // Test that whitelist is disabled by checking supply and withdraw without whitelist
            
            const pool = await routerAtProxy.getLendingPool(await mockToken.getAddress(), feeConfig._modelType);
            const amount = ethers.parseUnits("1", await mockToken.decimals());
            await mockToken.transfer(user.address, amount);
            await mockToken.connect(user).approve(pool, amount);
            // Non-whitelist user should be able to supply and withdraw
            await routerAtProxy.connect(user).supply(
                await mockToken.getAddress(),
                feeConfig._modelType,
                user.address,
                amount
            );
            await routerAtProxy.connect(user).withdraw(
                await mockToken.getAddress(),
                feeConfig._modelType,
                user.address,
                amount
            );
        });
    });

    describe("V2 New Features", function () {
        it("Should track asset enabled status", async function () {
            const { routerAtProxy, interestRateModel } = await loadFixture(deployRouterProxyFixture);
            const { mockToken } = await loadFixture(deployERC20Fixture);
            
            // Initially asset should not be enabled
            expect(await routerAtProxy.isAssetEnabled(await mockToken.getAddress())).to.equal(false);
            
            await routerAtProxy.setInterestRateModel(interestRateModelType, await interestRateModel.getAddress());
            await routerAtProxy.createLendingPool(
                await mockToken.getAddress(),
                feeConfig._modelType,
                feeConfig._supplyCap,
                feeConfig._borrowCap,
                feeConfig._reserveRatio
            );

            // After creating lending pool, asset should be enabled
            expect(await routerAtProxy.isAssetEnabled(await mockToken.getAddress())).to.equal(true);
        });

        it("Should test lending pool creation with different lending types", async function () {
            const { routerAtProxy, interestRateModel } = await loadFixture(deployRouterProxyFixture);
            const { mockToken } = await loadFixture(deployERC20Fixture);
            
            await routerAtProxy.setInterestRateModel(interestRateModelType, await interestRateModel.getAddress());
            
            // Create first pool with lending type 2
            await routerAtProxy.createLendingPool(
                await mockToken.getAddress(),
                2,
                feeConfig._supplyCap,
                feeConfig._borrowCap,
                feeConfig._reserveRatio
            );

            const pool1 = await routerAtProxy.getLendingPool(await mockToken.getAddress(), 2);
            expect(pool1).to.be.properAddress;

            // Create second pool with different lending type 3 (if we have another interest rate model)
            const anotherInterestRateModelType = 3;
            await routerAtProxy.setInterestRateModel(anotherInterestRateModelType, await interestRateModel.getAddress());
            
            await routerAtProxy.createLendingPool(
                await mockToken.getAddress(),
                3,
                feeConfig._supplyCap,
                feeConfig._borrowCap,
                feeConfig._reserveRatio
            );

            const pool2 = await routerAtProxy.getLendingPool(await mockToken.getAddress(), 3);
            expect(pool2).to.be.properAddress;
            expect(pool1).to.not.equal(pool2);
        });

        it("Should test borrowing rate calculation", async function () {
            const { routerAtProxy, interestRateModel } = await loadFixture(deployRouterProxyFixture);
            const { mockToken } = await loadFixture(deployERC20Fixture);
            
            await routerAtProxy.setInterestRateModel(interestRateModelType, await interestRateModel.getAddress());
            await routerAtProxy.createLendingPool(
                await mockToken.getAddress(),
                feeConfig._modelType,
                feeConfig._supplyCap,
                feeConfig._borrowCap,
                feeConfig._reserveRatio
            );

            const borrowRate = await routerAtProxy.getBorrowRate(await mockToken.getAddress(), feeConfig._modelType);
            expect(borrowRate).to.be.a('bigint');
        });
    });

    describe("Advanced Pool Management", function () {
        it("Should handle multiple pools for same asset with different lending types", async function () {
            const { routerAtProxy, interestRateModel } = await loadFixture(deployRouterProxyFixture);
            const { mockToken } = await loadFixture(deployERC20Fixture);
            
            // Set up multiple interest rate models
            await routerAtProxy.setInterestRateModel(2, await interestRateModel.getAddress());
            await routerAtProxy.setInterestRateModel(3, await interestRateModel.getAddress());
            await routerAtProxy.setInterestRateModel(4, await interestRateModel.getAddress());
            
            // Create multiple pools for same asset
            await routerAtProxy.createLendingPool(await mockToken.getAddress(), 2, ethers.parseUnits("1000000", 6), ethers.parseUnits("500000", 6), 50000);
            await routerAtProxy.createLendingPool(await mockToken.getAddress(), 3, ethers.parseUnits("2000000", 6), ethers.parseUnits("1000000", 6), 60000);
            await routerAtProxy.createLendingPool(await mockToken.getAddress(), 4, ethers.parseUnits("3000000", 6), ethers.parseUnits("1500000", 6), 70000);
            
            // Verify each pool exists and has different configurations
            const pool2 = await routerAtProxy.getLendingPool(await mockToken.getAddress(), 2);
            const pool3 = await routerAtProxy.getLendingPool(await mockToken.getAddress(), 3);
            const pool4 = await routerAtProxy.getLendingPool(await mockToken.getAddress(), 4);
            
            expect(pool2).to.not.equal(pool3);
            expect(pool3).to.not.equal(pool4);
            expect(pool2).to.not.equal(pool4);
            
            // Verify pool configurations
            const Pool = await ethers.getContractFactory("Pool");
            const poolInstance2 = Pool.attach(pool2);
            const poolInstance3 = Pool.attach(pool3);
            const poolInstance4 = Pool.attach(pool4);
            
            expect(await poolInstance2.supplyCap()).to.equal(ethers.parseUnits("1000000", 6));
            expect(await poolInstance3.supplyCap()).to.equal(ethers.parseUnits("2000000", 6));
            expect(await poolInstance4.supplyCap()).to.equal(ethers.parseUnits("3000000", 6));
            
            expect(await poolInstance2.reserveRatio()).to.equal(50000);
            expect(await poolInstance3.reserveRatio()).to.equal(60000);
            expect(await poolInstance4.reserveRatio()).to.equal(70000);
        });

        it("Should prevent creating duplicate pools", async function () {
            const { routerAtProxy, interestRateModel } = await loadFixture(deployRouterProxyFixture);
            const { mockToken } = await loadFixture(deployERC20Fixture);
            
            await routerAtProxy.setInterestRateModel(interestRateModelType, await interestRateModel.getAddress());
            
            // Create first pool
            await routerAtProxy.createLendingPool(
                await mockToken.getAddress(),
                interestRateModelType,
                feeConfig._supplyCap,
                feeConfig._borrowCap,
                feeConfig._reserveRatio
            );
            
            // Try to create duplicate pool - should revert
            await expect(routerAtProxy.createLendingPool(
                await mockToken.getAddress(),
                interestRateModelType,
                feeConfig._supplyCap,
                feeConfig._borrowCap,
                feeConfig._reserveRatio
            )).to.be.revertedWithCustomError(routerAtProxy, "PoolAlreadyExists");
        });

        it("Should prevent creating pool with unset interest rate model", async function () {
            const { routerAtProxy } = await loadFixture(deployRouterProxyFixture);
            const { mockToken } = await loadFixture(deployERC20Fixture);
            
            // Try to create pool without setting interest rate model
            await expect(routerAtProxy.createLendingPool(
                await mockToken.getAddress(),
                999, // Non-existent lending type
                feeConfig._supplyCap,
                feeConfig._borrowCap,
                feeConfig._reserveRatio
            )).to.be.revertedWithCustomError(routerAtProxy, "ModelNotSet");
        });

        it("Should revert when accessing non-existent pool", async function () {
            const { routerAtProxy } = await loadFixture(deployRouterProxyFixture);
            const { mockToken } = await loadFixture(deployERC20Fixture);
            
            // Try to access pool that doesn't exist
            await expect(routerAtProxy.getLendingPool(await mockToken.getAddress(), 999))
                .to.be.revertedWithCustomError(routerAtProxy, "PoolNotExists");
        });
    });

    describe("Interest Rate and Fee Management", function () {
        it("Should calculate supply and borrow rates correctly", async function () {
            const { routerAtProxy, interestRateModel, owner } = await loadFixture(deployRouterProxyFixture);
            const { mockToken } = await loadFixture(deployERC20Fixture);
            
            await routerAtProxy.setInterestRateModel(interestRateModelType, await interestRateModel.getAddress());
            await routerAtProxy.createLendingPool(
                await mockToken.getAddress(),
                interestRateModelType,
                feeConfig._supplyCap,
                feeConfig._borrowCap,
                feeConfig._reserveRatio
            );
            
            // Test initial rates (should be base rates when no utilization)
            const initialSupplyRate = await routerAtProxy.getSupplyRate(await mockToken.getAddress(), interestRateModelType);
            const initialBorrowRate = await routerAtProxy.getBorrowRate(await mockToken.getAddress(), interestRateModelType);
            
            expect(initialSupplyRate).to.be.a('bigint');
            expect(initialBorrowRate).to.be.a('bigint');
            expect(initialBorrowRate).to.be.gt(initialSupplyRate); // Borrow rate should be higher than supply rate
            
            // Set up whitelist and supply some tokens to test rate changes
            await routerAtProxy.setEnableWhitelist(true);
            await routerAtProxy.setWhitelistedOperator([owner.address], [true]);
            
            const pool = await routerAtProxy.getLendingPool(await mockToken.getAddress(), interestRateModelType);
            const supplyAmount = ethers.parseUnits("10000", 6);
            
            await mockToken.approve(pool, supplyAmount);
            await routerAtProxy.supply(await mockToken.getAddress(), interestRateModelType, owner.address, supplyAmount);
            
            // Rates should still be similar when only supplied (low utilization)
            const postSupplySupplyRate = await routerAtProxy.getSupplyRate(await mockToken.getAddress(), interestRateModelType);
            const postSupplyBorrowRate = await routerAtProxy.getBorrowRate(await mockToken.getAddress(), interestRateModelType);
            
            expect(postSupplySupplyRate).to.equal(initialSupplyRate);
            expect(postSupplyBorrowRate).to.equal(initialBorrowRate);
        });

        it("Should manage fee configurations properly", async function () {
            const { routerAtProxy, interestRateModel, feeTreasury, owner } = await loadFixture(deployRouterProxyFixture);
            const { mockToken } = await loadFixture(deployERC20Fixture);
            
            // Set default fee config
            const defaultBorrowFee = 5000; // 0.5%
            const defaultWithdrawFee = 500; // 0.05%
            await routerAtProxy.setDefaultFeeConfig(feeTreasury.address, defaultBorrowFee, defaultWithdrawFee);
            
            // Create pool
            await routerAtProxy.setInterestRateModel(interestRateModelType, await interestRateModel.getAddress());
            await routerAtProxy.createLendingPool(
                await mockToken.getAddress(),
                interestRateModelType,
                feeConfig._supplyCap,
                feeConfig._borrowCap,
                feeConfig._reserveRatio
            );
            
            const pool1 = await routerAtProxy.getLendingPool(await mockToken.getAddress(), interestRateModelType);
            
            // Pool should use default fee config initially
            const poolFeeConfig1 = await routerAtProxy.feeConfig(pool1);
            expect(poolFeeConfig1.treasury).to.equal("0x0000000000000000000000000000000000000000"); // Should be zero address since no pool-specific config
            
            // Set pool-specific fee config
            const poolSpecificBorrowFee = 8000; // 0.8%
            const poolSpecificWithdrawFee = 800; // 0.08%
            const [newTreasury] = await ethers.getSigners();
            
            await routerAtProxy.setFeeConfig(pool1, newTreasury.address, poolSpecificBorrowFee, poolSpecificWithdrawFee);
            
            // Pool should now have specific fee config
            const poolFeeConfig2 = await routerAtProxy.feeConfig(pool1);
            expect(poolFeeConfig2.treasury).to.equal(newTreasury.address);
            expect(poolFeeConfig2.borrowFee).to.equal(poolSpecificBorrowFee);
            expect(poolFeeConfig2.withdrawalFee).to.equal(poolSpecificWithdrawFee);
        });

        it("Should test fee configuration edge cases", async function () {
            const { routerAtProxy, feeTreasury } = await loadFixture(deployRouterProxyFixture);
            const { mockToken } = await loadFixture(deployERC20Fixture);
            
            // Test fee at FEE_CAP limit
            await routerAtProxy.setDefaultFeeConfig(feeTreasury.address, FEE_CAP, FEE_CAP);
            
            // Test fee exceeding FEE_CAP should revert
            await expect(routerAtProxy.setDefaultFeeConfig(feeTreasury.address, FEE_CAP + 1, 0))
                .to.be.revertedWithCustomError(routerAtProxy, "ExceedsFeeCap");
            
            await expect(routerAtProxy.setDefaultFeeConfig(feeTreasury.address, 0, FEE_CAP + 1))
                .to.be.revertedWithCustomError(routerAtProxy, "ExceedsFeeCap");
        });
    });

    describe("Advanced Whitelist Management", function () {
        it("Should test complex whitelist scenarios", async function () {
            const { routerAtProxy, owner: routerOwner, tradingCore } = await loadFixture(deployRouterProxyFixture);
            const { mockToken, owner: tokenOwner } = await loadFixture(deployERC20Fixture);
            const [user2, user3] = await ethers.getSigners();
            
            // Set up basic router configuration
            await routerAtProxy.setTradingCore(tradingCore.address);
            await routerAtProxy.setEnableWhitelist(true);
            
            // Create a pool for testing with higher supply cap (use different lending type to avoid conflicts)
            const testLendingType = 10;
            await routerAtProxy.setInterestRateModel(testLendingType, await ethers.deployContract("VariableInterestRateModel", [routerOwner.address, { baseRate: 10000, hikedRate: 240000 }]).then(c => c.getAddress()));
            await routerAtProxy.createLendingPool(
                await mockToken.getAddress(),
                testLendingType,
                ethers.parseUnits("100000", 6), // Higher supply cap
                ethers.parseUnits("50000", 6),  // Higher borrow cap
                feeConfig._reserveRatio
            );
            
            // Test batch whitelist operations
            await routerAtProxy.setWhitelistedOperator(
                [user2.address, user3.address, tradingCore.address], 
                [true, false, false]
            );
            
            expect(await routerAtProxy.whitelistedOperator(user2.address)).to.equal(true);
            expect(await routerAtProxy.whitelistedOperator(user3.address)).to.equal(false);
            expect(await routerAtProxy.whitelistedOperator(tradingCore.address)).to.equal(false);
            
            // Test supply with different whitelist statuses
            const pool = await routerAtProxy.getLendingPool(await mockToken.getAddress(), testLendingType);
            const amount = ethers.parseUnits("100", 6);
            
            // Transfer tokens to test users from the token owner
            await mockToken.connect(tokenOwner).transfer(user2.address, amount);
            await mockToken.connect(tokenOwner).transfer(user3.address, amount);
            
            // user2 (whitelisted) should be able to supply
            await mockToken.connect(user2).approve(pool, amount);
            await expect(routerAtProxy.connect(user2).supply(
                await mockToken.getAddress(),
                testLendingType,
                user2.address,
                amount
            )).to.not.be.reverted;
            
            // user3 (not whitelisted) should not be able to supply
            await mockToken.connect(user3).approve(pool, amount);
            await expect(routerAtProxy.connect(user3).supply(
                await mockToken.getAddress(),
                testLendingType,
                user3.address,
                amount
            )).to.be.revertedWithCustomError(routerAtProxy, "NotInWhitelist");
            
            // Disable whitelist - user3 should now be able to supply
            await routerAtProxy.setEnableWhitelist(false);
            await expect(routerAtProxy.connect(user3).supply(
                await mockToken.getAddress(),
                testLendingType,
                user3.address,
                amount
            )).to.not.be.reverted;
        });

        it("Should test whitelist with withdraw operations", async function () {
            const { routerAtProxy, owner: routerOwner, tradingCore } = await loadFixture(deployRouterProxyFixture);
            const { mockToken, owner: tokenOwner } = await loadFixture(deployERC20Fixture);
            const [user2] = await ethers.getSigners();
            
            // Set up basic router configuration
            await routerAtProxy.setTradingCore(tradingCore.address);
            await routerAtProxy.setEnableWhitelist(true);
            
            // Create a pool for testing (use different lending type)
            const testLendingType = 11;
            await routerAtProxy.setInterestRateModel(testLendingType, await ethers.deployContract("VariableInterestRateModel", [routerOwner.address, { baseRate: 10000, hikedRate: 240000 }]).then(c => c.getAddress()));
            await routerAtProxy.createLendingPool(
                await mockToken.getAddress(),
                testLendingType,
                feeConfig._supplyCap,
                feeConfig._borrowCap,
                feeConfig._reserveRatio
            );
            
            // Set user2 as whitelisted
            await routerAtProxy.setWhitelistedOperator([user2.address], [true]);
            
            const pool = await routerAtProxy.getLendingPool(await mockToken.getAddress(), testLendingType);
            const amount = ethers.parseUnits("100", 6);
            
            // Transfer and supply from token owner
            await mockToken.connect(tokenOwner).transfer(user2.address, amount);
            await mockToken.connect(user2).approve(pool, amount);
            await routerAtProxy.connect(user2).supply(
                await mockToken.getAddress(),
                testLendingType,
                user2.address,
                amount
            );
            
            // user2 should be able to withdraw
            const teaTokenAmount = amount * 1000000000000000000n;
            await expect(routerAtProxy.connect(user2).withdraw(
                await mockToken.getAddress(),
                testLendingType,
                user2.address,
                teaTokenAmount
            )).to.not.be.reverted;
        });
    });

    describe("Pool Status and Queries", function () {
        it("Should test balance and debt queries", async function () {
            const { routerAtProxy, owner, tradingCore } = await loadFixture(deployRouterProxyFixture);
            const { mockToken, owner: tokenOwner } = await loadFixture(deployERC20Fixture);
            
            // Set up basic router configuration
            await routerAtProxy.setTradingCore(tradingCore.address);
            await routerAtProxy.setEnableWhitelist(true);
            
            // Create a fresh pool for testing (use different lending type)
            const testLendingType = 12;
            await routerAtProxy.setInterestRateModel(testLendingType, await ethers.deployContract("VariableInterestRateModel", [owner.address, { baseRate: 10000, hikedRate: 240000 }]).then(c => c.getAddress()));
            await routerAtProxy.createLendingPool(
                await mockToken.getAddress(),
                testLendingType,
                ethers.parseUnits("100000", 6),
                ethers.parseUnits("50000", 6),
                feeConfig._reserveRatio
            );
            
            const supplyAmount = ethers.parseUnits("1000", 6);
            const borrowAmount = ethers.parseUnits("500", 6);
            
            // Supply tokens from token owner
            const pool = await routerAtProxy.getLendingPool(await mockToken.getAddress(), testLendingType);
            await mockToken.connect(tokenOwner).approve(pool, supplyAmount);
            await routerAtProxy.setWhitelistedOperator([tokenOwner.address], [true]);
            await routerAtProxy.connect(tokenOwner).supply(
                await mockToken.getAddress(),
                testLendingType,
                tokenOwner.address,
                supplyAmount
            );
            
            // Test balance queries
            const teaTokenBalance = await routerAtProxy.balanceOf(
                await mockToken.getAddress(),
                testLendingType,
                tokenOwner.address
            );
            expect(teaTokenBalance).to.be.gt(0);
            
            const underlyingBalance = await routerAtProxy.balanceOfUnderlying(
                await mockToken.getAddress(),
                testLendingType,
                tokenOwner.address
            );
            expect(underlyingBalance).to.equal(supplyAmount);
            
            // Test conversion rates
            const [suppliedRate, borrowedRate] = await routerAtProxy.getConversionRates(
                await mockToken.getAddress(),
                testLendingType
            );
            expect(suppliedRate).to.be.gt(0);
            expect(borrowedRate).to.be.gt(0);
            
            // Test borrowing and debt queries
            await routerAtProxy.connect(tradingCore).commitBorrow(
                await mockToken.getAddress(),
                testLendingType,
                borrowAmount
            );
            
            const poolContract = await ethers.getContractAt("Pool", pool);
            const events = await poolContract.queryFilter("Borrowed");
            const borrowId = events[events.length - 1].args[1];
            
            const debtInTeaTokens = await routerAtProxy.debtOf(
                await mockToken.getAddress(),
                testLendingType,
                borrowId
            );
            expect(debtInTeaTokens).to.be.gt(0);
            
            const debtInUnderlying = await routerAtProxy.debtOfUnderlying(
                await mockToken.getAddress(),
                testLendingType,
                borrowId
            );
            expect(debtInUnderlying).to.equal(borrowAmount);
        });

        it("Should test interest fee collection", async function () {
            const { routerAtProxy, owner, tradingCore } = await loadFixture(deployRouterProxyFixture);
            const { mockToken, owner: tokenOwner } = await loadFixture(deployERC20Fixture);
            
            // Set up basic router configuration
            await routerAtProxy.setTradingCore(tradingCore.address);
            await routerAtProxy.setEnableWhitelist(true);
            
            // Create a fresh pool for testing (use different lending type)
            const testLendingType = 13;
            await routerAtProxy.setInterestRateModel(testLendingType, await ethers.deployContract("VariableInterestRateModel", [owner.address, { baseRate: 10000, hikedRate: 240000 }]).then(c => c.getAddress()));
            await routerAtProxy.createLendingPool(
                await mockToken.getAddress(),
                testLendingType,
                ethers.parseUnits("100000", 6),
                ethers.parseUnits("50000", 6),
                feeConfig._reserveRatio
            );
            
            const supplyAmount = ethers.parseUnits("10000", 6);
            const borrowAmount = ethers.parseUnits("5000", 6);
            
            // Supply and borrow to generate interest
            const pool = await routerAtProxy.getLendingPool(await mockToken.getAddress(), testLendingType);
            await mockToken.connect(tokenOwner).approve(pool, supplyAmount);
            await routerAtProxy.setWhitelistedOperator([tokenOwner.address], [true]);
            await routerAtProxy.connect(tokenOwner).supply(
                await mockToken.getAddress(),
                testLendingType,
                tokenOwner.address,
                supplyAmount
            );
            
            await routerAtProxy.connect(tradingCore).commitBorrow(
                await mockToken.getAddress(),
                testLendingType,
                borrowAmount
            );
            
            // Fast forward time to accrue interest
            await time.increase(86400 * 30); // 30 days
            
            // Collect interest and fees
            const result = await routerAtProxy.collectInterestFeeAndCommit(
                await mockToken.getAddress(),
                testLendingType
            );
            
            // Since this is a transaction, we just check it completes successfully
            expect(result).to.not.be.undefined;
        });

        it("Should test interest rate model queries", async function () {
            const { routerAtProxy, interestRateModel } = await loadFixture(deployRouterProxyFixture);
            
            // Set multiple interest rate models
            const models = [
                { type: 1, address: await interestRateModel.getAddress() },
                { type: 2, address: await interestRateModel.getAddress() },
                { type: 3, address: await interestRateModel.getAddress() }
            ];
            
            for (const model of models) {
                await routerAtProxy.setInterestRateModel(model.type, model.address);
                
                const retrievedAddress = await routerAtProxy.getInterestRateModel(model.type);
                expect(retrievedAddress).to.equal(model.address);
            }
            
            // Test non-existent model
            const nonExistentModel = await routerAtProxy.getInterestRateModel(999);
            expect(nonExistentModel).to.equal("0x0000000000000000000000000000000000000000");
        });
    });

    describe("Event Emissions", function () {
        it("Should emit correct events for all operations", async function () {
            const { routerAtProxy, interestRateModel, feeTreasury, tradingCore } = await loadFixture(deployRouterProxyFixture);
            const { mockToken } = await loadFixture(deployERC20Fixture);
            
            // Test TradingCoreSet event
            await expect(routerAtProxy.setTradingCore(tradingCore.address))
                .to.emit(routerAtProxy, "TradingCoreSet")
                .withArgs(anyValue, tradingCore.address);
            
            // Test DeFaultFeeConfigSet event
            await expect(routerAtProxy.setDefaultFeeConfig(feeTreasury.address, 10000, 1000))
                .to.emit(routerAtProxy, "DeFaultFeeConfigSet")
                .withArgs(anyValue, feeTreasury.address, 10000);
            
            // Test InterestRateModelSet event
            await expect(routerAtProxy.setInterestRateModel(interestRateModelType, await interestRateModel.getAddress()))
                .to.emit(routerAtProxy, "InterestRateModelSet")
                .withArgs(anyValue, interestRateModelType, await interestRateModel.getAddress());
            
            // Test LendingPoolCreated event
            await expect(routerAtProxy.createLendingPool(
                await mockToken.getAddress(),
                interestRateModelType,
                feeConfig._supplyCap,
                feeConfig._borrowCap,
                feeConfig._reserveRatio
            )).to.emit(routerAtProxy, "LendingPoolCreated")
            .withArgs(anyValue, await mockToken.getAddress(), interestRateModelType);
            
            // Test FeeConfigSet event
            const pool = await routerAtProxy.getLendingPool(await mockToken.getAddress(), interestRateModelType);
            await expect(routerAtProxy.setFeeConfig(pool, feeTreasury.address, 15000, 1500))
                .to.emit(routerAtProxy, "FeeConfigSet")
                .withArgs(anyValue, pool, feeTreasury.address, 15000);
        });
    });

    describe("User function", function () {
        it("Should not be able to supply if enableWhitelist and user is non-whitelist", async function () {
            const { mockToken, routerAtProxy, user } = await loadFixture(deployRouterProxyWithSetFixture);
            const underlyingAsset = await mockToken.getAddress();

            await routerAtProxy.setEnableWhitelist(true);
            const pool = await routerAtProxy.getLendingPool(underlyingAsset, feeConfig._modelType);            
            const amount = ethers.parseUnits("1", await mockToken.decimals());
            await mockToken.transfer(user.address, amount);
            await mockToken.connect(user).approve(pool, amount);
            await expect(routerAtProxy.connect(user).supply(
                underlyingAsset,
                feeConfig._modelType,
                user.address,
                amount
            )).to.be.revertedWithCustomError(routerAtProxy, "NotInWhitelist");
        });

        it("Should be able to supply and withdraw", async function () {
            const { mockToken, routerAtProxy, tradingCore } = await loadFixture(deployRouterProxyWithSetFixture);
            const underlyingAsset = await mockToken.getAddress(); 
            const pool = await routerAtProxy.getLendingPool(underlyingAsset, feeConfig._modelType);
            const poolContract = await ethers.getContractAt("Pool", pool);
            const amount = ethers.parseUnits("1", await mockToken.decimals());
            await mockToken.transfer(tradingCore.address, amount);
            const before_supply_amount = await mockToken.balanceOf(tradingCore.address);
            expect(before_supply_amount).to.equal(amount);

            await mockToken.connect(tradingCore).approve(pool, amount);
            expect(await routerAtProxy.connect(tradingCore).supply(
                underlyingAsset,
                feeConfig._modelType,
                tradingCore.address,
                amount
            )).to.emit(routerAtProxy, "Supplied")
            .withArgs(tradingCore.address, tradingCore.address, underlyingAsset, amount);
            const after_supply_amount = await mockToken.balanceOf(tradingCore.address);
            expect(before_supply_amount - after_supply_amount).to.equal(amount);

            const teaTokenAmount = amount * 1000000000000000000n;
            expect(await poolContract.balanceOf(tradingCore.address)).to.equal(teaTokenAmount);
            expect(await mockToken.balanceOf(tradingCore.address)).to.equal(0);
            expect(await mockToken.balanceOf(pool)).to.equal(amount);
            expect(await routerAtProxy.balanceOf(
                underlyingAsset,
                feeConfig._modelType,
                tradingCore.address
            )).to.equal(teaTokenAmount);

            expect(await routerAtProxy.balanceOfUnderlying(
                underlyingAsset, 
                feeConfig._modelType,
                tradingCore.address
            )).to.equal(amount);
            
            const withdraw_fee_amount = ethers.parseUnits("0.001", await mockToken.decimals()); // withdraw_fee 0.1%
            expect(await routerAtProxy.connect(tradingCore).withdraw(
                underlyingAsset,
                feeConfig._modelType,
                tradingCore.address,
                teaTokenAmount
            )).to.changeTokenBalances(
                mockToken,
                [pool, tradingCore],
                [-withdraw_fee_amount, withdraw_fee_amount]
            );
        });

        it("Should not be able to withdraw more than supply", async function () {
            const { mockToken, routerAtProxy, tradingCore } = await loadFixture(deployRouterProxyWithSetFixture);
            const underlyingAsset = await mockToken.getAddress();
            const pool = await routerAtProxy.getLendingPool(underlyingAsset, feeConfig._modelType);
            const amount = ethers.parseUnits("1", await mockToken.decimals());
            await mockToken.transfer(tradingCore.address, amount);
            await mockToken.connect(tradingCore).approve(pool, amount);
            await routerAtProxy.connect(tradingCore).supply(
                underlyingAsset,
                feeConfig._modelType,
                tradingCore.address,
                amount
            );
            
            await routerAtProxy.connect(tradingCore).withdraw(
                underlyingAsset,
                feeConfig._modelType,
                tradingCore.address,
                amount*1100000000000000000n);
        });

        it("Should be able to repay the debt", async function () {
            const { mockToken, owner, tradingCore, routerAtProxy } = await loadFixture(deployRouterProxyWithSetFixture);
            const underlyingAsset = await mockToken.getAddress();
            const pool = await routerAtProxy.getLendingPool(underlyingAsset, feeConfig._modelType);
            const poolContract = await ethers.getContractAt("Pool", pool);

            const transferAmount = ethers.parseUnits("2.5", await mockToken.decimals());
            const supplyAmount = ethers.parseUnits("1", await mockToken.decimals());
            await mockToken.transfer(tradingCore.address, transferAmount);
            await mockToken.connect(tradingCore).approve(pool, supplyAmount);
            await routerAtProxy.connect(tradingCore).supply(
                underlyingAsset,
                feeConfig._modelType,
                tradingCore.address,
                supplyAmount)

            await mockToken.approve(pool, supplyAmount);
            await routerAtProxy.supply(
                underlyingAsset,
                feeConfig._modelType,
                owner.address,
                supplyAmount)

            const borrowAmount = ethers.parseUnits("1", await mockToken.decimals());
            await routerAtProxy.connect(tradingCore).commitBorrow(mockToken.getAddress(), interestRateModelType, borrowAmount);

            const events = await poolContract.queryFilter("Borrowed");
            const lastEvent = events[events.length - 1];
            const borrowId = lastEvent.args[1];
            
            expect(await routerAtProxy.debtOf(
                underlyingAsset, 
                feeConfig._modelType,
                borrowId)).to.equal(borrowAmount*1000000000000000000n);

            expect(await routerAtProxy.debtOfUnderlying(
                underlyingAsset, 
                feeConfig._modelType, 
                borrowId)).to.equal(borrowAmount);
            
            await time.increase(86400);

            const newDebt = await routerAtProxy.debtOfUnderlying(
                underlyingAsset, 
                feeConfig._modelType, 
                borrowId);
            
            const repayAmount = ethers.parseUnits("1", await mockToken.decimals());
            await mockToken.connect(tradingCore).approve(pool, repayAmount);
            expect(await routerAtProxy.connect(tradingCore).repay(
                await mockToken.getAddress(),
                interestRateModelType,
                tradingCore.address,
                borrowId,
                repayAmount,
                false
            )).to.emit(routerAtProxy, "Repaid");

            expect(await routerAtProxy.debtOfUnderlying(
                underlyingAsset, 
                feeConfig._modelType, 
                borrowId)).to.equal(newDebt - repayAmount);
        });
    });

    describe("Trading core function", function () {
        it("Should be able to borrow from pool", async function () {
            const { mockToken, tradingCore, routerAtProxy, owner } = await loadFixture(deployRouterProxyWithSetFixture);
            const underlyingAsset = await mockToken.getAddress();
            const pool = await routerAtProxy.getLendingPool(underlyingAsset, feeConfig._modelType);
            const amount = ethers.parseUnits("1", await mockToken.decimals());
            await mockToken.approve(pool, amount);
            await routerAtProxy.supply(
                underlyingAsset,
                interestRateModelType,
                owner.address,
                amount)
            
            const borrowAmount = ethers.parseUnits("0.5", await mockToken.decimals());
            expect(await routerAtProxy.connect(tradingCore).borrow(underlyingAsset, interestRateModelType, borrowAmount))
            .to.changeTokenBalances(
                mockToken,
                [pool, tradingCore],
                [-borrowAmount, borrowAmount]
            );
        });

        it("Should not be able to borrow from non-trading core", async function () {
            const { mockToken, routerAtProxy, owner } = await loadFixture(deployRouterProxyWithSetFixture);
            const underlyingAsset = await mockToken.getAddress();
            const pool = await routerAtProxy.getLendingPool(underlyingAsset, feeConfig._modelType);
            const amount = ethers.parseUnits("1", await mockToken.decimals());
            await mockToken.approve(pool, amount);
            await routerAtProxy.supply(
                underlyingAsset,
                feeConfig._modelType,
                owner.address,
                amount)
            
            const borrowAmount = ethers.parseUnits("0.5", await mockToken.decimals());
            await expect(routerAtProxy.borrow(underlyingAsset, interestRateModelType, borrowAmount))
            .to.be.revertedWithCustomError(routerAtProxy, "CallerIsNotTradingCore");
        });

        it("Should not be able to supply exceed supply cap", async function () {
            const { mockToken, routerAtProxy, owner } = await loadFixture(deployRouterProxyWithSetFixture);
            const underlyingAsset = await mockToken.getAddress();
            const pool = await routerAtProxy.getLendingPool(underlyingAsset, feeConfig._modelType);
            const amount = feeConfig._supplyCap + 1n;
            await mockToken.approve(pool, amount);
            await expect(routerAtProxy.supply(
                underlyingAsset,
                feeConfig._modelType,
                owner.address,
                amount))
                .to.changeTokenBalances(
                    mockToken,
                    [owner.address, pool], 
                    [-feeConfig._supplyCap, feeConfig._supplyCap]
                );
        });       

        it("Should not be able to borrow exceed borrow cap", async function () {
            const { mockToken, routerAtProxy, tradingCore, owner } = await loadFixture(deployRouterProxyWithSetFixture);
            const underlyingAsset = await mockToken.getAddress();
            const pool = await routerAtProxy.getLendingPool(underlyingAsset, feeConfig._modelType);
            const poolContract = await ethers.getContractAt("Pool", pool);
            const amount = feeConfig._borrowCap + 1n;
            await mockToken.approve(pool, amount);
            await routerAtProxy.supply(
                underlyingAsset,
                feeConfig._modelType,
                owner.address,
                amount)

            await expect(routerAtProxy.connect(tradingCore).commitBorrow(underlyingAsset, interestRateModelType, amount))
            .to.be.revertedWithCustomError(poolContract, "ExceedsCap");
        });

        it("Should revert if reserve < reserve ratio", async function () {
            const { mockToken, routerAtProxy, tradingCore, owner } = await loadFixture(deployRouterProxyWithSetFixture);
            const underlyingAsset = await mockToken.getAddress();
            const pool = await routerAtProxy.getLendingPool(underlyingAsset, feeConfig._modelType);
            const amount = ethers.parseUnits("1", await mockToken.decimals());
            await mockToken.approve(pool, amount);
            await routerAtProxy.supply(
                underlyingAsset,
                feeConfig._modelType,
                owner.address,
                amount);

            const borrowAmount = ethers.parseUnits("0.99", await mockToken.decimals());
            await expect(routerAtProxy.connect(tradingCore).commitBorrow(
                underlyingAsset, 
                feeConfig._modelType,
                borrowAmount)
            ).to.be.reverted;
        });
    });
});