// SubscriptionEscrow tests — packed Subscription struct, 3 interval modes,
// grace period, drain flow, OKX APP session voucher stub.
//
// Created: 2026-04-27

const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("SubscriptionEscrow", function () {
  let registry, escrow;
  let owner, client, agentOwner, agentWallet, alice;

  const eciesPubKey = "0x04" + "ab".repeat(32);
  const sealedKey = "0x" + "cd".repeat(96);
  const profileHash = ethers.keccak256(ethers.toUtf8Bytes("profile"));
  const capabilityHash = ethers.keccak256(ethers.toUtf8Bytes("capability"));

  const taskHash = ethers.keccak256(ethers.toUtf8Bytes("Daily crypto alerts"));
  const checkInRate = ethers.parseEther("0.001");
  const alertRate = ethers.parseEther("0.0005");
  const budget = ethers.parseEther("0.5");
  const intervalSeconds = 86400; // 1 day
  const AUTO_INTERVAL = 0xFFFFFFFF; // type(uint32).max

  beforeEach(async function () {
    [owner, client, agentOwner, agentWallet, alice] = await ethers.getSigners();

    const Registry = await ethers.getContractFactory("AgentRegistry");
    registry = await Registry.deploy();

    const Escrow = await ethers.getContractFactory("SubscriptionEscrow");
    escrow = await Escrow.deploy(await registry.getAddress());

    // Mint agent #1
    await registry.connect(agentOwner).mintAgent(
      10, profileHash, capabilityHash, [],
      agentWallet.address, eciesPubKey, sealedKey
    );
  });

  // ─── createSubscription ───────────────────────────────────────────────
  describe("createSubscription", function () {
    it("creates ACTIVE subscription in Mode A (CLIENT_SET)", async function () {
      await escrow.connect(client).createSubscription(
        1, taskHash, intervalSeconds, checkInRate, alertRate, 0,
        false, 0, "0x", ethers.ZeroHash,
        { value: budget }
      );
      const sub = await escrow.getSubscription(1);
      expect(sub.client).to.equal(client.address);
      expect(sub.agentId).to.equal(1);
      expect(sub.intervalMode).to.equal(0); // CLIENT_SET
      expect(sub.status).to.equal(1); // ACTIVE
      expect(sub.balance).to.equal(budget);
    });

    it("creates PENDING subscription in Mode B (AGENT_PROPOSED)", async function () {
      await escrow.connect(client).createSubscription(
        1, taskHash, 0 /* triggers Mode B */, checkInRate, alertRate, 0,
        false, 0, "0x", ethers.ZeroHash,
        { value: budget }
      );
      const sub = await escrow.getSubscription(1);
      expect(sub.intervalMode).to.equal(1); // AGENT_PROPOSED
      expect(sub.status).to.equal(0); // PENDING
      expect(sub.intervalSeconds).to.equal(0);
    });

    it("creates ACTIVE subscription in Mode C (AGENT_AUTO)", async function () {
      await escrow.connect(client).createSubscription(
        1, taskHash, AUTO_INTERVAL, checkInRate, alertRate, 0,
        false, 0, "0x", ethers.ZeroHash,
        { value: budget }
      );
      const sub = await escrow.getSubscription(1);
      expect(sub.intervalMode).to.equal(2); // AGENT_AUTO
      expect(sub.status).to.equal(1); // ACTIVE
    });

    it("clamps grace period to MIN", async function () {
      await escrow.connect(client).createSubscription(
        1, taskHash, intervalSeconds, checkInRate, alertRate, 100, // < MIN_GRACE_PERIOD
        false, 0, "0x", ethers.ZeroHash,
        { value: budget }
      );
      const sub = await escrow.getSubscription(1);
      expect(sub.gracePeriodSeconds).to.equal(3600); // MIN
    });

    it("clamps grace period to MAX", async function () {
      await escrow.connect(client).createSubscription(
        1, taskHash, intervalSeconds, checkInRate, alertRate, 999999999, // > MAX
        false, 0, "0x", ethers.ZeroHash,
        { value: budget }
      );
      const sub = await escrow.getSubscription(1);
      expect(sub.gracePeriodSeconds).to.equal(604800); // MAX (7 days)
    });

    it("uses DEFAULT grace period when 0 passed", async function () {
      await escrow.connect(client).createSubscription(
        1, taskHash, intervalSeconds, checkInRate, alertRate, 0,
        false, 0, "0x", ethers.ZeroHash,
        { value: budget }
      );
      const sub = await escrow.getSubscription(1);
      expect(sub.gracePeriodSeconds).to.equal(86400); // DEFAULT (24h)
    });

    it("stores task hash", async function () {
      await escrow.connect(client).createSubscription(
        1, taskHash, intervalSeconds, checkInRate, alertRate, 0,
        false, 0, "0x", ethers.ZeroHash,
        { value: budget }
      );
      expect(await escrow.subscriptionTaskHash(1)).to.equal(taskHash);
    });

    it("stores OKX session voucher sig when enabled (preview slot — V1 stub, see OKX_session_voucher_design.md)", async function () {
      // V1 storage slot is still named subscriptionX402Sig; the OKX APP session-voucher
      // schema reuses the same byte buffer until the V2 redeploy lands post-demo.
      const clientVoucherSig = "0xabcdef0123456789";
      await escrow.connect(client).createSubscription(
        1, taskHash, intervalSeconds, checkInRate, alertRate, 0,
        true, 0, clientVoucherSig, ethers.ZeroHash,
        { value: budget }
      );
      expect(await escrow.subscriptionX402Sig(1)).to.equal(clientVoucherSig);
    });

    it("emits SubscriptionCreated", async function () {
      await expect(escrow.connect(client).createSubscription(
        1, taskHash, intervalSeconds, checkInRate, alertRate, 0,
        false, 0, "0x", ethers.ZeroHash,
        { value: budget }
      )).to.emit(escrow, "SubscriptionCreated")
        .withArgs(1n, 1n, client.address, budget, taskHash);
    });

    it("reverts on zero budget", async function () {
      await expect(
        escrow.connect(client).createSubscription(
          1, taskHash, intervalSeconds, checkInRate, alertRate, 0,
          false, 0, "0x", ethers.ZeroHash,
          { value: 0 }
        )
      ).to.be.revertedWithCustomError(escrow, "ZeroBudget");
    });

    it("reverts when both rates are 0", async function () {
      await expect(
        escrow.connect(client).createSubscription(
          1, taskHash, intervalSeconds, 0, 0, 0,
          false, 0, "0x", ethers.ZeroHash,
          { value: budget }
        )
      ).to.be.revertedWithCustomError(escrow, "ZeroRates");
    });

    it("reverts when agent inactive", async function () {
      await registry.connect(agentOwner).toggleActive(1);
      await expect(
        escrow.connect(client).createSubscription(
          1, taskHash, intervalSeconds, checkInRate, alertRate, 0,
          false, 0, "0x", ethers.ZeroHash,
          { value: budget }
        )
      ).to.be.revertedWithCustomError(escrow, "AgentInactive");
    });
  });

  // ─── topUp ────────────────────────────────────────────────────────────
  describe("topUp", function () {
    beforeEach(async function () {
      await escrow.connect(client).createSubscription(
        1, taskHash, intervalSeconds, checkInRate, alertRate, 0,
        false, 0, "0x", ethers.ZeroHash,
        { value: budget }
      );
    });

    it("increases balance", async function () {
      await escrow.connect(client).topUp(1, { value: ethers.parseEther("0.1") });
      const sub = await escrow.getSubscription(1);
      expect(sub.balance).to.equal(budget + ethers.parseEther("0.1"));
    });

    it("resumes PAUSED subscription", async function () {
      // Drain to nearly empty so it pauses
      const expensive = ethers.parseEther("0.49");
      await escrow.connect(client).createSubscription(
        1, taskHash, 1 /* 1 sec interval */, expensive, 0, 0,
        false, 0, "0x", ethers.ZeroHash,
        { value: ethers.parseEther("0.5") }
      );
      // Sub #2 created. Wait then drain to trigger pause (balance < checkInRate after first drain)
      await ethers.provider.send("evm_increaseTime", [2]);
      await ethers.provider.send("evm_mine", []);
      await escrow.connect(agentWallet).drainPerCheckIn(2);

      let s = await escrow.getSubscription(2);
      expect(s.status).to.equal(2); // PAUSED

      await expect(
        escrow.connect(client).topUp(2, { value: ethers.parseEther("0.5") })
      ).to.emit(escrow, "SubscriptionResumed");

      s = await escrow.getSubscription(2);
      expect(s.status).to.equal(1); // ACTIVE
    });

    it("reverts on zero value", async function () {
      await expect(
        escrow.connect(client).topUp(1, { value: 0 })
      ).to.be.revertedWithCustomError(escrow, "ZeroValue");
    });
  });

  // ─── drainPerCheckIn ──────────────────────────────────────────────────
  describe("drainPerCheckIn", function () {
    beforeEach(async function () {
      await escrow.connect(client).createSubscription(
        1, taskHash, intervalSeconds, checkInRate, alertRate, 0,
        false, 0, "0x", ethers.ZeroHash,
        { value: budget }
      );
      // Advance time so first drain is allowed
      await ethers.provider.send("evm_increaseTime", [intervalSeconds + 1]);
      await ethers.provider.send("evm_mine", []);
    });

    it("drains checkInRate to agentWallet", async function () {
      const balBefore = await ethers.provider.getBalance(agentWallet.address);
      const tx = await escrow.connect(agentWallet).drainPerCheckIn(1);
      const receipt = await tx.wait();
      const gasCost = receipt.gasUsed * receipt.gasPrice;
      const balAfter = await ethers.provider.getBalance(agentWallet.address);

      expect(balAfter).to.equal(balBefore - gasCost + checkInRate);

      const sub = await escrow.getSubscription(1);
      expect(sub.balance).to.equal(budget - checkInRate);
      expect(sub.totalDrained).to.equal(checkInRate);
    });

    it("emits CheckInDrained", async function () {
      await expect(escrow.connect(agentWallet).drainPerCheckIn(1))
        .to.emit(escrow, "CheckInDrained")
        .withArgs(1n, 1n, checkInRate, anyValue());
    });

    it("reverts if too early (before interval elapsed)", async function () {
      // Drain once so lastCheckIn updates
      await escrow.connect(agentWallet).drainPerCheckIn(1);
      // Try to drain again immediately
      await expect(
        escrow.connect(agentWallet).drainPerCheckIn(1)
      ).to.be.revertedWithCustomError(escrow, "TooEarly");
    });

    it("reverts when called by non-agent", async function () {
      await expect(
        escrow.connect(alice).drainPerCheckIn(1)
      ).to.be.revertedWithCustomError(escrow, "NotAgent");
    });
  });

  // ─── drainPerAlert ────────────────────────────────────────────────────
  describe("drainPerAlert", function () {
    beforeEach(async function () {
      await escrow.connect(client).createSubscription(
        1, taskHash, intervalSeconds, checkInRate, alertRate, 0,
        false, 0, "0x", ethers.ZeroHash,
        { value: budget }
      );
    });

    it("drains alertRate (no time gating)", async function () {
      await expect(
        escrow.connect(agentWallet).drainPerAlert(1, "0xdeadbeef")
      ).to.emit(escrow, "AlertFired");

      const sub = await escrow.getSubscription(1);
      expect(sub.balance).to.equal(budget - alertRate);
    });

    it("reverts when alert rate is 0", async function () {
      await escrow.connect(client).createSubscription(
        1, taskHash, intervalSeconds, checkInRate, 0, 0, // alertRate = 0
        false, 0, "0x", ethers.ZeroHash,
        { value: budget }
      );
      await expect(
        escrow.connect(agentWallet).drainPerAlert(2, "0x")
      ).to.be.revertedWithCustomError(escrow, "AlertsDisabled");
    });
  });

  // ─── Pause + grace period flow ────────────────────────────────────────
  describe("pause + finalizeExpired", function () {
    it("transitions ACTIVE → PAUSED → CANCELLED via grace", async function () {
      const tinyRate = ethers.parseEther("0.4");
      await escrow.connect(client).createSubscription(
        1, taskHash, 1, tinyRate, 0, 7200, // 2h grace
        false, 0, "0x", ethers.ZeroHash,
        { value: ethers.parseEther("0.5") }
      );

      // Drain once → PAUSED (balance 0.1, less than rate 0.4)
      await ethers.provider.send("evm_increaseTime", [2]);
      await ethers.provider.send("evm_mine", []);
      await escrow.connect(agentWallet).drainPerCheckIn(1);
      let sub = await escrow.getSubscription(1);
      expect(sub.status).to.equal(2); // PAUSED

      // Try to finalize before grace expires → revert
      await expect(
        escrow.finalizeExpired(1)
      ).to.be.revertedWithCustomError(escrow, "GraceNotExpired");

      // Advance past grace
      await ethers.provider.send("evm_increaseTime", [7201]);
      await ethers.provider.send("evm_mine", []);

      const balBefore = await ethers.provider.getBalance(client.address);
      await escrow.finalizeExpired(1);
      const balAfter = await ethers.provider.getBalance(client.address);
      expect(balAfter - balBefore).to.equal(ethers.parseEther("0.1"));

      sub = await escrow.getSubscription(1);
      expect(sub.status).to.equal(3); // CANCELLED
    });
  });

  // ─── Mode B: proposeInterval / approveInterval ────────────────────────
  describe("Mode B (AGENT_PROPOSED)", function () {
    beforeEach(async function () {
      await escrow.connect(client).createSubscription(
        1, taskHash, 0 /* mode B */, checkInRate, 0, 0,
        false, 0, "0x", ethers.ZeroHash,
        { value: budget }
      );
    });

    it("agent proposes, client approves", async function () {
      await escrow.connect(agentWallet).proposeInterval(1, 3600);
      let sub = await escrow.getSubscription(1);
      expect(sub.proposedInterval).to.equal(3600);

      await escrow.connect(client).approveInterval(1);
      sub = await escrow.getSubscription(1);
      expect(sub.intervalSeconds).to.equal(3600);
      expect(sub.status).to.equal(1); // ACTIVE
    });

    it("approveInterval reverts when no proposal exists", async function () {
      await expect(
        escrow.connect(client).approveInterval(1)
      ).to.be.revertedWithCustomError(escrow, "NoProposal");
    });
  });

  // ─── Mode C: updateInterval ───────────────────────────────────────────
  describe("Mode C (AGENT_AUTO)", function () {
    it("agent dynamically updates interval", async function () {
      await escrow.connect(client).createSubscription(
        1, taskHash, AUTO_INTERVAL, checkInRate, 0, 0,
        false, 0, "0x", ethers.ZeroHash,
        { value: budget }
      );

      await escrow.connect(agentWallet).updateInterval(1, 7200);
      const sub = await escrow.getSubscription(1);
      expect(sub.intervalSeconds).to.equal(7200);
    });

    it("reverts updateInterval on Mode A subscription", async function () {
      await escrow.connect(client).createSubscription(
        1, taskHash, intervalSeconds, checkInRate, 0, 0,
        false, 0, "0x", ethers.ZeroHash,
        { value: budget }
      );
      await expect(
        escrow.connect(agentWallet).updateInterval(1, 7200)
      ).to.be.revertedWithCustomError(escrow, "NotModeC");
    });
  });

  // ─── cancelSubscription ───────────────────────────────────────────────
  describe("cancelSubscription", function () {
    it("client cancels and gets refund", async function () {
      await escrow.connect(client).createSubscription(
        1, taskHash, intervalSeconds, checkInRate, 0, 0,
        false, 0, "0x", ethers.ZeroHash,
        { value: budget }
      );

      const balBefore = await ethers.provider.getBalance(client.address);
      const tx = await escrow.connect(client).cancelSubscription(1);
      const receipt = await tx.wait();
      const gasCost = receipt.gasUsed * receipt.gasPrice;
      const balAfter = await ethers.provider.getBalance(client.address);

      expect(balAfter).to.equal(balBefore - gasCost + budget);

      const sub = await escrow.getSubscription(1);
      expect(sub.status).to.equal(3); // CANCELLED
    });

    it("reverts when called by non-client", async function () {
      await escrow.connect(client).createSubscription(
        1, taskHash, intervalSeconds, checkInRate, 0, 0,
        false, 0, "0x", ethers.ZeroHash,
        { value: budget }
      );
      await expect(
        escrow.connect(alice).cancelSubscription(1)
      ).to.be.revertedWithCustomError(escrow, "NotClient");
    });
  });
});

// Helper for matching any value in event args
function anyValue() {
  return (val) => true;
}
