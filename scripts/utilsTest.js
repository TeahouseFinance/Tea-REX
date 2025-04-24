// test utils.js
// Teahouse Finance

const { ethers } = require("hardhat");
const tRexUtils = require("./utils.js");
const { use } = require("chai");
const { createPositionalIdentifier } = require("typechain");


// contract addresses
// these are alpha version deployed on SEI EVM
const TRADING_CORE = '0x99c2901d2883F8D295A989544f118e31eC21823e';
const UNISWAPV3_ROUTER_PROCESSOR = '0x970aEC8673771acbfce93931BA5c0047E92c2dbe';

// DragonSwap
const UNISWAPV3_ROUTER = '0x11DA6463D6Cb5a03411Dbf5ab6f6bc3997Ac7428';
const UNISWAPV3_ROUTER_FEE = 3000;

// token addresses
const BASE_TOKEN = '0x3894085Ef7Ff0f0aeDf52E2A2704928d1Ec074F1';    // USDC
const TARGET_TOKEN = '0x0555E30da8f98308EdB960aa94C0Db47230d2B9c';    // WBTC
//const TARGET_TOKEN = '0x160345fC359604fC6e70E3c5fAcbdE5F7A9342d8';      // WETH
//const TARGET_TOKEN = '0xE30feDd158A2e3b13e9badaeABaFc5516e95e8C7';      // WSEI


async function initContracts() {

    const tradingCore = await ethers.getContractAt("TradingCore", TRADING_CORE);
    const baseToken = await ethers.getContractAt("MockToken", BASE_TOKEN);
    const targetToken = await ethers.getContractAt("MockToken", TARGET_TOKEN);

    return { tradingCore, baseToken, targetToken };
}


// test open long position
async function testOpenLongPosition(tradingCore, user, baseToken, targetToken, marginAmount, swapFunction) {
    // check if allowance is large enough
    const allowance = await baseToken.allowance(user, tradingCore);
    if (allowance < marginAmount) {
        const tx = await baseToken.connect(user).approve(tradingCore, marginAmount);
        await tx.wait();
    }    

    const leverage = 5000n; // 5X leverage
    const tx = await tRexUtils.openLongPosition(tradingCore, user, baseToken.target, targetToken.target, marginAmount, leverage, 0n, swapFunction);
    await tx.wait();
}


// test open short position
async function testOpenShortPosition(tradingCore, user, baseToken, targetToken, marginAmount, swapFunction) {
    // check if allowance is large enough
    const allowance = await baseToken.allowance(user, tradingCore);
    if (allowance < marginAmount) {
        const tx = await baseToken.connect(user).approve(tradingCore, marginAmount);
        await tx.wait();
    }    

    const leverage = 5000n; // 5X leverage
    const tx = await tRexUtils.openShortPosition(tradingCore, user, baseToken.target, targetToken.target, marginAmount, leverage, 0n, swapFunction);
    await tx.wait();
}


async function main() {

    const [user] = await ethers.getSigners();
    const { tradingCore, baseToken, targetToken } = await initContracts();

    const baseDecimals = await baseToken.decimals();
    const marginAmount = ethers.parseUnits("1", baseDecimals);

    const swapper = tRexUtils.uniswapV3Swapper(UNISWAPV3_ROUTER, UNISWAPV3_ROUTER_FEE, UNISWAPV3_ROUTER_PROCESSOR);

    // test open long position
    // await testOpenLongPosition(tradingCore, user, baseToken, targetToken, marginAmount, swapper);

    // test open short position
    // await testOpenShortPosition(tradingCore, user, baseToken, targetToken, marginAmount, swapper);

    // test estimate position value
    // note it's required to use a tradingCore with ethers.provider as runner to avoid a mismatched 'from' address
    // const positionId = 372;
    // const value = await tRexUtils.estimatePositionValue(tradingCore.connect(ethers.provider), baseToken.target, targetToken.target, positionId, swapper);
    // console.log(value);

    // test close position
    // const positionId = 373;
    // await tRexUtils.closePosition(tradingCore, user, baseToken.target, targetToken.target, positionId, 0, swapper);
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
