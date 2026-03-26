const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  console.log("Account balance:", (await hre.ethers.provider.getBalance(deployer.address)).toString());

  // --- 1. Deploy AgentRegistry ---
  console.log("\n--- Deploying AgentRegistry ---");
  const AgentRegistry = await hre.ethers.getContractFactory("AgentRegistry");
  const agentRegistry = await AgentRegistry.deploy();
  await agentRegistry.waitForDeployment();
  const registryAddress = await agentRegistry.getAddress();
  console.log("AgentRegistry deployed to:", registryAddress);

  // --- 2. Deploy ProgressiveEscrow ---
  // Alignment Node Verifier: gunakan env var atau deployer address sebagai placeholder
  const alignmentNodeVerifier = process.env.ALIGNMENT_NODE_VERIFIER || deployer.address;
  console.log("\n--- Deploying ProgressiveEscrow ---");
  console.log("Using Alignment Node Verifier:", alignmentNodeVerifier);

  const ProgressiveEscrow = await hre.ethers.getContractFactory("ProgressiveEscrow");
  const escrow = await ProgressiveEscrow.deploy(registryAddress, alignmentNodeVerifier);
  await escrow.waitForDeployment();
  const escrowAddress = await escrow.getAddress();
  console.log("ProgressiveEscrow deployed to:", escrowAddress);

  // --- 3. Link: AgentRegistry.setEscrowContract() ---
  console.log("\n--- Linking AgentRegistry ↔ ProgressiveEscrow ---");
  const linkTx = await agentRegistry.setEscrowContract(escrowAddress);
  await linkTx.wait();
  console.log("AgentRegistry.escrowContract set to:", escrowAddress);

  // --- 4. Save deployment info ---
  const deployment = {
    AgentRegistry: registryAddress,
    ProgressiveEscrow: escrowAddress,
    AlignmentNodeVerifier: alignmentNodeVerifier,
    chainId: (await hre.ethers.provider.getNetwork()).chainId.toString(),
    deployer: deployer.address,
    deployedAt: new Date().toISOString(),
  };

  const outputPath = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(outputPath)) {
    fs.mkdirSync(outputPath, { recursive: true });
  }

  const networkName = hre.network.name;
  const filePath = path.join(outputPath, `${networkName}.json`);
  fs.writeFileSync(filePath, JSON.stringify(deployment, null, 2));
  console.log(`\nDeployment info saved to: ${filePath}`);
  console.log(JSON.stringify(deployment, null, 2));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
