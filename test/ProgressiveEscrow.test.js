// ProgressiveEscrow tests — packed Job/Milestone, ERC-8183 wrapper, alignment node sig.
//
// Created: 2026-04-27

const { expect } = require("chai");
const { ethers } = require("hardhat");

const SKILL_CODER = ethers.id("skill:coder");

describe("ProgressiveEscrow (ERC-8183 compliant)", function () {
  let registry, escrow, alignmentVerifier;
  let owner, client, agentOwner, agentWallet, otherAgent, alice;

  const eciesPubKey = "0x04" + "ab".repeat(32);
  const sealedKey = "0x" + "cd".repeat(96);
  const profileHash = ethers.keccak256(ethers.toUtf8Bytes("profile"));
  const capabilityHash = ethers.keccak256(ethers.toUtf8Bytes("capability"));

  beforeEach(async function () {
    [owner, client, agentOwner, agentWallet, otherAgent, alice] = await ethers.getSigners();
    alignmentVerifier = ethers.Wallet.createRandom().connect(ethers.provider);

    const Registry = await ethers.getContractFactory("AgentRegistry");
    registry = await Registry.deploy();

    const Escrow = await ethers.getContractFactory("ProgressiveEscrow");
    escrow = await Escrow.deploy(await registry.getAddress(), alignmentVerifier.address);
    await registry.addEscrowContract(await escrow.getAddress());

    // Mint agent #1 with SKILL_CODER
    await registry.connect(agentOwner).mintAgent(
      10, profileHash, capabilityHash, [SKILL_CODER],
      agentWallet.address, eciesPubKey, sealedKey
    );
  });

  async function signAlignment(jobId, milestoneIndex, score, outputHash) {
    const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint256", "uint8", "uint16", "bytes32"],
      [jobId, milestoneIndex, score, outputHash]
    );
    const inner = ethers.keccak256(encoded);
    return await alignmentVerifier.signMessage(ethers.getBytes(inner));
  }

  // ─── postJob ──────────────────────────────────────────────────────────
  describe("postJob", function () {
    it("creates job with id 1, OPEN status", async function () {
      const jobHash = ethers.keccak256(ethers.toUtf8Bytes("job-brief"));
      await escrow.connect(client).postJob(jobHash, SKILL_CODER);

      const job = await escrow.getJob(1);
      expect(job.client).to.equal(client.address);
      expect(job.status).to.equal(0); // OPEN
      expect(job.skillId).to.equal(SKILL_CODER);
      expect(job.jobDataHash).to.equal(jobHash);
    });

    it("emits JobPosted and ERC-8183 JobCreated", async function () {
      const jobHash = ethers.keccak256(ethers.toUtf8Bytes("evt"));
      await expect(escrow.connect(client).postJob(jobHash, SKILL_CODER))
        .to.emit(escrow, "JobPosted")
        .withArgs(1n, client.address, SKILL_CODER, jobHash)
        .and.to.emit(escrow, "JobCreated");
    });

    it("appends to client jobs and open jobs", async function () {
      await escrow.connect(client).postJob(ethers.keccak256("0xabcdef"), SKILL_CODER);
      expect(await escrow.getClientJobs(client.address)).to.deep.equal([1n]);
      expect(await escrow.getOpenJobs()).to.deep.equal([1n]);
    });

    it("reverts on zero jobDataHash", async function () {
      await expect(
        escrow.connect(client).postJob(ethers.ZeroHash, SKILL_CODER)
      ).to.be.revertedWithCustomError(escrow, "ZeroHash");
    });
  });

  // ─── submitProposal ───────────────────────────────────────────────────
  describe("submitProposal", function () {
    let descHash;
    beforeEach(async function () {
      await escrow.connect(client).postJob(ethers.keccak256("0xaa"), SKILL_CODER);
      descHash = ethers.keccak256(ethers.toUtf8Bytes("proposal-desc"));
    });

    it("appends proposal", async function () {
      const rate = ethers.parseEther("0.5");
      await escrow.connect(agentOwner).submitProposal(1, 1, rate, descHash);

      const proposals = await escrow.getProposals(1);
      expect(proposals).to.have.lengthOf(1);
      expect(proposals[0].agentId).to.equal(1);
      expect(proposals[0].agentOwner).to.equal(agentOwner.address);
      expect(proposals[0].proposedRateWei).to.equal(rate);
      expect(proposals[0].accepted).to.be.false;
    });

    it("emits ProposalSubmitted", async function () {
      const rate = ethers.parseEther("0.3");
      await expect(
        escrow.connect(agentOwner).submitProposal(1, 1, rate, descHash)
      ).to.emit(escrow, "ProposalSubmitted")
        .withArgs(1n, 0n, 1n, rate);
    });

    it("reverts when proposing for inactive agent", async function () {
      await registry.connect(agentOwner).toggleActive(1);
      await expect(
        escrow.connect(agentOwner).submitProposal(1, 1, ethers.parseEther("0.1"), descHash)
      ).to.be.revertedWithCustomError(escrow, "AgentInactive");
    });

    it("reverts when caller is not agent owner", async function () {
      await expect(
        escrow.connect(alice).submitProposal(1, 1, ethers.parseEther("0.1"), descHash)
      ).to.be.revertedWithCustomError(escrow, "NotAgentOwner");
    });

    it("reverts when agent missing required skill", async function () {
      await registry.connect(agentOwner).mintAgent(
        10, profileHash, capabilityHash, [],
        otherAgent.address, eciesPubKey, sealedKey
      );
      await expect(
        escrow.connect(agentOwner).submitProposal(1, 2, ethers.parseEther("0.1"), descHash)
      ).to.be.revertedWithCustomError(escrow, "AgentMissingSkill");
    });

    it("reverts on zero rate", async function () {
      await expect(
        escrow.connect(agentOwner).submitProposal(1, 1, 0, descHash)
      ).to.be.revertedWithCustomError(escrow, "ZeroRate");
    });
  });

  // ─── acceptProposal ───────────────────────────────────────────────────
  describe("acceptProposal", function () {
    const rate = ethers.parseEther("0.5");

    beforeEach(async function () {
      await escrow.connect(client).postJob(ethers.keccak256("0xbb"), SKILL_CODER);
      await escrow.connect(agentOwner).submitProposal(1, 1, rate, ethers.ZeroHash);
    });

    it("accepts proposal, sets PENDING_MILESTONES", async function () {
      await escrow.connect(client).acceptProposal(1, 0, { value: rate });
      const job = await escrow.getJob(1);
      expect(job.status).to.equal(1); // PENDING_MILESTONES
      expect(job.totalBudgetWei).to.equal(rate);
      expect(job.agentId).to.equal(1);
      expect(job.agentWallet).to.equal(agentWallet.address);
    });

    it("emits ProposalAccepted and ERC-8183 JobFunded", async function () {
      await expect(escrow.connect(client).acceptProposal(1, 0, { value: rate }))
        .to.emit(escrow, "ProposalAccepted")
        .withArgs(1n, 0n, 1n, rate)
        .and.to.emit(escrow, "JobFunded")
        .withArgs(1n, agentWallet.address, rate);
    });

    it("removes from open jobs list", async function () {
      expect(await escrow.getOpenJobs()).to.deep.equal([1n]);
      await escrow.connect(client).acceptProposal(1, 0, { value: rate });
      expect(await escrow.getOpenJobs()).to.deep.equal([]);
    });

    it("reverts on value mismatch", async function () {
      await expect(
        escrow.connect(client).acceptProposal(1, 0, { value: rate * 2n })
      ).to.be.revertedWithCustomError(escrow, "ValueMismatch");
    });

    it("reverts when called by non-client", async function () {
      await expect(
        escrow.connect(alice).acceptProposal(1, 0, { value: rate })
      ).to.be.revertedWithCustomError(escrow, "NotClient");
    });

    it("reverts on duplicate acceptance", async function () {
      await escrow.connect(client).acceptProposal(1, 0, { value: rate });
      await expect(
        escrow.connect(client).acceptProposal(1, 0, { value: rate })
      ).to.be.revertedWithCustomError(escrow, "JobNotOpen");
    });
  });

  // ─── defineMilestones ─────────────────────────────────────────────────
  describe("defineMilestones", function () {
    const rate = ethers.parseEther("1.0");

    beforeEach(async function () {
      await escrow.connect(client).postJob(ethers.keccak256("0xcc"), SKILL_CODER);
      await escrow.connect(agentOwner).submitProposal(1, 1, rate, ethers.ZeroHash);
      await escrow.connect(client).acceptProposal(1, 0, { value: rate });
    });

    it("creates milestones with correct amounts", async function () {
      const percents = [25, 25, 50];
      const criteria = [ethers.id("c1"), ethers.id("c2"), ethers.id("c3")];
      await escrow.connect(client).defineMilestones(1, percents, criteria);

      const milestones = await escrow.getMilestones(1);
      expect(milestones).to.have.lengthOf(3);
      expect(milestones[0].amountWei).to.equal(rate * 25n / 100n);
      expect(milestones[2].amountWei).to.equal(rate * 50n / 100n);
      expect(milestones[0].criteriaHash).to.equal(criteria[0]);

      const job = await escrow.getJob(1);
      expect(job.status).to.equal(2); // IN_PROGRESS
      expect(job.milestoneCount).to.equal(3);
    });

    it("reverts when percentage sum != 100", async function () {
      await expect(
        escrow.connect(client).defineMilestones(1, [50, 30, 10], [ethers.id("c1"), ethers.id("c2"), ethers.id("c3")])
      ).to.be.revertedWithCustomError(escrow, "PercentageSumInvalid");
    });

    it("reverts on zero milestone count", async function () {
      await expect(
        escrow.connect(client).defineMilestones(1, [], [])
      ).to.be.revertedWithCustomError(escrow, "InvalidMilestoneCount");
    });

    it("reverts when array lengths mismatch", async function () {
      await expect(
        escrow.connect(client).defineMilestones(1, [50, 50], [ethers.id("c1")])
      ).to.be.revertedWithCustomError(escrow, "ArrayLengthMismatch");
    });

    it("reverts on percentage = 0", async function () {
      await expect(
        escrow.connect(client).defineMilestones(1, [50, 0, 50], [ethers.id("c1"), ethers.id("c2"), ethers.id("c3")])
      ).to.be.revertedWithCustomError(escrow, "PercentageNotZero");
    });

    it("reverts when called by non-client", async function () {
      await expect(
        escrow.connect(alice).defineMilestones(1, [100], [ethers.id("c1")])
      ).to.be.revertedWithCustomError(escrow, "NotClient");
    });
  });

  // ─── releaseMilestone ─────────────────────────────────────────────────
  describe("releaseMilestone", function () {
    const rate = ethers.parseEther("1.0");

    beforeEach(async function () {
      await escrow.connect(client).postJob(ethers.keccak256("0xdd"), SKILL_CODER);
      await escrow.connect(agentOwner).submitProposal(1, 1, rate, ethers.ZeroHash);
      await escrow.connect(client).acceptProposal(1, 0, { value: rate });
      await escrow.connect(client).defineMilestones(1, [50, 50], [ethers.id("c1"), ethers.id("c2")]);
    });

    it("approves milestone with score >= 8000 and transfers to agentWallet", async function () {
      const outputHash = ethers.keccak256(ethers.toUtf8Bytes("output"));
      const sig = await signAlignment(1, 0, 8500, outputHash);
      const balBefore = await ethers.provider.getBalance(agentWallet.address);

      await expect(
        escrow.connect(agentWallet).releaseMilestone(1, 0, outputHash, 8500, sig)
      ).to.emit(escrow, "MilestoneApproved")
        .withArgs(1n, 0n, rate / 2n, 8500)
        .and.to.emit(escrow, "JobSubmitted");

      const balAfter = await ethers.provider.getBalance(agentWallet.address);
      expect(balAfter).to.be.gt(balBefore + (rate / 2n) - ethers.parseEther("0.01"));

      const m = await escrow.getMilestone(1, 0);
      expect(m.status).to.equal(2); // APPROVED
    });

    it("rejects milestone with score < 8000 and refunds client", async function () {
      const outputHash = ethers.keccak256(ethers.toUtf8Bytes("low-score"));
      const sig = await signAlignment(1, 0, 7500, outputHash);
      const balBefore = await ethers.provider.getBalance(client.address);

      await expect(
        escrow.connect(agentWallet).releaseMilestone(1, 0, outputHash, 7500, sig)
      ).to.emit(escrow, "MilestoneRejected");

      const balAfter = await ethers.provider.getBalance(client.address);
      expect(balAfter).to.equal(balBefore + (rate / 2n));

      const m = await escrow.getMilestone(1, 0);
      expect(m.status).to.equal(3); // REJECTED
    });

    it("emits ERC-8183 JobTerminal when all milestones approved", async function () {
      const outputHash = ethers.keccak256(ethers.toUtf8Bytes("done"));
      const sig0 = await signAlignment(1, 0, 9000, outputHash);
      await escrow.connect(agentWallet).releaseMilestone(1, 0, outputHash, 9000, sig0);

      const sig1 = await signAlignment(1, 1, 9500, outputHash);
      await expect(
        escrow.connect(agentWallet).releaseMilestone(1, 1, outputHash, 9500, sig1)
      ).to.emit(escrow, "JobCompleted")
        .and.to.emit(escrow, "JobTerminal");

      const job = await escrow.getJob(1);
      expect(job.status).to.equal(3); // COMPLETED
    });

    it("rejects invalid alignment node signature", async function () {
      const fakeSigner = ethers.Wallet.createRandom();
      const outputHash = ethers.keccak256(ethers.toUtf8Bytes("hijack"));
      const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
        ["uint256", "uint8", "uint16", "bytes32"],
        [1, 0, 8500, outputHash]
      );
      const fakeSig = await fakeSigner.signMessage(ethers.getBytes(ethers.keccak256(encoded)));

      await expect(
        escrow.connect(agentWallet).releaseMilestone(1, 0, outputHash, 8500, fakeSig)
      ).to.be.revertedWithCustomError(escrow, "InvalidSignature");
    });

    it("reverts when caller is not agentWallet", async function () {
      const sig = await signAlignment(1, 0, 8500, ethers.ZeroHash);
      await expect(
        escrow.connect(alice).releaseMilestone(1, 0, ethers.ZeroHash, 8500, sig)
      ).to.be.revertedWithCustomError(escrow, "NotAgentWallet");
    });

    it("reverts on score > 10000", async function () {
      const sig = await signAlignment(1, 0, 10001, ethers.ZeroHash);
      await expect(
        escrow.connect(agentWallet).releaseMilestone(1, 0, ethers.ZeroHash, 10001, sig)
      ).to.be.revertedWithCustomError(escrow, "InvalidScore");
    });

    it("reverts on invalid milestone index", async function () {
      const sig = await signAlignment(1, 99, 8500, ethers.ZeroHash);
      await expect(
        escrow.connect(agentWallet).releaseMilestone(1, 99, ethers.ZeroHash, 8500, sig)
      ).to.be.revertedWithCustomError(escrow, "InvalidMilestoneIndex");
    });
  });

  // ─── cancelJob ────────────────────────────────────────────────────────
  describe("cancelJob", function () {
    it("cancels OPEN job, removes from open list", async function () {
      await escrow.connect(client).postJob(ethers.keccak256("0xee"), SKILL_CODER);
      await escrow.connect(client).cancelJob(1);

      const job = await escrow.getJob(1);
      expect(job.status).to.equal(4); // CANCELLED
      expect(await escrow.getOpenJobs()).to.deep.equal([]);
    });

    it("cancels PENDING_MILESTONES job and refunds client", async function () {
      const rate = ethers.parseEther("0.5");
      await escrow.connect(client).postJob(ethers.keccak256("0xff"), SKILL_CODER);
      await escrow.connect(agentOwner).submitProposal(1, 1, rate, ethers.ZeroHash);
      await escrow.connect(client).acceptProposal(1, 0, { value: rate });

      const balBefore = await ethers.provider.getBalance(client.address);
      const tx = await escrow.connect(client).cancelJob(1);
      const receipt = await tx.wait();
      const gasCost = receipt.gasUsed * receipt.gasPrice;
      const balAfter = await ethers.provider.getBalance(client.address);

      expect(balAfter).to.equal(balBefore - gasCost + rate);
    });

    it("emits JobCancelled and ERC-8183 JobTerminal", async function () {
      await escrow.connect(client).postJob(ethers.keccak256("0x1234"), SKILL_CODER);
      await expect(escrow.connect(client).cancelJob(1))
        .to.emit(escrow, "JobCancelled")
        .and.to.emit(escrow, "JobTerminal");
    });

    it("reverts when trying to cancel IN_PROGRESS job", async function () {
      const rate = ethers.parseEther("0.5");
      await escrow.connect(client).postJob(ethers.keccak256("0x5678"), SKILL_CODER);
      await escrow.connect(agentOwner).submitProposal(1, 1, rate, ethers.ZeroHash);
      await escrow.connect(client).acceptProposal(1, 0, { value: rate });
      await escrow.connect(client).defineMilestones(1, [100], [ethers.id("c1")]);

      await expect(
        escrow.connect(client).cancelJob(1)
      ).to.be.revertedWithCustomError(escrow, "JobNotCancellable");
    });
  });

  // ─── ERC-8183 view functions ──────────────────────────────────────────
  describe("ERC-8183 conformance", function () {
    it("evaluator() returns alignmentNodeVerifier", async function () {
      expect(await escrow.evaluator()).to.equal(alignmentVerifier.address);
    });

    it("getJobState maps correctly across lifecycle", async function () {
      const rate = ethers.parseEther("0.5");
      await escrow.connect(client).postJob(ethers.keccak256("0x9876"), SKILL_CODER);
      expect(await escrow.getJobState(1)).to.equal(0); // Open

      await escrow.connect(agentOwner).submitProposal(1, 1, rate, ethers.ZeroHash);
      await escrow.connect(client).acceptProposal(1, 0, { value: rate });
      expect(await escrow.getJobState(1)).to.equal(1); // Funded

      await escrow.connect(client).defineMilestones(1, [100], [ethers.id("c1")]);
      expect(await escrow.getJobState(1)).to.equal(2); // Submitted

      const outputHash = ethers.keccak256(ethers.toUtf8Bytes("done"));
      const sig = await signAlignment(1, 0, 9000, outputHash);
      await escrow.connect(agentWallet).releaseMilestone(1, 0, outputHash, 9000, sig);
      expect(await escrow.getJobState(1)).to.equal(3); // Terminal
    });
  });
});
