// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

/// @title AgentRegistry — ERC-721 Agent ID untuk DeAI FreelanceAgent
/// @notice Setiap token merepresentasikan satu AI Agent dengan profil, reputasi, dan wallet otonom.
contract AgentRegistry is ERC721, Ownable {
    using Counters for Counters.Counter;

    // ─── ENUMS ───────────────────────────────────────────────────────────────

    /// @notice Spesialisasi AI Agent. Digunakan untuk filtering di marketplace.
    enum AgentType {
        WRITER,    // 0 — Penulisan konten, copywriting, SEO
        CODER,     // 1 — Code generation, code review, debugging
        ANALYST,   // 2 — Data analysis, summarization, research
        CREATIVE,  // 3 — Image prompting, creative direction, brainstorming
        GENERAL    // 4 — Multi-purpose
    }

    // ─── STRUCTS ─────────────────────────────────────────────────────────────

    /// @notice Profil lengkap setiap AI Agent
    struct AgentProfile {
        address owner;              // Alamat wallet Majikan
        AgentType agentType;        // Spesialisasi agent
        uint256 baseRate;           // Harga minimum per job (wei)
        uint256 efficiencyScore;    // 0–10000 basis points (10000 = 100%)
        string resumeCID;           // Root hash ke JSON resume di 0G Storage
        address agentWallet;        // Alamat wallet otonom Agent ID (EOA)
        bytes eciesPublicKey;       // Public key ECIES untuk enkripsi job data
        uint256 totalJobsCompleted; // Jumlah milestone yang berhasil di-approve
        uint256 totalJobsAttempted; // Jumlah milestone yang pernah disubmit
        uint256 totalEarningsWei;   // Total pendapatan kumulatif (wei)
        uint256 createdAt;          // Timestamp mint
        bool isActive;              // Majikan bisa nonaktifkan sementara
    }

    // ─── STATE ───────────────────────────────────────────────────────────────

    Counters.Counter private _tokenIdCounter;
    mapping(uint256 => AgentProfile) public agents;
    mapping(address => uint256[]) public ownerToAgentIds;

    /// @notice Alamat ProgressiveEscrow yang boleh memanggil recordJobResult()
    address public escrowContract;

    // ─── EVENTS ──────────────────────────────────────────────────────────────

    event AgentMinted(
        uint256 indexed agentId,
        address indexed owner,
        AgentType agentType,
        uint256 baseRate,
        address agentWallet
    );
    event EfficiencyUpdated(
        uint256 indexed agentId,
        uint256 newScore,
        uint256 jobsCompleted,
        uint256 jobsAttempted
    );
    event ResumeUpdated(uint256 indexed agentId, string oldCID, string newCID);
    event AgentToggled(uint256 indexed agentId, bool isActive);

    // ─── MODIFIERS ───────────────────────────────────────────────────────────

    modifier onlyAgentOwner(uint256 agentId) {
        require(agents[agentId].owner == msg.sender, "AgentRegistry: bukan owner agent");
        _;
    }

    modifier onlyEscrow() {
        require(msg.sender == escrowContract, "AgentRegistry: hanya escrow contract");
        _;
    }

    // ─── CONSTRUCTOR ─────────────────────────────────────────────────────────

    constructor() ERC721("DeAI Agent ID", "AGENT") {}

    // ─── EXTERNAL FUNCTIONS ──────────────────────────────────────────────────

    /// @notice Mint Agent ID baru. Dipanggil oleh Majikan.
    function mintAgent(
        AgentType agentType,
        uint256 baseRate,
        string calldata resumeCID,
        address agentWallet,
        bytes calldata eciesPublicKey
    ) external returns (uint256 agentId) {
        require(agentWallet != address(0), "AgentRegistry: agentWallet tidak boleh zero");
        require(agentWallet != msg.sender, "AgentRegistry: agentWallet harus berbeda dari owner");
        require(bytes(resumeCID).length > 0, "AgentRegistry: resumeCID tidak boleh kosong");

        _tokenIdCounter.increment();
        agentId = _tokenIdCounter.current();
        _safeMint(msg.sender, agentId);

        agents[agentId] = AgentProfile({
            owner: msg.sender,
            agentType: agentType,
            baseRate: baseRate,
            efficiencyScore: 8000, // Default: 80%
            resumeCID: resumeCID,
            agentWallet: agentWallet,
            eciesPublicKey: eciesPublicKey,
            totalJobsCompleted: 0,
            totalJobsAttempted: 0,
            totalEarningsWei: 0,
            createdAt: block.timestamp,
            isActive: true
        });

        ownerToAgentIds[msg.sender].push(agentId);
        emit AgentMinted(agentId, msg.sender, agentType, baseRate, agentWallet);
    }

    /// @notice Catat hasil job. Hanya bisa dipanggil oleh ProgressiveEscrow.
    function recordJobResult(
        uint256 agentId,
        uint256 earningsWei,
        bool jobCompleted
    ) external onlyEscrow {
        AgentProfile storage agent = agents[agentId];
        agent.totalJobsAttempted++;

        if (jobCompleted) {
            agent.totalJobsCompleted++;
            agent.totalEarningsWei += earningsWei;
        }

        if (agent.totalJobsAttempted > 0) {
            agent.efficiencyScore =
                (agent.totalJobsCompleted * 10000) / agent.totalJobsAttempted;
        }

        emit EfficiencyUpdated(
            agentId,
            agent.efficiencyScore,
            agent.totalJobsCompleted,
            agent.totalJobsAttempted
        );
    }

    /// @notice Update CID resume. Hanya owner agent.
    function updateResumeCID(
        uint256 agentId,
        string calldata newCID
    ) external onlyAgentOwner(agentId) {
        string memory oldCID = agents[agentId].resumeCID;
        agents[agentId].resumeCID = newCID;
        emit ResumeUpdated(agentId, oldCID, newCID);
    }

    /// @notice Toggle active status. Hanya owner agent.
    function toggleActive(uint256 agentId) external onlyAgentOwner(agentId) {
        agents[agentId].isActive = !agents[agentId].isActive;
        emit AgentToggled(agentId, agents[agentId].isActive);
    }

    /// @notice Set alamat ProgressiveEscrow. Hanya contract owner (admin).
    function setEscrowContract(address _escrowContract) external onlyOwner {
        require(_escrowContract != address(0), "AgentRegistry: zero address");
        escrowContract = _escrowContract;
    }

    // ─── VIEW FUNCTIONS ───────────────────────────────────────────────────────

    function getOwnerAgents(address owner) external view returns (uint256[] memory) {
        return ownerToAgentIds[owner];
    }

    function getAgentProfile(uint256 agentId) external view returns (AgentProfile memory) {
        require(_exists(agentId), "AgentRegistry: agent tidak ada");
        return agents[agentId];
    }

    function totalAgents() external view returns (uint256) {
        return _tokenIdCounter.current();
    }
}
