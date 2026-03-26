require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
    },
  },

  networks: {
    // Local development
    hardhat: {
      chainId: 31337,
    },

    // 0G Newton Testnet
    newton: {
      url: process.env.OG_NEWTON_RPC_URL || "https://rpc-testnet.0g.ai",
      chainId: 16600,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      gasPrice: "auto",
      timeout: 60000,
    },
  },

  etherscan: {
    apiKey: {
      newton: process.env.OG_EXPLORER_API_KEY || "empty",
    },
    customChains: [
      {
        network: "newton",
        chainId: 16600,
        urls: {
          apiURL: "https://scan-testnet.0g.ai/api",
          browserURL: "https://scan-testnet.0g.ai",
        },
      },
    ],
  },

  paths: {
    sources: "./src",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
};
