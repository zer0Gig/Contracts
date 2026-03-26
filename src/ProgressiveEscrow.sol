// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice Interface minimal ke AgentRegistry
interface IAgentRegistry {
    struct AgentProfile {
        address owner;
        uint8 agentType;
        uint256 baseRate;
        uint256 efficiencyScore;
        string resumeCID;
        address agentWallet;
        bytes eciesPublicKey;
        uint256 totalJobsCompleted;
        uint256 totalJobsAttempted;
        uint256 totalEarningsWei;
        uint256 createdAt;
        bool isActive;
    }

    function getAgentProfile(uint256 agentId) external view returns (AgentProfile memory);
    function recordJobResult(uint256 agentId, uint256 earningsWei, bool jobCompleted) external;
}

/// @title ProgressiveEscrow — Escrow dengan milestone-based release untuk DeAI FreelanceAgent
/// @notice Klien deposit dana, milestone dinilai oleh 0G Alignment Node, dana cair per milestone.
contract ProgressiveEscrow is ReentrancyGuard {
    using ECDSA for bytes32;

    // ─── ENUMS ───────────────────────────────────────────────────────────────

    enum JobStatus {
        PENDING_MILESTONES, // Menunggu klien definisikan milestone
        IN_PROGRESS,        // Agent bisa mulai bekerja
        COMPLETED,          // Semua milestone di-approve
        CANCELLED,          // Dibatalkan, full refund
        PARTIALLY_DONE      // Sebagian selesai, sebagian gagal
    }

    enum MilestoneStatus {
        PENDING,    // Belum disubmit
        SUBMITTED,  // Disubmit, menunggu evaluasi
        APPROVED,   // Score >= threshold, dana cair
        REJECTED,   // Score < threshold, dana refund
        RETRYING    // Agent sedang mengulang
    }

    // ─── STRUCTS ─────────────────────────────────────────────────────────────

    struct Milestone {
        uint8 percentage;           // % dari total budget (sum = 100)
        uint256 amountWei;          // Dana milestone ini
        MilestoneStatus status;
        bytes32 criteriaHash;       // keccak256(kriteria sukses)
        string outputCID;           // CID hasil kerja di 0G Storage
        uint256 alignmentScore;     // Skor dari Alignment Node (0–10000)
        uint256 retryCount;
        uint256 submittedAt;
        uint256 completedAt;
    }

    struct Job {
        uint256 jobId;
        address client;
        uint256 agentId;            // Token ID dari AgentRegistry
        address agentWallet;
        uint256 totalBudgetWei;
        uint256 releasedWei;
        JobStatus status;
        Milestone[] milestones;
        uint256 createdAt;
        string jobDataCID;          // Job brief terenkripsi di 0G Storage
    }

    // ─── STATE ───────────────────────────────────────────────────────────────

    uint256 private _jobIdCounter;
    mapping(uint256 => Job) public jobs;
    mapping(address => uint256[]) public clientJobs;
    mapping(address => uint256[]) public agentJobs;

    IAgentRegistry public immutable agentRegistry;

    /// @notice Alamat valid untuk sign evaluation result (0G Alignment Node relay)
    address public alignmentNodeVerifier;

    /// @notice Minimum score untuk auto-approve (8000 = 80%)
    uint256 public constant APPROVAL_THRESHOLD = 8000;

    /// @notice Maximum retry per milestone
    uint256 public constant MAX_RETRIES = 5;

    // ─── EVENTS ──────────────────────────────────────────────────────────────

    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        uint256 indexed agentId,
        uint256 totalBudgetWei,
        string jobDataCID
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

    // ─── CONSTRUCTOR ─────────────────────────────────────────────────────────

    constructor(address _agentRegistry, address _alignmentNodeVerifier) {
        require(_agentRegistry != address(0), "ProgressiveEscrow: zero agentRegistry");
        require(_alignmentNodeVerifier != address(0), "ProgressiveEscrow: zero verifier");
        agentRegistry = IAgentRegistry(_agentRegistry);
        alignmentNodeVerifier = _alignmentNodeVerifier;
    }

    // ─── EXTERNAL FUNCTIONS ──────────────────────────────────────────────────

    /// @notice Klien membuat job baru dan deposit dana ke escrow.
    function createJob(
        uint256 agentId,
        string calldata jobDataCID
    ) external payable nonReentrant returns (uint256 jobId) {
        require(msg.value > 0, "ProgressiveEscrow: budget harus > 0");
        require(bytes(jobDataCID).length > 0, "ProgressiveEscrow: jobDataCID kosong");

        IAgentRegistry.AgentProfile memory agent = agentRegistry.getAgentProfile(agentId);
        require(agent.isActive, "ProgressiveEscrow: agent tidak aktif");
        require(agent.agentWallet != address(0), "ProgressiveEscrow: agentWallet tidak valid");

        _jobIdCounter++;
        jobId = _jobIdCounter;

        Job storage job = jobs[jobId];
        job.jobId = jobId;
        job.client = msg.sender;
        job.agentId = agentId;
        job.agentWallet = agent.agentWallet;
        job.totalBudgetWei = msg.value;
        job.releasedWei = 0;
        job.status = JobStatus.PENDING_MILESTONES;
        job.createdAt = block.timestamp;
        job.jobDataCID = jobDataCID;

        clientJobs[msg.sender].push(jobId);
        agentJobs[agent.agentWallet].push(jobId);

        emit JobCreated(jobId, msg.sender, agentId, msg.value, jobDataCID);
    }

    /// @notice Klien mendefinisikan breakdown milestone.
    function defineMilestones(
        uint256 jobId,
        uint8[] calldata percentages,
        bytes32[] calldata criteriaHashes
    ) external {
        Job storage job = jobs[jobId];
        require(msg.sender == job.client, "ProgressiveEscrow: bukan klien");
        require(job.status == JobStatus.PENDING_MILESTONES, "ProgressiveEscrow: milestone sudah didefinisikan");
        require(percentages.length > 0, "ProgressiveEscrow: minimal 1 milestone");
        require(percentages.length == criteriaHashes.length, "ProgressiveEscrow: array length tidak sama");
        require(percentages.length <= 10, "ProgressiveEscrow: maksimal 10 milestone");

        uint256 totalPercent = 0;
        for (uint256 i = 0; i < percentages.length; i++) {
            require(percentages[i] > 0, "ProgressiveEscrow: persentase harus > 0");
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
        require(totalPercent == 100, "ProgressiveEscrow: total persentase harus 100");

        job.status = JobStatus.IN_PROGRESS;
        emit MilestoneDefined(jobId, uint8(percentages.length));
    }

    /// @notice Agent request pencairan milestone setelah dapat score + sig dari Alignment Node.
    function releaseMilestone(
        uint256 jobId,
        uint8 milestoneIndex,
        string calldata outputCID,
        uint256 alignmentScore,
        bytes calldata signature
    ) external nonReentrant {
        Job storage job = jobs[jobId];
        require(msg.sender == job.agentWallet, "ProgressiveEscrow: hanya agentWallet");
        require(job.status == JobStatus.IN_PROGRESS, "ProgressiveEscrow: job tidak dalam progress");
        require(milestoneIndex < job.milestones.length, "ProgressiveEscrow: index tidak valid");

        Milestone storage milestone = job.milestones[milestoneIndex];
        require(
            milestone.status == MilestoneStatus.PENDING ||
            milestone.status == MilestoneStatus.RETRYING,
            "ProgressiveEscrow: milestone sudah final"
        );
        require(milestone.retryCount < MAX_RETRIES, "ProgressiveEscrow: max retries tercapai");
        require(alignmentScore <= 10000, "ProgressiveEscrow: score tidak valid");

        // Verifikasi signature dari Alignment Node
        bytes32 messageHash = keccak256(abi.encodePacked(
            jobId, milestoneIndex, alignmentScore, outputCID
        ));
        require(
            _verifyAlignmentSignature(messageHash, signature),
            "ProgressiveEscrow: signature tidak valid"
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
            require(sent, "ProgressiveEscrow: transfer ke agent gagal");

            agentRegistry.recordJobResult(job.agentId, milestone.amountWei, true);
            emit MilestoneApproved(jobId, milestoneIndex, milestone.amountWei, alignmentScore);

            _checkJobCompletion(jobId);
        } else {
            milestone.status = MilestoneStatus.REJECTED;
            milestone.completedAt = block.timestamp;

            (bool sent, ) = payable(job.client).call{value: milestone.amountWei}("");
            require(sent, "ProgressiveEscrow: refund gagal");

            agentRegistry.recordJobResult(job.agentId, 0, false);
            emit MilestoneRejected(jobId, milestoneIndex, milestone.amountWei, alignmentScore);
        }
    }

    /// @notice Klien batalkan job (hanya jika belum IN_PROGRESS).
    function cancelJob(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        require(msg.sender == job.client, "ProgressiveEscrow: bukan klien");
        require(
            job.status == JobStatus.PENDING_MILESTONES,
            "ProgressiveEscrow: tidak bisa cancel job yang sudah berjalan"
        );

        uint256 refund = job.totalBudgetWei - job.releasedWei;
        job.status = JobStatus.CANCELLED;

        (bool sent, ) = payable(job.client).call{value: refund}("");
        require(sent, "ProgressiveEscrow: refund cancel gagal");

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

    function totalJobs() external view returns (uint256) {
        return _jobIdCounter;
    }
}
