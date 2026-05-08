const hre = require("hardhat");

// Deployed on 0G Newton Testnet
const AGENT_REGISTRY_ADDRESS = "0x4c49D008E72eF1E098Bcd6E75857Ed17377dB4ab";

// Oracle wallet generated for iTransfer/iClone signing
const ORACLE_ADDRESS = "0x01A9badBf4F691e9A23c8014E758De48a5A947C1";

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Caller wallet:    ", deployer.address);
  console.log("AgentRegistry:    ", AGENT_REGISTRY_ADDRESS);
  console.log("Oracle address:   ", ORACLE_ADDRESS);

  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log("Balance:          ", hre.ethers.formatEther(balance), "OG\n");

  const AgentRegistry = await hre.ethers.getContractFactory("AgentRegistry");
  const registry = AgentRegistry.attach(AGENT_REGISTRY_ADDRESS);

  // Read current oracle before update
  const currentOracle = await registry.oracle();
  console.log("Current oracle:   ", currentOracle);

  if (currentOracle.toLowerCase() === ORACLE_ADDRESS.toLowerCase()) {
    console.log("Oracle already set correctly. Nothing to do.");
    return;
  }

  console.log("Calling setOracle()...");
  const tx = await registry.setOracle(ORACLE_ADDRESS);
  console.log("Tx hash:          ", tx.hash);
  await tx.wait();
  console.log("Confirmed.");

  const newOracle = await registry.oracle();
  console.log("New oracle:       ", newOracle);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
