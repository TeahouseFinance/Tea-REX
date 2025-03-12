const { ethers, upgrades } = require("hardhat");

function loadEnvVar(env, errorMsg) {
    if (env == undefined) {
        throw errorMsg;
    }

    return env;
}

const tradingCoreProxy = loadEnvVar(process.env.TRADING_CORE_PROXY, "No TRADING_CORE_PROXY");

async function main() {
    const TradingCore = await ethers.getContractFactory("TradingCore");
    await upgrades.upgradeProxy(tradingCoreProxy, TradingCore, {
        kind: "uups",
        unsafeAllow: ["delegatecall"],
    });
    console.log("TradingCore upgraded:", tradingCoreProxy);
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
