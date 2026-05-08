require("@nomicfoundation/hardhat-toolbox");
require("@nomicfoundation/hardhat-verify");
require("dotenv").config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 800,           // Optimize for frequent calls (txn cost) over deploy size
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
      chainId: 16602,
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
        chainId: 16602,
        urls: {
          apiURL: "https://chainscan-galileo.0g.ai/open/api",
          browserURL: "https://chainscan-galileo.0g.ai",
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
