/**
 * Contract Verification Script for 0G Newton Testnet
 * 
 * Uses the chainscan-galileo.0g.ai API endpoint which is confirmed working.
 * Run: npx hardhat run scripts/verify.js --network newton
 */

const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  console.log("╔══════════════════════════════════════════════════╗");
  console.log("║  zer0Gig Contract Verification                   ║");
  console.log("║  Network: 0G Newton Testnet (Chain ID: 16602)    ║");
  console.log("╚══════════════════════════════════════════════════╝\n");

  // Load deployed addresses
  const deploymentsPath = path.join(__dirname, "../deployments/newton.json");
  if (!fs.existsSync(deploymentsPath)) {
    throw new Error("deployments/newton.json not found. Deploy contracts first.");
  }

  const deployments = JSON.parse(fs.readFileSync(deploymentsPath, "utf8"));
  
  console.log("Deployed Addresses:");
  console.log("  AgentRegistry:      ", deployments.AgentRegistry);
  console.log("  ProgressiveEscrow:  ", deployments.ProgressiveEscrow);
  console.log("  SubscriptionEscrow: ", deployments.SubscriptionEscrow);
  console.log("  UserRegistry:       ", deployments.UserRegistry);
  console.log("  AlignmentVerifier:  ", deployments.AlignmentNodeVerifier);
  console.log();

  const results = {
    AgentRegistry: false,
    ProgressiveEscrow: false,
    SubscriptionEscrow: false,
    UserRegistry: false,
  };

  // 1. Verify AgentRegistry (no constructor args)
  console.log("[1/4] Verifying AgentRegistry...");
  try {
    await hre.run("verify:verify", {
      address: deployments.AgentRegistry,
      constructorArguments: [],
    });
    console.log("  ✅ AgentRegistry verified!\n");
    results.AgentRegistry = true;
  } catch (err) {
    if (err.message.includes("Already Verified") || err.message.includes("already verified")) {
      console.log("  ✅ AgentRegistry already verified!\n");
      results.AgentRegistry = true;
    } else {
      console.log("  ❌ Failed:", err.message.slice(0, 100), "\n");
    }
  }

  // 2. Verify ProgressiveEscrow (constructor: agentRegistry, alignmentVerifier)
  console.log("[2/4] Verifying ProgressiveEscrow...");
  try {
    await hre.run("verify:verify", {
      address: deployments.ProgressiveEscrow,
      constructorArguments: [
        deployments.AgentRegistry,
        deployments.AlignmentNodeVerifier,
      ],
    });
    console.log("  ✅ ProgressiveEscrow verified!\n");
    results.ProgressiveEscrow = true;
  } catch (err) {
    if (err.message.includes("Already Verified") || err.message.includes("already verified")) {
      console.log("  ✅ ProgressiveEscrow already verified!\n");
      results.ProgressiveEscrow = true;
    } else {
      console.log("  ❌ Failed:", err.message.slice(0, 100), "\n");
    }
  }

  // 3. Verify SubscriptionEscrow (constructor: agentRegistry)
  console.log("[3/4] Verifying SubscriptionEscrow...");
  try {
    await hre.run("verify:verify", {
      address: deployments.SubscriptionEscrow,
      constructorArguments: [deployments.AgentRegistry],
    });
    console.log("  ✅ SubscriptionEscrow verified!\n");
    results.SubscriptionEscrow = true;
  } catch (err) {
    if (err.message.includes("Already Verified") || err.message.includes("already verified")) {
      console.log("  ✅ SubscriptionEscrow already verified!\n");
      results.SubscriptionEscrow = true;
    } else {
      console.log("  ❌ Failed:", err.message.slice(0, 100), "\n");
    }
  }

  // 4. Verify UserRegistry (no constructor args)
  console.log("[4/4] Verifying UserRegistry...");
  try {
    await hre.run("verify:verify", {
      address: deployments.UserRegistry,
      constructorArguments: [],
    });
    console.log("  ✅ UserRegistry verified!\n");
    results.UserRegistry = true;
  } catch (err) {
    if (err.message.includes("Already Verified") || err.message.includes("already verified")) {
      console.log("  ✅ UserRegistry already verified!\n");
      results.UserRegistry = true;
    } else {
      console.log("  ❌ Failed:", err.message.slice(0, 100), "\n");
    }
  }

  // Summary
  console.log("═══════════════════════════════════════════════════════");
  console.log("  Verification Summary");
  console.log("═══════════════════════════════════════════════════════");
  
  const verified = Object.values(results).filter(Boolean).length;
  const total = Object.keys(results).length;
  
  for (const [contract, success] of Object.entries(results)) {
    const status = success ? "✅" : "❌";
    const addr = deployments[contract];
    console.log(`  ${status} ${contract}`);
    console.log(`     https://chainscan-galileo.0g.ai/address/${addr}`);
  }
  
  console.log();
  console.log(`  Total: ${verified}/${total} contracts verified`);
  console.log("═══════════════════════════════════════════════════════\n");
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
