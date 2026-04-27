// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @notice Minimal interface to AgentRegistry (ERC-7857) — packed struct version.
interface IAgentRegistry {
    struct AgentProfile {
        // Slot 0
        address owner;
        uint48  createdAt;
        uint16  winRate;
        uint16  version;
        bool    isActive;
        // Slot 1
        bytes32 capabilityHash;
        // Slot 2
        bytes32 profileHash;
        // Slot 3
        address agentWallet;
        uint64  totalJobsCompleted;
        uint32  defaultRate;
        // Slot 4
        uint64  totalJobsAttempted;
        uint128 totalEarningsWei;
        uint48  updatedAt;
    }

    function getAgentProfile(uint256 agentId) external view returns (AgentProfile memory);
}

/// @title SubscriptionEscrow — Recurring AI service escrow (ERC-8183 Recurring Extension)
/// @notice Clients fund a budget; agents drain per check-in or per alert.
///         Supports three interval modes (CLIENT_SET / AGENT_PROPOSED / AGENT_AUTO),
///         x402 micropayment bonus, and grace period auto-cancellation.
/// @dev Gas optimizations applied:
///        - Packed Subscription struct (5 slots core, was 18+).
///        - bytes32 taskDescriptionHash + webhookUrlHash (no string storage).
///        - Custom errors instead of require strings.
///        - uint96 wei amounts (max ~7.9e28 wei = 79B OG).
///        - Raw uint256 counter (no OZ Counters wrapper).
///        - x402 sig moved to separate mapping (only read on drain when enabled).
contract SubscriptionEscrow is ReentrancyGuard {

    // ─── ERRORS ─────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroBudget();
    error ZeroValue();
    error EmptyDescription();
    error ZeroRates();
    error AgentInactive();
    error InvalidStatus();
    error NotClient();
    error NotAgent();
    error NotAuthorized();
    error AlreadyCancelled();
    error TooEarly();
    error InsufficientBalance();
    error CheckInDisabled();
    error AlertsDisabled();
    error NotPaused();
    error NotActive();
    error NotPending();
    error GraceNotExpired();
    error NotModeB();
    error NotModeC();
    error InvalidInterval();
    error NoProposal();
    error TransferFailed();
    error RefundFailed();
    error ValueTooLarge();

    // ─── ENUMS ──────────────────────────────────────────────────────────────

    enum Status {
        PENDING,    // Mode B only — awaiting interval approval
        ACTIVE,
        PAUSED,
        CANCELLED
    }

    enum IntervalMode {
        CLIENT_SET,
        AGENT_PROPOSED,  // Mode B
        AGENT_AUTO       // Mode C
    }

    enum X402VerificationMode {
        AGENT_SIDE,
        ON_CHAIN
    }

    // ─── CONSTANTS ──────────────────────────────────────────────────────────

    uint32 public constant DEFAULT_GRACE_PERIOD = 86400;     // 24h
    uint32 public constant MIN_GRACE_PERIOD = 3600;          // 1h
    uint32 public constant MAX_GRACE_PERIOD = 604800;        // 7d
    uint32 public constant AUTO_INTERVAL = type(uint32).max; // Mode C sentinel (4,294,967,295 ≈ 49,710 days)

    // ─── STRUCTS (PACKED) ───────────────────────────────────────────────────

    /// @dev Slot 0: client(20) + agentId(8) + status(1) + intervalMode(1) + x402Mode(1) + x402Enabled(1)
    /// @dev Slot 1: agentWallet(20) + lastCheckIn(8) + intervalSeconds(4)
    /// @dev Slot 2: checkInRate(12) + alertRate(12) + createdAt(8)
    /// @dev Slot 3: balance(16) + totalDrained(16)
    /// @dev Slot 4: pausedAt(8) + gracePeriodEnds(8) + gracePeriodSeconds(4) + proposedInterval(4) + 8 free
    struct Subscription {
        // Slot 0
        address client;
        uint64  agentId;
        Status  status;
        IntervalMode intervalMode;
        X402VerificationMode x402VerificationMode;
        bool    x402Enabled;

        // Slot 1
        address agentWallet;
        uint64  lastCheckIn;
        uint32  intervalSeconds;

        // Slot 2
        uint96  checkInRate;
        uint96  alertRate;
        uint64  createdAt;

        // Slot 3
        uint128 balance;
        uint128 totalDrained;

        // Slot 4
        uint64  pausedAt;
        uint64  gracePeriodEnds;
        uint32  gracePeriodSeconds;
        uint32  proposedInterval;
        // 8 bytes free
    }

    // ─── STATE ──────────────────────────────────────────────────────────────

    uint256 private _nextSubId = 1;

    mapping(uint256 => Subscription) public subscriptions;

    /// @notice subId => task description hash (off-chain text in 0G Storage by hash)
    mapping(uint256 => bytes32) public subscriptionTaskHash;

    /// @notice subId => webhook URL hash (off-chain URL stored by hash; full URL in event)
    mapping(uint256 => bytes32) public subscriptionWebhookHash;

    /// @notice subId => x402 client signature (only for x402-enabled subs)
    mapping(uint256 => bytes) public subscriptionX402Sig;

    mapping(address => uint256[]) public clientSubscriptions;
    mapping(address => uint256[]) public agentSubscriptions;

    IAgentRegistry public immutable agentRegistry;

    // ─── EVENTS ─────────────────────────────────────────────────────────────

    event SubscriptionCreated(
        uint256 indexed subscriptionId,
        uint256 indexed agentId,
        address indexed client,
        uint128 budget,
        bytes32 taskHash
    );
    event SubscriptionPaused(uint256 indexed subscriptionId, bytes32 reason);
    event SubscriptionResumed(uint256 indexed subscriptionId, uint128 newBalance);
    event SubscriptionCancelled(uint256 indexed subscriptionId, bytes32 reason, uint128 refund);
    event CheckInDrained(uint256 indexed subscriptionId, uint256 indexed agentId, uint96 amount, uint64 timestamp);
    event AlertFired(uint256 indexed subscriptionId, uint256 indexed agentId, uint64 timestamp, bytes alertData, uint96 amountDrained);
    event IntervalProposed(uint256 indexed subscriptionId, uint32 suggestedInterval);
    event IntervalApproved(uint256 indexed subscriptionId, uint32 interval);
    event IntervalUpdated(uint256 indexed subscriptionId, uint32 newInterval);
    event WebhookSet(uint256 indexed subscriptionId, bytes32 webhookHash);

    // ─── MODIFIERS ──────────────────────────────────────────────────────────

    modifier onlyClient(uint256 subId) {
        if (msg.sender != subscriptions[subId].client) revert NotClient();
        _;
    }
    modifier onlyAgent(uint256 subId) {
        if (msg.sender != subscriptions[subId].agentWallet) revert NotAgent();
        _;
    }
    modifier whenActive(uint256 subId) {
        if (subscriptions[subId].status != Status.ACTIVE) revert NotActive();
        _;
    }
    modifier whenPending(uint256 subId) {
        if (subscriptions[subId].status != Status.PENDING) revert NotPending();
        _;
    }

    // ─── CONSTRUCTOR ────────────────────────────────────────────────────────

    constructor(address _agentRegistry) {
        if (_agentRegistry == address(0)) revert ZeroAddress();
        agentRegistry = IAgentRegistry(_agentRegistry);
    }

    // ─── CLIENT FUNCTIONS ───────────────────────────────────────────────────

    /// @notice Create a new subscription.
    /// @param agentId            The agent to subscribe to
    /// @param taskHash           keccak256 of the task description (text stored in 0G Storage)
    /// @param intervalSeconds    0 = agent proposes (Mode B); AUTO_INTERVAL = agent auto (Mode C); else client-set (Mode A)
    /// @param checkInRate        wei drained per check-in
    /// @param alertRate          wei drained per alert
    /// @param gracePeriodSeconds 0 = use default; clamped to [MIN, MAX]
    /// @param x402Enabled        Whether x402 micropayment bonus is active
    /// @param x402VerificationMode AGENT_SIDE (gas-efficient) or ON_CHAIN
    /// @param clientX402Sig      Pre-signed x402 authorization (empty if disabled)
    /// @param webhookHash        keccak256 of webhook URL (URL stored off-chain)
    function createSubscription(
        uint256 agentId,
        bytes32 taskHash,
        uint32  intervalSeconds,
        uint96  checkInRate,
        uint96  alertRate,
        uint32  gracePeriodSeconds,
        bool    x402Enabled,
        X402VerificationMode x402VerificationMode,
        bytes calldata clientX402Sig,
        bytes32 webhookHash
    ) external payable returns (uint256 subId) {
        if (msg.value == 0) revert ZeroBudget();
        if (msg.value > type(uint128).max) revert ValueTooLarge();
        if (taskHash == bytes32(0)) revert EmptyDescription();
        if (checkInRate == 0 && alertRate == 0) revert ZeroRates();

        IAgentRegistry.AgentProfile memory agent = agentRegistry.getAgentProfile(agentId);
        if (!agent.isActive) revert AgentInactive();
        if (agent.agentWallet == address(0)) revert ZeroAddress();

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
        uint32 grace = gracePeriodSeconds;
        if (grace == 0) {
            grace = DEFAULT_GRACE_PERIOD;
        } else if (grace < MIN_GRACE_PERIOD) {
            grace = MIN_GRACE_PERIOD;
        } else if (grace > MAX_GRACE_PERIOD) {
            grace = MAX_GRACE_PERIOD;
        }

        unchecked { subId = _nextSubId++; }

        Status initialStatus = (mode == IntervalMode.AGENT_PROPOSED) ? Status.PENDING : Status.ACTIVE;

        Subscription storage sub = subscriptions[subId];
        sub.client = msg.sender;
        sub.agentId = uint64(agentId);
        sub.agentWallet = agent.agentWallet;
        sub.intervalSeconds = (mode == IntervalMode.AGENT_PROPOSED) ? 0 : intervalSeconds;
        sub.intervalMode = mode;
        sub.checkInRate = checkInRate;
        sub.alertRate = alertRate;
        sub.balance = uint128(msg.value);
        sub.status = initialStatus;
        sub.createdAt = uint64(block.timestamp);
        sub.gracePeriodSeconds = grace;
        sub.x402Enabled = x402Enabled;
        sub.x402VerificationMode = x402VerificationMode;

        subscriptionTaskHash[subId] = taskHash;
        if (webhookHash != bytes32(0)) {
            subscriptionWebhookHash[subId] = webhookHash;
        }
        if (x402Enabled && clientX402Sig.length > 0) {
            subscriptionX402Sig[subId] = clientX402Sig;
        }

        clientSubscriptions[msg.sender].push(subId);
        agentSubscriptions[agent.agentWallet].push(subId);

        emit SubscriptionCreated(subId, agentId, msg.sender, uint128(msg.value), taskHash);
    }

    /// @notice Add more funds to a subscription.
    function topUp(uint256 subId) external payable nonReentrant {
        if (msg.value == 0) revert ZeroValue();
        if (msg.value > type(uint128).max) revert ValueTooLarge();

        Subscription storage sub = subscriptions[subId];
        Status s = sub.status;
        if (s != Status.ACTIVE && s != Status.PAUSED) revert InvalidStatus();

        unchecked { sub.balance += uint128(msg.value); }

        if (s == Status.PAUSED) {
            sub.status = Status.ACTIVE;
            sub.pausedAt = 0;
            sub.gracePeriodEnds = 0;
            emit SubscriptionResumed(subId, sub.balance);
        }
    }

    /// @notice Cancel a subscription (client only).
    function cancelSubscription(uint256 subId) external nonReentrant onlyClient(subId) {
        Subscription storage sub = subscriptions[subId];
        if (sub.status == Status.CANCELLED) revert AlreadyCancelled();

        uint128 refund = sub.balance;
        sub.balance = 0;
        sub.status = Status.CANCELLED;

        if (refund > 0) {
            (bool sent, ) = payable(sub.client).call{value: refund}("");
            if (!sent) revert RefundFailed();
        }

        emit SubscriptionCancelled(subId, "CLIENT_CANCELLED", refund);
    }

    /// @notice Approve a proposed interval (Mode B only, client only).
    function approveInterval(uint256 subId) external onlyClient(subId) whenPending(subId) {
        Subscription storage sub = subscriptions[subId];
        if (sub.intervalMode != IntervalMode.AGENT_PROPOSED) revert NotModeB();
        if (sub.proposedInterval == 0) revert NoProposal();

        sub.intervalSeconds = sub.proposedInterval;
        sub.status = Status.ACTIVE;

        emit IntervalApproved(subId, sub.intervalSeconds);
    }

    // ─── AGENT FUNCTIONS ────────────────────────────────────────────────────

    /// @notice Drain funds after a scheduled check-in.
    function drainPerCheckIn(uint256 subId)
        external nonReentrant onlyAgent(subId) whenActive(subId)
    {
        Subscription storage sub = subscriptions[subId];

        unchecked {
            if (block.timestamp < uint256(sub.lastCheckIn) + uint256(sub.intervalSeconds)) revert TooEarly();
        }
        if (sub.checkInRate == 0) revert CheckInDisabled();
        if (sub.balance < sub.checkInRate) revert InsufficientBalance();

        uint96 amount = sub.checkInRate;
        unchecked {
            sub.balance -= amount;
            sub.totalDrained += amount;
        }
        sub.lastCheckIn = uint64(block.timestamp);

        emit CheckInDrained(subId, sub.agentId, amount, uint64(block.timestamp));

        (bool sent, ) = payable(sub.agentWallet).call{value: amount}("");
        if (!sent) revert TransferFailed();

        if (sub.balance < sub.checkInRate) {
            _pauseSubscription(subId, "INSUFFICIENT_BALANCE");
        }
    }

    /// @notice Drain funds after detecting an anomaly (alert).
    function drainPerAlert(uint256 subId, bytes calldata alertData)
        external nonReentrant onlyAgent(subId) whenActive(subId)
    {
        Subscription storage sub = subscriptions[subId];

        if (sub.alertRate == 0) revert AlertsDisabled();
        if (sub.balance < sub.alertRate) revert InsufficientBalance();

        uint96 amount = sub.alertRate;
        unchecked {
            sub.balance -= amount;
            sub.totalDrained += amount;
        }

        emit AlertFired(subId, sub.agentId, uint64(block.timestamp), alertData, amount);

        (bool sent, ) = payable(sub.agentWallet).call{value: amount}("");
        if (!sent) revert TransferFailed();

        if (sub.checkInRate > 0 && sub.balance < sub.checkInRate) {
            _pauseSubscription(subId, "INSUFFICIENT_BALANCE");
        }
    }

    /// @notice Propose an interval (Mode B only, agent only).
    function proposeInterval(uint256 subId, uint32 suggestedInterval)
        external onlyAgent(subId) whenPending(subId)
    {
        Subscription storage sub = subscriptions[subId];
        if (sub.intervalMode != IntervalMode.AGENT_PROPOSED) revert NotModeB();
        if (suggestedInterval == 0) revert InvalidInterval();

        sub.proposedInterval = suggestedInterval;

        emit IntervalProposed(subId, suggestedInterval);
    }

    /// @notice Update interval dynamically (Mode C only, agent only).
    function updateInterval(uint256 subId, uint32 newInterval)
        external onlyAgent(subId) whenActive(subId)
    {
        Subscription storage sub = subscriptions[subId];
        if (sub.intervalMode != IntervalMode.AGENT_AUTO) revert NotModeC();
        if (newInterval == 0) revert InvalidInterval();

        sub.intervalSeconds = newInterval;

        emit IntervalUpdated(subId, newInterval);
    }

    // ─── SHARED ─────────────────────────────────────────────────────────────

    /// @notice Set webhook URL hash (client OR agent).
    function setWebhookHash(uint256 subId, bytes32 webhookHash) external {
        Subscription storage sub = subscriptions[subId];
        if (msg.sender != sub.client && msg.sender != sub.agentWallet) revert NotAuthorized();
        if (sub.status == Status.CANCELLED) revert AlreadyCancelled();

        subscriptionWebhookHash[subId] = webhookHash;
        emit WebhookSet(subId, webhookHash);
    }

    // ─── KEEPER ─────────────────────────────────────────────────────────────

    /// @notice Finalize an expired (paused) subscription. Permissionless.
    function finalizeExpired(uint256 subId) external nonReentrant {
        Subscription storage sub = subscriptions[subId];
        if (sub.status != Status.PAUSED) revert NotPaused();
        if (block.timestamp < sub.gracePeriodEnds) revert GraceNotExpired();

        uint128 refund = sub.balance;
        sub.balance = 0;
        sub.status = Status.CANCELLED;

        if (refund > 0) {
            (bool sent, ) = payable(sub.client).call{value: refund}("");
            if (!sent) revert RefundFailed();
        }

        emit SubscriptionCancelled(subId, "GRACE_EXPIRED", refund);
    }

    // ─── INTERNAL ───────────────────────────────────────────────────────────

    function _pauseSubscription(uint256 subId, bytes32 reason) internal {
        Subscription storage sub = subscriptions[subId];
        sub.status = Status.PAUSED;
        sub.pausedAt = uint64(block.timestamp);
        unchecked { sub.gracePeriodEnds = uint64(block.timestamp) + uint64(sub.gracePeriodSeconds); }

        emit SubscriptionPaused(subId, reason);
    }

    // ─── ERC-8183 ────────────────────────────────────────────────────────────

    /// @notice ERC-8183 evaluator stub (subscription doesn't have per-call evaluation).
    ///         Reserved for future per-execution alignment verification.
    function evaluator() external pure returns (address) {
        return address(0);
    }

    // ─── VIEW FUNCTIONS ─────────────────────────────────────────────────────

    function getSubscription(uint256 subId) external view returns (Subscription memory) {
        return subscriptions[subId];
    }

    function getBalance(uint256 subId) external view returns (uint128) {
        return subscriptions[subId].balance;
    }

    function getStatus(uint256 subId) external view returns (Status) {
        return subscriptions[subId].status;
    }

    function getClientSubscriptions(address client) external view returns (uint256[] memory) {
        return clientSubscriptions[client];
    }

    function getAgentSubscriptions(address agentWallet) external view returns (uint256[] memory) {
        return agentSubscriptions[agentWallet];
    }

    function totalSubscriptions() external view returns (uint256) {
        unchecked { return _nextSubId - 1; }
    }
}
