// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/**
 * @title CopyrightRegistry
 * @notice Copyright registration contract - Users register copyright claims with RUID
 * @dev Minimal on-chain state design. Use events + RPC for indexing/queries.
 *      RUID = keccak256(puid, auid, claimant, blockNumber) computed off-chain
 * @custom:address 0x0000000000000000000000000000000000009000
 */
contract CopyrightRegistry {
    // ============ Constants ============

    address public constant OTS_ANCHOR_ADDR = 0x0000000000000000000000000000000000009001;

    // ============ Structs ============

    struct Copyright {
        bytes32 ruid;             // Registration Unique ID (primary key)
        bytes32 puid;             // Product Unique ID
        bytes32 auid;             // Asset Unique ID
        address claimant;         // Copyright claimant
        uint64 registeredBlock;   // Registration block number
        uint64 registeredAt;      // Registration timestamp
        bytes32 batchRoot;        // OTS batch root (filled after anchoring)
        uint64 btcBlockHeight;    // Bitcoin block height (filled after anchoring)
        uint64 btcTimestamp;      // Bitcoin block timestamp (filled after anchoring)
    }

    // ============ State Variables ============

    /// @notice Copyright records mapping: ruid => Copyright
    mapping(bytes32 => Copyright) public copyrights;

    /// @notice Contract admin
    address public admin;

    /// @notice Initialization flag
    bool public initialized;

    // ============ Events ============

    /// @notice Copyright claim event - indexed for off-chain querying
    event CopyrightClaimed(
        bytes32 indexed ruid,
        bytes32 indexed puid,
        bytes32 indexed auid,
        address claimant
    );

    /// @notice OTS status update event - batch level update
    event OtsStatusUpdated(
        bytes32 indexed ruid,
        bytes32 batchRoot,
        uint64 btcBlockHeight,
        uint64 btcTimestamp
    );

    // ============ Errors ============

    error AlreadyInitialized();
    error NotInitialized();
    error OnlyAdmin();
    error OnlyOTSAnchor();
    error InvalidRUID();
    error InvalidPUID();
    error InvalidAUID();
    error AlreadyRegistered();
    error NotRegistered();

    // ============ Modifiers ============

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    modifier onlyOTSAnchor() {
        if (msg.sender != OTS_ANCHOR_ADDR) revert OnlyOTSAnchor();
        _;
    }

    modifier onlyInit() {
        if (!initialized) revert NotInitialized();
        _;
    }

    // ============ Initialization ============

    /**
     * @notice Initialize the contract (called once at genesis)
     * @param _admin Admin address
     */
    function init(address _admin) external {
        if (initialized) revert AlreadyInitialized();
        admin = _admin;
        initialized = true;
    }

    // ============ External Functions ============

    /**
     * @notice Register a copyright claim
     * @dev RUID must be pre-computed: keccak256(abi.encodePacked(puid, auid, msg.sender, block.number))
     * @param ruid Registration Unique ID (pre-computed)
     * @param puid Product Unique ID
     * @param auid Asset Unique ID
     */
    function registerClaim(
        bytes32 ruid,
        bytes32 puid,
        bytes32 auid
    ) external onlyInit {
        if (ruid == bytes32(0)) revert InvalidRUID();
        if (puid == bytes32(0)) revert InvalidPUID();
        if (auid == bytes32(0)) revert InvalidAUID();
        if (copyrights[ruid].registeredAt != 0) revert AlreadyRegistered();

        // Verify RUID computation
        bytes32 expectedRuid = keccak256(abi.encodePacked(puid, auid, msg.sender, block.number));
        if (ruid != expectedRuid) revert InvalidRUID();

        Copyright storage c = copyrights[ruid];
        c.ruid = ruid;
        c.puid = puid;
        c.auid = auid;
        c.claimant = msg.sender;
        c.registeredBlock = uint64(block.number);
        c.registeredAt = uint64(block.timestamp);

        emit CopyrightClaimed(ruid, puid, auid, msg.sender);
    }

    /**
     * @notice Batch update OTS status for multiple RUIDs (only callable by OTSAnchor)
     * @dev Called once per batch when BTC confirmation is received
     * @param ruids Array of RUIDs to update
     * @param batchRoot Merkle root of the batch
     * @param btcBlockHeight Bitcoin block height
     * @param btcTimestamp Bitcoin block timestamp
     */
    function updateOtsStatus(
        bytes32[] calldata ruids,
        bytes32 batchRoot,
        uint64 btcBlockHeight,
        uint64 btcTimestamp
    ) external onlyOTSAnchor {
        for (uint256 i = 0; i < ruids.length; i++) {
            bytes32 ruid = ruids[i];
            Copyright storage c = copyrights[ruid];

            // Skip if not registered (defensive, shouldn't happen)
            if (c.registeredAt == 0) continue;

            c.batchRoot = batchRoot;
            c.btcBlockHeight = btcBlockHeight;
            c.btcTimestamp = btcTimestamp;

            emit OtsStatusUpdated(ruid, batchRoot, btcBlockHeight, btcTimestamp);
        }
    }

    /**
     * @notice Transfer admin rights
     * @param newAdmin New admin address
     */
    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "invalid address");
        admin = newAdmin;
    }

    // ============ View Functions ============

    /**
     * @notice Get copyright details by RUID
     * @param ruid Registration Unique ID
     * @return Copyright struct
     */
    function getCopyright(bytes32 ruid) external view returns (Copyright memory) {
        return copyrights[ruid];
    }

    /**
     * @notice Check if RUID is registered
     * @param ruid Registration Unique ID
     * @return bool Whether registered
     */
    function isRegistered(bytes32 ruid) external view returns (bool) {
        return copyrights[ruid].registeredAt != 0;
    }

    /**
     * @notice Check if RUID has been anchored to Bitcoin
     * @param ruid Registration Unique ID
     * @return bool Whether anchored
     */
    function isAnchored(bytes32 ruid) external view returns (bool) {
        return copyrights[ruid].btcBlockHeight != 0;
    }

    /**
     * @notice Compute RUID for given parameters
     * @dev Helper for clients to compute RUID before calling registerClaim
     * @param puid Product Unique ID
     * @param auid Asset Unique ID
     * @param claimant Claimant address
     * @param blockNumber Block number
     * @return bytes32 Computed RUID
     */
    function computeRUID(
        bytes32 puid,
        bytes32 auid,
        address claimant,
        uint256 blockNumber
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(puid, auid, claimant, blockNumber));
    }
}
