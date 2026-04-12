// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

/// @title AgentRegistry v2 — Dynamic AI Agent Identity NFT
/// @notice Each token represents an AI Agent with flexible capabilities,
///         per-skill reputation, and an on-chain capability commitment.
contract AgentRegistry is ERC721, Ownable {
    using Counters for Counters.Counter;

    // ─── CONSTANTS ──────────────────────────────────────────────────────────

    uint256 public constant MAX_INITIAL_SKILLS = 20;
    uint256 public constant MAX_SKILLS_PER_AGENT = 50;

    // ─── STRUCTS ────────────────────────────────────────────────────────────

    /// @notice Core agent identity stored on-chain
    struct AgentProfile {
        address owner;              // Human wallet that owns this agent
        address agentWallet;        // Autonomous agent EOA
        bytes eciesPublicKey;       // ECIES pub key for encrypted job briefs

        // ── Capability commitment (hybrid on-chain / 0G Storage) ──
        bytes32 capabilityHash;     // keccak256 of the capability manifest CID
        string capabilityCID;       // 0G Storage CID → full capability manifest JSON

        // ── Rich profile (off-chain) ──
        string profileCID;          // 0G Storage CID → agent profile, portfolio, resume

        // ── Aggregate reputation ──
        uint256 overallScore;       // 0–10000 basis points (10000 = 100%)
        uint256 totalJobsCompleted;
        uint256 totalJobsAttempted;
        uint256 totalEarningsWei;

        // ── Pricing ──
        uint256 defaultRate;        // Default rate per task (wei)

        // ── Metadata ──
        uint256 createdAt;
        bool isActive;
    }

    /// @notice Per-skill reputation tracked on-chain
    struct SkillReputation {
        uint256 score;              // 0–10000 basis points
        uint256 jobsCompleted;
        uint256 jobsAttempted;
        uint256 totalEarningsWei;
        uint256 lastUpdated;
    }

    // ─── STATE ──────────────────────────────────────────────────────────────

    Counters.Counter private _tokenIdCounter;

    /// @notice agentId => AgentProfile
    mapping(uint256 => AgentProfile) public agents;

    /// @notice owner address => array of agentIds they own
    mapping(address => uint256[]) public ownerToAgentIds;

    /// @notice agentId => skillId => SkillReputation
    mapping(uint256 => mapping(bytes32 => SkillReputation)) public skillReputations;

    /// @notice agentId => number of registered skills
    mapping(uint256 => uint256) public agentSkillCount;

    /// @notice agentId => index => skillId (for enumeration)
    mapping(uint256 => mapping(uint256 => bytes32)) public agentSkillAtIndex;

    /// @notice agentId => skillId => bool (O(1) existence check)
    mapping(uint256 => mapping(bytes32 => bool)) public agentHasSkill;

    /// @notice agentId => skillId => index in the skills array (for removal)
    mapping(uint256 => mapping(bytes32 => uint256)) private _skillIndex;

    /// @notice Authorized escrow contracts that can call recordJobResult
    mapping(address => bool) public authorizedEscrows;

    // ─── EVENTS ─────────────────────────────────────────────────────────────

    event AgentMinted(
        uint256 indexed agentId,
        address indexed owner,
        uint256 defaultRate,
        address agentWallet,
        string capabilityCID
    );

    event OverallScoreUpdated(
        uint256 indexed agentId,
        uint256 newScore,
        uint256 jobsCompleted,
        uint256 jobsAttempted
    );

    event SkillReputationUpdated(
        uint256 indexed agentId,
        bytes32 indexed skillId,
        uint256 newScore,
        uint256 skillJobsCompleted,
        uint256 skillJobsAttempted
    );

    event ProfileUpdated(uint256 indexed agentId, string oldCID, string newCID);

    event CapabilitiesUpdated(
        uint256 indexed agentId,
        string newCapabilityCID,
        bytes32 newCapabilityHash
    );

    event SkillAdded(uint256 indexed agentId, bytes32 indexed skillId);
    event SkillRemoved(uint256 indexed agentId, bytes32 indexed skillId);
    event AgentToggled(uint256 indexed agentId, bool isActive);
    event EscrowAuthorized(address indexed escrow, bool authorized);

    // ─── MODIFIERS ──────────────────────────────────────────────────────────

    modifier onlyAgentOwner(uint256 agentId) {
        require(agents[agentId].owner == msg.sender, "AgentRegistry: not agent owner");
        _;
    }

    modifier onlyEscrow() {
        require(authorizedEscrows[msg.sender], "AgentRegistry: unauthorized escrow");
        _;
    }

    // ─── CONSTRUCTOR ────────────────────────────────────────────────────────

    constructor() ERC721("zer0Gig Agent ID", "AGENT") {}

    // ─── MINT ───────────────────────────────────────────────────────────────

    /// @notice Mint a new Agent ID NFT with capabilities and initial skills
    function mintAgent(
        uint256 defaultRate,
        string calldata profileCID,
        string calldata capabilityCID,
        bytes32[] calldata skillIds,
        address agentWallet,
        bytes calldata eciesPublicKey
    ) external returns (uint256 agentId) {
        require(agentWallet != address(0), "AgentRegistry: zero agentWallet");
        require(agentWallet != msg.sender, "AgentRegistry: agentWallet must differ from owner");
        require(bytes(profileCID).length > 0, "AgentRegistry: empty profileCID");
        require(bytes(capabilityCID).length > 0, "AgentRegistry: empty capabilityCID");
        require(skillIds.length <= MAX_INITIAL_SKILLS, "AgentRegistry: too many initial skills");

        _tokenIdCounter.increment();
        agentId = _tokenIdCounter.current();
        _safeMint(msg.sender, agentId);

        bytes32 capHash = keccak256(abi.encodePacked(capabilityCID));

        agents[agentId] = AgentProfile({
            owner: msg.sender,
            agentWallet: agentWallet,
            eciesPublicKey: eciesPublicKey,
            capabilityHash: capHash,
            capabilityCID: capabilityCID,
            profileCID: profileCID,
            overallScore: 8000, // Default: 80%
            totalJobsCompleted: 0,
            totalJobsAttempted: 0,
            totalEarningsWei: 0,
            defaultRate: defaultRate,
            createdAt: block.timestamp,
            isActive: true
        });

        // Register initial skills
        for (uint256 i = 0; i < skillIds.length; i++) {
            _addSkill(agentId, skillIds[i]);
        }

        ownerToAgentIds[msg.sender].push(agentId);
        emit AgentMinted(agentId, msg.sender, defaultRate, agentWallet, capabilityCID);
    }

    // ─── ESCROW CALLBACKS ───────────────────────────────────────────────────

    /// @notice Record job result. Called by authorized escrow contracts only.
    /// @param skillId Pass bytes32(0) to only update aggregate score
    function recordJobResult(
        uint256 agentId,
        uint256 earningsWei,
        bool jobCompleted,
        bytes32 skillId
    ) external onlyEscrow {
        AgentProfile storage agent = agents[agentId];
        agent.totalJobsAttempted++;

        if (jobCompleted) {
            agent.totalJobsCompleted++;
            agent.totalEarningsWei += earningsWei;
        }

        // Update aggregate score
        if (agent.totalJobsAttempted > 0) {
            agent.overallScore =
                (agent.totalJobsCompleted * 10000) / agent.totalJobsAttempted;
        }

        emit OverallScoreUpdated(
            agentId,
            agent.overallScore,
            agent.totalJobsCompleted,
            agent.totalJobsAttempted
        );

        // Update per-skill reputation
        if (skillId != bytes32(0)) {
            SkillReputation storage rep = skillReputations[agentId][skillId];
            rep.jobsAttempted++;

            if (jobCompleted) {
                rep.jobsCompleted++;
                rep.totalEarningsWei += earningsWei;
            }

            if (rep.jobsAttempted > 0) {
                rep.score = (rep.jobsCompleted * 10000) / rep.jobsAttempted;
            }
            rep.lastUpdated = block.timestamp;

            emit SkillReputationUpdated(
                agentId,
                skillId,
                rep.score,
                rep.jobsCompleted,
                rep.jobsAttempted
            );
        }
    }

    // ─── CAPABILITY MANAGEMENT ──────────────────────────────────────────────

    /// @notice Add a skill to the agent
    function addSkill(
        uint256 agentId,
        bytes32 skillId
    ) external onlyAgentOwner(agentId) {
        _addSkill(agentId, skillId);
    }

    /// @notice Remove a skill from the agent (swap-and-pop for gas efficiency)
    function removeSkill(
        uint256 agentId,
        bytes32 skillId
    ) external onlyAgentOwner(agentId) {
        require(agentHasSkill[agentId][skillId], "AgentRegistry: skill not found");

        uint256 count = agentSkillCount[agentId];
        uint256 removeIdx = _skillIndex[agentId][skillId];
        uint256 lastIdx = count - 1;

        // Swap with last element if not already last
        if (removeIdx != lastIdx) {
            bytes32 lastSkillId = agentSkillAtIndex[agentId][lastIdx];
            agentSkillAtIndex[agentId][removeIdx] = lastSkillId;
            _skillIndex[agentId][lastSkillId] = removeIdx;
        }

        // Remove last element
        delete agentSkillAtIndex[agentId][lastIdx];
        delete _skillIndex[agentId][skillId];
        delete agentHasSkill[agentId][skillId];
        agentSkillCount[agentId] = lastIdx;

        emit SkillRemoved(agentId, skillId);
    }

    /// @notice Bulk update capabilities: new manifest + add/remove skills
    function updateCapabilities(
        uint256 agentId,
        string calldata newCapabilityCID,
        bytes32[] calldata addSkillIds,
        bytes32[] calldata removeSkillIds
    ) external onlyAgentOwner(agentId) {
        require(bytes(newCapabilityCID).length > 0, "AgentRegistry: empty CID");
        require(
            addSkillIds.length + agentSkillCount[agentId] - removeSkillIds.length <= MAX_SKILLS_PER_AGENT,
            "AgentRegistry: too many skills"
        );

        // Update capability manifest
        bytes32 newHash = keccak256(abi.encodePacked(newCapabilityCID));
        agents[agentId].capabilityCID = newCapabilityCID;
        agents[agentId].capabilityHash = newHash;

        emit CapabilitiesUpdated(agentId, newCapabilityCID, newHash);

        // Remove skills first (to free slots)
        for (uint256 i = 0; i < removeSkillIds.length; i++) {
            if (agentHasSkill[agentId][removeSkillIds[i]]) {
                // Inline removal logic
                uint256 count = agentSkillCount[agentId];
                uint256 removeIdx = _skillIndex[agentId][removeSkillIds[i]];
                uint256 lastIdx = count - 1;

                if (removeIdx != lastIdx) {
                    bytes32 lastSkillId = agentSkillAtIndex[agentId][lastIdx];
                    agentSkillAtIndex[agentId][removeIdx] = lastSkillId;
                    _skillIndex[agentId][lastSkillId] = removeIdx;
                }

                delete agentSkillAtIndex[agentId][lastIdx];
                delete _skillIndex[agentId][removeSkillIds[i]];
                delete agentHasSkill[agentId][removeSkillIds[i]];
                agentSkillCount[agentId] = lastIdx;

                emit SkillRemoved(agentId, removeSkillIds[i]);
            }
        }

        // Add new skills
        for (uint256 i = 0; i < addSkillIds.length; i++) {
            _addSkill(agentId, addSkillIds[i]);
        }
    }

    /// @notice Update the profile CID (portfolio, resume, etc.)
    function updateProfileCID(
        uint256 agentId,
        string calldata newCID
    ) external onlyAgentOwner(agentId) {
        require(bytes(newCID).length > 0, "AgentRegistry: empty CID");
        string memory oldCID = agents[agentId].profileCID;
        agents[agentId].profileCID = newCID;
        emit ProfileUpdated(agentId, oldCID, newCID);
    }

    /// @notice Toggle agent active status
    function toggleActive(uint256 agentId) external onlyAgentOwner(agentId) {
        agents[agentId].isActive = !agents[agentId].isActive;
        emit AgentToggled(agentId, agents[agentId].isActive);
    }

    // ─── ADMIN ──────────────────────────────────────────────────────────────

    /// @notice Authorize an escrow contract to call recordJobResult
    function addEscrowContract(address escrow) external onlyOwner {
        require(escrow != address(0), "AgentRegistry: zero address");
        authorizedEscrows[escrow] = true;
        emit EscrowAuthorized(escrow, true);
    }

    /// @notice Revoke escrow authorization
    function removeEscrowContract(address escrow) external onlyOwner {
        authorizedEscrows[escrow] = false;
        emit EscrowAuthorized(escrow, false);
    }

    // ─── VIEW FUNCTIONS ─────────────────────────────────────────────────────

    function getAgentProfile(uint256 agentId) external view returns (AgentProfile memory) {
        require(_exists(agentId), "AgentRegistry: agent does not exist");
        return agents[agentId];
    }

    function getOwnerAgents(address owner) external view returns (uint256[] memory) {
        return ownerToAgentIds[owner];
    }

    function totalAgents() external view returns (uint256) {
        return _tokenIdCounter.current();
    }

    /// @notice Check if an agent has a specific skill
    function hasSkill(uint256 agentId, bytes32 skillId) external view returns (bool) {
        return agentHasSkill[agentId][skillId];
    }

    /// @notice Get all skill IDs registered to an agent
    function getAgentSkills(uint256 agentId) external view returns (bytes32[] memory) {
        uint256 count = agentSkillCount[agentId];
        bytes32[] memory skills = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            skills[i] = agentSkillAtIndex[agentId][i];
        }
        return skills;
    }

    /// @notice Get per-skill reputation
    function getSkillReputation(
        uint256 agentId,
        bytes32 skillId
    ) external view returns (SkillReputation memory) {
        return skillReputations[agentId][skillId];
    }

    // ─── INTERNAL ───────────────────────────────────────────────────────────

    function _addSkill(uint256 agentId, bytes32 skillId) internal {
        require(skillId != bytes32(0), "AgentRegistry: zero skillId");
        if (agentHasSkill[agentId][skillId]) return; // Idempotent — skip duplicates

        uint256 count = agentSkillCount[agentId];
        require(count < MAX_SKILLS_PER_AGENT, "AgentRegistry: max skills reached");

        agentSkillAtIndex[agentId][count] = skillId;
        _skillIndex[agentId][skillId] = count;
        agentHasSkill[agentId][skillId] = true;
        agentSkillCount[agentId] = count + 1;

        emit SkillAdded(agentId, skillId);
    }
}
