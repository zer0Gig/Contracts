// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Interface minimal ke AgentRegistry v2
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
    function recordJobResult(uint256 agentId, uint256 earningsWei, bool jobCompleted, bytes32 skillId) external;
    function hasSkill(uint256 agentId, bytes32 skillId) external view returns (bool);
}

/// @title ProgressiveEscrow — Proposal-based escrow with milestone-based release for zer0Gig
/// @notice Clients post jobs, agents submit proposals, clients accept and deposit budget, milestones evaluated by 0G Alignment Node.
contract ProgressiveEscrow is ReentrancyGuard, Ownable {
    using ECDSA for bytes32;

    // ─── ENUMS ───────────────────────────────────────────────────────────────

    enum JobStatus {
        OPEN,               // Job posted, waiting for proposals
        PENDING_MILESTONES, // Proposal accepted, waiting for client to define milestones
        IN_PROGRESS,        // Agent is working
        COMPLETED,          // All milestones approved
        CANCELLED,          // Cancelled
        PARTIALLY_DONE      // Some milestones approved, some rejected
    }

    enum MilestoneStatus {
        PENDING,    // Not yet submitted
        SUBMITTED,  // Submitted, awaiting evaluation
        APPROVED,   // Score >= threshold, funds released
        REJECTED,   // Score < threshold, funds refunded
        RETRYING    // Agent retrying
    }

    // ─── STRUCTS ─────────────────────────────────────────────────────────────

    struct Proposal {
        uint256 agentId;
        address agentOwner;
        uint256 proposedRateWei;
        string descriptionCID;
        uint256 submittedAt;
        bool accepted;
    }

    struct Milestone {
        uint8 percentage;           // % of total budget (sum = 100)
        uint256 amountWei;          // Milestone funds
        MilestoneStatus status;
        bytes32 criteriaHash;       // keccak256(success criteria)
        string outputCID;           // CID of work output in 0G Storage
        uint256 alignmentScore;     // Score from Alignment Node (0–10000)
        uint256 retryCount;
        uint256 submittedAt;
        uint256 completedAt;
    }

    struct Job {
        uint256 jobId;
        address client;
        uint256 agentId;            // Token ID from AgentRegistry
        address agentWallet;
        uint256 totalBudgetWei;
        uint256 releasedWei;
        JobStatus status;
        Milestone[] milestones;
        uint256 createdAt;
        string jobDataCID;          // Job brief (encrypted) in 0G Storage
        bytes32 skillId;            // Which skill this job requires
    }

    // ─── STATE ───────────────────────────────────────────────────────────────

    uint256 private _jobIdCounter;
    mapping(uint256 => Job) public jobs;
    mapping(address => uint256[]) public clientJobs;
    mapping(address => uint256[]) public agentJobs;
    mapping(uint256 => Proposal[]) public jobProposals;
    uint256[] private _openJobIds;
    mapping(uint256 => bool) private _isJobOpen;

    IAgentRegistry public immutable agentRegistry;

    /// @notice Valid address for signing evaluation result (0G Alignment Node relay)
    address public alignmentNodeVerifier;

    /// @notice Authorized platform releasers (e.g. platform dispatcher wallet)
    mapping(address => bool) public authorizedReleasers;

    /// @notice Minimum score for auto-approve (8000 = 80%)
    uint256 public constant APPROVAL_THRESHOLD = 8000;

    /// @notice Maximum retries per milestone
    uint256 public constant MAX_RETRIES = 5;

    // ─── EVENTS ──────────────────────────────────────────────────────────────

    event JobPosted(
        uint256 indexed jobId,
        address indexed client,
        bytes32 skillId,
        string jobDataCID
    );
    event ProposalSubmitted(
        uint256 indexed jobId,
        uint256 proposalIndex,
        uint256 indexed agentId,
        uint256 proposedRateWei
    );
    event ProposalAccepted(
        uint256 indexed jobId,
        uint256 proposalIndex,
        uint256 indexed agentId,
        uint256 budgetWei
    );
    event MilestoneDefined(uint256 indexed jobId, uint8 milestoneCount);
    event MilestoneSubmitted(
        uint256 indexed jobId,
        uint8 indexed milestoneIndex,
        string outputCID,
        uint256 retryCount
    );
    event MilestoneApproved(
        uint256 indexed jobId,
        uint8 indexed milestoneIndex,
        uint256 amountWei,
        uint256 alignmentScore
    );
    event MilestoneRejected(
        uint256 indexed jobId,
        uint8 indexed milestoneIndex,
        uint256 refundWei,
        uint256 alignmentScore
    );
    event JobCompleted(uint256 indexed jobId, uint256 totalReleasedWei);
    event JobCancelled(uint256 indexed jobId, uint256 refundWei);
    event ReleaserAuthorized(address indexed releaser, bool authorized);

    // ─── CONSTRUCTOR ─────────────────────────────────────────────────────────

    constructor(address _agentRegistry, address _alignmentNodeVerifier) {
        require(_agentRegistry != address(0), "ProgressiveEscrow: zero agentRegistry");
        require(_alignmentNodeVerifier != address(0), "ProgressiveEscrow: zero verifier");
        agentRegistry = IAgentRegistry(_agentRegistry);
        alignmentNodeVerifier = _alignmentNodeVerifier;
    }

    // ─── ADMIN ───────────────────────────────────────────────────────────────

    /// @notice Authorize a platform wallet to release milestones on behalf of agents.
    function addAuthorizedReleaser(address releaser) external onlyOwner {
        require(releaser != address(0), "ProgressiveEscrow: zero address");
        authorizedReleasers[releaser] = true;
        emit ReleaserAuthorized(releaser, true);
    }

    /// @notice Revoke platform releaser authorization.
    function removeAuthorizedReleaser(address releaser) external onlyOwner {
        authorizedReleasers[releaser] = false;
        emit ReleaserAuthorized(releaser, false);
    }

    // ─── EXTERNAL FUNCTIONS ──────────────────────────────────────────────────

    /// @notice Client posts a new open job (no deposit, no agent selected yet).
    function postJob(
        string calldata jobDataCID,
        bytes32 skillId
    ) external returns (uint256 jobId) {
        require(bytes(jobDataCID).length > 0, "ProgressiveEscrow: jobDataCID empty");

        _jobIdCounter++;
        jobId = _jobIdCounter;

        Job storage job = jobs[jobId];
        job.jobId = jobId;
        job.client = msg.sender;
        job.agentId = 0;
        job.agentWallet = address(0);
        job.totalBudgetWei = 0;
        job.releasedWei = 0;
        job.status = JobStatus.OPEN;
        job.createdAt = block.timestamp;
        job.jobDataCID = jobDataCID;
        job.skillId = skillId;

        clientJobs[msg.sender].push(jobId);
        _openJobIds.push(jobId);
        _isJobOpen[jobId] = true;

        emit JobPosted(jobId, msg.sender, skillId, jobDataCID);
    }

    /// @notice Agent submits a proposal for an open job.
    function submitProposal(
        uint256 jobId,
        uint256 agentId,
        uint256 proposedRateWei,
        string calldata descriptionCID
    ) external {
        Job storage job = jobs[jobId];
        require(job.status == JobStatus.OPEN, "ProgressiveEscrow: job not open");
        require(proposedRateWei > 0, "ProgressiveEscrow: rate must be > 0");

        IAgentRegistry.AgentProfile memory agent = agentRegistry.getAgentProfile(agentId);
        require(agent.owner == msg.sender, "ProgressiveEscrow: not agent owner");
        require(agent.isActive, "ProgressiveEscrow: agent not active");

        // Verify agent has the required skill (skip if general job)
        if (job.skillId != bytes32(0)) {
            require(
                agentRegistry.hasSkill(agentId, job.skillId),
                "ProgressiveEscrow: agent does not have required skill"
            );
        }

        uint256 proposalIndex = jobProposals[jobId].length;
        jobProposals[jobId].push(Proposal({
            agentId: agentId,
            agentOwner: msg.sender,
            proposedRateWei: proposedRateWei,
            descriptionCID: descriptionCID,
            submittedAt: block.timestamp,
            accepted: false
        }));

        emit ProposalSubmitted(jobId, proposalIndex, agentId, proposedRateWei);
    }

    /// @notice Client accepts a proposal and deposits the agreed budget.
    function acceptProposal(
        uint256 jobId,
        uint256 proposalIndex
    ) external payable nonReentrant {
        Job storage job = jobs[jobId];
        require(msg.sender == job.client, "ProgressiveEscrow: not client");
        require(job.status == JobStatus.OPEN, "ProgressiveEscrow: job not open");
        require(proposalIndex < jobProposals[jobId].length, "ProgressiveEscrow: invalid proposal index");

        Proposal storage proposal = jobProposals[jobId][proposalIndex];
        require(!proposal.accepted, "ProgressiveEscrow: proposal already accepted");
        require(msg.value == proposal.proposedRateWei, "ProgressiveEscrow: value must match proposed rate");

        IAgentRegistry.AgentProfile memory agent = agentRegistry.getAgentProfile(proposal.agentId);
        require(agent.isActive, "ProgressiveEscrow: agent no longer active");
        require(agent.agentWallet != address(0), "ProgressiveEscrow: invalid agentWallet");

        proposal.accepted = true;
        job.agentId = proposal.agentId;
        job.agentWallet = agent.agentWallet;
        job.totalBudgetWei = msg.value;
        job.status = JobStatus.PENDING_MILESTONES;

        _isJobOpen[jobId] = false;
        agentJobs[agent.agentWallet].push(jobId);

        emit ProposalAccepted(jobId, proposalIndex, proposal.agentId, msg.value);
    }

    /// @notice Client defines milestone breakdown.
    function defineMilestones(
        uint256 jobId,
        uint8[] calldata percentages,
        bytes32[] calldata criteriaHashes
    ) external {
        Job storage job = jobs[jobId];
        require(msg.sender == job.client, "ProgressiveEscrow: not client");
        require(job.status == JobStatus.PENDING_MILESTONES, "ProgressiveEscrow: milestones already defined");
        require(percentages.length > 0, "ProgressiveEscrow: at least 1 milestone required");
        require(percentages.length == criteriaHashes.length, "ProgressiveEscrow: array length mismatch");
        require(percentages.length <= 10, "ProgressiveEscrow: max 10 milestones");

        uint256 totalPercent = 0;
        for (uint256 i = 0; i < percentages.length; i++) {
            require(percentages[i] > 0, "ProgressiveEscrow: percentage must be > 0");
            totalPercent += percentages[i];

            job.milestones.push(Milestone({
                percentage: percentages[i],
                amountWei: (job.totalBudgetWei * percentages[i]) / 100,
                status: MilestoneStatus.PENDING,
                criteriaHash: criteriaHashes[i],
                outputCID: "",
                alignmentScore: 0,
                retryCount: 0,
                submittedAt: 0,
                completedAt: 0
            }));
        }
        require(totalPercent == 100, "ProgressiveEscrow: total percentage must be 100");

        job.status = JobStatus.IN_PROGRESS;
        emit MilestoneDefined(jobId, uint8(percentages.length));
    }

    /// @notice Agent requests milestone release after receiving score + sig from Alignment Node.
    function releaseMilestone(
        uint256 jobId,
        uint8 milestoneIndex,
        string calldata outputCID,
        uint256 alignmentScore,
        bytes calldata signature
    ) external nonReentrant {
        Job storage job = jobs[jobId];
        require(
            msg.sender == job.agentWallet || authorizedReleasers[msg.sender],
            "ProgressiveEscrow: only agentWallet or authorized releaser"
        );
        require(job.status == JobStatus.IN_PROGRESS, "ProgressiveEscrow: job not in progress");
        require(milestoneIndex < job.milestones.length, "ProgressiveEscrow: invalid index");

        Milestone storage milestone = job.milestones[milestoneIndex];
        require(
            milestone.status == MilestoneStatus.PENDING ||
            milestone.status == MilestoneStatus.RETRYING,
            "ProgressiveEscrow: milestone already finalized"
        );
        require(milestone.retryCount < MAX_RETRIES, "ProgressiveEscrow: max retries reached");
        require(alignmentScore <= 10000, "ProgressiveEscrow: invalid score");

        // Verify signature from Alignment Node
        bytes32 messageHash = keccak256(abi.encodePacked(
            jobId, milestoneIndex, alignmentScore, outputCID
        ));
        require(
            _verifyAlignmentSignature(messageHash, signature),
            "ProgressiveEscrow: invalid signature"
        );

        // Update milestone state
        milestone.outputCID = outputCID;
        milestone.alignmentScore = alignmentScore;
        milestone.submittedAt = block.timestamp;
        milestone.retryCount++;

        emit MilestoneSubmitted(jobId, milestoneIndex, outputCID, milestone.retryCount);

        if (alignmentScore >= APPROVAL_THRESHOLD) {
            milestone.status = MilestoneStatus.APPROVED;
            milestone.completedAt = block.timestamp;
            job.releasedWei += milestone.amountWei;

            (bool sent, ) = payable(job.agentWallet).call{value: milestone.amountWei}("");
            require(sent, "ProgressiveEscrow: transfer to agent failed");

            agentRegistry.recordJobResult(job.agentId, milestone.amountWei, true, job.skillId);
            emit MilestoneApproved(jobId, milestoneIndex, milestone.amountWei, alignmentScore);

            _checkJobCompletion(jobId);
        } else {
            milestone.status = MilestoneStatus.REJECTED;
            milestone.completedAt = block.timestamp;

            (bool sent, ) = payable(job.client).call{value: milestone.amountWei}("");
            require(sent, "ProgressiveEscrow: refund failed");

            agentRegistry.recordJobResult(job.agentId, 0, false, job.skillId);
            emit MilestoneRejected(jobId, milestoneIndex, milestone.amountWei, alignmentScore);
        }
    }

    /// @notice Client cancels job (allowed when OPEN or PENDING_MILESTONES).
    function cancelJob(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        require(msg.sender == job.client, "ProgressiveEscrow: not client");
        require(
            job.status == JobStatus.OPEN || job.status == JobStatus.PENDING_MILESTONES,
            "ProgressiveEscrow: cannot cancel a running job"
        );

        bool wasOpen = (job.status == JobStatus.OPEN);
        uint256 refund = job.totalBudgetWei - job.releasedWei;
        job.status = JobStatus.CANCELLED;

        if (wasOpen) {
            _isJobOpen[jobId] = false;
        }

        if (refund > 0) {
            (bool sent, ) = payable(job.client).call{value: refund}("");
            require(sent, "ProgressiveEscrow: cancel refund failed");
        }

        emit JobCancelled(jobId, refund);
    }

    // ─── INTERNAL FUNCTIONS ──────────────────────────────────────────────────

    function _verifyAlignmentSignature(
        bytes32 messageHash,
        bytes calldata signature
    ) internal view returns (bool) {
        bytes32 ethSignedHash = ECDSA.toEthSignedMessageHash(messageHash);
        address recovered = ECDSA.recover(ethSignedHash, signature);
        return recovered == alignmentNodeVerifier;
    }

    function _checkJobCompletion(uint256 jobId) internal {
        Job storage job = jobs[jobId];
        bool allApproved = true;
        bool anyRejected = false;

        for (uint256 i = 0; i < job.milestones.length; i++) {
            MilestoneStatus s = job.milestones[i].status;
            if (s != MilestoneStatus.APPROVED) allApproved = false;
            if (s == MilestoneStatus.REJECTED) anyRejected = true;
            if (s == MilestoneStatus.PENDING || s == MilestoneStatus.RETRYING) {
                return;
            }
        }

        if (allApproved) {
            job.status = JobStatus.COMPLETED;
        } else if (anyRejected) {
            job.status = JobStatus.PARTIALLY_DONE;
        }

        emit JobCompleted(jobId, job.releasedWei);
    }

    // ─── VIEW FUNCTIONS ───────────────────────────────────────────────────────

    function getJob(uint256 jobId) external view returns (Job memory) {
        return jobs[jobId];
    }

    function getMilestone(uint256 jobId, uint8 index) external view returns (Milestone memory) {
        return jobs[jobId].milestones[index];
    }

    function getClientJobs(address client) external view returns (uint256[] memory) {
        return clientJobs[client];
    }

    function getAgentJobs(address agentWallet) external view returns (uint256[] memory) {
        return agentJobs[agentWallet];
    }

    function getProposals(uint256 jobId) external view returns (Proposal[] memory) {
        return jobProposals[jobId];
    }

    function getOpenJobs() external view returns (uint256[] memory) {
        // Count open jobs
        uint256 count = 0;
        for (uint256 i = 0; i < _openJobIds.length; i++) {
            if (_isJobOpen[_openJobIds[i]]) count++;
        }

        uint256[] memory result = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < _openJobIds.length; i++) {
            if (_isJobOpen[_openJobIds[i]]) {
                result[idx++] = _openJobIds[i];
            }
        }
        return result;
    }

    function totalJobs() external view returns (uint256) {
        return _jobIdCounter;
    }
}
