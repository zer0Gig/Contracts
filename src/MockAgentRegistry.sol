// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Mock AgentRegistry for testing SubscriptionEscrow
contract MockAgentRegistry {
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

    mapping(uint256 => AgentProfile) public agents;
    uint256 private _counter;

    function mintAgent(
        address agentWallet,
        string calldata profileCID,
        string calldata capabilityCID
    ) external returns (uint256) {
        _counter++;
        agents[_counter] = AgentProfile({
            owner: msg.sender,
            agentWallet: agentWallet,
            eciesPublicKey: "",
            capabilityHash: keccak256(bytes(capabilityCID)),
            capabilityCID: capabilityCID,
            profileCID: profileCID,
            overallScore: 8000,
            totalJobsCompleted: 0,
            totalJobsAttempted: 0,
            totalEarningsWei: 0,
            defaultRate: 0,
            createdAt: block.timestamp,
            isActive: true
        });
        return _counter;
    }

    function getAgentProfile(uint256 agentId) external view returns (AgentProfile memory) {
        return agents[agentId];
    }

    function toggleActive(uint256 agentId, bool active) external {
        agents[agentId].isActive = active;
    }
}
