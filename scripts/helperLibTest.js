// tester script for HelperLib.js

const { ethers, upgrades } = require("hardhat");


const ZERO_ADDRESS = '0x' + '0'.repeat(40);

async function deployContracts() {
    const [ owner, treasury, user ] = await ethers.getSigners();

    const VariableInterestRateModel = await ethers.getContractFactory("VariableInterestRateModel");
    const variableInterestRateModel = await VariableInterestRateModel.deploy();

    const Pool = await ethers.getContractFactory("Pool");
    const poolBeacon = await upgrades.deployBeacon(Pool);

    const Router = await ethers.getContractFactory("Router");
    const router = await upgrades.deployProxy(
        Router,
        [ owner.address, poolBeacon.target, 200000 ]    // fee cap at 20%
    );

    const SwapRelayer = await ethers.getContractFactory("SwapRelayer");
    const swapRelayer = await SwapRelayer.deploy(owner);

    const UniswapV3Processor = await ethers.getContractFactory("UniswapV3Processor");
    const uniswapV3Processor = await UniswapV3Processor.deploy();

    const UniswapV3TwapOracle = await ethers.getContractFactory("UniswapV3TwapOracle");
    const uniswapV3TwapOracle = await UniswapV3TwapOracle.deploy(owner, baseAsset);

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
                tradingFee: tradingFee,
                liquidationFee: liquidationFee
            },
            ZERO_ADDRESS
        ]
    );    
}

async function main() {

    await deployContracts();
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
