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
        const interestRateModel = await interestRateModelSample.deploy();
        await interestRateModel.waitForDeployment();
        // console.log("InterestRateModel deployed to:", await interestRateModel.getAddress());

        return { owner, tradingCore, feeTreasury, user, interestRateModel, routerAtProxy };
    }

    async function deployERC20Fixture() {
        const [owner] = await ethers.getSigners();
        const MockERC20 = await ethers.getContractFactory("MockToken");
        const initialSupply = 10_000_000;
        const mockToken = await MockERC20.deploy(owner, "Mock", "Mock", initialSupply, 6);
        await mockToken.waitForDeployment();
        // console.log("MockToken deployed to:", await mockToken.getAddress());

        return { mockToken };
      }

    async function deployRouterProxyWithSetFixture() {
        const { owner, tradingCore, feeTreasury, user, interestRateModel, routerAtProxy } = await deployRouterProxyFixture();
        const { mockToken } = await deployERC20Fixture(owner); 
        const borrow_fee = 10_000;

        await routerAtProxy.setInterestRateModel(interestRateModelType, await interestRateModel.getAddress());
        await routerAtProxy.setTradingCore(await tradingCore.address);
        await routerAtProxy.setFeeConfig(await feeTreasury.address, borrow_fee);
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
            const { feeTreasury, routerAtProxy } = await loadFixture(deployRouterProxyFixture);

            const borrowFee = 10_000;
            await routerAtProxy.setFeeConfig(feeTreasury.address, borrowFee);

            const [feeReceiver, fee] = await routerAtProxy.getFeeConfig();

            expect(feeReceiver).to.equal(feeTreasury.address);
            expect(fee).to.equal(borrowFee);
        });

        it("Should revert if the fee config set with invalid borrow fee", async function () {
            const { feeTreasury, routerAtProxy } = await loadFixture(deployRouterProxyFixture);
            
            const borrowFee = FEE_CAP + 1;
            await expect(routerAtProxy.setFeeConfig(feeTreasury.address, borrowFee))
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
            const borrowFee = 100_000;
            // We can increase the time in Hardhat Network
            await expect(routerAtProxy.connect(user).pause())
            .to.be.revertedWithCustomError(routerAtProxy, "OwnableUnauthorizedAccount");

            await expect(routerAtProxy.connect(user).unpause())
            .to.be.revertedWithCustomError(routerAtProxy, "OwnableUnauthorizedAccount");

            await expect(routerAtProxy.connect(user).setTradingCore(await tradingCore.address))
            .to.be.revertedWithCustomError(routerAtProxy, "OwnableUnauthorizedAccount");

            await expect(routerAtProxy.connect(user).setFeeConfig(await feeTreasury.address, borrowFee))
            .to.be.revertedWithCustomError(routerAtProxy, "OwnableUnauthorizedAccount");

            await expect(routerAtProxy.connect(user).setInterestRateModel(interestRateModelType, await interestRateModel.getAddress()))
            .to.be.revertedWithCustomError(routerAtProxy, "OwnableUnauthorizedAccount");        
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
            expect(await mockToken.balanceOf(tradingCore.address)).to.equal(amount);

            await mockToken.connect(tradingCore).approve(pool, amount);
            expect(await routerAtProxy.connect(tradingCore).supply(
                underlyingAsset,
                feeConfig._modelType,
                tradingCore.address,
                amount
            )).to.emit(routerAtProxy, "Supplied")
            .withArgs(tradingCore.address, tradingCore.address, underlyingAsset, anyValue);

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
            
            await expect(routerAtProxy.connect(tradingCore).withdraw(
                underlyingAsset,
                feeConfig._modelType,
                tradingCore.address,
                amount*1000000000000000000n
            )).to.changeTokenBalances(
                mockToken, 
                [pool, tradingCore], 
                [-amount, amount]
            );
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