// AgentRegistry tests — ERC-7857 Musashi-style implementation.
// Covers: basic mint, ownerOf/balanceOf, skill management, escrow callback,
//         iTransfer (incl replay protection), iClone, time-bounded authorization,
//         updateCapability, delegateAccess, pause, custom errors.
//
// Created: 2026-04-27

const { expect } = require("chai");
const { ethers } = require("hardhat");

const SKILL_A = ethers.id("skill:a");
const SKILL_B = ethers.id("skill:b");
const SKILL_C = ethers.id("skill:c");

describe("AgentRegistry (ERC-7857)", function () {
  let registry, oracleSigner, owner, agentOwner, agentWallet, recipient, alice, bob, escrow;
  let chainId;

  // Standard mint args helper
  const eciesPubKey = "0x04" + "ab".repeat(32);
  const sealedKey   = "0x" + "cd".repeat(96);
  const profileHash = ethers.keccak256(ethers.toUtf8Bytes("profile-1"));
  const capabilityHash = ethers.keccak256(ethers.toUtf8Bytes("capability-1"));
  const defaultRate = 10; // uint32 in 0.01-OG units

  beforeEach(async function () {
    [owner, agentOwner, agentWallet, recipient, alice, bob, escrow] = await ethers.getSigners();
    oracleSigner = ethers.Wallet.createRandom().connect(ethers.provider);

    const Registry = await ethers.getContractFactory("AgentRegistry");
    registry = await Registry.deploy();
    await registry.waitForDeployment();
    await registry.setOracle(oracleSigner.address);

    chainId = (await ethers.provider.getNetwork()).chainId;
  });

  // ─── Helper: build oracle proof for iTransfer/iClone ──────────────────
  async function buildProof(agentId, version, oldHash, newHash, to) {
    const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint256", "address", "uint256", "uint16", "bytes32", "bytes32", "address"],
      [chainId, await registry.getAddress(), agentId, version, oldHash, newHash, to]
    );
    const inner = ethers.keccak256(encoded);
    return await oracleSigner.signMessage(ethers.getBytes(inner));
  }

  async function mintBasic(skills = []) {
    return registry.connect(agentOwner).mintAgent(
      defaultRate, profileHash, capabilityHash, skills,
      agentWallet.address, eciesPubKey, sealedKey
    );
  }

  // ─── BASIC MINT ───────────────────────────────────────────────────────
  describe("mintAgent", function () {
    it("mints with id starting at 1", async function () {
      const tx = await mintBasic();
      const receipt = await tx.wait();
      const event = receipt.logs.find(l => {
        try { return registry.interface.parseLog(l).name === "AgentMinted"; } catch { return false; }
      });
      const parsed = registry.interface.parseLog(event);
      expect(parsed.args.agentId).to.equal(1);
      expect(parsed.args.owner).to.equal(agentOwner.address);
    });

    it("emits SealedKeyPublished on mint", async function () {
      await expect(mintBasic())
        .to.emit(registry, "SealedKeyPublished")
        .withArgs(1n, agentOwner.address, 1, sealedKey);
    });

    it("stores correct profile fields", async function () {
      await mintBasic([SKILL_A, SKILL_B]);
      const p = await registry.getAgentProfile(1);
      expect(p.owner).to.equal(agentOwner.address);
      expect(p.agentWallet).to.equal(agentWallet.address);
      expect(p.capabilityHash).to.equal(capabilityHash);
      expect(p.profileHash).to.equal(profileHash);
      expect(p.winRate).to.equal(8000);
      expect(p.version).to.equal(1);
      expect(p.isActive).to.be.true;
      expect(p.totalJobsCompleted).to.equal(0);
      expect(p.totalJobsAttempted).to.equal(0);
      expect(p.defaultRate).to.equal(defaultRate);
    });

    it("ownerOf and balanceOf reflect mint", async function () {
      await mintBasic();
      expect(await registry.ownerOf(1)).to.equal(agentOwner.address);
      expect(await registry.balanceOf(agentOwner.address)).to.equal(1);
      await mintBasic();
      expect(await registry.balanceOf(agentOwner.address)).to.equal(2);
    });

    it("totalAgents increments correctly", async function () {
      expect(await registry.totalAgents()).to.equal(0);
      await mintBasic();
      expect(await registry.totalAgents()).to.equal(1);
      await mintBasic();
      expect(await registry.totalAgents()).to.equal(2);
    });

    it("reverts on zero agentWallet", async function () {
      await expect(
        registry.connect(agentOwner).mintAgent(
          defaultRate, profileHash, capabilityHash, [],
          ethers.ZeroAddress, eciesPubKey, sealedKey
        )
      ).to.be.revertedWithCustomError(registry, "ZeroAddress");
    });

    it("reverts when agentWallet equals msg.sender", async function () {
      await expect(
        registry.connect(agentOwner).mintAgent(
          defaultRate, profileHash, capabilityHash, [],
          agentOwner.address, eciesPubKey, sealedKey
        )
      ).to.be.revertedWithCustomError(registry, "ZeroAddress");
    });

    it("reverts on zero capabilityHash", async function () {
      await expect(
        registry.connect(agentOwner).mintAgent(
          defaultRate, profileHash, ethers.ZeroHash, [],
          agentWallet.address, eciesPubKey, sealedKey
        )
      ).to.be.revertedWithCustomError(registry, "ZeroRoot");
    });

    it("reverts on empty sealedKey", async function () {
      await expect(
        registry.connect(agentOwner).mintAgent(
          defaultRate, profileHash, capabilityHash, [],
          agentWallet.address, eciesPubKey, "0x"
        )
      ).to.be.revertedWithCustomError(registry, "EmptySealedKey");
    });

    it("reverts when initial skills exceed MAX_INITIAL_SKILLS (20)", async function () {
      const skills = Array.from({length: 21}, (_, i) => ethers.id(`skill:${i}`));
      await expect(
        registry.connect(agentOwner).mintAgent(
          defaultRate, profileHash, capabilityHash, skills,
          agentWallet.address, eciesPubKey, sealedKey
        )
      ).to.be.revertedWithCustomError(registry, "TooManyInitialSkills");
    });
  });

  // ─── SKILL MANAGEMENT ─────────────────────────────────────────────────
  describe("skill management", function () {
    beforeEach(async function () {
      await mintBasic();
    });

    it("addSkill is idempotent (no error on duplicate)", async function () {
      await registry.connect(agentOwner).addSkill(1, SKILL_A);
      await registry.connect(agentOwner).addSkill(1, SKILL_A); // no revert
      expect(await registry.agentSkillCount(1)).to.equal(1);
    });

    it("hasSkill returns correct state", async function () {
      expect(await registry.hasSkill(1, SKILL_A)).to.be.false;
      await registry.connect(agentOwner).addSkill(1, SKILL_A);
      expect(await registry.hasSkill(1, SKILL_A)).to.be.true;
    });

    it("getAgentSkills returns array", async function () {
      await registry.connect(agentOwner).addSkill(1, SKILL_A);
      await registry.connect(agentOwner).addSkill(1, SKILL_B);
      const skills = await registry.getAgentSkills(1);
      expect(skills).to.have.lengthOf(2);
      expect(skills).to.include(SKILL_A);
      expect(skills).to.include(SKILL_B);
    });

    it("removeSkill swap-pop preserves remaining skills", async function () {
      await registry.connect(agentOwner).addSkill(1, SKILL_A);
      await registry.connect(agentOwner).addSkill(1, SKILL_B);
      await registry.connect(agentOwner).addSkill(1, SKILL_C);
      await registry.connect(agentOwner).removeSkill(1, SKILL_B);
      const skills = await registry.getAgentSkills(1);
      expect(skills).to.have.lengthOf(2);
      expect(skills).to.include(SKILL_A);
      expect(skills).to.include(SKILL_C);
      expect(await registry.hasSkill(1, SKILL_B)).to.be.false;
    });

    it("addSkill reverts for non-owner", async function () {
      await expect(
        registry.connect(alice).addSkill(1, SKILL_A)
      ).to.be.revertedWithCustomError(registry, "NotAgentOwner");
    });

    it("removeSkill reverts for non-existent skill", async function () {
      await expect(
        registry.connect(agentOwner).removeSkill(1, SKILL_A)
      ).to.be.revertedWithCustomError(registry, "SkillNotFound");
    });

    it("addSkill reverts on zero skillId", async function () {
      await expect(
        registry.connect(agentOwner).addSkill(1, ethers.ZeroHash)
      ).to.be.revertedWithCustomError(registry, "ZeroSkill");
    });
  });

  // ─── ERC-7857: iTRANSFER + REPLAY PROTECTION ──────────────────────────
  describe("iTransfer", function () {
    let agent;

    beforeEach(async function () {
      await mintBasic();
      agent = await registry.getAgentProfile(1);
    });

    it("transfers ownership with valid proof", async function () {
      const newHash = ethers.keccak256(ethers.toUtf8Bytes("re-encrypted"));
      const newSealed = "0x" + "ee".repeat(96);
      const proof = await buildProof(1, agent.version, agent.capabilityHash, newHash, recipient.address);

      await expect(
        registry.connect(agentOwner).iTransfer(1, recipient.address, newHash, newSealed, proof)
      ).to.emit(registry, "SealedTransfer")
        .withArgs(1n, agentOwner.address, recipient.address, agent.capabilityHash, newHash, 2);

      expect(await registry.ownerOf(1)).to.equal(recipient.address);
    });

    it("emits SealedKeyPublished on transfer", async function () {
      const newHash = ethers.keccak256(ethers.toUtf8Bytes("re-enc-2"));
      const newSealed = "0x" + "ff".repeat(96);
      const proof = await buildProof(1, agent.version, agent.capabilityHash, newHash, recipient.address);

      await expect(
        registry.connect(agentOwner).iTransfer(1, recipient.address, newHash, newSealed, proof)
      ).to.emit(registry, "SealedKeyPublished")
        .withArgs(1n, recipient.address, 2, newSealed);
    });

    it("bumps version and updates capabilityHash", async function () {
      const newHash = ethers.keccak256(ethers.toUtf8Bytes("v2-blob"));
      const newSealed = "0x" + "11".repeat(96);
      const proof = await buildProof(1, 1, agent.capabilityHash, newHash, recipient.address);
      await registry.connect(agentOwner).iTransfer(1, recipient.address, newHash, newSealed, proof);

      const updated = await registry.getAgentProfile(1);
      expect(updated.version).to.equal(2);
      expect(updated.capabilityHash).to.equal(newHash);
    });

    it("updates owner indexes correctly", async function () {
      const newHash = ethers.keccak256(ethers.toUtf8Bytes("idx"));
      const newSealed = "0x" + "22".repeat(96);
      const proof = await buildProof(1, 1, agent.capabilityHash, newHash, recipient.address);
      await registry.connect(agentOwner).iTransfer(1, recipient.address, newHash, newSealed, proof);

      expect(await registry.balanceOf(agentOwner.address)).to.equal(0);
      expect(await registry.balanceOf(recipient.address)).to.equal(1);
      expect(await registry.getOwnerAgents(recipient.address)).to.deep.equal([1n]);
    });

    it("rejects signature from non-oracle", async function () {
      const fakeOracle = ethers.Wallet.createRandom();
      const newHash = ethers.keccak256(ethers.toUtf8Bytes("evil"));
      const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
        ["uint256", "address", "uint256", "uint16", "bytes32", "bytes32", "address"],
        [chainId, await registry.getAddress(), 1, 1, agent.capabilityHash, newHash, recipient.address]
      );
      const inner = ethers.keccak256(encoded);
      const fakeProof = await fakeOracle.signMessage(ethers.getBytes(inner));

      await expect(
        registry.connect(agentOwner).iTransfer(1, recipient.address, newHash, "0x" + "33".repeat(96), fakeProof)
      ).to.be.revertedWithCustomError(registry, "BadOracleSignature");
    });

    it("rejects replay across chains (different chainId)", async function () {
      const newHash = ethers.keccak256(ethers.toUtf8Bytes("cross-chain"));
      // Sign for wrong chainId
      const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
        ["uint256", "address", "uint256", "uint16", "bytes32", "bytes32", "address"],
        [9999n, await registry.getAddress(), 1, 1, agent.capabilityHash, newHash, recipient.address]
      );
      const inner = ethers.keccak256(encoded);
      const wrongChainProof = await oracleSigner.signMessage(ethers.getBytes(inner));

      await expect(
        registry.connect(agentOwner).iTransfer(1, recipient.address, newHash, "0x" + "44".repeat(96), wrongChainProof)
      ).to.be.revertedWithCustomError(registry, "BadOracleSignature");
    });

    it("rejects replay across versions (signature for v1 used after version bumped to 2)", async function () {
      const newHash1 = ethers.keccak256(ethers.toUtf8Bytes("v1-target"));
      const proof1 = await buildProof(1, 1, agent.capabilityHash, newHash1, recipient.address);
      await registry.connect(agentOwner).iTransfer(1, recipient.address, newHash1, "0x" + "55".repeat(96), proof1);

      // Try to reuse same proof on version 2 (now owned by recipient)
      const newHash2 = ethers.keccak256(ethers.toUtf8Bytes("v2-target"));
      await expect(
        registry.connect(recipient).iTransfer(1, alice.address, newHash2, "0x" + "66".repeat(96), proof1)
      ).to.be.revertedWithCustomError(registry, "BadOracleSignature");
    });

    it("reverts when oracle not set", async function () {
      // Deploy fresh registry without oracle
      const R = await ethers.getContractFactory("AgentRegistry");
      const r2 = await R.deploy();
      await r2.connect(agentOwner).mintAgent(
        defaultRate, profileHash, capabilityHash, [],
        agentWallet.address, eciesPubKey, sealedKey
      );

      const newHash = ethers.keccak256(ethers.toUtf8Bytes("noOracle"));
      const proof = "0x" + "77".repeat(65);
      await expect(
        r2.connect(agentOwner).iTransfer(1, recipient.address, newHash, "0x" + "88".repeat(96), proof)
      ).to.be.revertedWithCustomError(r2, "OracleNotSet");
    });

    it("reverts on stale (same) capabilityHash", async function () {
      const proof = await buildProof(1, 1, agent.capabilityHash, agent.capabilityHash, recipient.address);
      await expect(
        registry.connect(agentOwner).iTransfer(1, recipient.address, agent.capabilityHash, "0x99", proof)
      ).to.be.revertedWithCustomError(registry, "StaleRoot");
    });

    it("reverts on self transfer", async function () {
      const newHash = ethers.keccak256(ethers.toUtf8Bytes("self"));
      const proof = await buildProof(1, 1, agent.capabilityHash, newHash, agentOwner.address);
      await expect(
        registry.connect(agentOwner).iTransfer(1, agentOwner.address, newHash, "0xaa", proof)
      ).to.be.revertedWithCustomError(registry, "SelfTransfer");
    });

    it("reverts when caller is not owner", async function () {
      const newHash = ethers.keccak256(ethers.toUtf8Bytes("hijack"));
      const proof = await buildProof(1, 1, agent.capabilityHash, newHash, recipient.address);
      await expect(
        registry.connect(alice).iTransfer(1, recipient.address, newHash, "0xbb", proof)
      ).to.be.revertedWithCustomError(registry, "NotAgentOwner");
    });
  });

  // ─── ERC-7857: iCLONE ─────────────────────────────────────────────────
  describe("iClone", function () {
    let agent;

    beforeEach(async function () {
      await mintBasic([SKILL_A, SKILL_B]);
      agent = await registry.getAgentProfile(1);
    });

    it("creates new tokenId with reset reputation", async function () {
      const newHash = ethers.keccak256(ethers.toUtf8Bytes("clone-blob"));
      const proof = await buildProof(1, 1, agent.capabilityHash, newHash, recipient.address);

      await registry.connect(agentOwner).iClone(1, recipient.address, newHash, "0x" + "cc".repeat(96), proof);

      const cloned = await registry.getAgentProfile(2);
      expect(cloned.owner).to.equal(recipient.address);
      expect(cloned.winRate).to.equal(8000); // RESET to default
      expect(cloned.totalJobsCompleted).to.equal(0);
      expect(cloned.totalJobsAttempted).to.equal(0);
      expect(cloned.version).to.equal(1);
      expect(cloned.capabilityHash).to.equal(newHash);
      expect(cloned.profileHash).to.equal(agent.profileHash);
      expect(cloned.agentWallet).to.equal(agent.agentWallet);
    });

    it("copies skills", async function () {
      const newHash = ethers.keccak256(ethers.toUtf8Bytes("clone-skills"));
      const proof = await buildProof(1, 1, agent.capabilityHash, newHash, recipient.address);
      await registry.connect(agentOwner).iClone(1, recipient.address, newHash, "0xdd", proof);

      const skills = await registry.getAgentSkills(2);
      expect(skills).to.have.lengthOf(2);
      expect(skills).to.include(SKILL_A);
      expect(skills).to.include(SKILL_B);
    });

    it("emits AgentCloned event", async function () {
      const newHash = ethers.keccak256(ethers.toUtf8Bytes("clone-evt"));
      const proof = await buildProof(1, 1, agent.capabilityHash, newHash, recipient.address);
      await expect(
        registry.connect(agentOwner).iClone(1, recipient.address, newHash, "0xee", proof)
      ).to.emit(registry, "AgentCloned")
        .withArgs(1n, 2n, recipient.address, newHash);
    });

    it("original agent retains all data", async function () {
      const newHash = ethers.keccak256(ethers.toUtf8Bytes("clone-orig"));
      const proof = await buildProof(1, 1, agent.capabilityHash, newHash, recipient.address);
      await registry.connect(agentOwner).iClone(1, recipient.address, newHash, "0xff", proof);

      const orig = await registry.getAgentProfile(1);
      expect(orig.owner).to.equal(agentOwner.address);
      expect(orig.capabilityHash).to.equal(agent.capabilityHash); // unchanged
    });

    it("reverts when caller is not owner", async function () {
      const newHash = ethers.keccak256(ethers.toUtf8Bytes("hijack-clone"));
      const proof = await buildProof(1, 1, agent.capabilityHash, newHash, recipient.address);
      await expect(
        registry.connect(alice).iClone(1, recipient.address, newHash, "0x12", proof)
      ).to.be.revertedWithCustomError(registry, "NotAgentOwner");
    });
  });

  // ─── TIME-BOUNDED USAGE AUTHORIZATION ─────────────────────────────────
  describe("authorizeUsage / revokeUsage", function () {
    beforeEach(async function () {
      await mintBasic();
    });

    it("authorizes for given duration", async function () {
      const permsHash = ethers.keccak256(ethers.toUtf8Bytes("perms:tools:web"));
      const tx = await registry.connect(agentOwner).authorizeUsage(1, alice.address, 3600, permsHash);
      const receipt = await tx.wait();
      const blockTs = (await ethers.provider.getBlock(receipt.blockNumber)).timestamp;

      const auth = await registry.getAuthorization(1, alice.address);
      expect(Number(auth.expiresAt)).to.be.closeTo(blockTs + 3600, 2);
      expect(auth.permissionsHash).to.equal(permsHash);
    });

    it("isAuthorized returns true within duration", async function () {
      await registry.connect(agentOwner).authorizeUsage(1, alice.address, 3600, ethers.ZeroHash);
      expect(await registry.isAuthorized(1, alice.address)).to.be.true;
    });

    it("isAuthorized returns false after expiry", async function () {
      await registry.connect(agentOwner).authorizeUsage(1, alice.address, 100, ethers.ZeroHash);
      await ethers.provider.send("evm_increaseTime", [101]);
      await ethers.provider.send("evm_mine", []);
      expect(await registry.isAuthorized(1, alice.address)).to.be.false;
    });

    it("re-authorizing extends expiry without duplicating in list", async function () {
      await registry.connect(agentOwner).authorizeUsage(1, alice.address, 100, ethers.ZeroHash);
      const list1 = await registry.authorizedUsersOf(1);
      expect(list1).to.have.lengthOf(1);

      await ethers.provider.send("evm_increaseTime", [50]);
      await registry.connect(agentOwner).authorizeUsage(1, alice.address, 200, ethers.ZeroHash);
      const list2 = await registry.authorizedUsersOf(1);
      expect(list2).to.have.lengthOf(1); // still 1, not 2
    });

    it("revokeUsage removes from enumerable list", async function () {
      await registry.connect(agentOwner).authorizeUsage(1, alice.address, 3600, ethers.ZeroHash);
      await registry.connect(agentOwner).authorizeUsage(1, bob.address, 3600, ethers.ZeroHash);
      expect((await registry.authorizedUsersOf(1)).length).to.equal(2);

      await registry.connect(agentOwner).revokeUsage(1, alice.address);
      const list = await registry.authorizedUsersOf(1);
      expect(list).to.have.lengthOf(1);
      expect(list[0]).to.equal(bob.address);
      expect(await registry.isAuthorized(1, alice.address)).to.be.false;
    });

    it("reverts when non-owner tries to authorize", async function () {
      await expect(
        registry.connect(alice).authorizeUsage(1, bob.address, 3600, ethers.ZeroHash)
      ).to.be.revertedWithCustomError(registry, "NotAgentOwner");
    });
  });

  // ─── UPDATE CAPABILITY (owner self-update) ────────────────────────────
  describe("updateCapability", function () {
    beforeEach(async function () {
      await mintBasic();
    });

    it("rotates capability hash and bumps version", async function () {
      const newHash = ethers.keccak256(ethers.toUtf8Bytes("rotated"));
      const newSealed = "0x" + "ab".repeat(96);
      await registry.connect(agentOwner).updateCapability(1, newHash, newSealed);

      const p = await registry.getAgentProfile(1);
      expect(p.capabilityHash).to.equal(newHash);
      expect(p.version).to.equal(2);
    });

    it("emits CapabilityUpdated and SealedKeyPublished", async function () {
      const newHash = ethers.keccak256(ethers.toUtf8Bytes("evt"));
      const newSealed = "0x" + "cd".repeat(96);
      await expect(
        registry.connect(agentOwner).updateCapability(1, newHash, newSealed)
      ).to.emit(registry, "CapabilityUpdated")
        .withArgs(1n, newHash, 2)
        .and.to.emit(registry, "SealedKeyPublished")
        .withArgs(1n, agentOwner.address, 2, newSealed);
    });

    it("reverts for non-owner", async function () {
      await expect(
        registry.connect(alice).updateCapability(1, ethers.keccak256("0x01"), "0x02")
      ).to.be.revertedWithCustomError(registry, "NotAgentOwner");
    });
  });

  // ─── ESCROW CALLBACK ──────────────────────────────────────────────────
  describe("recordJobResult", function () {
    beforeEach(async function () {
      await mintBasic();
      await registry.addEscrowContract(escrow.address);
    });

    it("updates aggregate winRate correctly", async function () {
      // 1 job, completed → 100%
      await registry.connect(escrow).recordJobResult(1, ethers.parseEther("0.1"), true, ethers.ZeroHash);
      let p = await registry.getAgentProfile(1);
      expect(p.winRate).to.equal(10000);
      expect(p.totalJobsCompleted).to.equal(1);

      // 1 of 2 jobs completed → 50%
      await registry.connect(escrow).recordJobResult(1, 0, false, ethers.ZeroHash);
      p = await registry.getAgentProfile(1);
      expect(p.winRate).to.equal(5000);
    });

    it("updates per-skill reputation when skillId provided", async function () {
      await registry.connect(escrow).recordJobResult(1, ethers.parseEther("0.5"), true, SKILL_A);
      const skillRep = await registry.getSkillReputation(1, SKILL_A);
      expect(skillRep.scoreBps).to.equal(10000);
      expect(skillRep.jobsCompleted).to.equal(1);
    });

    it("reverts when called by non-escrow", async function () {
      await expect(
        registry.connect(alice).recordJobResult(1, 0, true, ethers.ZeroHash)
      ).to.be.revertedWithCustomError(registry, "UnauthorizedEscrow");
    });
  });

  // ─── DELEGATE ACCESS ──────────────────────────────────────────────────
  describe("delegateAccess", function () {
    it("sets and reads delegate", async function () {
      await registry.connect(agentOwner).delegateAccess(alice.address);
      expect(await registry.getDelegateAccess(agentOwner.address)).to.equal(alice.address);
    });

    it("emits DelegateAccessSet", async function () {
      await expect(
        registry.connect(agentOwner).delegateAccess(alice.address)
      ).to.emit(registry, "DelegateAccessSet")
        .withArgs(agentOwner.address, alice.address);
    });
  });

  // ─── ADMIN ────────────────────────────────────────────────────────────
  describe("admin functions", function () {
    it("setOracle updates oracle and emits event", async function () {
      const newOracle = ethers.Wallet.createRandom();
      await expect(registry.setOracle(newOracle.address))
        .to.emit(registry, "OracleSet")
        .withArgs(oracleSigner.address, newOracle.address);
      expect(await registry.oracle()).to.equal(newOracle.address);
    });

    it("setOracle reverts on zero address", async function () {
      await expect(
        registry.setOracle(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(registry, "ZeroAddress");
    });

    it("setOracle reverts for non-owner", async function () {
      await expect(
        registry.connect(alice).setOracle(alice.address)
      ).to.be.reverted;
    });

    it("pause blocks mint", async function () {
      await registry.pause();
      await expect(mintBasic()).to.be.revertedWith("Pausable: paused");
      await registry.unpause();
      await mintBasic(); // works again
    });
  });

  // ─── transferDigest determinism ───────────────────────────────────────
  describe("transferDigest", function () {
    it("returns same hash for same inputs", async function () {
      const oldH = ethers.keccak256(ethers.toUtf8Bytes("a"));
      const newH = ethers.keccak256(ethers.toUtf8Bytes("b"));
      const d1 = await registry.transferDigest(1, 1, oldH, newH, recipient.address);
      const d2 = await registry.transferDigest(1, 1, oldH, newH, recipient.address);
      expect(d1).to.equal(d2);
    });

    it("returns different hash when version changes", async function () {
      const oldH = ethers.keccak256(ethers.toUtf8Bytes("a"));
      const newH = ethers.keccak256(ethers.toUtf8Bytes("b"));
      const d1 = await registry.transferDigest(1, 1, oldH, newH, recipient.address);
      const d2 = await registry.transferDigest(1, 2, oldH, newH, recipient.address);
      expect(d1).to.not.equal(d2);
    });
  });
});
