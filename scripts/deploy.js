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
  let alignmentNodeVerifier = process.env.ALIGNMENT_NODE_VERIFIER || deployer.address;
  try {
    alignmentNodeVerifier = hre.ethers.getAddress(alignmentNodeVerifier);
  } catch {
    console.log("Invalid ALIGNMENT_NODE_VERIFIER, using deployer address as placeholder");
    alignmentNodeVerifier = deployer.address;
  }
  console.log("\n--- Deploying ProgressiveEscrow ---");
  console.log("Using Alignment Node Verifier:", alignmentNodeVerifier);

  const ProgressiveEscrow = await hre.ethers.getContractFactory("ProgressiveEscrow");
  const escrow = await ProgressiveEscrow.deploy(registryAddress, alignmentNodeVerifier);
  await escrow.waitForDeployment();
  const escrowAddress = await escrow.getAddress();
  console.log("ProgressiveEscrow deployed to:", escrowAddress);

  // --- 3. Link: AgentRegistry.addEscrowContract() ---
  console.log("\n--- Linking AgentRegistry ↔ ProgressiveEscrow ---");
  const linkTx = await agentRegistry.addEscrowContract(escrowAddress);
  await linkTx.wait();
  console.log("AgentRegistry authorized escrow:", escrowAddress);

  // --- 4. Deploy SubscriptionEscrow (TIER 3) ---
  console.log("\n--- Deploying SubscriptionEscrow ---");
  const SubscriptionEscrow = await hre.ethers.getContractFactory("SubscriptionEscrow");
  const subscriptionEscrow = await SubscriptionEscrow.deploy(registryAddress);
  await subscriptionEscrow.waitForDeployment();
  const subscriptionEscrowAddress = await subscriptionEscrow.getAddress();
  console.log("SubscriptionEscrow deployed to:", subscriptionEscrowAddress);

  // --- 5. Link SubscriptionEscrow to AgentRegistry ---
  const subLinkTx = await agentRegistry.addEscrowContract(subscriptionEscrowAddress);
  await subLinkTx.wait();
  console.log("AgentRegistry authorized escrow:", subscriptionEscrowAddress);

  // --- 6. Deploy UserRegistry ---
  console.log("\n--- Deploying UserRegistry ---");
  const UserRegistry = await hre.ethers.getContractFactory("UserRegistry");
  const userRegistry = await UserRegistry.deploy();
  await userRegistry.waitForDeployment();
  const userRegistryAddress = await userRegistry.getAddress();
  console.log("UserRegistry deployed to:", userRegistryAddress);

  // --- 7. Save deployment info ---
  const deployment = {
    AgentRegistry: registryAddress,
    ProgressiveEscrow: escrowAddress,
    SubscriptionEscrow: subscriptionEscrowAddress,
    UserRegistry: userRegistryAddress,
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
