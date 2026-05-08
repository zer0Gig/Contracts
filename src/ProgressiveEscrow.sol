// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

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
    function recordJobResult(uint256 agentId, uint128 earningsWei, bool jobCompleted, bytes32 skillId) external;
    function hasSkill(uint256 agentId, bytes32 skillId) external view returns (bool);
}

/// @title ProgressiveEscrow — Milestone-based job escrow (ERC-8183 Agentic Commerce compliant)
/// @notice Clients post jobs, agents submit proposals, clients accept and deposit budget,
///         milestones evaluated by 0G Alignment Node signature.
/// @dev Gas optimizations applied:
///        - Packed Job struct (4 slots core, was 9+).
///        - Packed Milestone struct (3 slots, was 8+).
///        - Packed Proposal struct (2 slots, was 4+).
///        - bytes32 jobDataHash / outputHash instead of string CIDs.
///        - Custom errors instead of require strings.
///        - Open job tracking via single index map (not 2 storage vars).
///        - uint96 wei amounts (max ~79 billion OG, plenty for any rate).
///        - Raw uint256 counter (no OZ Counters wrapper).
///        - ERC-8183 events emitted alongside richer existing events.
contract ProgressiveEscrow is ReentrancyGuard {
    using ECDSA for bytes32;

    // ─── ERRORS ─────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroHash();
    error JobNotOpen();
    error JobNotInProgress();
    error JobNotCancellable();
    error NotClient();
    error NotAgentOwner();
    error NotAgentWallet();
    error AgentInactive();
    error AgentMissingSkill();
    error InvalidProposalIndex();
    error ProposalAlreadyAccepted();
    error ValueMismatch();
    error InvalidMilestoneCount();
    error PercentageNotZero();
    error PercentageSumInvalid();
    error InvalidMilestoneIndex();
    error MilestoneFinalized();
    error MaxRetriesReached();
    error InvalidScore();
    error InvalidSignature();
    error TransferFailed();
    error NotStale();
    error JobNotInProgressForCancel();
    error RefundFailed();
    error ZeroRate();
    error MilestonesAlreadyDefined();
    error ArrayLengthMismatch();

    // ─── ENUMS ──────────────────────────────────────────────────────────────

    enum JobStatus {
        OPEN,                // 0
        PENDING_MILESTONES,  // 1 — proposal accepted, awaiting client to define milestones
        IN_PROGRESS,         // 2
        COMPLETED,           // 3
        CANCELLED,           // 4
        PARTIALLY_DONE       // 5
    }

    enum MilestoneStatus {
        PENDING,    // 0
        SUBMITTED,  // 1
        APPROVED,   // 2
        REJECTED,   // 3
        RETRYING    // 4
    }

    /// @notice ERC-8183 standard state mapping
    enum ERC8183State {
        Open,        // 0
        Funded,      // 1
        Submitted,   // 2
        Terminal     // 3
    }

    // ─── STRUCTS (PACKED) ───────────────────────────────────────────────────

    /// @dev Slot 0: agentId(8) + agentOwner(20) + accepted(1) + reserved(3)
    /// @dev Slot 1: proposedRateWei(12) + submittedAt(8) + reserved(12)
    /// @dev Slot 2: descriptionHash (32) — replaces string descriptionCID
    struct Proposal {
        uint64  agentId;
        address agentOwner;
        bool    accepted;
        // 3 bytes free in slot 0
        uint96  proposedRateWei;
        uint64  submittedAt;
        // 12 bytes free in slot 1
        bytes32 descriptionHash;  // keccak256 of off-chain proposal description
    }

    /// @dev Slot 0: amountWei(12) + alignmentScore(2) + percentage(1) + retryCount(1)
    ///              + status(1) + submittedAt(6) + completedAt(6) + reserved(3)
    /// @dev Slot 1: criteriaHash(32)
    /// @dev Slot 2: outputHash(32)
    struct Milestone {
        uint96  amountWei;
        uint16  alignmentScore;     // 0–10000
        uint8   percentage;         // 0–100
        uint8   retryCount;         // 0–MAX_RETRIES
        MilestoneStatus status;     // 1 byte
        uint48  submittedAt;
        uint48  completedAt;
        // 3 bytes free in slot 0
        bytes32 criteriaHash;
        bytes32 outputHash;         // replaces string outputCID
    }

    /// @dev Slot 0: client(20) + agentId(8) + status(1) + milestoneCount(1) + reserved(2)
    /// @dev Slot 1: agentWallet(20) + totalBudgetWei(12)
    /// @dev Slot 2: releasedWei(12) + createdAt(8) + reserved(12)
    /// @dev Slot 3: skillId(32)
    /// @dev Slot 4: jobDataHash(32)  — replaces string jobDataCID
    struct Job {
        address client;
        uint64  agentId;
        JobStatus status;       // 1 byte
        uint8   milestoneCount; // 1 byte (max 10)
        // 2 bytes free
        address agentWallet;
        uint96  totalBudgetWei;
        uint96  releasedWei;
        uint64  createdAt;
        // 12 bytes free
        bytes32 skillId;
        bytes32 jobDataHash;
    }

    // ─── STATE ──────────────────────────────────────────────────────────────

    uint256 private _nextJobId = 1;

    mapping(uint256 => Job) public jobs;
    /// @notice jobId => array of milestones (separate from Job to keep struct lean).
    mapping(uint256 => Milestone[]) public jobMilestones;
    mapping(uint256 => Proposal[]) public jobProposals;
    mapping(address => uint256[]) public clientJobs;
    mapping(address => uint256[]) public agentJobs;

    uint256[] private _openJobIds;
    mapping(uint256 => uint256) private _openJobIndexPlusOne;  // 0 = not open

    IAgentRegistry public immutable agentRegistry;

    /// @notice Address whose ECDSA signature attests milestone alignment scores.
    ///         Aligns with ERC-8183 `evaluator` concept.
    address public alignmentNodeVerifier;

    uint256 public constant APPROVAL_THRESHOLD = 8000; // 80%
    uint256 public constant MAX_RETRIES = 5;
    uint8   public constant MAX_MILESTONES = 10;

    /// @notice After this many seconds of no milestone submission, the client may
    /// reclaim the unreleased budget via `cancelStaleJob`. 7 days by default.
    uint64  public constant STALE_JOB_TIMEOUT = 7 days;

    /// @notice Last on-chain activity (proposal accepted, milestone submitted/approved/rejected)
    /// for an IN_PROGRESS job. Used by `cancelStaleJob` to enforce the timeout.
    mapping(uint256 => uint64) public jobLastActivityAt;

    // ─── EVENTS ─────────────────────────────────────────────────────────────

    event JobPosted(uint256 indexed jobId, address indexed client, bytes32 skillId, bytes32 jobDataHash);
    event ProposalSubmitted(uint256 indexed jobId, uint256 proposalIndex, uint256 indexed agentId, uint96 proposedRateWei);
    event ProposalAccepted(uint256 indexed jobId, uint256 proposalIndex, uint256 indexed agentId, uint96 budgetWei);
    event MilestoneDefined(uint256 indexed jobId, uint8 milestoneCount);
    event MilestoneSubmitted(uint256 indexed jobId, uint8 indexed milestoneIndex, bytes32 outputHash, uint8 retryCount);
    event MilestoneApproved(uint256 indexed jobId, uint8 indexed milestoneIndex, uint96 amountWei, uint16 alignmentScore);
    event MilestoneRejected(uint256 indexed jobId, uint8 indexed milestoneIndex, uint96 refundWei, uint16 alignmentScore);
    event JobCompleted(uint256 indexed jobId, uint96 totalReleasedWei);
    event JobCancelled(uint256 indexed jobId, uint96 refundWei);

    // ERC-8183 standard events (emitted alongside the richer events above)
    event JobCreated(uint256 indexed jobId, address indexed client, bytes params);
    event JobFunded(uint256 indexed jobId, address indexed agent, uint96 amount);
    event JobSubmitted(uint256 indexed jobId, bytes evidence);
    event JobTerminal(uint256 indexed jobId, bool success, bytes data);

    // ─── CONSTRUCTOR ────────────────────────────────────────────────────────

    constructor(address _agentRegistry, address _alignmentNodeVerifier) {
        if (_agentRegistry == address(0) || _alignmentNodeVerifier == address(0)) revert ZeroAddress();
        agentRegistry = IAgentRegistry(_agentRegistry);
        alignmentNodeVerifier = _alignmentNodeVerifier;
    }

    // ─── PRIMARY FLOW ───────────────────────────────────────────────────────

    /// @notice Client posts a new open job. No deposit yet — agent is selected later.
    /// @param jobDataHash  keccak256 of job brief (computed off-chain; brief stored in 0G Storage)
    /// @param skillId      Required skill (bytes32(0) for skill-agnostic job)
    function postJob(bytes32 jobDataHash, bytes32 skillId) external returns (uint256 jobId) {
        if (jobDataHash == bytes32(0)) revert ZeroHash();

        unchecked { jobId = _nextJobId++; }

        Job storage job = jobs[jobId];
        job.client = msg.sender;
        job.status = JobStatus.OPEN;
        job.createdAt = uint64(block.timestamp);
        job.skillId = skillId;
        job.jobDataHash = jobDataHash;

        clientJobs[msg.sender].push(jobId);
        _openJobIds.push(jobId);
        _openJobIndexPlusOne[jobId] = _openJobIds.length;

        emit JobPosted(jobId, msg.sender, skillId, jobDataHash);
        // ERC-8183
        emit JobCreated(jobId, msg.sender, abi.encode(skillId, jobDataHash));
    }

    /// @notice Agent submits a proposal for an open job.
    function submitProposal(
        uint256 jobId,
        uint256 agentId,
        uint96  proposedRateWei,
        bytes32 descriptionHash
    ) external {
        Job storage job = jobs[jobId];
        if (job.status != JobStatus.OPEN) revert JobNotOpen();
        if (proposedRateWei == 0) revert ZeroRate();

        IAgentRegistry.AgentProfile memory agent = agentRegistry.getAgentProfile(agentId);
        if (agent.owner != msg.sender) revert NotAgentOwner();
        if (!agent.isActive) revert AgentInactive();

        // Skill check (skip if general job)
        bytes32 sId = job.skillId;
        if (sId != bytes32(0)) {
            if (!agentRegistry.hasSkill(agentId, sId)) revert AgentMissingSkill();
        }

        uint256 proposalIndex = jobProposals[jobId].length;
        jobProposals[jobId].push(Proposal({
            agentId: uint64(agentId),
            agentOwner: msg.sender,
            accepted: false,
            proposedRateWei: proposedRateWei,
            submittedAt: uint64(block.timestamp),
            descriptionHash: descriptionHash
        }));

        emit ProposalSubmitted(jobId, proposalIndex, agentId, proposedRateWei);
    }

    /// @notice Client accepts a proposal and deposits the agreed budget.
    function acceptProposal(uint256 jobId, uint256 proposalIndex)
        external payable nonReentrant
    {
        Job storage job = jobs[jobId];
        if (msg.sender != job.client) revert NotClient();
        if (job.status != JobStatus.OPEN) revert JobNotOpen();
        if (proposalIndex >= jobProposals[jobId].length) revert InvalidProposalIndex();

        Proposal storage proposal = jobProposals[jobId][proposalIndex];
        if (proposal.accepted) revert ProposalAlreadyAccepted();
        if (msg.value != proposal.proposedRateWei) revert ValueMismatch();
        if (msg.value > type(uint96).max) revert ValueMismatch();

        IAgentRegistry.AgentProfile memory agent = agentRegistry.getAgentProfile(proposal.agentId);
        if (!agent.isActive) revert AgentInactive();
        if (agent.agentWallet == address(0)) revert ZeroAddress();

        proposal.accepted = true;
        job.agentId = proposal.agentId;
        job.agentWallet = agent.agentWallet;
        job.totalBudgetWei = uint96(msg.value);
        job.status = JobStatus.PENDING_MILESTONES;

        // Remove from open list (swap-pop)
        _removeFromOpenList(jobId);

        agentJobs[agent.agentWallet].push(jobId);

        emit ProposalAccepted(jobId, proposalIndex, proposal.agentId, uint96(msg.value));
        // ERC-8183
        emit JobFunded(jobId, agent.agentWallet, uint96(msg.value));
    }

    /// @notice Client defines milestone breakdown.
    function defineMilestones(
        uint256 jobId,
        uint8[] calldata percentages,
        bytes32[] calldata criteriaHashes
    ) external {
        Job storage job = jobs[jobId];
        if (msg.sender != job.client) revert NotClient();
        if (job.status != JobStatus.PENDING_MILESTONES) revert MilestonesAlreadyDefined();

        uint256 len = percentages.length;
        if (len == 0 || len > MAX_MILESTONES) revert InvalidMilestoneCount();
        if (len != criteriaHashes.length) revert ArrayLengthMismatch();

        Milestone[] storage milestones = jobMilestones[jobId];
        uint96 budget = job.totalBudgetWei;
        uint256 totalPercent;

        for (uint256 i; i < len; ) {
            uint8 p = percentages[i];
            if (p == 0) revert PercentageNotZero();
            unchecked { totalPercent += p; }

            uint96 amount = uint96((uint256(budget) * p) / 100);
            milestones.push(Milestone({
                amountWei: amount,
                alignmentScore: 0,
                percentage: p,
                retryCount: 0,
                status: MilestoneStatus.PENDING,
                submittedAt: 0,
                completedAt: 0,
                criteriaHash: criteriaHashes[i],
                outputHash: bytes32(0)
            }));

            unchecked { ++i; }
        }
        if (totalPercent != 100) revert PercentageSumInvalid();

        job.milestoneCount = uint8(len);
        job.status = JobStatus.IN_PROGRESS;
        jobLastActivityAt[jobId] = uint64(block.timestamp);

        emit MilestoneDefined(jobId, uint8(len));
    }

    /// @notice Agent submits milestone output with alignment node signature.
    /// @param outputHash  keccak256 of work output (output stored in 0G Storage by hash)
    function releaseMilestone(
        uint256 jobId,
        uint8   milestoneIndex,
        bytes32 outputHash,
        uint16  alignmentScore,
        bytes calldata signature
    ) external nonReentrant {
        Job storage job = jobs[jobId];
        if (msg.sender != job.agentWallet) revert NotAgentWallet();
        if (job.status != JobStatus.IN_PROGRESS) revert JobNotInProgress();
        if (milestoneIndex >= job.milestoneCount) revert InvalidMilestoneIndex();
        if (alignmentScore > 10000) revert InvalidScore();

        Milestone storage milestone = jobMilestones[jobId][milestoneIndex];
        if (milestone.status != MilestoneStatus.PENDING && milestone.status != MilestoneStatus.RETRYING) {
            revert MilestoneFinalized();
        }
        if (milestone.retryCount >= MAX_RETRIES) revert MaxRetriesReached();

        // Verify alignment node signature over (jobId, milestoneIndex, alignmentScore, outputHash)
        bytes32 messageHash = keccak256(abi.encode(jobId, milestoneIndex, alignmentScore, outputHash));
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        if (ethSigned.recover(signature) != alignmentNodeVerifier) revert InvalidSignature();

        // Update milestone
        milestone.outputHash = outputHash;
        milestone.alignmentScore = alignmentScore;
        milestone.submittedAt = uint48(block.timestamp);
        unchecked { milestone.retryCount += 1; }
        jobLastActivityAt[jobId] = uint64(block.timestamp);

        emit MilestoneSubmitted(jobId, milestoneIndex, outputHash, milestone.retryCount);
        // ERC-8183
        emit JobSubmitted(jobId, abi.encode(milestoneIndex, outputHash, alignmentScore));

        if (alignmentScore >= APPROVAL_THRESHOLD) {
            milestone.status = MilestoneStatus.APPROVED;
            milestone.completedAt = uint48(block.timestamp);

            uint96 amount = milestone.amountWei;
            unchecked { job.releasedWei += amount; }

            (bool sent, ) = payable(job.agentWallet).call{value: amount}("");
            if (!sent) revert TransferFailed();

            agentRegistry.recordJobResult(uint256(job.agentId), uint128(amount), true, job.skillId);
            emit MilestoneApproved(jobId, milestoneIndex, amount, alignmentScore);

            _checkJobCompletion(jobId);
        } else {
            milestone.status = MilestoneStatus.REJECTED;
            milestone.completedAt = uint48(block.timestamp);

            uint96 amount = milestone.amountWei;
            (bool sent, ) = payable(job.client).call{value: amount}("");
            if (!sent) revert RefundFailed();

            agentRegistry.recordJobResult(uint256(job.agentId), 0, false, job.skillId);
            emit MilestoneRejected(jobId, milestoneIndex, amount, alignmentScore);
        }
    }

    /// @notice Client cancels a job (only when OPEN or PENDING_MILESTONES).
    function cancelJob(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        if (msg.sender != job.client) revert NotClient();

        JobStatus status = job.status;
        if (status != JobStatus.OPEN && status != JobStatus.PENDING_MILESTONES) revert JobNotCancellable();

        uint96 refund;
        unchecked { refund = job.totalBudgetWei - job.releasedWei; }
        job.status = JobStatus.CANCELLED;

        if (status == JobStatus.OPEN) {
            _removeFromOpenList(jobId);
        }

        if (refund > 0) {
            (bool sent, ) = payable(job.client).call{value: refund}("");
            if (!sent) revert RefundFailed();
        }

        emit JobCancelled(jobId, refund);
        // ERC-8183
        emit JobTerminal(jobId, false, abi.encode(refund));
    }

    /// @notice Reclaim funds from a stalled IN_PROGRESS job. The client may call
    /// this after STALE_JOB_TIMEOUT seconds have elapsed since the agent's last
    /// on-chain activity (acceptProposal, milestone submit/approve/reject).
    /// Refunds the unreleased portion only — already-released milestones stay
    /// with the agent. The agent's reputation is decremented (failed job).
    function cancelStaleJob(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        if (msg.sender != job.client) revert NotClient();
        if (job.status != JobStatus.IN_PROGRESS) revert JobNotInProgressForCancel();

        uint64 lastActivity = jobLastActivityAt[jobId];
        if (lastActivity == 0) lastActivity = job.createdAt;
        if (block.timestamp < uint256(lastActivity) + STALE_JOB_TIMEOUT) revert NotStale();

        uint96 refund;
        unchecked { refund = job.totalBudgetWei - job.releasedWei; }
        job.status = JobStatus.CANCELLED;

        // Reputation hit on the agent (treated as a failed job, no payout for this slice)
        agentRegistry.recordJobResult(uint256(job.agentId), 0, false, job.skillId);

        if (refund > 0) {
            (bool sent, ) = payable(job.client).call{value: refund}("");
            if (!sent) revert RefundFailed();
        }

        emit JobCancelled(jobId, refund);
        emit JobTerminal(jobId, false, abi.encode(refund));
    }

    // ─── INTERNAL ───────────────────────────────────────────────────────────

    function _removeFromOpenList(uint256 jobId) internal {
        uint256 idxPlus1 = _openJobIndexPlusOne[jobId];
        if (idxPlus1 == 0) return; // not in list

        uint256 idx;
        unchecked { idx = idxPlus1 - 1; }
        uint256 lastIdx;
        unchecked { lastIdx = _openJobIds.length - 1; }

        if (idx != lastIdx) {
            uint256 lastId = _openJobIds[lastIdx];
            _openJobIds[idx] = lastId;
            _openJobIndexPlusOne[lastId] = idx + 1;
        }
        _openJobIds.pop();
        delete _openJobIndexPlusOne[jobId];
    }

    function _checkJobCompletion(uint256 jobId) internal {
        Job storage job = jobs[jobId];
        Milestone[] storage milestones = jobMilestones[jobId];

        bool allApproved = true;
        bool anyRejected = false;
        uint256 len = milestones.length;

        for (uint256 i; i < len; ) {
            MilestoneStatus s = milestones[i].status;
            if (s == MilestoneStatus.PENDING || s == MilestoneStatus.RETRYING) return;
            if (s != MilestoneStatus.APPROVED) allApproved = false;
            if (s == MilestoneStatus.REJECTED) anyRejected = true;
            unchecked { ++i; }
        }

        if (allApproved) {
            job.status = JobStatus.COMPLETED;
            emit JobCompleted(jobId, job.releasedWei);
            emit JobTerminal(jobId, true, abi.encode(job.releasedWei));
        } else if (anyRejected) {
            job.status = JobStatus.PARTIALLY_DONE;
            emit JobCompleted(jobId, job.releasedWei);
            emit JobTerminal(jobId, false, abi.encode(job.releasedWei));
        }
    }

    // ─── ERC-8183 VIEWS ─────────────────────────────────────────────────────

    /// @notice ERC-8183: address that attests job completion.
    function evaluator() external view returns (address) {
        return alignmentNodeVerifier;
    }

    /// @notice ERC-8183: map our 6-state JobStatus to ERC-8183's 4 states.
    function getJobState(uint256 jobId) external view returns (ERC8183State) {
        JobStatus s = jobs[jobId].status;
        if (s == JobStatus.OPEN) return ERC8183State.Open;
        if (s == JobStatus.PENDING_MILESTONES) return ERC8183State.Funded;
        if (s == JobStatus.IN_PROGRESS) return ERC8183State.Submitted;
        return ERC8183State.Terminal;
    }

    // ─── VIEW FUNCTIONS ─────────────────────────────────────────────────────

    function getJob(uint256 jobId) external view returns (Job memory) {
        return jobs[jobId];
    }

    function getMilestone(uint256 jobId, uint8 index) external view returns (Milestone memory) {
        return jobMilestones[jobId][index];
    }

    function getMilestones(uint256 jobId) external view returns (Milestone[] memory) {
        return jobMilestones[jobId];
    }

    function getProposals(uint256 jobId) external view returns (Proposal[] memory) {
        return jobProposals[jobId];
    }

    function getClientJobs(address client) external view returns (uint256[] memory) {
        return clientJobs[client];
    }

    function getAgentJobs(address agentWallet) external view returns (uint256[] memory) {
        return agentJobs[agentWallet];
    }

    function getOpenJobs() external view returns (uint256[] memory) {
        return _openJobIds;
    }

    function totalJobs() external view returns (uint256) {
        unchecked { return _nextJobId - 1; }
    }
}
