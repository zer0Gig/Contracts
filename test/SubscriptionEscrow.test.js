const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("SubscriptionEscrow", function () {
  let agentRegistry;
  let subscriptionEscrow;
  let owner, client, agentWallet, stranger;

  const AUTO_INTERVAL = ethers.MaxUint256;
  const DEFAULT_GRACE = 86400n;
  const MIN_GRACE = 3600n;
  const MAX_GRACE = 604800n;

  beforeEach(async function () {
    [owner, client, agentWallet, stranger] = await ethers.getSigners();

    // Deploy mock AgentRegistry
    const MockAgentRegistry = await ethers.getContractFactory("MockAgentRegistry");
    agentRegistry = await MockAgentRegistry.deploy();

    // Register a test agent
    await agentRegistry.mintAgent(
      agentWallet.address,
      "ipfs://test-profile",
      "ipfs://test-capability"
    );

    // Deploy SubscriptionEscrow
    const SubscriptionEscrow = await ethers.getContractFactory("SubscriptionEscrow");
    subscriptionEscrow = await SubscriptionEscrow.deploy(await agentRegistry.getAddress());
  });

  describe("createSubscription", function () {
    it("should create subscription with client-set interval (Mode A)", async function () {
      const tx = await subscriptionEscrow.connect(client).createSubscription(
        1, // agentId
        "Monitor my wallet",
        3600, // 1 hour interval
        ethers.parseEther("0.01"), // checkInRate
        ethers.parseEther("0.05"), // alertRate
        0, // use default grace
        false, // x402 disabled
        0, // AGENT_SIDE
        "0x", // no sig
        "" // no webhook
      , { value: ethers.parseEther("1") });

      await expect(tx).to.emit(subscriptionEscrow, "SubscriptionCreated")
        .withArgs(1, 1, client.address, ethers.parseEther("1"));

      const sub = await subscriptionEscrow.getSubscription(1);
      expect(sub.client).to.equal(client.address);
      expect(sub.status).to.equal(1); // ACTIVE
      expect(sub.intervalSeconds).to.equal(3600);
      expect(sub.balance).to.equal(ethers.parseEther("1"));
    });

    it("should create subscription with agent-proposed interval (Mode B)", async function () {
      await subscriptionEscrow.connect(client).createSubscription(
        1,
        "Monitor my wallet",
        0, // Mode B
        ethers.parseEther("0.01"),
        ethers.parseEther("0.05"),
        0,
        false,
        0,
        "0x",
        ""
      , { value: ethers.parseEther("1") });

      const sub = await subscriptionEscrow.getSubscription(1);
      expect(sub.status).to.equal(0); // PENDING
      expect(sub.intervalMode).to.equal(1); // AGENT_PROPOSED
    });

    it("should create subscription with agent-auto interval (Mode C)", async function () {
      await subscriptionEscrow.connect(client).createSubscription(
        1,
        "Monitor my wallet",
        AUTO_INTERVAL, // Mode C
        ethers.parseEther("0.01"),
        ethers.parseEther("0.05"),
        0,
        false,
        0,
        "0x",
        ""
      , { value: ethers.parseEther("1") });

      const sub = await subscriptionEscrow.getSubscription(1);
      expect(sub.status).to.equal(1); // ACTIVE
      expect(sub.intervalMode).to.equal(2); // AGENT_AUTO
    });

    it("should clamp grace period to min", async function () {
      await subscriptionEscrow.connect(client).createSubscription(
        1,
        "Test",
        3600,
        ethers.parseEther("0.01"),
        ethers.parseEther("0.05"),
        100, // below min
        false,
        0,
        "0x",
        ""
      , { value: ethers.parseEther("1") });

      const sub = await subscriptionEscrow.getSubscription(1);
      expect(sub.gracePeriodSeconds).to.equal(MIN_GRACE);
    });

    it("should clamp grace period to max", async function () {
      await subscriptionEscrow.connect(client).createSubscription(
        1,
        "Test",
        3600,
        ethers.parseEther("0.01"),
        ethers.parseEther("0.05"),
        999999999, // above max
        false,
        0,
        "0x",
        ""
      , { value: ethers.parseEther("1") });

      const sub = await subscriptionEscrow.getSubscription(1);
      expect(sub.gracePeriodSeconds).to.equal(MAX_GRACE);
    });

    it("should store x402 sig when enabled", async function () {
      const testSig = ethers.hexlify(ethers.randomBytes(65));
      
      await subscriptionEscrow.connect(client).createSubscription(
        1,
        "Test",
        3600,
        ethers.parseEther("0.01"),
        ethers.parseEther("0.05"),
        0,
        true, // x402 enabled
        0, // AGENT_SIDE
        testSig,
        ""
      , { value: ethers.parseEther("1") });

      const sub = await subscriptionEscrow.getSubscription(1);
      expect(sub.x402Enabled).to.equal(true);
      expect(sub.clientX402Sig).to.equal(testSig);
    });

    it("should revert with zero budget", async function () {
      await expect(
        subscriptionEscrow.connect(client).createSubscription(
          1, "Test", 3600, ethers.parseEther("0.01"), ethers.parseEther("0.05"),
          0, false, 0, "0x", ""
        )
      ).to.be.revertedWith("SubscriptionEscrow: budget must be > 0");
    });
  });

  describe("drainPerCheckIn", function () {
    beforeEach(async function () {
      await subscriptionEscrow.connect(client).createSubscription(
        1,
        "Monitor",
        3600,
        ethers.parseEther("0.01"),
        ethers.parseEther("0.05"),
        0,
        false,
        0,
        "0x",
        ""
      , { value: ethers.parseEther("0.1") });
    });

    it("should drain check-in balance and emit event", async function () {
      // Advance time past interval
      await ethers.provider.send("evm_increaseTime", [3600]);
      await ethers.provider.send("evm_mine");

      await expect(
        subscriptionEscrow.connect(agentWallet).drainPerCheckIn(1)
      ).to.emit(subscriptionEscrow, "CheckInDrained");

      const sub = await subscriptionEscrow.getSubscription(1);
      expect(sub.balance).to.equal(ethers.parseEther("0.09"));
      expect(sub.totalDrained).to.equal(ethers.parseEther("0.01"));
    });

    it("should revert if too early for second check-in", async function () {
      // First check-in should succeed (no prior check-in)
      await ethers.provider.send("evm_increaseTime", [3600]);
      await ethers.provider.send("evm_mine");
      await subscriptionEscrow.connect(agentWallet).drainPerCheckIn(1);

      // Second check-in immediately should fail
      await expect(
        subscriptionEscrow.connect(agentWallet).drainPerCheckIn(1)
      ).to.be.revertedWith("SubscriptionEscrow: too early");
    });

    it("should revert if not agent", async function () {
      await ethers.provider.send("evm_increaseTime", [3600]);
      await ethers.provider.send("evm_mine");

      await expect(
        subscriptionEscrow.connect(stranger).drainPerCheckIn(1)
      ).to.be.revertedWith("SubscriptionEscrow: not agent");
    });

    it("should pause when balance too low", async function () {
      // Drain multiple times
      for (let i = 0; i < 10; i++) {
        await ethers.provider.send("evm_increaseTime", [3600]);
        await ethers.provider.send("evm_mine");
        await subscriptionEscrow.connect(agentWallet).drainPerCheckIn(1);
      }

      const sub = await subscriptionEscrow.getSubscription(1);
      expect(sub.status).to.equal(2); // PAUSED
    });
  });

  describe("drainPerAlert", function () {
    beforeEach(async function () {
      await subscriptionEscrow.connect(client).createSubscription(
        1,
        "Alert monitor",
        3600,
        ethers.parseEther("0.01"),
        ethers.parseEther("0.05"),
        0,
        false,
        0,
        "0x",
        ""
      , { value: ethers.parseEther("0.2") });
    });

    it("should drain alert balance and emit event", async function () {
      const alertData = ethers.toUtf8Bytes('{"severity":"high","message":"Balance low"}');

      await expect(
        subscriptionEscrow.connect(agentWallet).drainPerAlert(1, alertData)
      ).to.emit(subscriptionEscrow, "AlertFired");

      const sub = await subscriptionEscrow.getSubscription(1);
      expect(sub.balance).to.equal(ethers.parseEther("0.15"));
    });

    it("should allow multiple alerts without time gating", async function () {
      const alertData = ethers.toUtf8Bytes('{"severity":"high"}');

      // Fire two alerts quickly
      await subscriptionEscrow.connect(agentWallet).drainPerAlert(1, alertData);
      await subscriptionEscrow.connect(agentWallet).drainPerAlert(1, alertData);

      const sub = await subscriptionEscrow.getSubscription(1);
      expect(sub.totalDrained).to.equal(ethers.parseEther("0.1"));
    });
  });

  describe("balance exhaustion and grace period", function () {
    beforeEach(async function () {
      await subscriptionEscrow.connect(client).createSubscription(
        1,
        "Test",
        3600,
        ethers.parseEther("0.06"), // checkInRate
        ethers.parseEther("0.1"),
        86400, // 24h grace
        false,
        0,
        "0x",
        ""
      , { value: ethers.parseEther("0.1") }); // balance just enough for 1 check-in
    });

    it("should resume after topUp", async function () {
      // Drain all balance (0.1 - 0.06 = 0.04, which is < 0.06, so pause)
      await ethers.provider.send("evm_increaseTime", [3600]);
      await ethers.provider.send("evm_mine");
      await subscriptionEscrow.connect(agentWallet).drainPerCheckIn(1);

      // Should be paused (remaining 0.04 < checkInRate 0.06)
      let sub = await subscriptionEscrow.getSubscription(1);
      expect(sub.status).to.equal(2); // PAUSED

      // Top up
      await expect(
        subscriptionEscrow.connect(client).topUp(1, { value: ethers.parseEther("0.5") })
      ).to.emit(subscriptionEscrow, "SubscriptionResumed");

      sub = await subscriptionEscrow.getSubscription(1);
      expect(sub.status).to.equal(1); // ACTIVE
      expect(sub.balance).to.equal(ethers.parseEther("0.54")); // 0.04 + 0.5
    });

    it("should cancel after grace period expires", async function () {
      // Drain all balance
      await ethers.provider.send("evm_increaseTime", [3600]);
      await ethers.provider.send("evm_mine");
      await subscriptionEscrow.connect(agentWallet).drainPerCheckIn(1);

      // Should be paused
      const subPaused = await subscriptionEscrow.getSubscription(1);
      expect(subPaused.status).to.equal(2); // PAUSED

      // Advance past grace period
      await ethers.provider.send("evm_increaseTime", [86401]); // 24h + 1s
      await ethers.provider.send("evm_mine");

      await expect(
        subscriptionEscrow.connect(stranger).finalizeExpired(1)
      ).to.emit(subscriptionEscrow, "SubscriptionCancelled")
        .withArgs(1, "GRACE_EXPIRED", ethers.parseEther("0.04")); // refund remaining

      const sub = await subscriptionEscrow.getSubscription(1);
      expect(sub.status).to.equal(3); // CANCELLED
    });
  });

  describe("Mode B interval proposal", function () {
    beforeEach(async function () {
      await subscriptionEscrow.connect(client).createSubscription(
        1,
        "Test",
        0, // Mode B
        ethers.parseEther("0.01"),
        ethers.parseEther("0.05"),
        0,
        false,
        0,
        "0x",
        ""
      , { value: ethers.parseEther("1") });
    });

    it("should allow agent to propose and client to approve", async function () {
      // Agent proposes
      await expect(
        subscriptionEscrow.connect(agentWallet).proposeInterval(1, 7200)
      ).to.emit(subscriptionEscrow, "IntervalProposed")
        .withArgs(1, 7200);

      // Client approves
      await expect(
        subscriptionEscrow.connect(client).approveInterval(1)
      ).to.emit(subscriptionEscrow, "IntervalApproved")
        .withArgs(1, 7200);

      const sub = await subscriptionEscrow.getSubscription(1);
      expect(sub.status).to.equal(1); // ACTIVE
      expect(sub.intervalSeconds).to.equal(7200);
    });
  });

  describe("Mode C auto interval", function () {
    beforeEach(async function () {
      await subscriptionEscrow.connect(client).createSubscription(
        1,
        "Test",
        AUTO_INTERVAL, // Mode C
        ethers.parseEther("0.01"),
        ethers.parseEther("0.05"),
        0,
        false,
        0,
        "0x",
        ""
      , { value: ethers.parseEther("1") });
    });

    it("should allow agent to update interval dynamically", async function () {
      await expect(
        subscriptionEscrow.connect(agentWallet).updateInterval(1, 1800)
      ).to.emit(subscriptionEscrow, "IntervalUpdated")
        .withArgs(1, 1800);

      const sub = await subscriptionEscrow.getSubscription(1);
      expect(sub.intervalSeconds).to.equal(1800);
    });
  });

  describe("cancelSubscription", function () {
    beforeEach(async function () {
      await subscriptionEscrow.connect(client).createSubscription(
        1,
        "Test",
        3600,
        ethers.parseEther("0.01"),
        ethers.parseEther("0.05"),
        0,
        false,
        0,
        "0x",
        ""
      , { value: ethers.parseEther("1") });
    });

    it("should cancel and refund remaining balance", async function () {
      const initialBalance = await ethers.provider.getBalance(client.address);

      const tx = await subscriptionEscrow.connect(client).cancelSubscription(1);
      await expect(tx).to.emit(subscriptionEscrow, "SubscriptionCancelled");

      const sub = await subscriptionEscrow.getSubscription(1);
      expect(sub.status).to.equal(3); // CANCELLED
      expect(sub.balance).to.equal(0);
    });

    it("should revert if not client", async function () {
      await expect(
        subscriptionEscrow.connect(stranger).cancelSubscription(1)
      ).to.be.revertedWith("SubscriptionEscrow: not client");
    });
  });

  describe("setWebhookUrl", function () {
    beforeEach(async function () {
      await subscriptionEscrow.connect(client).createSubscription(
        1,
        "Test",
        3600,
        ethers.parseEther("0.01"),
        ethers.parseEther("0.05"),
        0,
        false,
        0,
        "0x",
        ""
      , { value: ethers.parseEther("1") });
    });

    it("should allow client to set webhook", async function () {
      await subscriptionEscrow.connect(client).setWebhookUrl(1, "https://example.com/hook");
      const sub = await subscriptionEscrow.getSubscription(1);
      expect(sub.webhookUrl).to.equal("https://example.com/hook");
    });

    it("should allow agent to set webhook", async function () {
      await subscriptionEscrow.connect(agentWallet).setWebhookUrl(1, "https://agent.io/webhook");
      const sub = await subscriptionEscrow.getSubscription(1);
      expect(sub.webhookUrl).to.equal("https://agent.io/webhook");
    });

    it("should revert for unauthorized user", async function () {
      await expect(
        subscriptionEscrow.connect(stranger).setWebhookUrl(1, "https://evil.com")
      ).to.be.revertedWith("SubscriptionEscrow: not authorized");
    });
  });
});

// Mock AgentRegistry for testing - deployed in beforeEach
