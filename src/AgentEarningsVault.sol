// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title  AgentEarningsVault — keyless custody of agent yield
/// @notice Holds native OG balances credited to specific agentIds. Replaces
///         the legacy "agent.agentWallet is an EOA" model: nobody needs to
///         hold the agent's private key because the iNFT owner (per
///         AgentRegistry.ownerOf) is the only address allowed to withdraw.
///
///         Design goals:
///           - No private keys anywhere (Vercel env, Supabase, or otherwise).
///             Withdrawal authority derives from iNFT ownership on-chain.
///           - Anyone may deposit on behalf of any agent. Escrow contracts,
///             clients tipping an agent, the owner topping it up — all the
///             same path: `deposit{value: amount}(agentId)`.
///           - Withdraw is a normal user-signed transaction. No backend
///             dispatcher, no signature recovery in this contract.
///           - Per-agent accounting. Funds belonging to agent #2 are never
///             commingled with agent #3.
///
/// @dev    Stateless w.r.t. owner — every withdraw re-reads the registry, so
///         iTransfer / iClone of an iNFT instantly hands withdrawal rights to
///         the new owner without any state update here.

interface IAgentRegistry {
    function ownerOf(uint256 tokenId) external view returns (address);
}

contract AgentEarningsVault is ReentrancyGuard {
    // ── Storage ───────────────────────────────────────────────────────────

    /// @notice Reference to the canonical AgentRegistry. Immutable — if the
    ///         registry is ever redeployed, deploy a new vault.
    IAgentRegistry public immutable registry;

    /// @notice Pending balance per agentId, in wei.
    mapping(uint256 => uint256) public balanceOf;

    /// @notice Total OG deposited across the vault's lifetime, for analytics.
    uint256 public totalDepositedWei;

    /// @notice Total OG withdrawn across the vault's lifetime, for analytics.
    uint256 public totalWithdrawnWei;

    // ── Events ────────────────────────────────────────────────────────────

    event Deposited(
        uint256 indexed agentId,
        address indexed from,
        uint256          amount,
        uint256          newBalance
    );

    event Withdrawn(
        uint256 indexed agentId,
        address indexed owner,
        address indexed to,
        uint256          amount,
        uint256          newBalance
    );

    // ── Errors ────────────────────────────────────────────────────────────

    error ZeroAmount();
    error ZeroAddress();
    error NotOwner(address caller, address owner);
    error InsufficientBalance(uint256 requested, uint256 available);
    error TransferFailed();

    // ── Constructor ───────────────────────────────────────────────────────

    constructor(address agentRegistry) {
        if (agentRegistry == address(0)) revert ZeroAddress();
        registry = IAgentRegistry(agentRegistry);
    }

    // ── Deposit ───────────────────────────────────────────────────────────

    /// @notice Credit `msg.value` to `agentId`. Anyone may call.
    /// @dev    No check that the agentId exists in the registry — depositing
    ///         to a non-existent id is harmless (funds sit there until the
    ///         registry mints that id, at which point the new owner can
    ///         withdraw). Callers should validate upstream.
    function deposit(uint256 agentId) external payable {
        if (msg.value == 0) revert ZeroAmount();

        uint256 newBalance = balanceOf[agentId] + msg.value;
        balanceOf[agentId] = newBalance;
        totalDepositedWei += msg.value;

        emit Deposited(agentId, msg.sender, msg.value, newBalance);
    }

    // ── Withdraw ──────────────────────────────────────────────────────────

    /// @notice Pull `amount` of agent earnings to `to`. msg.sender must be
    ///         the current iNFT owner (AgentRegistry.ownerOf(agentId)).
    function withdraw(uint256 agentId, address to, uint256 amount)
        external
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0)      revert ZeroAmount();

        address owner = registry.ownerOf(agentId);
        if (msg.sender != owner) revert NotOwner(msg.sender, owner);

        uint256 available = balanceOf[agentId];
        if (amount > available) revert InsufficientBalance(amount, available);

        uint256 newBalance = available - amount;
        balanceOf[agentId] = newBalance;
        totalWithdrawnWei += amount;

        (bool sent, ) = payable(to).call{value: amount}("");
        if (!sent) revert TransferFailed();

        emit Withdrawn(agentId, msg.sender, to, amount, newBalance);
    }

    /// @notice Convenience: pull the full balance to `to`.
    function withdrawAll(uint256 agentId, address to)
        external
        nonReentrant
        returns (uint256 amount)
    {
        if (to == address(0)) revert ZeroAddress();

        address owner = registry.ownerOf(agentId);
        if (msg.sender != owner) revert NotOwner(msg.sender, owner);

        amount = balanceOf[agentId];
        if (amount == 0) revert ZeroAmount();

        balanceOf[agentId] = 0;
        totalWithdrawnWei += amount;

        (bool sent, ) = payable(to).call{value: amount}("");
        if (!sent) revert TransferFailed();

        emit Withdrawn(agentId, msg.sender, to, amount, 0);
    }

    // ── Receive fallback ──────────────────────────────────────────────────

    /// @notice Block accidental sends — any raw transfer without an agentId
    ///         context would create orphan funds the contract can't account
    ///         for. Use `deposit(agentId)` instead.
    receive() external payable {
        revert("Use deposit(agentId)");
    }
}
