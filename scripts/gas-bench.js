/**
 * Gas Benchmark Script (ERC-7857 / ERC-8183 era)
 *
 * Records gas costs for the migrated contracts and compares against the
 * baseline captured by gas-baseline.json.
 *
 * Usage:  npx hardhat run scripts/gas-bench.js
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

  // Oracle keypair for ERC-7857 transfers
  const oracleSigner = ethers.Wallet.createRandom().connect(ethers.provider);
  // Fund the oracle (only used for view-side, but useful)
  await deployer.sendTransaction({ to: oracleSigner.address, value: ethers.parseEther("1") });

  console.log("─".repeat(70));
  console.log("GAS BENCHMARK — Migrated ERC-7857 / ERC-8183 Contracts");
  console.log("─".repeat(70));

  const results = {
    capturedAt: new Date().toISOString(),
    network: hre.network.name,
    solcVersion: "0.8.20",
    optimizerRuns: 800,
    viaIR: true,
    contracts: {
      AgentRegistry: { deploy: 0, ops: {} },
      ProgressiveEscrow: { deploy: 0, ops: {} },
      SubscriptionEscrow: { deploy: 0, ops: {} },
    },
  };

  // ─── Deploy AgentRegistry ────────────────────────────────────────────
  console.log("\n[Deploy] AgentRegistry (ERC-7857)...");
  const AgentRegistry = await ethers.getContractFactory("AgentRegistry");
  const registry = await AgentRegistry.deploy();
  const registryDeployTx = registry.deploymentTransaction();
  const registryDeployReceipt = await registryDeployTx.wait();
  results.contracts.AgentRegistry.deploy = Number(registryDeployReceipt.gasUsed);
  console.log(`  deploy gas: ${results.contracts.AgentRegistry.deploy.toLocaleString()}`);

  // setOracle
  await (await registry.setOracle(oracleSigner.address)).wait();

  // ─── Deploy ProgressiveEscrow ────────────────────────────────────────
  console.log("\n[Deploy] ProgressiveEscrow...");
  const ProgressiveEscrow = await ethers.getContractFactory("ProgressiveEscrow");
  const progressive = await ProgressiveEscrow.deploy(
    await registry.getAddress(),
    alignmentVerifier.address
  );
  const progressiveDeployReceipt = await progressive.deploymentTransaction().wait();
  results.contracts.ProgressiveEscrow.deploy = Number(progressiveDeployReceipt.gasUsed);
  console.log(`  deploy gas: ${results.contracts.ProgressiveEscrow.deploy.toLocaleString()}`);

  // ─── Deploy SubscriptionEscrow ───────────────────────────────────────
  console.log("\n[Deploy] SubscriptionEscrow...");
  const SubscriptionEscrow = await ethers.getContractFactory("SubscriptionEscrow");
  const subscription = await SubscriptionEscrow.deploy(await registry.getAddress());
  const subscriptionDeployReceipt = await subscription.deploymentTransaction().wait();
  results.contracts.SubscriptionEscrow.deploy = Number(subscriptionDeployReceipt.gasUsed);
  console.log(`  deploy gas: ${results.contracts.SubscriptionEscrow.deploy.toLocaleString()}`);

  // Authorize escrows
  await (await registry.addEscrowContract(await progressive.getAddress())).wait();
  await (await registry.addEscrowContract(await subscription.getAddress())).wait();

  // ─── AgentRegistry operations ────────────────────────────────────────
  console.log("\n[AgentRegistry operations]");
  const profileHash = ethers.keccak256(ethers.toUtf8Bytes("Profile blob"));
  const capabilityHash = ethers.keccak256(ethers.toUtf8Bytes("Capability blob"));
  const eciesPubKey = "0x04" + "ab".repeat(32); // 65 bytes typical secp256k1 pubkey
  const sealedKey = "0x" + "cd".repeat(96);     // ~96 bytes ECIES-sealed AES key

  // defaultRate is uint32 in 0.01-OG units (so e.g., 10 = 0.1 OG)
  const defaultRateUnits = 10;

  results.contracts.AgentRegistry.ops.mintAgent_5skills = await bench(
    "mintAgent (5 initial skills)",
    registry.connect(agentOwner).mintAgent(
      defaultRateUnits,
      profileHash,
      capabilityHash,
      [SKILL_CODER, SKILL_RESEARCHER, SKILL_WRITER, SKILL_TRADER, SKILL_DESIGNER],
      agentWallet.address,
      eciesPubKey,
      sealedKey
    )
  );

  results.contracts.AgentRegistry.ops.mintAgent_0skills = await bench(
    "mintAgent (0 skills, 2nd agent)",
    registry.connect(agentOwner).mintAgent(
      defaultRateUnits * 2,
      profileHash,
      capabilityHash,
      [],
      otherUser.address,
      eciesPubKey,
      sealedKey
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

  const newProfileHash = ethers.keccak256(ethers.toUtf8Bytes("New profile"));
  results.contracts.AgentRegistry.ops.updateProfileHash = await bench(
    "updateProfileHash",
    registry.connect(agentOwner).updateProfileHash(1, newProfileHash)
  );

  results.contracts.AgentRegistry.ops.toggleActive = await bench(
    "toggleActive",
    registry.connect(agentOwner).toggleActive(1)
  );
  await (await registry.connect(agentOwner).toggleActive(1)).wait(); // toggle back

  // updateCapability — owner-only re-seal
  const newCapHash = ethers.keccak256(ethers.toUtf8Bytes("Capability v2"));
  const newSealed = "0x" + "ef".repeat(96);
  results.contracts.AgentRegistry.ops.updateCapability = await bench(
    "updateCapability",
    registry.connect(agentOwner).updateCapability(1, newCapHash, newSealed)
  );

  // updateSkillSet (analogous to old updateCapabilities)
  const newCapHash2 = ethers.keccak256(ethers.toUtf8Bytes("Capability v3"));
  results.contracts.AgentRegistry.ops.updateSkillSet = await bench(
    "updateSkillSet (add 1, remove 1)",
    registry.connect(agentOwner).updateSkillSet(
      1,
      newCapHash2,
      [SKILL_ANALYST],
      [SKILL_DESIGNER]
    )
  );

  // ─── ERC-7857 specific operations ────────────────────────────────────
  console.log("\n[ERC-7857 INFT operations]");

  // Helper: build oracle proof for iTransfer
  // Contract uses abi.encode (NOT abi.encodePacked) → use defaultAbiCoder
  async function buildProof(agentId, version, oldHash, newHash, to) {
    const network = await ethers.provider.getNetwork();
    const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint256", "address", "uint256", "uint16", "bytes32", "bytes32", "address"],
      [network.chainId, await registry.getAddress(), agentId, version, oldHash, newHash, to]
    );
    const inner = ethers.keccak256(encoded);
    return await oracleSigner.signMessage(ethers.getBytes(inner));
  }

  // iTransfer: transfer agent #2 (the simpler, 0-skill agent) to client
  const agent2 = await registry.getAgentProfile(2);
  const transferOldHash = agent2.capabilityHash;
  const transferNewHash = ethers.keccak256(ethers.toUtf8Bytes("Re-encrypted for client"));
  const transferSealedKey = "0x" + "11".repeat(96);
  const transferProof = await buildProof(2, agent2.version, transferOldHash, transferNewHash, client.address);

  results.contracts.AgentRegistry.ops.iTransfer = await bench(
    "iTransfer (with oracle ECDSA proof)",
    registry.connect(agentOwner).iTransfer(2, client.address, transferNewHash, transferSealedKey, transferProof)
  );

  // iClone: clone agent #1 (5-skill agent) to otherUser
  const agent1 = await registry.getAgentProfile(1);
  const cloneNewHash = ethers.keccak256(ethers.toUtf8Bytes("Cloned + re-sealed"));
  const cloneSealedKey = "0x" + "22".repeat(96);
  const cloneProof = await buildProof(1, agent1.version, agent1.capabilityHash, cloneNewHash, otherUser.address);

  results.contracts.AgentRegistry.ops.iClone_5skills = await bench(
    "iClone (5 skills copied)",
    registry.connect(agentOwner).iClone(1, otherUser.address, cloneNewHash, cloneSealedKey, cloneProof)
  );

  // authorizeUsage (1 day duration, simple permissionsHash)
  const permsHash = ethers.keccak256(ethers.toUtf8Bytes("perms:tools:web,email"));
  results.contracts.AgentRegistry.ops.authorizeUsage = await bench(
    "authorizeUsage (1 day)",
    registry.connect(agentOwner).authorizeUsage(1, otherUser.address, 86400, permsHash)
  );

  results.contracts.AgentRegistry.ops.revokeUsage = await bench(
    "revokeUsage",
    registry.connect(agentOwner).revokeUsage(1, otherUser.address)
  );

  results.contracts.AgentRegistry.ops.delegateAccess = await bench(
    "delegateAccess",
    registry.connect(agentOwner).delegateAccess(client.address)
  );

  // ─── ProgressiveEscrow operations ────────────────────────────────────
  console.log("\n[ProgressiveEscrow operations]");
  const proposalRate = ethers.parseEther("0.5");

  // bytes32 hash forms now (no more string CIDs on-chain)
  const jobDataHash = ethers.keccak256(ethers.toUtf8Bytes("QmJobBriefCID12345"));
  const proposalDescHash = ethers.keccak256(ethers.toUtf8Bytes("QmProposalDescriptionCID"));

  results.contracts.ProgressiveEscrow.ops.postJob = await bench(
    "postJob",
    progressive.connect(client).postJob(jobDataHash, SKILL_CODER)
  );

  results.contracts.ProgressiveEscrow.ops.submitProposal = await bench(
    "submitProposal",
    progressive.connect(agentOwner).submitProposal(
      1, 1, proposalRate, proposalDescHash
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
    progressive.connect(client).defineMilestones(1, milestonePercents, milestoneCriteriaHashes)
  );

  // releaseMilestone — first milestone, agentWallet signs
  const milestoneIndex = 0;
  const outputHash = ethers.keccak256(ethers.toUtf8Bytes("QmOutputCID"));
  const alignmentScore = 8500;
  // Contract uses abi.encode (NOT abi.encodePacked) — match exactly
  const releaseEncoded = ethers.AbiCoder.defaultAbiCoder().encode(
    ["uint256", "uint8", "uint16", "bytes32"],
    [1, milestoneIndex, alignmentScore, outputHash]
  );
  const releaseMessageHash = ethers.keccak256(releaseEncoded);
  const releaseSig = await alignmentVerifier.signMessage(ethers.getBytes(releaseMessageHash));

  results.contracts.ProgressiveEscrow.ops.releaseMilestone_approve = await bench(
    "releaseMilestone (approve, score=8500)",
    progressive.connect(agentWallet).releaseMilestone(
      1, milestoneIndex, outputHash, alignmentScore, releaseSig
    )
  );

  // ─── SubscriptionEscrow operations ───────────────────────────────────
  console.log("\n[SubscriptionEscrow operations]");
  const checkInRate = ethers.parseEther("0.001");
  const alertRate = ethers.parseEther("0.0005");
  const budget = ethers.parseEther("0.5");

  const taskHash = ethers.keccak256(ethers.toUtf8Bytes("Daily crypto price alerts"));
  const webhookHash = ethers.ZeroHash;

  results.contracts.SubscriptionEscrow.ops.createSubscription = await bench(
    "createSubscription (Mode A, x402 disabled)",
    subscription.connect(client).createSubscription(
      1, taskHash, 86400, checkInRate, alertRate, 0,
      false, 0, "0x", webhookHash,
      { value: budget }
    )
  );

  results.contracts.SubscriptionEscrow.ops.topUp = await bench(
    "topUp",
    subscription.connect(client).topUp(1, { value: ethers.parseEther("0.1") })
  );

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

  // ─── Save results + diff against baseline ────────────────────────────
  const outputDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(outputDir)) fs.mkdirSync(outputDir, { recursive: true });

  const outPath = path.join(outputDir, "gas-optimized.json");
  fs.writeFileSync(outPath, JSON.stringify(results, null, 2));

  console.log("\n─".repeat(70));
  console.log(`✅ Optimized results → ${outPath}`);

  // Diff against baseline
  const baselinePath = path.join(outputDir, "gas-baseline.json");
  if (!fs.existsSync(baselinePath)) {
    console.log("⚠ No baseline found at deployments/gas-baseline.json — skipping diff");
    return;
  }

  const baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));

  console.log("\n" + "═".repeat(78));
  console.log("DIFF — Baseline (ERC-721) → Optimized (ERC-7857/8183)");
  console.log("═".repeat(78));
  console.log("Function                                  Baseline    Optimized   Delta");
  console.log("─".repeat(78));

  for (const [contractName, data] of Object.entries(results.contracts)) {
    const baseDeploy = baseline.contracts[contractName]?.deploy ?? 0;
    const optDeploy = data.deploy;
    const deployDelta = baseDeploy ? ((optDeploy - baseDeploy) / baseDeploy) * 100 : 0;
    console.log(`${(contractName + " deploy").padEnd(40)}  ${baseDeploy.toLocaleString().padStart(10)}  ${optDeploy.toLocaleString().padStart(10)}  ${deployDelta.toFixed(1).padStart(6)}%`);

    for (const [op, optGas] of Object.entries(data.ops)) {
      const baseGas = baseline.contracts[contractName]?.ops?.[op] ?? 0;
      if (baseGas === 0) {
        console.log(`  ${op.padEnd(38)}        N/A  ${optGas.toLocaleString().padStart(10)}    NEW`);
      } else {
        const delta = ((optGas - baseGas) / baseGas) * 100;
        const deltaStr = delta.toFixed(1).padStart(6) + "%";
        const indicator = delta < -30 ? "✅" : delta < -10 ? "🟢" : delta < 5 ? "≈" : "⚠️";
        console.log(`  ${op.padEnd(38)}  ${baseGas.toLocaleString().padStart(10)}  ${optGas.toLocaleString().padStart(10)}  ${deltaStr}  ${indicator}`);
      }
    }
  }
  console.log("═".repeat(78));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
