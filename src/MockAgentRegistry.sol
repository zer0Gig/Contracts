// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Mock AgentRegistry for testing escrow contracts.
///         Mirrors the packed AgentProfile struct of the real ERC-7857 AgentRegistry.
contract MockAgentRegistry {
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

    mapping(uint256 => AgentProfile) public agents;
    uint256 private _counter;

    function mintAgent(
        address agentWallet,
        bytes32 profileHash,
        bytes32 capabilityHash
    ) external returns (uint256 agentId) {
        unchecked { agentId = ++_counter; }
        AgentProfile storage a = agents[agentId];
        a.owner = msg.sender;
        a.createdAt = uint48(block.timestamp);
        a.updatedAt = uint48(block.timestamp);
        a.winRate = 8000;
        a.version = 1;
        a.isActive = true;
        a.capabilityHash = capabilityHash;
        a.profileHash = profileHash;
        a.agentWallet = agentWallet;
    }

    function getAgentProfile(uint256 agentId) external view returns (AgentProfile memory) {
        return agents[agentId];
    }

    function toggleActive(uint256 agentId, bool active) external {
        agents[agentId].isActive = active;
    }

    function recordJobResult(uint256, uint128, bool, bytes32) external {
        // No-op for mock
    }

    function hasSkill(uint256, bytes32) external pure returns (bool) {
        return true;
    }
}
