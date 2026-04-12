// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title UserRegistry — On-chain user roles for zer0Gig
/// @notice Stores whether a wallet is a Client or FreelancerOwner.
///         Called once per wallet on first dashboard entry.
contract UserRegistry {

    // ─── ROLES ───────────────────────────────────────────────────────────────

    /// @notice 0 = Unregistered, 1 = Client, 2 = FreelancerOwner
    enum Role { Unregistered, Client, FreelancerOwner }

    // ─── STATE ───────────────────────────────────────────────────────────────

    mapping(address => Role) public userRoles;

    // ─── EVENTS ──────────────────────────────────────────────────────────────

    event UserRegistered(address indexed user, Role role, uint256 registeredAt);

    // ─── WRITE ───────────────────────────────────────────────────────────────

    /// @notice Register caller as Client (1) or FreelancerOwner (2).
    ///         Can only be called once per wallet.
    function registerUser(Role role) external {
        require(role != Role.Unregistered, "UserRegistry: invalid role");
        require(userRoles[msg.sender] == Role.Unregistered, "UserRegistry: already registered");
        userRoles[msg.sender] = role;
        emit UserRegistered(msg.sender, role, block.timestamp);
    }

    // ─── READ ────────────────────────────────────────────────────────────────

    function getUserRole(address user) external view returns (Role) {
        return userRoles[user];
    }

    function isRegistered(address user) external view returns (bool) {
        return userRoles[user] != Role.Unregistered;
    }
}
