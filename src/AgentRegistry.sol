// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title AgentRegistry — ERC-7857 Intelligent NFT for zer0Gig Agents
/// @notice Tokenizes AI agents whose intelligence (system prompt, skill configs,
///         API keys, MCP server URLs) lives as an *encrypted* blob in 0G Storage.
///         Ownership transfers re-encrypt the blob for the new owner via an
///         oracle (TEE-attested signing service in production; ECDSA EOA for testnet).
///
///         ERC-7857 surface:
///           - Encrypted off-chain capability — `capabilityHash` is a 0G Storage
///             merkle root of an AES-256-CTR encrypted blob.
///           - Per-owner sealed AES key — emitted in `SealedKeyPublished` event
///             on every mint / transfer / clone / update (event-only storage
///             saves ~88k gas per transfer; new owner reads from log).
///           - Oracle-verified transfer/clone — `iTransfer` / `iClone` accept
///             a fresh `(newCapabilityHash, newSealedKey)` pair plus an ECDSA
///             signature from the configured re-encryption oracle.
///           - Time-bounded usage authorization — license without ownership.
///           - Owner self-update — `updateCapability` rotates AES key without
///             transferring ownership.
///
///         Gas optimizations applied:
///           - Custom errors instead of revert strings.
///           - Packed AgentProfile struct (5 slots vs ~13 in v1).
///           - bytes32 capabilityHash & profileHash (no string storage).
///           - Sealed key event-only (saves ~88k gas per transfer).
///           - Skill storage uses 2 mappings instead of 4.
///           - Caller pre-computes hashes off-chain (no on-chain keccak).
///           - Raw uint256 counter (no OZ Counters wrapper).
///           - eciesPublicKey moved to separate mapping (lean main struct).
contract AgentRegistry is Ownable2Step, Pausable, ReentrancyGuard {
    using ECDSA for bytes32;

    // ─── ERRORS ─────────────────────────────────────────────────────────────

    error InvalidTokenId();
    error NotAgentOwner();
    error UnauthorizedEscrow();
    error ZeroAddress();
    error SelfTransfer();
    error ZeroRoot();
    error EmptySealedKey();
    error EmptyEciesKey();
    error EmptyCID();
    error StaleRoot();
    error OracleNotSet();
    error BadOracleSignature();
    error TooManyInitialSkills();
    error MaxSkillsReached();
    error ZeroSkill();
    error SkillNotFound();
    error SkillsTooMany();
    error DurationOverflow();
    error AgentInactive();

    // ─── CONSTANTS ──────────────────────────────────────────────────────────

    uint256 public constant MAX_INITIAL_SKILLS = 20;
    uint256 public constant MAX_SKILLS_PER_AGENT = 50;
    uint16  public constant DEFAULT_WIN_RATE_BPS = 8000; // 80%
    uint256 private constant BPS_SCALE = 10_000;

    // ─── STRUCTS ────────────────────────────────────────────────────────────

    /// @notice Core agent state. Packed into 5 slots for gas efficiency.
    /// @dev Slot layout:
    ///   slot 0: owner(20) + createdAt(6) + winRate(2) + version(2) + isActive(1) + reserved(1)
    ///   slot 1: capabilityHash(32)
    ///   slot 2: profileHash(32)
    ///   slot 3: agentWallet(20) + totalJobsCompleted(8) + defaultRate(4 bytes uint32)
    ///   slot 4: totalJobsAttempted(8) + totalEarningsWei(16) + updatedAt(6) + reserved(2)
    struct AgentProfile {
        // Slot 0
        address owner;
        uint48  createdAt;
        uint16  winRate;            // basis points 0–10000
        uint16  version;            // bumped on every re-seal
        bool    isActive;
        // 1 byte free

        // Slot 1
        bytes32 capabilityHash;     // 0G Storage merkle root of encrypted manifest

        // Slot 2
        bytes32 profileHash;        // 0G Storage merkle root of public profile descriptor

        // Slot 3
        address agentWallet;
        uint64  totalJobsCompleted;
        uint32  defaultRate;        // wei in units of 1e10 (so max ~4.29e19 wei = 42.9 OG)
                                    // For values >42.9 OG, raise this to uint64.

        // Slot 4
        uint64  totalJobsAttempted;
        uint128 totalEarningsWei;
        uint48  updatedAt;
        // 2 bytes free
    }

    /// @notice Per-skill reputation tracked on-chain.
    /// @dev Packed into 2 slots.
    struct SkillReputation {
        // Slot 0
        uint16  scoreBps;           // 0–10000
        uint64  jobsCompleted;
        uint64  jobsAttempted;
        uint48  lastUpdated;
        // 14 bytes free

        // Slot 1
        uint128 totalEarningsWei;
        // 16 bytes free
    }

    /// @notice Time-bounded usage authorization (license without ownership).
    struct UsageAuth {
        uint48  expiresAt;          // 0 = no auth; >0 = expires at unix ts
        bytes32 permissionsHash;    // keccak256 of permissions JSON in 0G Storage
    }

    // ─── STATE ──────────────────────────────────────────────────────────────

    /// @notice Next tokenId to mint (raw counter, no OZ Counters overhead).
    uint256 private _nextId = 1;

    /// @notice Total agents ever minted (== _nextId - 1).
    function totalAgents() external view returns (uint256) {
        unchecked { return _nextId - 1; }
    }

    /// @notice agentId => packed profile.
    mapping(uint256 => AgentProfile) public agents;

    /// @notice agentId => owner's ECIES pubkey (separate from packed struct to save slots).
    mapping(uint256 => bytes) public eciesPublicKey;

    /// @notice owner address => list of agentIds owned (for enumeration).
    mapping(address => uint256[]) public ownerToAgentIds;

    /// @notice owner => agentId => index in ownerToAgentIds (for swap-pop O(1) removal).
    mapping(address => mapping(uint256 => uint256)) private _ownerTokenIndex;

    /// @notice agentId => list of skill IDs (dynamic, length implicit).
    mapping(uint256 => bytes32[]) public agentSkills;

    /// @notice agentId => skillId => positionInArray + 1 (0 = not present).
    /// @dev Using +1 encoding lets us check existence without a separate boolean map.
    mapping(uint256 => mapping(bytes32 => uint256)) private _skillIdxPlusOne;

    /// @notice agentId => skillId => packed reputation.
    mapping(uint256 => mapping(bytes32 => SkillReputation)) public skillReputations;

    /// @notice agentId => executor => time-bounded usage authorization.
    mapping(uint256 => mapping(address => UsageAuth)) private _auths;

    /// @notice agentId => list of authorized addresses (for enumeration; check isAuthorized for validity).
    mapping(uint256 => address[]) private _authorizedUsers;

    /// @notice owner => assistant address (delegate-access for agentWallet operations).
    mapping(address => address) private _delegate;

    /// @notice Authorized escrow contracts that can call recordJobResult.
    mapping(address => bool) public authorizedEscrows;

    /// @notice Re-encryption oracle EOA. Signs attestations over `transferDigest()`.
    ///         For hackathon: an EOA we control. For production: TEE-attested service.
    address public oracle;

    // ─── EVENTS ─────────────────────────────────────────────────────────────

    event AgentMinted(
        uint256 indexed agentId,
        address indexed owner,
        bytes32 capabilityHash,
        bytes32 profileHash,
        address agentWallet,
        uint32  defaultRate
    );

    /// @notice Emitted on every mint/transfer/clone/update. New owner reads sealedKey from this log.
    /// @dev Storing sealed key only in the event (not on-chain) saves ~88k gas per transfer.
    event SealedKeyPublished(
        uint256 indexed agentId,
        address indexed to,
        uint16  version,
        bytes   sealedKey
    );

    event SealedTransfer(
        uint256 indexed agentId,
        address indexed from,
        address indexed to,
        bytes32 oldHash,
        bytes32 newHash,
        uint16  newVersion
    );

    event AgentCloned(
        uint256 indexed originalId,
        uint256 indexed newId,
        address indexed newOwner,
        bytes32 newHash
    );

    event CapabilityUpdated(uint256 indexed agentId, bytes32 newHash, uint16 newVersion);
    event ProfileUpdated(uint256 indexed agentId, bytes32 newHash);
    event AgentToggled(uint256 indexed agentId, bool isActive);
    event SkillAdded(uint256 indexed agentId, bytes32 indexed skillId);
    event SkillRemoved(uint256 indexed agentId, bytes32 indexed skillId);
    event SkillReputationUpdated(
        uint256 indexed agentId,
        bytes32 indexed skillId,
        uint16  scoreBps,
        uint64  jobsCompleted,
        uint64  jobsAttempted
    );
    event OverallScoreUpdated(uint256 indexed agentId, uint16 winRate, uint64 jobsCompleted, uint64 jobsAttempted);
    event UsageAuthorized(uint256 indexed agentId, address indexed executor, uint48 expiresAt, bytes32 permissionsHash);
    event UsageRevoked(uint256 indexed agentId, address indexed executor);
    event DelegateAccessSet(address indexed user, address indexed assistant);
    event EscrowAuthorized(address indexed escrow, bool authorized);
    event OracleSet(address indexed oldOracle, address indexed newOracle);

    // ─── MODIFIERS ──────────────────────────────────────────────────────────

    modifier onlyEscrow() {
        if (!authorizedEscrows[msg.sender]) revert UnauthorizedEscrow();
        _;
    }

    // ─── CONSTRUCTOR ────────────────────────────────────────────────────────

    constructor() {}

    // ─── ADMIN ──────────────────────────────────────────────────────────────

    /// @notice Set the oracle EOA whose signature is required for iTransfer/iClone.
    function setOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert ZeroAddress();
        emit OracleSet(oracle, newOracle);
        oracle = newOracle;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function addEscrowContract(address escrow) external onlyOwner {
        if (escrow == address(0)) revert ZeroAddress();
        authorizedEscrows[escrow] = true;
        emit EscrowAuthorized(escrow, true);
    }

    function removeEscrowContract(address escrow) external onlyOwner {
        authorizedEscrows[escrow] = false;
        emit EscrowAuthorized(escrow, false);
    }

    // ─── MINT ───────────────────────────────────────────────────────────────

    /// @notice Mint a new agent INFT.
    /// @param defaultRate     Job default rate in 0.01-OG units (uint32 — caller multiplies wei by 1e-10).
    /// @param profileHash     0G Storage merkle root of public profile descriptor.
    /// @param capabilityHash  0G Storage merkle root of encrypted capability manifest.
    /// @param skillIds        Initial skill IDs (max MAX_INITIAL_SKILLS).
    /// @param agentWallet     Autonomous EOA the agent uses to sign drains/releases.
    /// @param eciesPubKey     Owner's ECIES public key (used for sealing during transfer/clone).
    /// @param sealedAesKey    AES-256 key wrapped to msg.sender's eciesPubKey via ECIES.
    function mintAgent(
        uint32  defaultRate,
        bytes32 profileHash,
        bytes32 capabilityHash,
        bytes32[] calldata skillIds,
        address agentWallet,
        bytes   calldata eciesPubKey,
        bytes   calldata sealedAesKey
    ) external whenNotPaused returns (uint256 agentId) {
        if (agentWallet == address(0)) revert ZeroAddress();
        if (agentWallet == msg.sender) revert ZeroAddress();
        if (profileHash == bytes32(0)) revert ZeroRoot();
        if (capabilityHash == bytes32(0)) revert ZeroRoot();
        if (eciesPubKey.length == 0) revert EmptyEciesKey();
        if (sealedAesKey.length == 0) revert EmptySealedKey();
        if (skillIds.length > MAX_INITIAL_SKILLS) revert TooManyInitialSkills();

        unchecked { agentId = _nextId++; }

        AgentProfile storage agent = agents[agentId];
        agent.owner = msg.sender;
        agent.createdAt = uint48(block.timestamp);
        agent.updatedAt = uint48(block.timestamp);
        agent.winRate = DEFAULT_WIN_RATE_BPS;
        agent.version = 1;
        agent.isActive = true;
        agent.capabilityHash = capabilityHash;
        agent.profileHash = profileHash;
        agent.agentWallet = agentWallet;
        agent.defaultRate = defaultRate;

        eciesPublicKey[agentId] = eciesPubKey;

        // Owner index
        _ownerTokenIndex[msg.sender][agentId] = ownerToAgentIds[msg.sender].length;
        ownerToAgentIds[msg.sender].push(agentId);

        // Initial skills
        uint256 len = skillIds.length;
        for (uint256 i; i < len; ) {
            _addSkill(agentId, skillIds[i]);
            unchecked { ++i; }
        }

        emit AgentMinted(agentId, msg.sender, capabilityHash, profileHash, agentWallet, defaultRate);
        emit SealedKeyPublished(agentId, msg.sender, 1, sealedAesKey);
    }

    // ─── ERC-7857 OPERATIONS ────────────────────────────────────────────────

    /// @notice Transfer agent INFT with sealed re-encryption.
    ///         Oracle signs an attestation over the transfer digest; re-encrypted
    ///         blob (newCapabilityHash) replaces the old. Sealed key emitted in event.
    function iTransfer(
        uint256 agentId,
        address to,
        bytes32 newCapabilityHash,
        bytes calldata newSealedKey,
        bytes calldata oracleProof
    ) external whenNotPaused nonReentrant {
        AgentProfile storage agent = agents[agentId];
        if (agent.owner != msg.sender) revert NotAgentOwner();
        if (to == address(0)) revert ZeroAddress();
        if (to == msg.sender) revert SelfTransfer();
        if (newCapabilityHash == bytes32(0)) revert ZeroRoot();
        if (newSealedKey.length == 0) revert EmptySealedKey();

        bytes32 oldHash = agent.capabilityHash;
        if (newCapabilityHash == oldHash) revert StaleRoot();

        _verifyOracleProof(agentId, agent.version, oldHash, newCapabilityHash, to, oracleProof);

        address from = agent.owner;
        agent.owner = to;
        agent.capabilityHash = newCapabilityHash;
        unchecked { agent.version += 1; }
        agent.updatedAt = uint48(block.timestamp);

        // Move agentId between owner indexes
        _removeFromOwnerList(from, agentId);
        _addToOwnerList(to, agentId);

        emit SealedTransfer(agentId, from, to, oldHash, newCapabilityHash, agent.version);
        emit SealedKeyPublished(agentId, to, agent.version, newSealedKey);
    }

    /// @notice Clone an agent for a new owner. Capability copied (re-sealed).
    ///         Reputation RESET on the clone (winRate=80%, jobs=0).
    ///         Skills copied; agentWallet copied; eciesPubKey copied (recipient should rotate).
    function iClone(
        uint256 agentId,
        address newOwner,
        bytes32 newCapabilityHash,
        bytes calldata newSealedKey,
        bytes calldata oracleProof
    ) external whenNotPaused nonReentrant returns (uint256 newId) {
        AgentProfile storage original = agents[agentId];
        if (original.owner != msg.sender) revert NotAgentOwner();
        if (newOwner == address(0)) revert ZeroAddress();
        if (newCapabilityHash == bytes32(0)) revert ZeroRoot();
        if (newSealedKey.length == 0) revert EmptySealedKey();

        _verifyOracleProof(agentId, original.version, original.capabilityHash,
                           newCapabilityHash, newOwner, oracleProof);

        unchecked { newId = _nextId++; }

        AgentProfile storage cloned = agents[newId];
        cloned.owner = newOwner;
        cloned.createdAt = uint48(block.timestamp);
        cloned.updatedAt = uint48(block.timestamp);
        cloned.winRate = DEFAULT_WIN_RATE_BPS;
        cloned.version = 1;
        cloned.isActive = true;
        cloned.capabilityHash = newCapabilityHash;
        cloned.profileHash = original.profileHash;
        cloned.agentWallet = original.agentWallet;
        cloned.defaultRate = original.defaultRate;
        // totalJobsCompleted / totalJobsAttempted / totalEarningsWei stay 0 (RESET)

        eciesPublicKey[newId] = eciesPublicKey[agentId];

        // Copy skills (lean loop, no SkillAdded events for each — just one bulk event)
        bytes32[] storage origSkills = agentSkills[agentId];
        uint256 sLen = origSkills.length;
        for (uint256 i; i < sLen; ) {
            _addSkill(newId, origSkills[i]);
            unchecked { ++i; }
        }

        // Owner index for new owner
        _ownerTokenIndex[newOwner][newId] = ownerToAgentIds[newOwner].length;
        ownerToAgentIds[newOwner].push(newId);

        emit AgentCloned(agentId, newId, newOwner, newCapabilityHash);
        emit SealedKeyPublished(newId, newOwner, 1, newSealedKey);
    }

    /// @notice Owner updates encrypted capability blob (rotate AES key, update prompt, etc.).
    ///         No oracle proof needed — same owner re-seals to themselves.
    function updateCapability(
        uint256 agentId,
        bytes32 newCapabilityHash,
        bytes calldata newSealedKey
    ) external whenNotPaused {
        AgentProfile storage agent = agents[agentId];
        if (agent.owner != msg.sender) revert NotAgentOwner();
        if (newCapabilityHash == bytes32(0)) revert ZeroRoot();
        if (newSealedKey.length == 0) revert EmptySealedKey();

        agent.capabilityHash = newCapabilityHash;
        unchecked { agent.version += 1; }
        agent.updatedAt = uint48(block.timestamp);

        emit CapabilityUpdated(agentId, newCapabilityHash, agent.version);
        emit SealedKeyPublished(agentId, msg.sender, agent.version, newSealedKey);
    }

    /// @notice Update public profile descriptor (off-chain storage merkle root).
    function updateProfileHash(uint256 agentId, bytes32 newProfileHash) external {
        AgentProfile storage agent = agents[agentId];
        if (agent.owner != msg.sender) revert NotAgentOwner();
        if (newProfileHash == bytes32(0)) revert ZeroRoot();
        agent.profileHash = newProfileHash;
        agent.updatedAt = uint48(block.timestamp);
        emit ProfileUpdated(agentId, newProfileHash);
    }

    function toggleActive(uint256 agentId) external {
        AgentProfile storage agent = agents[agentId];
        if (agent.owner != msg.sender) revert NotAgentOwner();
        agent.isActive = !agent.isActive;
        emit AgentToggled(agentId, agent.isActive);
    }

    // ─── USAGE AUTHORIZATION (TIME-BOUNDED) ─────────────────────────────────

    function authorizeUsage(
        uint256 agentId,
        address executor,
        uint48  duration,
        bytes32 permissionsHash
    ) external whenNotPaused {
        if (agents[agentId].owner != msg.sender) revert NotAgentOwner();
        if (executor == address(0)) revert ZeroAddress();

        uint48 ts = uint48(block.timestamp);
        uint48 expiresAt;
        unchecked { expiresAt = ts + duration; }
        if (expiresAt < ts) revert DurationOverflow();

        // First-time authorization: add to enumerable list.
        // If re-authorizing, the executor is already in the list — just update.
        if (_auths[agentId][executor].expiresAt == 0) {
            _authorizedUsers[agentId].push(executor);
        }

        _auths[agentId][executor] = UsageAuth(expiresAt, permissionsHash);
        emit UsageAuthorized(agentId, executor, expiresAt, permissionsHash);
    }

    function revokeUsage(uint256 agentId, address executor) external {
        if (agents[agentId].owner != msg.sender) revert NotAgentOwner();

        delete _auths[agentId][executor];

        // Remove from enumerable list (swap-and-pop)
        address[] storage list = _authorizedUsers[agentId];
        uint256 len = list.length;
        for (uint256 i; i < len; ) {
            if (list[i] == executor) {
                list[i] = list[len - 1];
                list.pop();
                break;
            }
            unchecked { ++i; }
        }

        emit UsageRevoked(agentId, executor);
    }

    function isAuthorized(uint256 agentId, address executor) external view returns (bool) {
        return _auths[agentId][executor].expiresAt > block.timestamp;
    }

    function getAuthorization(uint256 agentId, address executor) external view returns (UsageAuth memory) {
        return _auths[agentId][executor];
    }

    function authorizedUsersOf(uint256 agentId) external view returns (address[] memory) {
        return _authorizedUsers[agentId];
    }

    // ─── DELEGATE ACCESS ────────────────────────────────────────────────────

    function delegateAccess(address assistant) external {
        _delegate[msg.sender] = assistant;
        emit DelegateAccessSet(msg.sender, assistant);
    }

    function getDelegateAccess(address user) external view returns (address) {
        return _delegate[user];
    }

    // ─── SKILL MANAGEMENT ───────────────────────────────────────────────────

    function addSkill(uint256 agentId, bytes32 skillId) external {
        if (agents[agentId].owner != msg.sender) revert NotAgentOwner();
        _addSkill(agentId, skillId);
    }

    function removeSkill(uint256 agentId, bytes32 skillId) external {
        if (agents[agentId].owner != msg.sender) revert NotAgentOwner();
        _removeSkill(agentId, skillId);
    }

    /// @notice Bulk skill update + capability hash refresh in a single tx.
    function updateSkillSet(
        uint256 agentId,
        bytes32 newCapabilityHash,
        bytes32[] calldata addSkillIds,
        bytes32[] calldata removeSkillIds
    ) external whenNotPaused {
        if (agents[agentId].owner != msg.sender) revert NotAgentOwner();
        if (newCapabilityHash != bytes32(0)) {
            agents[agentId].capabilityHash = newCapabilityHash;
            unchecked { agents[agentId].version += 1; }
            emit CapabilityUpdated(agentId, newCapabilityHash, agents[agentId].version);
        }

        // Remove first to free slots
        uint256 rLen = removeSkillIds.length;
        for (uint256 i; i < rLen; ) {
            if (_skillIdxPlusOne[agentId][removeSkillIds[i]] != 0) {
                _removeSkill(agentId, removeSkillIds[i]);
            }
            unchecked { ++i; }
        }

        uint256 aLen = addSkillIds.length;
        if (agentSkills[agentId].length + aLen > MAX_SKILLS_PER_AGENT) revert SkillsTooMany();
        for (uint256 i; i < aLen; ) {
            _addSkill(agentId, addSkillIds[i]);
            unchecked { ++i; }
        }

        agents[agentId].updatedAt = uint48(block.timestamp);
    }

    // ─── ESCROW CALLBACKS ───────────────────────────────────────────────────

    /// @notice Record job result. Only authorized escrow contracts can call.
    /// @param skillId Pass bytes32(0) to update only aggregate score.
    function recordJobResult(
        uint256 agentId,
        uint128 earningsWei,
        bool    jobCompleted,
        bytes32 skillId
    ) external onlyEscrow {
        AgentProfile storage agent = agents[agentId];
        unchecked { agent.totalJobsAttempted += 1; }

        if (jobCompleted) {
            unchecked {
                agent.totalJobsCompleted += 1;
                agent.totalEarningsWei += earningsWei;
            }
        }

        // Recompute aggregate winRate
        if (agent.totalJobsAttempted > 0) {
            agent.winRate = uint16((uint256(agent.totalJobsCompleted) * BPS_SCALE) / agent.totalJobsAttempted);
        }

        emit OverallScoreUpdated(agentId, agent.winRate, agent.totalJobsCompleted, agent.totalJobsAttempted);

        // Per-skill reputation
        if (skillId != bytes32(0)) {
            SkillReputation storage rep = skillReputations[agentId][skillId];
            unchecked { rep.jobsAttempted += 1; }

            if (jobCompleted) {
                unchecked {
                    rep.jobsCompleted += 1;
                    rep.totalEarningsWei += earningsWei;
                }
            }

            if (rep.jobsAttempted > 0) {
                rep.scoreBps = uint16((uint256(rep.jobsCompleted) * BPS_SCALE) / rep.jobsAttempted);
            }
            rep.lastUpdated = uint48(block.timestamp);

            emit SkillReputationUpdated(agentId, skillId, rep.scoreBps, rep.jobsCompleted, rep.jobsAttempted);
        }
    }

    // ─── ORACLE PROOF VERIFICATION ──────────────────────────────────────────

    /// @notice Digest the oracle signs. Includes chainid + contract + version
    ///         to prevent replay across chains, contracts, and re-seal generations.
    function transferDigest(
        uint256 agentId,
        uint16  version,
        bytes32 oldHash,
        bytes32 newHash,
        address to
    ) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), agentId, version, oldHash, newHash, to));
    }

    function _verifyOracleProof(
        uint256 agentId,
        uint16  version,
        bytes32 oldHash,
        bytes32 newHash,
        address to,
        bytes calldata proof
    ) internal view {
        if (oracle == address(0)) revert OracleNotSet();
        bytes32 inner = transferDigest(agentId, version, oldHash, newHash, to);
        // EIP-191 prefix — equivalent to MessageHashUtils.toEthSignedMessageHash().
        bytes32 prefixed = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
        address signer = prefixed.recover(proof);
        if (signer != oracle) revert BadOracleSignature();
    }

    // ─── VIEW FUNCTIONS ─────────────────────────────────────────────────────

    function getAgentProfile(uint256 agentId) external view returns (AgentProfile memory) {
        if (agents[agentId].owner == address(0)) revert InvalidTokenId();
        return agents[agentId];
    }

    function getOwnerAgents(address owner) external view returns (uint256[] memory) {
        return ownerToAgentIds[owner];
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        address o = agents[agentId].owner;
        if (o == address(0)) revert InvalidTokenId();
        return o;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return ownerToAgentIds[owner].length;
    }

    function hasSkill(uint256 agentId, bytes32 skillId) external view returns (bool) {
        return _skillIdxPlusOne[agentId][skillId] != 0;
    }

    function getAgentSkills(uint256 agentId) external view returns (bytes32[] memory) {
        return agentSkills[agentId];
    }

    function agentSkillCount(uint256 agentId) external view returns (uint256) {
        return agentSkills[agentId].length;
    }

    function getSkillReputation(uint256 agentId, bytes32 skillId) external view returns (SkillReputation memory) {
        return skillReputations[agentId][skillId];
    }

    // ─── INTERNAL ───────────────────────────────────────────────────────────

    function _addSkill(uint256 agentId, bytes32 skillId) internal {
        if (skillId == bytes32(0)) revert ZeroSkill();
        if (_skillIdxPlusOne[agentId][skillId] != 0) return; // idempotent

        bytes32[] storage list = agentSkills[agentId];
        if (list.length >= MAX_SKILLS_PER_AGENT) revert MaxSkillsReached();

        list.push(skillId);
        _skillIdxPlusOne[agentId][skillId] = list.length; // position+1

        emit SkillAdded(agentId, skillId);
    }

    function _removeSkill(uint256 agentId, bytes32 skillId) internal {
        uint256 idxPlus1 = _skillIdxPlusOne[agentId][skillId];
        if (idxPlus1 == 0) revert SkillNotFound();

        bytes32[] storage list = agentSkills[agentId];
        uint256 idx;
        unchecked { idx = idxPlus1 - 1; }
        uint256 lastIdx;
        unchecked { lastIdx = list.length - 1; }

        if (idx != lastIdx) {
            bytes32 last = list[lastIdx];
            list[idx] = last;
            _skillIdxPlusOne[agentId][last] = idx + 1;
        }

        list.pop();
        delete _skillIdxPlusOne[agentId][skillId];

        emit SkillRemoved(agentId, skillId);
    }

    function _addToOwnerList(address owner, uint256 agentId) internal {
        _ownerTokenIndex[owner][agentId] = ownerToAgentIds[owner].length;
        ownerToAgentIds[owner].push(agentId);
        agents[agentId].owner = owner;
    }

    function _removeFromOwnerList(address owner, uint256 agentId) internal {
        uint256[] storage list = ownerToAgentIds[owner];
        uint256 idx = _ownerTokenIndex[owner][agentId];
        uint256 lastIdx;
        unchecked { lastIdx = list.length - 1; }

        if (idx != lastIdx) {
            uint256 lastTokenId = list[lastIdx];
            list[idx] = lastTokenId;
            _ownerTokenIndex[owner][lastTokenId] = idx;
        }

        list.pop();
        delete _ownerTokenIndex[owner][agentId];
    }

    // ─── METADATA (lightweight ERC-721-ish) ─────────────────────────────────

    function name() external pure returns (string memory) { return "zer0Gig Agent ID"; }
    function symbol() external pure returns (string memory) { return "AGENT"; }
}
