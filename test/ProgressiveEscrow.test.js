const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("ProgressiveEscrow", function () {
  let agentRegistry, escrow;
  let deployer, client, majikan, agentWallet, alignmentSigner;

  const AGENT_TYPE_CODER = 1;
  const BASE_RATE = ethers.parseEther("0.01");
  const RESUME_CID = "QmTestResumeCID";
  const ECIES_PUB_KEY = "0x04abcdef";
  const JOB_DATA_CID = "QmJobDataCID123";
  const OUTPUT_CID = "QmOutputCID456";
  const JOB_BUDGET = ethers.parseEther("1.0");

  beforeEach(async function () {
    [deployer, client, majikan, agentWallet, alignmentSigner] = await ethers.getSigners();

    // Deploy AgentRegistry
    const AgentRegistry = await ethers.getContractFactory("AgentRegistry");
    agentRegistry = await AgentRegistry.deploy();
    await agentRegistry.waitForDeployment();

    // Deploy ProgressiveEscrow
    const ProgressiveEscrow = await ethers.getContractFactory("ProgressiveEscrow");
    escrow = await ProgressiveEscrow.deploy(
      await agentRegistry.getAddress(),
      alignmentSigner.address
    );
    await escrow.waitForDeployment();

    // Link: AgentRegistry ↔ ProgressiveEscrow
    await agentRegistry.setEscrowContract(await escrow.getAddress());

    // Mint an agent (by majikan)
    await agentRegistry.connect(majikan).mintAgent(
      AGENT_TYPE_CODER,
      BASE_RATE,
      RESUME_CID,
      agentWallet.address,
      ECIES_PUB_KEY
    );
  });

  // Helper: sign alignment node message
  async function signAlignment(jobId, milestoneIndex, score, outputCID) {
    const messageHash = ethers.solidityPackedKeccak256(
      ["uint256", "uint8", "uint256", "string"],
      [jobId, milestoneIndex, score, outputCID]
    );
    return alignmentSigner.signMessage(ethers.getBytes(messageHash));
  }

  describe("createJob()", function () {
    it("should create a job and emit JobCreated event", async function () {
      await expect(
        escrow.connect(client).createJob(1, JOB_DATA_CID, { value: JOB_BUDGET })
      )
        .to.emit(escrow, "JobCreated")
        .withArgs(1, client.address, 1, JOB_BUDGET, JOB_DATA_CID);
    });

    it("should store job details correctly", async function () {
      await escrow.connect(client).createJob(1, JOB_DATA_CID, { value: JOB_BUDGET });

      const job = await escrow.getJob(1);
      expect(job.client).to.equal(client.address);
      expect(job.agentId).to.equal(1);
      expect(job.agentWallet).to.equal(agentWallet.address);
      expect(job.totalBudgetWei).to.equal(JOB_BUDGET);
      expect(job.status).to.equal(0); // PENDING_MILESTONES
    });

    it("should revert with 0 value", async function () {
      await expect(
        escrow.connect(client).createJob(1, JOB_DATA_CID, { value: 0 })
      ).to.be.revertedWith("ProgressiveEscrow: budget harus > 0");
    });
  });

  describe("defineMilestones()", function () {
    beforeEach(async function () {
      await escrow.connect(client).createJob(1, JOB_DATA_CID, { value: JOB_BUDGET });
    });

    it("should define milestones and change status to IN_PROGRESS", async function () {
      const percentages = [40, 30, 30];
      const criteriaHashes = [
        ethers.keccak256(ethers.toUtf8Bytes("criteria1")),
        ethers.keccak256(ethers.toUtf8Bytes("criteria2")),
        ethers.keccak256(ethers.toUtf8Bytes("criteria3")),
      ];

      await expect(
        escrow.connect(client).defineMilestones(1, percentages, criteriaHashes)
      ).to.emit(escrow, "MilestoneDefined").withArgs(1, 3);

      const job = await escrow.getJob(1);
      expect(job.status).to.equal(1); // IN_PROGRESS
    });

    it("should revert if percentages don't sum to 100", async function () {
      await expect(
        escrow.connect(client).defineMilestones(
          1,
          [40, 30, 20], // sum = 90
          [ethers.ZeroHash, ethers.ZeroHash, ethers.ZeroHash]
        )
      ).to.be.revertedWith("ProgressiveEscrow: total persentase harus 100");
    });

    it("should revert if called by non-client", async function () {
      await expect(
        escrow.connect(majikan).defineMilestones(
          1,
          [100],
          [ethers.ZeroHash]
        )
      ).to.be.revertedWith("ProgressiveEscrow: bukan klien");
    });
  });

  describe("releaseMilestone()", function () {
    beforeEach(async function () {
      await escrow.connect(client).createJob(1, JOB_DATA_CID, { value: JOB_BUDGET });
      await escrow.connect(client).defineMilestones(
        1,
        [50, 50],
        [
          ethers.keccak256(ethers.toUtf8Bytes("criteria1")),
          ethers.keccak256(ethers.toUtf8Bytes("criteria2")),
        ]
      );
    });

    it("should approve milestone with valid signature and score >= 8000", async function () {
      const score = 8500;
      const signature = await signAlignment(1, 0, score, OUTPUT_CID);

      const agentBalanceBefore = await ethers.provider.getBalance(agentWallet.address);

      await expect(
        escrow.connect(agentWallet).releaseMilestone(1, 0, OUTPUT_CID, score, signature)
      )
        .to.emit(escrow, "MilestoneApproved")
        .withArgs(1, 0, JOB_BUDGET / 2n, score);

      // Agent should have received 50% of budget
      const agentBalanceAfter = await ethers.provider.getBalance(agentWallet.address);
      // Account for gas costs — balance should increase significantly
      expect(agentBalanceAfter).to.be.gt(agentBalanceBefore);
    });

    it("should reject milestone with valid signature and score < 8000", async function () {
      const score = 5000;
      const signature = await signAlignment(1, 0, score, OUTPUT_CID);

      await expect(
        escrow.connect(agentWallet).releaseMilestone(1, 0, OUTPUT_CID, score, signature)
      )
        .to.emit(escrow, "MilestoneRejected")
        .withArgs(1, 0, JOB_BUDGET / 2n, score);
    });

    it("should revert with invalid signature", async function () {
      const score = 9000;
      // Sign with wrong signer (client instead of alignmentSigner)
      const messageHash = ethers.solidityPackedKeccak256(
        ["uint256", "uint8", "uint256", "string"],
        [1, 0, score, OUTPUT_CID]
      );
      const badSignature = await client.signMessage(ethers.getBytes(messageHash));

      await expect(
        escrow.connect(agentWallet).releaseMilestone(1, 0, OUTPUT_CID, score, badSignature)
      ).to.be.revertedWith("ProgressiveEscrow: signature tidak valid");
    });

    it("should revert if called by non-agentWallet", async function () {
      const score = 9000;
      const signature = await signAlignment(1, 0, score, OUTPUT_CID);

      await expect(
        escrow.connect(client).releaseMilestone(1, 0, OUTPUT_CID, score, signature)
      ).to.be.revertedWith("ProgressiveEscrow: hanya agentWallet");
    });

    it("should mark job as COMPLETED when all milestones approved", async function () {
      // Approve milestone 0
      const sig0 = await signAlignment(1, 0, 9000, OUTPUT_CID);
      await escrow.connect(agentWallet).releaseMilestone(1, 0, OUTPUT_CID, 9000, sig0);

      // Approve milestone 1
      const sig1 = await signAlignment(1, 1, 8500, "QmOutput2");
      await escrow.connect(agentWallet).releaseMilestone(1, 1, "QmOutput2", 8500, sig1);

      const job = await escrow.getJob(1);
      expect(job.status).to.equal(2); // COMPLETED
    });
  });
});
