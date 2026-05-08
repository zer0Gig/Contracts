/**
 * Gas Baseline Measurement Script (ERC-721 era)
 *
 * Records gas costs for all major operations in the CURRENT (pre-migration)
 * contracts. Output is written to deployments/gas-baseline.json so that
 * post-migration measurements can be diffed against it.
 *
 * Usage:  npx hardhat run scripts/gas-baseline.js
 *
 * Created: 2026-04-27
 */

const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const { ethers } = hre;

const SKILL_CODER     = ethers.id("skill:coder");
const SKILL_RESEARCHER = ethers.id("skill:researcher");
const SKILL_WRITER    = ethers.id("skill:writer");
const SKILL_TRADER    = ethers.id("skill:trader");
const SKILL_DESIGNER  = ethers.id("skill:designer");
const SKILL_ANALYST   = ethers.id("skill:analyst");

async function bench(label, txPromise) {
  const tx = await txPromise;
  const receipt = await tx.wait();
  const gas = Number(receipt.gasUsed);
  console.log(`  ${label.padEnd(38)} ${gas.toLocaleString().padStart(10)} gas`);
  return gas;
}

async function main() {
  const [deployer, client, agentOwner, agentWallet, alignmentVerifier, otherUser] =
    await ethers.getSigners();

  console.log("─".repeat(70));
  console.log("GAS BASELINE — Current ERC-721 Contracts");
  console.log("─".repeat(70));

  const results = {
    capturedAt: new Date().toISOString(),
    network: hre.network.name,
    solcVersion: "0.8.20",
    optimizerRuns: 200,
    viaIR: true,
    contracts: {
      AgentRegistry: { deploy: 0, ops: {} },
      ProgressiveEscrow: { deploy: 0, ops: {} },
      SubscriptionEscrow: { deploy: 0, ops: {} },
    },
  };

  // ─── Deploy AgentRegistry ────────────────────────────────────────────
  console.log("\n[Deploy] AgentRegistry...");
  const AgentRegistry = await ethers.getContractFactory("AgentRegistry");
  const registry = await AgentRegistry.deploy();
  const registryDeployTx = registry.deploymentTransaction();
  const registryDeployReceipt = await registryDeployTx.wait();
  results.contracts.AgentRegistry.deploy = Number(registryDeployReceipt.gasUsed);
  console.log(`  deploy gas: ${results.contracts.AgentRegistry.deploy.toLocaleString()}`);

  // ─── Deploy ProgressiveEscrow ────────────────────────────────────────
  console.log("\n[Deploy] ProgressiveEscrow...");
  const ProgressiveEscrow = await ethers.getContractFactory("ProgressiveEscrow");
  const progressive = await ProgressiveEscrow.deploy(
    await registry.getAddress(),
    alignmentVerifier.address
  );
  const progressiveDeployTx = progressive.deploymentTransaction();
  const progressiveDeployReceipt = await progressiveDeployTx.wait();
  results.contracts.ProgressiveEscrow.deploy = Number(progressiveDeployReceipt.gasUsed);
  console.log(`  deploy gas: ${results.contracts.ProgressiveEscrow.deploy.toLocaleString()}`);

  // ─── Deploy SubscriptionEscrow ───────────────────────────────────────
  console.log("\n[Deploy] SubscriptionEscrow...");
  const SubscriptionEscrow = await ethers.getContractFactory("SubscriptionEscrow");
  const subscription = await SubscriptionEscrow.deploy(await registry.getAddress());
  const subscriptionDeployTx = subscription.deploymentTransaction();
  const subscriptionDeployReceipt = await subscriptionDeployTx.wait();
  results.contracts.SubscriptionEscrow.deploy = Number(subscriptionDeployReceipt.gasUsed);
  console.log(`  deploy gas: ${results.contracts.SubscriptionEscrow.deploy.toLocaleString()}`);

  // ─── Authorize escrows ───────────────────────────────────────────────
  await (await registry.addEscrowContract(await progressive.getAddress())).wait();
  await (await registry.addEscrowContract(await subscription.getAddress())).wait();

  // ─── AgentRegistry operations ────────────────────────────────────────
  console.log("\n[AgentRegistry operations]");
  const profileCID = "QmExampleProfile12345678901234567890";
  const capabilityCID = "QmExampleCapability1234567890123456";

  results.contracts.AgentRegistry.ops.mintAgent_5skills = await bench(
    "mintAgent (5 initial skills)",
    registry.connect(agentOwner).mintAgent(
      ethers.parseEther("0.01"),         // defaultRate
      profileCID,
      capabilityCID,
      [SKILL_CODER, SKILL_RESEARCHER, SKILL_WRITER, SKILL_TRADER, SKILL_DESIGNER],
      agentWallet.address,
      "0x04abcdef"
    )
  );

  results.contracts.AgentRegistry.ops.mintAgent_0skills = await bench(
    "mintAgent (0 skills, 2nd agent)",
    registry.connect(agentOwner).mintAgent(
      ethers.parseEther("0.02"),
      profileCID,
      capabilityCID,
      [],
      otherUser.address,
      "0x04abcdef"
    )
  );

  results.contracts.AgentRegistry.ops.addSkill = await bench(
    "addSkill (cold)",
    registry.connect(agentOwner).addSkill(1, SKILL_ANALYST)
  );

  results.contracts.AgentRegistry.ops.removeSkill = await bench(
    "removeSkill",
    registry.connect(agentOwner).removeSkill(1, SKILL_ANALYST)
  );

  results.contracts.AgentRegistry.ops.updateProfileCID = await bench(
    "updateProfileCID",
    registry.connect(agentOwner).updateProfileCID(1, "QmNewProfileCID")
  );

  results.contracts.AgentRegistry.ops.toggleActive = await bench(
    "toggleActive",
    registry.connect(agentOwner).toggleActive(1)
  );
  // toggle back so other tests work
  await (await registry.connect(agentOwner).toggleActive(1)).wait();

  results.contracts.AgentRegistry.ops.updateCapabilities = await bench(
    "updateCapabilities (add 1, remove 1)",
    registry.connect(agentOwner).updateCapabilities(
      1,
      "QmUpdatedCapability",
      [SKILL_ANALYST],
      [SKILL_DESIGNER]
    )
  );

  // ─── ProgressiveEscrow operations ────────────────────────────────────
  console.log("\n[ProgressiveEscrow operations]");
  const proposalRate = ethers.parseEther("0.5");

  results.contracts.ProgressiveEscrow.ops.postJob = await bench(
    "postJob",
    progressive.connect(client).postJob(
      "QmJobBriefCID12345",
      SKILL_CODER
    )
  );

  results.contracts.ProgressiveEscrow.ops.submitProposal = await bench(
    "submitProposal",
    progressive.connect(agentOwner).submitProposal(
      1,
      1,
      proposalRate,
      "QmProposalDescriptionCID"
    )
  );

  results.contracts.ProgressiveEscrow.ops.acceptProposal = await bench(
    "acceptProposal (with budget)",
    progressive.connect(client).acceptProposal(1, 0, { value: proposalRate })
  );

  const milestonePercents = [25, 25, 25, 25];
  const milestoneCriteriaHashes = [
    ethers.id("milestone:1"),
    ethers.id("milestone:2"),
    ethers.id("milestone:3"),
    ethers.id("milestone:4"),
  ];

  results.contracts.ProgressiveEscrow.ops.defineMilestones_4 = await bench(
    "defineMilestones (4 milestones)",
    progressive.connect(client).defineMilestones(
      1,
      milestonePercents,
      milestoneCriteriaHashes
    )
  );

  // releaseMilestone needs valid alignment verifier signature
  const milestoneIndex = 0;
  const outputCID = "QmOutputCID";
  const alignmentScore = 8500n;
  const messageHash = ethers.solidityPackedKeccak256(
    ["uint256", "uint8", "uint256", "string"],
    [1, milestoneIndex, alignmentScore, outputCID]
  );
  const signature = await alignmentVerifier.signMessage(ethers.getBytes(messageHash));

  results.contracts.ProgressiveEscrow.ops.releaseMilestone_approve = await bench(
    "releaseMilestone (approve, score=8500)",
    progressive.connect(agentWallet).releaseMilestone(
      1,
      milestoneIndex,
      outputCID,
      alignmentScore,
      signature
    )
  );

  // ─── SubscriptionEscrow operations ───────────────────────────────────
  console.log("\n[SubscriptionEscrow operations]");
  const checkInRate = ethers.parseEther("0.001");
  const alertRate = ethers.parseEther("0.0005");
  const budget = ethers.parseEther("0.5");

  results.contracts.SubscriptionEscrow.ops.createSubscription = await bench(
    "createSubscription (Mode A, x402 disabled)",
    subscription.connect(client).createSubscription(
      1,                                 // agentId
      "Daily crypto price alerts",
      86400,                             // intervalSeconds (1 day)
      checkInRate,
      alertRate,
      0,                                 // gracePeriodSeconds (use default)
      false,                             // x402Enabled
      0,                                 // x402VerificationMode
      "0x",                              // clientX402Sig
      "",                                // webhookUrl
      { value: budget }
    )
  );

  results.contracts.SubscriptionEscrow.ops.topUp = await bench(
    "topUp",
    subscription.connect(client).topUp(1, { value: ethers.parseEther("0.1") })
  );

  // Advance time so drainPerCheckIn can succeed (interval = 1 day)
  await ethers.provider.send("evm_increaseTime", [86401]);
  await ethers.provider.send("evm_mine", []);

  results.contracts.SubscriptionEscrow.ops.drainPerCheckIn = await bench(
    "drainPerCheckIn",
    subscription.connect(agentWallet).drainPerCheckIn(1)
  );

  results.contracts.SubscriptionEscrow.ops.drainPerAlert = await bench(
    "drainPerAlert",
    subscription.connect(agentWallet).drainPerAlert(1, "0xdeadbeef")
  );

  results.contracts.SubscriptionEscrow.ops.cancelSubscription = await bench(
    "cancelSubscription",
    subscription.connect(client).cancelSubscription(1)
  );

  // ─── Save results ────────────────────────────────────────────────────
  const outputDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(outputDir)) fs.mkdirSync(outputDir, { recursive: true });

  const outPath = path.join(outputDir, "gas-baseline.json");
  fs.writeFileSync(outPath, JSON.stringify(results, null, 2));

  console.log("\n─".repeat(70));
  console.log(`✅ Baseline saved → ${outPath}`);
  console.log("─".repeat(70));

  // Print summary table
  console.log("\nSummary (all gas values in wei units, just numbers):");
  for (const [contractName, data] of Object.entries(results.contracts)) {
    console.log(`\n${contractName}:`);
    console.log(`  deploy: ${data.deploy.toLocaleString()}`);
    for (const [op, gas] of Object.entries(data.ops)) {
      console.log(`  ${op.padEnd(40)} ${gas.toLocaleString()}`);
    }
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
