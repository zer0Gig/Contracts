// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @notice Minimal interface to AgentRegistry
interface IAgentRegistry {
    struct AgentProfile {
        address owner;
        address agentWallet;
        bytes eciesPublicKey;
        bytes32 capabilityHash;
        string capabilityCID;
        string profileCID;
        uint256 overallScore;
        uint256 totalJobsCompleted;
        uint256 totalJobsAttempted;
        uint256 totalEarningsWei;
        uint256 defaultRate;
        uint256 createdAt;
        bool isActive;
    }

    function getAgentProfile(uint256 agentId) external view returns (AgentProfile memory);
}

/// @title SubscriptionEscrow — Ongoing/subscription jobs for zer0Gig
/// @notice Clients fund a budget, agents drain per check-in or per alert.
///         Supports three interval modes, x402 bonus, and grace period logic.
contract SubscriptionEscrow is ReentrancyGuard {

    // ─── ENUMS ───────────────────────────────────────────────────────────────

    enum Status {
        PENDING,    // Waiting for interval approval (Mode B only)
        ACTIVE,     // Running normally
        PAUSED,     // Balance too low, grace period running
        CANCELLED   // Terminated, balance returned
    }

    enum IntervalMode {
        CLIENT_SET,     // Client defined interval at creation
        AGENT_PROPOSED, // Agent proposes, client approves (Mode B)
        AGENT_AUTO      // Agent auto-schedules (Mode C)
    }

    enum X402VerificationMode {
        AGENT_SIDE,     // Sig stored, agent verifies off-chain (default, low gas)
        ON_CHAIN        // Contract verifies sig on each drain
    }

    // ─── CONSTANTS ───────────────────────────────────────────────────────────

    uint256 public constant DEFAULT_GRACE_PERIOD = 86400;     // 24 hours
    uint256 public constant MIN_GRACE_PERIOD = 3600;          // 1 hour
    uint256 public constant MAX_GRACE_PERIOD = 604800;        // 7 days
    uint256 public constant AUTO_INTERVAL = type(uint256).max; // Mode C sentinel

    // ─── STRUCTS ─────────────────────────────────────────────────────────────

    struct Subscription {
        uint256 subscriptionId;
        address client;
        uint256 agentId;
        address agentWallet;
        string taskDescription;
        uint256 intervalSeconds;
        IntervalMode intervalMode;
        uint256 checkInRate;
        uint256 alertRate;
        uint256 balance;
        uint256 totalDrained;
        Status status;
        uint256 createdAt;
        uint256 lastCheckIn;
        uint256 pausedAt;
        uint256 gracePeriodEnds;
        uint256 gracePeriodSeconds;
        bool x402Enabled;
        X402VerificationMode x402VerificationMode;
        bytes clientX402Sig;
        string webhookUrl;
        uint256 proposedInterval;
    }

    // ─── STATE ───────────────────────────────────────────────────────────────

    uint256 private _subscriptionIdCounter;

    mapping(uint256 => Subscription) public subscriptions;
    mapping(address => uint256[]) public clientSubscriptions;
    mapping(address => uint256[]) public agentSubscriptions;

    IAgentRegistry public immutable agentRegistry;

    // ─── EVENTS ──────────────────────────────────────────────────────────────

    event SubscriptionCreated(
        uint256 indexed subscriptionId,
        uint256 indexed agentId,
        address client,
        uint256 budget
    );
    event SubscriptionPaused(uint256 indexed subscriptionId, string reason);
    event SubscriptionResumed(uint256 indexed subscriptionId, uint256 newBalance);
    event SubscriptionCancelled(uint256 indexed subscriptionId, string reason, uint256 refund);
    event CheckInDrained(
        uint256 indexed subscriptionId,
        uint256 indexed agentId,
        uint256 amount,
        uint256 timestamp
    );
    event AlertFired(
        uint256 indexed subscriptionId,
        uint256 indexed agentId,
        uint256 timestamp,
        bytes alertData,
        uint256 amountDrained
    );
    event IntervalProposed(uint256 indexed subscriptionId, uint256 suggestedInterval);
    event IntervalApproved(uint256 indexed subscriptionId, uint256 interval);
    event IntervalUpdated(uint256 indexed subscriptionId, uint256 newInterval);
    event X402BonusPaid(
        uint256 indexed subscriptionId,
        uint256 indexed agentId,
        uint256 amount
    );

    // ─── MODIFIERS ───────────────────────────────────────────────────────────

    modifier onlyClient(uint256 subscriptionId) {
        require(
            msg.sender == subscriptions[subscriptionId].client,
            "SubscriptionEscrow: not client"
        );
        _;
    }

    modifier onlyAgent(uint256 subscriptionId) {
        require(
            msg.sender == subscriptions[subscriptionId].agentWallet,
            "SubscriptionEscrow: not agent"
        );
        _;
    }

    modifier whenActive(uint256 subscriptionId) {
        require(
            subscriptions[subscriptionId].status == Status.ACTIVE,
            "SubscriptionEscrow: not active"
        );
        _;
    }

    modifier whenPending(uint256 subscriptionId) {
        require(
            subscriptions[subscriptionId].status == Status.PENDING,
            "SubscriptionEscrow: not pending"
        );
        _;
    }

    modifier whenPaused(uint256 subscriptionId) {
        require(
            subscriptions[subscriptionId].status == Status.PAUSED,
            "SubscriptionEscrow: not paused"
        );
        _;
    }

    // ─── CONSTRUCTOR ─────────────────────────────────────────────────────────

    constructor(address _agentRegistry) {
        require(_agentRegistry != address(0), "SubscriptionEscrow: zero address");
        agentRegistry = IAgentRegistry(_agentRegistry);
    }

    // ─── CLIENT FUNCTIONS ────────────────────────────────────────────────────

    /// @notice Create a new subscription (three modes based on intervalSeconds)
    /// @dev For Mode C (AGENT_AUTO), caller MUST call updateInterval() after creation to set a valid interval.
    ///      Using AUTO_INTERVAL (type(uint256).max) will cause drainPerCheckIn to revert until updated.
    /// @param agentId The agent to hire
    /// @param taskDescription What the agent should do
    /// @param intervalSeconds 0 = agent proposes (Mode B), MAX = agent auto (Mode C), else client-set (Mode A)
    /// @param checkInRate Wei per check-in
    /// @param alertRate Wei per alert
    /// @param gracePeriodSeconds 0 = use default (24h), clamped 1h-7d
    /// @param x402Enabled Whether x402 micropayment bonus is active
    /// @param x402VerificationMode AGENT_SIDE or ON_CHAIN
    /// @param clientX402Sig Pre-signed x402 authorization (empty if disabled)
    /// @param webhookUrl URL for webhook delivery (empty = on-chain only)
    function createSubscription(
        uint256 agentId,
        string calldata taskDescription,
        uint256 intervalSeconds,
        uint256 checkInRate,
        uint256 alertRate,
        uint256 gracePeriodSeconds,
        bool x402Enabled,
        X402VerificationMode x402VerificationMode,
        bytes calldata clientX402Sig,
        string calldata webhookUrl
    ) external payable returns (uint256 subscriptionId) {
        require(msg.value > 0, "SubscriptionEscrow: budget must be > 0");
        require(bytes(taskDescription).length > 0, "SubscriptionEscrow: empty description");
        require(checkInRate > 0 || alertRate > 0, "SubscriptionEscrow: need at least one rate > 0");

        // Fetch agent profile to get agentWallet
        IAgentRegistry.AgentProfile memory agent = agentRegistry.getAgentProfile(agentId);
        require(agent.isActive, "SubscriptionEscrow: agent not active");
        require(agent.agentWallet != address(0), "SubscriptionEscrow: invalid agent wallet");

        // Determine interval mode
        IntervalMode mode;
        if (intervalSeconds == 0) {
            mode = IntervalMode.AGENT_PROPOSED;
        } else if (intervalSeconds == AUTO_INTERVAL) {
            mode = IntervalMode.AGENT_AUTO;
        } else {
            mode = IntervalMode.CLIENT_SET;
        }

        // Clamp grace period
        uint256 grace = gracePeriodSeconds;
        if (grace == 0) {
            grace = DEFAULT_GRACE_PERIOD;
        } else if (grace < MIN_GRACE_PERIOD) {
            grace = MIN_GRACE_PERIOD;
        } else if (grace > MAX_GRACE_PERIOD) {
            grace = MAX_GRACE_PERIOD;
        }

        _subscriptionIdCounter++;
        subscriptionId = _subscriptionIdCounter;

        Status initialStatus = (mode == IntervalMode.AGENT_PROPOSED)
            ? Status.PENDING
            : Status.ACTIVE;

        subscriptions[subscriptionId] = Subscription({
            subscriptionId: subscriptionId,
            client: msg.sender,
            agentId: agentId,
            agentWallet: agent.agentWallet,
            taskDescription: taskDescription,
            intervalSeconds: (mode == IntervalMode.AGENT_PROPOSED) ? 0 : intervalSeconds,
            intervalMode: mode,
            checkInRate: checkInRate,
            alertRate: alertRate,
            balance: msg.value,
            totalDrained: 0,
            status: initialStatus,
            createdAt: block.timestamp,
            lastCheckIn: 0,
            pausedAt: 0,
            gracePeriodEnds: 0,
            gracePeriodSeconds: grace,
            x402Enabled: x402Enabled,
            x402VerificationMode: x402VerificationMode,
            clientX402Sig: clientX402Sig,
            webhookUrl: webhookUrl,
            proposedInterval: 0
        });

        clientSubscriptions[msg.sender].push(subscriptionId);
        agentSubscriptions[agent.agentWallet].push(subscriptionId);

        emit SubscriptionCreated(subscriptionId, agentId, msg.sender, msg.value);
    }

    /// @notice Add more funds to a subscription
    /// @param subscriptionId The subscription to top up
    function topUp(uint256 subscriptionId) external payable nonReentrant {
        require(msg.value > 0, "SubscriptionEscrow: must send ETH");

        Subscription storage sub = subscriptions[subscriptionId];
        require(
            sub.status == Status.ACTIVE || sub.status == Status.PAUSED,
            "SubscriptionEscrow: invalid status"
        );

        sub.balance += msg.value;

        if (sub.status == Status.PAUSED) {
            sub.status = Status.ACTIVE;
            sub.pausedAt = 0;
            sub.gracePeriodEnds = 0;
            emit SubscriptionResumed(subscriptionId, sub.balance);
        }
    }

    /// @notice Cancel a subscription (client only)
    /// @param subscriptionId The subscription to cancel
    function cancelSubscription(uint256 subscriptionId) external nonReentrant onlyClient(subscriptionId) {
        Subscription storage sub = subscriptions[subscriptionId];
        require(sub.status != Status.CANCELLED, "SubscriptionEscrow: already cancelled");

        uint256 refund = sub.balance;
        sub.balance = 0;
        sub.status = Status.CANCELLED;

        if (refund > 0) {
            (bool sent, ) = payable(sub.client).call{value: refund}("");
            require(sent, "SubscriptionEscrow: refund failed");
        }

        emit SubscriptionCancelled(subscriptionId, "CLIENT_CANCELLED", refund);
    }

    /// @notice Approve proposed interval (Mode B only, client only)
    /// @param subscriptionId The subscription
    function approveInterval(uint256 subscriptionId)
        external
        onlyClient(subscriptionId)
        whenPending(subscriptionId)
    {
        Subscription storage sub = subscriptions[subscriptionId];
        require(
            sub.intervalMode == IntervalMode.AGENT_PROPOSED,
            "SubscriptionEscrow: not Mode B"
        );
        require(sub.proposedInterval > 0, "SubscriptionEscrow: no proposal");

        sub.intervalSeconds = sub.proposedInterval;
        sub.status = Status.ACTIVE;

        emit IntervalApproved(subscriptionId, sub.intervalSeconds);
    }

    // ─── AGENT FUNCTIONS ─────────────────────────────────────────────────────

    /// @notice Drain funds after a scheduled check-in
    /// @dev Must call updateInterval() first if intervalMode == AGENT_AUTO (Mode C) to set a valid interval.
    ///      Otherwise, with AUTO_INTERVAL = type(uint256).max, the check-in will always revert.
    /// @param subscriptionId The subscription
    function drainPerCheckIn(uint256 subscriptionId)
        external
        nonReentrant
        onlyAgent(subscriptionId)
        whenActive(subscriptionId)
    {
        Subscription storage sub = subscriptions[subscriptionId];

        // Time gating
        require(
            block.timestamp >= sub.lastCheckIn + sub.intervalSeconds,
            "SubscriptionEscrow: too early"
        );
        require(sub.checkInRate > 0, "SubscriptionEscrow: check-in disabled");
        require(sub.balance >= sub.checkInRate, "SubscriptionEscrow: insufficient balance");

        // Check-effects-interactions
        sub.balance -= sub.checkInRate;
        sub.totalDrained += sub.checkInRate;
        sub.lastCheckIn = block.timestamp;

        emit CheckInDrained(subscriptionId, sub.agentId, sub.checkInRate, block.timestamp);

        // Transfer after state update
        (bool sent, ) = payable(sub.agentWallet).call{value: sub.checkInRate}("");
        require(sent, "SubscriptionEscrow: transfer failed");

        // Check if we should pause
        if (sub.balance < sub.checkInRate) {
            _pauseSubscription(subscriptionId, "INSUFFICIENT_BALANCE");
        }
    }

    /// @notice Drain funds after detecting an anomaly
    /// @param subscriptionId The subscription
    /// @param alertData Encoded alert payload
    function drainPerAlert(uint256 subscriptionId, bytes calldata alertData)
        external
        nonReentrant
        onlyAgent(subscriptionId)
        whenActive(subscriptionId)
    {
        Subscription storage sub = subscriptions[subscriptionId];

        require(sub.alertRate > 0, "SubscriptionEscrow: alerts disabled");
        require(sub.balance >= sub.alertRate, "SubscriptionEscrow: insufficient balance");

        uint256 amount = sub.alertRate;

        // Check-effects-interactions
        sub.balance -= amount;
        sub.totalDrained += amount;

        emit AlertFired(subscriptionId, sub.agentId, block.timestamp, alertData, amount);

        // Transfer after state update
        (bool sent, ) = payable(sub.agentWallet).call{value: amount}("");
        require(sent, "SubscriptionEscrow: transfer failed");

        // Check if we should pause
        if (sub.balance < sub.checkInRate && sub.checkInRate > 0) {
            _pauseSubscription(subscriptionId, "INSUFFICIENT_BALANCE");
        }
    }

    /// @notice Propose an interval (Mode B only, agent only)
    /// @param subscriptionId The subscription
    /// @param suggestedInterval The proposed interval in seconds
    function proposeInterval(uint256 subscriptionId, uint256 suggestedInterval)
        external
        onlyAgent(subscriptionId)
        whenPending(subscriptionId)
    {
        Subscription storage sub = subscriptions[subscriptionId];
        require(
            sub.intervalMode == IntervalMode.AGENT_PROPOSED,
            "SubscriptionEscrow: not Mode B"
        );
        require(suggestedInterval > 0, "SubscriptionEscrow: invalid interval");

        sub.proposedInterval = suggestedInterval;

        emit IntervalProposed(subscriptionId, suggestedInterval);
    }

    /// @notice Update interval dynamically (Mode C only, agent only)
    /// @param subscriptionId The subscription
    /// @param newInterval The new interval in seconds
    function updateInterval(uint256 subscriptionId, uint256 newInterval)
        external
        onlyAgent(subscriptionId)
        whenActive(subscriptionId)
    {
        Subscription storage sub = subscriptions[subscriptionId];
        require(
            sub.intervalMode == IntervalMode.AGENT_AUTO,
            "SubscriptionEscrow: not Mode C"
        );
        require(newInterval > 0, "SubscriptionEscrow: invalid interval");

        sub.intervalSeconds = newInterval;

        emit IntervalUpdated(subscriptionId, newInterval);
    }

    // ─── SHARED FUNCTIONS ────────────────────────────────────────────────────

    /// @notice Set webhook URL (client OR agent)
    /// @param subscriptionId The subscription
    /// @param webhookUrl The new webhook URL
    function setWebhookUrl(uint256 subscriptionId, string calldata webhookUrl) external {
        Subscription storage sub = subscriptions[subscriptionId];
        require(
            msg.sender == sub.client || msg.sender == sub.agentWallet,
            "SubscriptionEscrow: not authorized"
        );
        require(sub.status != Status.CANCELLED, "SubscriptionEscrow: cancelled");

        sub.webhookUrl = webhookUrl;
    }

    // ─── KEEPER FUNCTION ─────────────────────────────────────────────────────

    /// @notice Finalize an expired subscription (permissionless)
    /// @param subscriptionId The subscription
    function finalizeExpired(uint256 subscriptionId) external nonReentrant {
        Subscription storage sub = subscriptions[subscriptionId];

        require(sub.status == Status.PAUSED, "SubscriptionEscrow: not paused");
        require(
            block.timestamp >= sub.gracePeriodEnds,
            "SubscriptionEscrow: grace not expired"
        );

        uint256 refund = sub.balance;
        sub.balance = 0;
        sub.status = Status.CANCELLED;

        if (refund > 0) {
            (bool sent, ) = payable(sub.client).call{value: refund}("");
            require(sent, "SubscriptionEscrow: refund failed");
        }

        emit SubscriptionCancelled(subscriptionId, "GRACE_EXPIRED", refund);
    }

    // ─── INTERNAL FUNCTIONS ──────────────────────────────────────────────────

    function _pauseSubscription(uint256 subscriptionId, string memory reason) internal {
        Subscription storage sub = subscriptions[subscriptionId];

        sub.status = Status.PAUSED;
        sub.pausedAt = block.timestamp;
        sub.gracePeriodEnds = block.timestamp + sub.gracePeriodSeconds;

        emit SubscriptionPaused(subscriptionId, reason);
    }

    // ─── VIEW FUNCTIONS ───────────────────────────────────────────────────────

    function getSubscription(uint256 subscriptionId)
        external
        view
        returns (Subscription memory)
    {
        return subscriptions[subscriptionId];
    }

    function getBalance(uint256 subscriptionId) external view returns (uint256) {
        return subscriptions[subscriptionId].balance;
    }

    function getStatus(uint256 subscriptionId) external view returns (Status) {
        return subscriptions[subscriptionId].status;
    }

    function getClientSubscriptions(address client) external view returns (uint256[] memory) {
        return clientSubscriptions[client];
    }

    function getAgentSubscriptions(address agentWallet) external view returns (uint256[] memory) {
        return agentSubscriptions[agentWallet];
    }

    function totalSubscriptions() external view returns (uint256) {
        return _subscriptionIdCounter;
    }
}
