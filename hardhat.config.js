require("dotenv").config();
require("@nomicfoundation/hardhat-toolbox");
require("@nomicfoundation/hardhat-verify");
require("hardhat-contract-sizer");
require('@openzeppelin/hardhat-upgrades');

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.26",
    settings: {
      viaIR: true,
      optimizer: {
        enabled: true,
        runs: 200,
      }
    },
  },
  networks: {
    hardhat: {
      allowUnlimitedContractSize: true,
    },
    sepolia: {
      url: process.env.SEPOLIA_URL || "",
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },
    arb: {
      url: process.env.ARB_URL || "",
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },
    op: {
      url: process.env.OP_URL || "",
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },
    poly: {
      url: process.env.POLY_URL || "",
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },
    base: {
      url: process.env.BASE_URL || "",
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },
    linea: {
      url: process.env.LINEA_URL || "",
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },
    bsc: {
      url: process.env.BSC_URL || "",
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    }
  },
  etherscan: {
    apiKey: {
      sepolia: process.env.SEPOLIA_API_KEY,
      arbitrumOne: process.env.ARB_API_KEY,
      optimisticEthereum: process.env.OP_API_KEY,
      polygon: process.env.POLY_API_KEY,
      base: process.env.BASE_API_KEY,
      linea: process.env.LINEA_API_KEY,
      bsc: process.env.BSC_API_KEY,
    },
    customChains: [
      {
        network: "linea",
        chainId: 59144,
        urls: {
          apiURL: "https://api.lineascan.build/api",
          browserURL: "https://lineascan.build",
        },
      }
    ]
  },
  sourcify: {
    enabled: false
  },
};
