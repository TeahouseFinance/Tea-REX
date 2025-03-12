const { ethers, upgrades } = require("hardhat");

function loadEnvVar(env, errorMsg) {
    if (env == undefined) {
        throw errorMsg;
    }

    return env;
}

const beacon = loadEnvVar(process.env.POOL_BEACON, "No POOL_BEACON");

async function main() {
    const Pool = await ethers.getContractFactory("Pool");
    await upgrades.upgradeBeacon(beacon, Pool);
    console.log("Beacon upgraded:", beacon);
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});