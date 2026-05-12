// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title AgentMarketplace — escrow-based sales layer for ERC-7857 agents
/// @notice Buyers pay this contract upfront. Funds are held in escrow while the
///         seller calls `AgentRegistry.iTransfer` (TRANSFER mode) or
///         `AgentRegistry.iClone` (CLONE mode) directly. Once the transfer/clone
///         completes, anyone calls `completeTransfer` / `completeClone` and the
///         marketplace verifies ownership on-chain then releases payment minus
///         protocol fee. If `escrowDuration` (default 7 days) elapses without
///         completion, the buyer can `refundExpired` to recover funds.
///
///         The marketplace deliberately does NOT modify AgentRegistry. It
///         depends only on `ownerOf(agentId)` reads from AgentRegistry to
///         verify state transitions.
///
/// @dev    Listings themselves live off-chain (Supabase order book). This
///         contract only handles the on-chain escrow + settlement once a buyer
///         commits.

interface IAgentRegistry {
    function ownerOf(uint256 agentId) external view returns (address);
}

contract AgentMarketplace {

    // ─── ENUMS ──────────────────────────────────────────────────────────────

    enum Mode    { TRANSFER, CLONE }
    enum Status  { PENDING, SETTLED, REFUNDED }

    // ─── STORAGE ────────────────────────────────────────────────────────────

    struct Order {
        address buyer;
        address seller;
        uint256 agentId;          // original agent (for TRANSFER) or template (for CLONE)
        uint256 finalAgentId;     // populated on settle — same as agentId for TRANSFER, newId for CLONE
        uint96  amountWei;        // total paid by buyer (gross)
        uint64  createdAt;
        uint64  expiresAt;
        Mode    mode;
        Status  status;
    }

    mapping(uint256 => Order) public orders;
    uint256 public nextOrderId = 1;

    /// @notice Indexes for client queries (rebuilt off-chain via events; these are convenience)
    mapping(address => uint256[]) public buyerOrders;
    mapping(address => uint256[]) public sellerOrders;
    mapping(uint256 => uint256[]) public agentOrders;       // agentId → orderId[]

    // ─── CONFIG ─────────────────────────────────────────────────────────────

    address public owner;
    address public treasury;
    IAgentRegistry public immutable agentRegistry;
    uint16  public protocolFeeBps = 250;       // 2.5%
    uint32  public escrowDuration = 7 days;    // buyer refund window
    bool    public paused;

    uint16 public constant MAX_FEE_BPS = 1_000; // hard cap 10%

    // ─── EVENTS ─────────────────────────────────────────────────────────────

    event BuyRequested(
        uint256 indexed orderId,
        address indexed buyer,
        address indexed seller,
        uint256 agentId,
        uint96  amountWei,
        Mode    mode,
        bytes32 newCapabilityHash,
        bytes   newSealedKey,
        bytes   oracleProof,
        uint64  expiresAt
    );
    event SaleCompleted(
        uint256 indexed orderId,
        address indexed seller,
        address indexed buyer,
        uint96  sellerPayout,
        uint96  protocolFee,
        uint256 finalAgentId,
        Mode    mode
    );
    event RefundIssued(uint256 indexed orderId, address indexed buyer, uint96 amountWei);

    event ProtocolFeeUpdated(uint16 oldBps, uint16 newBps);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event EscrowDurationUpdated(uint32 oldDuration, uint32 newDuration);
    event Paused(bool isPaused);

    // ─── ERRORS ─────────────────────────────────────────────────────────────

    error NotOwner();
    error NotBuyer();
    error ZeroValue();
    error ValueTooLarge();
    error InvalidAgent();
    error AlreadySettled();
    error WrongMode();
    error TransferNotCompleted();
    error CloneNotCompleted();
    error NotExpired();
    error AgentAlreadyTransferred();
    error TransferFailed();
    error InvalidFee();
    error ZeroAddress();
    error MarketplacePaused();

    // ─── MODIFIERS ──────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }
    modifier whenNotPaused() {
        if (paused) revert MarketplacePaused();
        _;
    }

    // ─── CONSTRUCTOR ────────────────────────────────────────────────────────

    constructor(address _agentRegistry, address _treasury) {
        if (_agentRegistry == address(0) || _treasury == address(0)) revert ZeroAddress();
        agentRegistry = IAgentRegistry(_agentRegistry);
        treasury = _treasury;
        owner    = msg.sender;
    }

    // ─── BUYER ENTRY ────────────────────────────────────────────────────────

    /// @notice Buyer commits funds to buy an agent. Encryption params (newSealedKey,
    ///         newCapabilityHash) and the oracle ECDSA proof are emitted so the
    ///         seller can copy them into their direct `iTransfer` / `iClone` call.
    function buyAgent(
        uint256 agentId,
        address seller,
        Mode    mode,
        bytes32 newCapabilityHash,
        bytes calldata newSealedKey,
        bytes calldata oracleProof
    ) external payable whenNotPaused returns (uint256 orderId) {
        if (msg.value == 0)                      revert ZeroValue();
        if (msg.value > type(uint96).max)        revert ValueTooLarge();
        if (seller == address(0))                revert ZeroAddress();
        if (agentRegistry.ownerOf(agentId) != seller) revert InvalidAgent();

        orderId = nextOrderId++;
        Order storage o = orders[orderId];
        o.buyer       = msg.sender;
        o.seller      = seller;
        o.agentId     = agentId;
        o.amountWei   = uint96(msg.value);
        o.createdAt   = uint64(block.timestamp);
        o.expiresAt   = uint64(block.timestamp) + uint64(escrowDuration);
        o.mode        = mode;
        o.status      = Status.PENDING;

        buyerOrders[msg.sender].push(orderId);
        sellerOrders[seller].push(orderId);
        agentOrders[agentId].push(orderId);

        emit BuyRequested(
            orderId,
            msg.sender,
            seller,
            agentId,
            uint96(msg.value),
            mode,
            newCapabilityHash,
            newSealedKey,
            oracleProof,
            o.expiresAt
        );
    }

    // ─── SELLER COMPLETION ─────────────────────────────────────────────────

    /// @notice Called after seller has executed `AgentRegistry.iTransfer` directly.
    ///         Anyone can call (permissionless settlement) — payment goes to seller.
    function completeTransfer(uint256 orderId) external whenNotPaused {
        Order storage o = orders[orderId];
        if (o.status != Status.PENDING)                          revert AlreadySettled();
        if (o.mode   != Mode.TRANSFER)                            revert WrongMode();
        if (agentRegistry.ownerOf(o.agentId) != o.buyer)         revert TransferNotCompleted();

        o.finalAgentId = o.agentId;
        _settle(orderId);
    }

    /// @notice Called after seller has executed `AgentRegistry.iClone`. Seller
    ///         (or any keeper) passes the new agentId minted to the buyer.
    function completeClone(uint256 orderId, uint256 newAgentId) external whenNotPaused {
        Order storage o = orders[orderId];
        if (o.status != Status.PENDING)                          revert AlreadySettled();
        if (o.mode   != Mode.CLONE)                              revert WrongMode();
        if (agentRegistry.ownerOf(newAgentId) != o.buyer)        revert CloneNotCompleted();

        o.finalAgentId = newAgentId;
        _settle(orderId);
    }

    function _settle(uint256 orderId) internal {
        Order storage o = orders[orderId];
        o.status = Status.SETTLED;

        uint96 fee    = uint96((uint256(o.amountWei) * protocolFeeBps) / 10_000);
        uint96 payout = o.amountWei - fee;

        (bool sentSeller, )   = payable(o.seller).call{value: payout}("");
        if (!sentSeller)   revert TransferFailed();
        (bool sentTreasury, ) = payable(treasury).call{value: fee}("");
        if (!sentTreasury) revert TransferFailed();

        emit SaleCompleted(orderId, o.seller, o.buyer, payout, fee, o.finalAgentId, o.mode);
    }

    // ─── BUYER REFUND ──────────────────────────────────────────────────────

    /// @notice Buyer reclaims funds if seller hasn't transferred within `escrowDuration`.
    function refundExpired(uint256 orderId) external whenNotPaused {
        Order storage o = orders[orderId];
        if (msg.sender != o.buyer)                                 revert NotBuyer();
        if (o.status != Status.PENDING)                            revert AlreadySettled();
        if (block.timestamp < o.expiresAt)                         revert NotExpired();
        // Sanity: if for TRANSFER mode the buyer already owns the agent, force settle
        if (o.mode == Mode.TRANSFER && agentRegistry.ownerOf(o.agentId) == o.buyer) {
            revert AgentAlreadyTransferred();
        }

        o.status = Status.REFUNDED;
        uint96 amount = o.amountWei;

        (bool sent, ) = payable(o.buyer).call{value: amount}("");
        if (!sent) revert TransferFailed();

        emit RefundIssued(orderId, o.buyer, amount);
    }

    // ─── VIEW ──────────────────────────────────────────────────────────────

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }
    function getBuyerOrders(address buyer) external view returns (uint256[] memory) {
        return buyerOrders[buyer];
    }
    function getSellerOrders(address seller) external view returns (uint256[] memory) {
        return sellerOrders[seller];
    }
    function getAgentOrders(uint256 agentId) external view returns (uint256[] memory) {
        return agentOrders[agentId];
    }
    function totalOrders() external view returns (uint256) {
        return nextOrderId - 1;
    }

    // ─── ADMIN ─────────────────────────────────────────────────────────────

    function setProtocolFee(uint16 newBps) external onlyOwner {
        if (newBps > MAX_FEE_BPS) revert InvalidFee();
        uint16 old = protocolFeeBps;
        protocolFeeBps = newBps;
        emit ProtocolFeeUpdated(old, newBps);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function setEscrowDuration(uint32 newDuration) external onlyOwner {
        uint32 old = escrowDuration;
        escrowDuration = newDuration;
        emit EscrowDurationUpdated(old, newDuration);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }
}
