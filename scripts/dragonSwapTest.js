// test script for DragonSwap mixed V1/V2 swaps

const { ethers } = require("hardhat");

const SWAP_ROUTER = '0x11DA6463D6Cb5a03411Dbf5ab6f6bc3997Ac7428';  // UniswapV3 Router
const SRC_TOKEN = '0x3894085Ef7Ff0f0aeDf52E2A2704928d1Ec074F1'; // USDC
const TARGET_TOKEN = '0x0a526e425809aEA71eb279d24ae22Dee6C92A4Fe'; // DRG
const INTER_TOKEN = '0xE30feDd158A2e3b13e9badaeABaFc5516e95e8C7'; // WSEI

const ADDRESS_THIS = '0x' + '0'.repeat(39) + '2';
const AMOUNT = 100000;

async function main() {

    [owner] = await ethers.getSigners();

    const router = await ethers.getContractAt("ISwapRouter02", SWAP_ROUTER);

    const srcToken = await ethers.getContractAt("MockToken", SRC_TOKEN);
    const targetToken = await ethers.getContractAt("MockToken", TARGET_TOKEN);
    let srcBalance = await srcToken.balanceOf(owner);
    let targetBalance = await targetToken.balanceOf(owner);
    console.log("source token balance:", srcBalance);
    console.log("target token balance:", targetBalance);

    const srcAllowance = await srcToken.allowance(router, owner);
    if (srcAllowance < AMOUNT) {
        const tx = await srcToken.approve(router, AMOUNT);
        await tx.wait();
    }
    
    // swap SRC_TOKEN to TARGET_TOKEN using INTER_TOKEN as intermediate, SRC to INTER with V2 and INTER to TARGET with V1
    console.log("swap SRC to TARGET");
    const swapSrcToInter = router.interface.encodeFunctionData(
        "exactInput",
        [[
            ethers.solidityPacked([ "address", "uint24", "address" ], [ SRC_TOKEN, 3000, INTER_TOKEN ]),
            ADDRESS_THIS,
            AMOUNT,
            0,
        ]]
    );

    const swapInterToTarget = router.interface.encodeFunctionData(
        "swapExactTokensForTokens",
        [
            0, // use 0 as amount for all tokens in the contract
            0,
            [ INTER_TOKEN, TARGET_TOKEN ],
            owner.address
        ]
    );

    // const multicallData = router.interface.encodeFunctionData(
    //     "multicall(bytes[])",
    //     [[
    //         swapSrcToInter,
    //         swapInterToTarget,
    //     ]]
    // );
    // console.log("multicallData:", multicallData);

    let tx = await router.multicall([ swapSrcToInter, swapInterToTarget ]);
    await tx.wait();

    // display balances
    srcBalance = await srcToken.balanceOf(owner);
    targetBalance = await targetToken.balanceOf(owner);
    console.log("source token balance:", srcBalance);
    console.log("target token balance:", targetBalance);

    const targetAllowance = await targetToken.allowance(router, owner);
    if (targetAllowance < targetBalance) {
        const tx = await targetToken.approve(router, targetBalance);
        await tx.wait();
    }

    // swap TARGET_TOKEN back to SRC_TOKEN using INTER_TOKEN as intermediate    
    console.log("swap TARGET to SRC");
    const swapTargetToInter = router.interface.encodeFunctionData(
        "swapExactTokensForTokens",
        [
            targetBalance, 
            0,
            [ TARGET_TOKEN, INTER_TOKEN ],
            ADDRESS_THIS,
        ]
    );

    const swapInterToSrc = router.interface.encodeFunctionData(
        "exactInput",
        [[
            ethers.solidityPacked([ "address", "uint24", "address" ], [ INTER_TOKEN, 3000, SRC_TOKEN ]),
            owner.address,
            0, // use 0 as amount for all tokens in the contract
            0,
        ]]
    );

    tx = await router.multicall([ swapTargetToInter, swapInterToSrc ]);
    await tx.wait();

    // display balances
    srcBalance = await srcToken.balanceOf(owner);
    targetBalance = await targetToken.balanceOf(owner);
    console.log("source token balance:", srcBalance);
    console.log("target token balance:", targetBalance);
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
