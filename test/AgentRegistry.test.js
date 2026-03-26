const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("AgentRegistry", function () {
  let agentRegistry;
  let owner, majikan, agentWallet, otherUser;

  const AGENT_TYPE_CODER = 1;
  const BASE_RATE = ethers.parseEther("0.01");
  const RESUME_CID = "QmTestResumeCID123";
  const ECIES_PUB_KEY = "0x04abcdef";

  beforeEach(async function () {
    [owner, majikan, agentWallet, otherUser] = await ethers.getSigners();

    const AgentRegistry = await ethers.getContractFactory("AgentRegistry");
    agentRegistry = await AgentRegistry.deploy();
    await agentRegistry.waitForDeployment();
  });

  describe("mintAgent()", function () {
    it("should mint a new agent and return the correct agentId", async function () {
      const tx = await agentRegistry.connect(majikan).mintAgent(
        AGENT_TYPE_CODER,
        BASE_RATE,
        RESUME_CID,
        agentWallet.address,
        ECIES_PUB_KEY
      );

      const receipt = await tx.wait();
      // Check that AgentMinted event was emitted
      const event = receipt.logs.find(
        (log) => agentRegistry.interface.parseLog(log)?.name === "AgentMinted"
      );
      expect(event).to.not.be.undefined;

      const parsed = agentRegistry.interface.parseLog(event);
      expect(parsed.args.agentId).to.equal(1);
      expect(parsed.args.owner).to.equal(majikan.address);
    });

    it("should store correct agent profile data", async function () {
      await agentRegistry.connect(majikan).mintAgent(
        AGENT_TYPE_CODER,
        BASE_RATE,
        RESUME_CID,
        agentWallet.address,
        ECIES_PUB_KEY
      );

      const profile = await agentRegistry.getAgentProfile(1);
      expect(profile.owner).to.equal(majikan.address);
      expect(profile.agentType).to.equal(AGENT_TYPE_CODER);
      expect(profile.baseRate).to.equal(BASE_RATE);
      expect(profile.efficiencyScore).to.equal(8000); // default 80%
      expect(profile.resumeCID).to.equal(RESUME_CID);
      expect(profile.agentWallet).to.equal(agentWallet.address);
      expect(profile.isActive).to.be.true;
    });

    it("should revert if agentWallet is zero address", async function () {
      await expect(
        agentRegistry.connect(majikan).mintAgent(
          AGENT_TYPE_CODER,
          BASE_RATE,
          RESUME_CID,
          ethers.ZeroAddress,
          ECIES_PUB_KEY
        )
      ).to.be.revertedWith("AgentRegistry: agentWallet tidak boleh zero");
    });

    it("should revert if agentWallet is same as msg.sender", async function () {
      await expect(
        agentRegistry.connect(majikan).mintAgent(
          AGENT_TYPE_CODER,
          BASE_RATE,
          RESUME_CID,
          majikan.address,
          ECIES_PUB_KEY
        )
      ).to.be.revertedWith("AgentRegistry: agentWallet harus berbeda dari owner");
    });
  });

  describe("getOwnerAgents()", function () {
    it("should return correct array of agent IDs for an owner", async function () {
      // Mint 2 agents
      await agentRegistry.connect(majikan).mintAgent(
        AGENT_TYPE_CODER, BASE_RATE, RESUME_CID, agentWallet.address, ECIES_PUB_KEY
      );
      await agentRegistry.connect(majikan).mintAgent(
        0, BASE_RATE, "QmResume2", otherUser.address, ECIES_PUB_KEY
      );

      const agentIds = await agentRegistry.getOwnerAgents(majikan.address);
      expect(agentIds.length).to.equal(2);
      expect(agentIds[0]).to.equal(1);
      expect(agentIds[1]).to.equal(2);
    });
  });

  describe("updateResumeCID()", function () {
    it("should update resume and emit event", async function () {
      await agentRegistry.connect(majikan).mintAgent(
        AGENT_TYPE_CODER, BASE_RATE, RESUME_CID, agentWallet.address, ECIES_PUB_KEY
      );

      const newCID = "QmNewResumeCID456";
      await expect(
        agentRegistry.connect(majikan).updateResumeCID(1, newCID)
      )
        .to.emit(agentRegistry, "ResumeUpdated")
        .withArgs(1, RESUME_CID, newCID);

      const profile = await agentRegistry.getAgentProfile(1);
      expect(profile.resumeCID).to.equal(newCID);
    });

    it("should revert if called by non-owner", async function () {
      await agentRegistry.connect(majikan).mintAgent(
        AGENT_TYPE_CODER, BASE_RATE, RESUME_CID, agentWallet.address, ECIES_PUB_KEY
      );

      await expect(
        agentRegistry.connect(otherUser).updateResumeCID(1, "QmHack")
      ).to.be.revertedWith("AgentRegistry: bukan owner agent");
    });
  });

  describe("recordJobResult()", function () {
    beforeEach(async function () {
      await agentRegistry.connect(majikan).mintAgent(
        AGENT_TYPE_CODER, BASE_RATE, RESUME_CID, agentWallet.address, ECIES_PUB_KEY
      );
      // Set escrow contract to owner for testing
      await agentRegistry.setEscrowContract(owner.address);
    });

    it("should update efficiency score on successful job", async function () {
      await agentRegistry.recordJobResult(1, ethers.parseEther("0.01"), true);

      const profile = await agentRegistry.getAgentProfile(1);
      expect(profile.totalJobsCompleted).to.equal(1);
      expect(profile.totalJobsAttempted).to.equal(1);
      expect(profile.efficiencyScore).to.equal(10000); // 1/1 = 100%
    });

    it("should decrease efficiency score on failed job", async function () {
      // 1 success + 1 fail = 50%
      await agentRegistry.recordJobResult(1, ethers.parseEther("0.01"), true);
      await agentRegistry.recordJobResult(1, 0, false);

      const profile = await agentRegistry.getAgentProfile(1);
      expect(profile.totalJobsCompleted).to.equal(1);
      expect(profile.totalJobsAttempted).to.equal(2);
      expect(profile.efficiencyScore).to.equal(5000); // 1/2 = 50%
    });

    it("should revert if called by non-escrow address", async function () {
      await expect(
        agentRegistry.connect(otherUser).recordJobResult(1, 0, true)
      ).to.be.revertedWith("AgentRegistry: hanya escrow contract");
    });
  });
});
