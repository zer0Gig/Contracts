// Deploy AgentMarketplace.sol to 0G Newton testnet
//
//   cd Project/contracts
//   npx hardhat run scripts/deploy-marketplace.js --network newton
//
// Required env vars:
//   PRIVATE_KEY            — deployer EOA private key
//   AGENT_REGISTRY_ADDRESS — already deployed, defaults to canonical
//   TREASURY_ADDRESS       — receives 2.5% protocol fees (defaults to deployer)

const hre = require("hardhat");

const DEFAULT_AGENT_REGISTRY = "0x4c49D008E72eF1E098Bcd6E75857Ed17377dB4ab";

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const agentRegistry = process.env.AGENT_REGISTRY_ADDRESS || DEFAULT_AGENT_REGISTRY;
  const treasury      = process.env.TREASURY_ADDRESS || deployer.address;

  console.log("AgentRegistry:", agentRegistry);
  console.log("Treasury:",      treasury);

  const Factory = await hre.ethers.getContractFactory("AgentMarketplace");
  const contract = await Factory.deploy(agentRegistry, treasury);
  await contract.waitForDeployment();

  const addr = await contract.getAddress();
  console.log("\n✅ AgentMarketplace deployed:");
  console.log("   address:", addr);
  console.log("   scan:    https://scan-testnet.0g.ai/address/" + addr);
  console.log("\nNext steps:");
  console.log("   1. Update Project/frontend/src/lib/contracts.ts → CONTRACT_ADDRESSES.AgentMarketplace");
  console.log("   2. Verify: npx hardhat verify --network newton", addr, agentRegistry, treasury);
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
