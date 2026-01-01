// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/**
 * @title CopyrightRegistry
 * @notice Copyright registration contract - Users submit content hash for copyright claims
 * @dev Works with OTSAnchor contract for Bitcoin timestamp anchoring
 * @custom:address 0x0000000000000000000000000000000000009000
 */
contract CopyrightRegistry {
    // ============ Constants ============

    address public constant OTS_ANCHOR_ADDR = 0x0000000000000000000000000000000000009001;

    // ============ Enums ============

    enum AnchorStatus {
        Pending,      // Waiting for anchoring
        Anchoring,    // Anchoring in progress (submitted to Bitcoin)
        Confirmed,    // Confirmed (Bitcoin confirmed)
        Failed        // Anchoring failed
    }

    // ============ Structs ============

    struct Copyright {
        bytes32 contentHash;      // Content hash (SHA-256)
        address owner;            // Copyright owner
        string title;             // Work title
        string author;            // Author name
        uint256 registeredAt;     // Registration timestamp (block time)
        uint256 registeredBlock;  // Registration block number
        AnchorStatus status;      // OTS anchoring status
        bytes32 otsProofHash;     // OTS proof hash (filled after anchoring)
        uint256 btcBlockHeight;   // Bitcoin block height (filled after anchoring)
    }

    // ============ State Variables ============

    /// @notice Copyright records mapping: contentHash => Copyright
    mapping(bytes32 => Copyright) public copyrights;

    /// @notice All registered content hashes
    bytes32[] public registeredHashes;

    /// @notice Copyrights owned by user: owner => contentHash[]
    mapping(address => bytes32[]) public ownerCopyrights;

    /// @notice Pending anchor queue (waiting for OTS processing)
    bytes32[] public pendingAnchors;

    /// @notice Contract admin
    address public admin;

    /// @notice Initialization flag
    bool public initialized;

    // ============ Events ============

    /// @notice Copyright registration event
    event CopyrightClaimed(
        bytes32 indexed contentHash,
        address indexed owner,
        string title,
        string author,
        uint256 registeredAt,
        uint256 registeredBlock
    );

    /// @notice OTS anchor status update event
    event AnchorStatusUpdated(
        bytes32 indexed contentHash,
        AnchorStatus status,
        bytes32 otsProofHash,
        uint256 btcBlockHeight
    );

    // ============ Errors ============

    error AlreadyInitialized();
    error NotInitialized();
    error OnlyAdmin();
    error OnlyOTSAnchor();
    error InvalidContentHash();
    error TitleRequired();
    error AuthorRequired();
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
     * @param contentHash SHA-256 hash of the content
     * @param title Work title
     * @param author Author name
     */
    function claimCopyright(
        bytes32 contentHash,
        string calldata title,
        string calldata author
    ) external onlyInit {
        if (contentHash == bytes32(0)) revert InvalidContentHash();
        if (bytes(title).length == 0) revert TitleRequired();
        if (bytes(author).length == 0) revert AuthorRequired();
        if (copyrights[contentHash].registeredAt != 0) revert AlreadyRegistered();

        Copyright storage c = copyrights[contentHash];
        c.contentHash = contentHash;
        c.owner = msg.sender;
        c.title = title;
        c.author = author;
        c.registeredAt = block.timestamp;
        c.registeredBlock = block.number;
        c.status = AnchorStatus.Pending;

        registeredHashes.push(contentHash);
        ownerCopyrights[msg.sender].push(contentHash);
        pendingAnchors.push(contentHash);

        emit CopyrightClaimed(
            contentHash,
            msg.sender,
            title,
            author,
            block.timestamp,
            block.number
        );
    }

    /**
     * @notice Update OTS anchor status (only callable by OTSAnchor contract)
     * @param contentHash Content hash
     * @param status New status
     * @param otsProofHash OTS proof hash
     * @param btcBlockHeight Bitcoin block height
     */
    function updateAnchorStatus(
        bytes32 contentHash,
        AnchorStatus status,
        bytes32 otsProofHash,
        uint256 btcBlockHeight
    ) external onlyOTSAnchor {
        if (copyrights[contentHash].registeredAt == 0) revert NotRegistered();

        Copyright storage c = copyrights[contentHash];
        c.status = status;
        c.otsProofHash = otsProofHash;
        c.btcBlockHeight = btcBlockHeight;

        // Remove from pending queue if confirmed or failed
        if (status == AnchorStatus.Confirmed || status == AnchorStatus.Failed) {
            _removeFromPending(contentHash);
        }

        emit AnchorStatusUpdated(contentHash, status, otsProofHash, btcBlockHeight);
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
     * @notice Get copyright details
     * @param contentHash Content hash
     * @return Copyright struct
     */
    function getCopyright(bytes32 contentHash) external view returns (Copyright memory) {
        return copyrights[contentHash];
    }

    /**
     * @notice Check if content is registered
     * @param contentHash Content hash
     * @return bool Whether registered
     */
    function isRegistered(bytes32 contentHash) external view returns (bool) {
        return copyrights[contentHash].registeredAt != 0;
    }

    /**
     * @notice Get all copyrights by owner
     * @param owner User address
     * @return bytes32[] Content hash array
     */
    function getCopyrightsByOwner(address owner) external view returns (bytes32[] memory) {
        return ownerCopyrights[owner];
    }

    /**
     * @notice Get pending anchor queue
     * @return bytes32[] Pending content hash array
     */
    function getPendingAnchors() external view returns (bytes32[] memory) {
        return pendingAnchors;
    }

    /**
     * @notice Get pending count
     * @return uint256 Pending count
     */
    function getPendingCount() external view returns (uint256) {
        return pendingAnchors.length;
    }

    /**
     * @notice Get total registered count
     * @return uint256 Total count
     */
    function getTotalRegistered() external view returns (uint256) {
        return registeredHashes.length;
    }

    // ============ Internal Functions ============

    /**
     * @dev Remove hash from pending queue
     * @param contentHash Hash to remove
     */
    function _removeFromPending(bytes32 contentHash) internal {
        uint256 len = pendingAnchors.length;
        for (uint256 i = 0; i < len; i++) {
            if (pendingAnchors[i] == contentHash) {
                pendingAnchors[i] = pendingAnchors[len - 1];
                pendingAnchors.pop();
                break;
            }
        }
    }
}
