// Deploy AgentEarningsVault.sol to 0G Newton testnet
//
//   cd Project/contracts
//   npx hardhat run scripts/deploy-vault.js --network newton
//
// Required env vars:
//   PRIVATE_KEY            — deployer EOA private key
//   AGENT_REGISTRY_ADDRESS — defaults to canonical mainnet (Newton) address

const hre = require("hardhat");

const DEFAULT_AGENT_REGISTRY = "0x4c49D008E72eF1E098Bcd6E75857Ed17377dB4ab";

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const agentRegistry = process.env.AGENT_REGISTRY_ADDRESS || DEFAULT_AGENT_REGISTRY;
  console.log("AgentRegistry:", agentRegistry);

  const Factory  = await hre.ethers.getContractFactory("AgentEarningsVault");
  const contract = await Factory.deploy(agentRegistry);
  await contract.waitForDeployment();

  const addr = await contract.getAddress();
  console.log("\n[OK] AgentEarningsVault deployed:");
  console.log("   address:", addr);
  console.log("   scan:    https://scan-testnet.0g.ai/address/" + addr);
  console.log("\nNext steps:");
  console.log("   1. Update Project/frontend/src/lib/contracts.ts -> CONTRACT_ADDRESSES.AgentEarningsVault");
  console.log("   2. Run: node scripts/sync-abis.js  (regenerates Project/frontend/src/lib/abis/)");
  console.log("   3. Verify: npx hardhat verify --network newton", addr, agentRegistry);
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
