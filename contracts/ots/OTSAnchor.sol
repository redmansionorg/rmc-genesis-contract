// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./CopyrightRegistry.sol";

/**
 * @title OTSAnchor
 * @notice OTS anchoring system contract - Receives system calls from OTS module
 * @dev Only allows validators (coinbase) to call via gasPrice=0 system transactions
 * @custom:address 0x0000000000000000000000000000000000009001
 *
 * System call flow:
 * 1. OTS module builds system transaction in FinalizeHook
 * 2. Validator executes updateOtsStatus with gasPrice=0
 * 3. This contract updates status and notifies CopyrightRegistry
 */
contract OTSAnchor {
    // ============ Constants ============

    address public constant COPYRIGHT_REGISTRY_ADDR = 0x0000000000000000000000000000000000009000;

    // ============ Structs ============

    struct AnchorRecord {
        bytes32 merkleRoot;       // Merkle root of all copyright hashes for the day
        uint256 anchorBlock;      // RMC anchor block number
        uint256 anchorTime;       // RMC anchor timestamp
        uint256 btcBlockHeight;   // Bitcoin block height
        bytes32 btcTxHash;        // Bitcoin transaction hash
        bytes otsProof;           // OTS proof data (optional storage)
        bool confirmed;           // Whether confirmed
    }

    // ============ State Variables ============

    /// @notice Anchor records: merkleRoot => AnchorRecord
    mapping(bytes32 => AnchorRecord) public anchorRecords;

    /// @notice Daily anchors: date (YYYYMMDD) => merkleRoot
    mapping(uint256 => bytes32) public dailyAnchors;

    /// @notice All merkle roots list
    bytes32[] public allMerkleRoots;

    /// @notice Contract admin
    address public admin;

    /// @notice Allowed system callers (usually validators)
    mapping(address => bool) public systemCallers;

    /// @notice Initialization flag
    bool public initialized;

    // ============ Events ============

    /// @notice New anchor submission event
    event AnchorSubmitted(
        bytes32 indexed merkleRoot,
        uint256 indexed date,
        uint256 anchorBlock,
        bytes32[] contentHashes
    );

    /// @notice Anchor confirmation event (after Bitcoin confirmation)
    event AnchorConfirmed(
        bytes32 indexed merkleRoot,
        uint256 btcBlockHeight,
        bytes32 btcTxHash
    );

    /// @notice Single copyright status update event
    event CopyrightStatusUpdated(
        bytes32 indexed contentHash,
        bytes32 indexed merkleRoot,
        CopyrightRegistry.AnchorStatus status
    );

    // ============ Errors ============

    error AlreadyInitialized();
    error NotInitialized();
    error OnlyAdmin();
    error NotSystemCall();
    error InvalidMerkleRoot();
    error DateAlreadyAnchored();
    error NoContentHashes();
    error AnchorNotFound();
    error AlreadyConfirmed();

    // ============ Modifiers ============

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    modifier onlySystem() {
        // System call check: gasPrice == 0 or in allowed list
        if (tx.gasprice != 0 && !systemCallers[msg.sender] && msg.sender != admin) {
            revert NotSystemCall();
        }
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

    // ============ System Functions (Called by OTS Module) ============

    /**
     * @notice Submit new OTS anchor (OTS module system call)
     * @dev Called by validator at daily trigger time, packing all pending copyrights
     * @param merkleRoot Merkle root of all pending content hashes
     * @param date Date in YYYYMMDD format
     * @param contentHashes Content hash list included
     */
    function submitAnchor(
        bytes32 merkleRoot,
        uint256 date,
        bytes32[] calldata contentHashes
    ) external onlySystem onlyInit {
        if (merkleRoot == bytes32(0)) revert InvalidMerkleRoot();
        if (dailyAnchors[date] != bytes32(0)) revert DateAlreadyAnchored();
        if (contentHashes.length == 0) revert NoContentHashes();

        // Record anchor
        AnchorRecord storage record = anchorRecords[merkleRoot];
        record.merkleRoot = merkleRoot;
        record.anchorBlock = block.number;
        record.anchorTime = block.timestamp;
        record.confirmed = false;

        dailyAnchors[date] = merkleRoot;
        allMerkleRoots.push(merkleRoot);

        // Update all related copyrights status to Anchoring
        CopyrightRegistry registry = CopyrightRegistry(COPYRIGHT_REGISTRY_ADDR);
        for (uint256 i = 0; i < contentHashes.length; i++) {
            bytes32 contentHash = contentHashes[i];
            registry.updateAnchorStatus(
                contentHash,
                CopyrightRegistry.AnchorStatus.Anchoring,
                merkleRoot,
                0
            );
            emit CopyrightStatusUpdated(
                contentHash,
                merkleRoot,
                CopyrightRegistry.AnchorStatus.Anchoring
            );
        }

        emit AnchorSubmitted(merkleRoot, date, block.number, contentHashes);
    }

    /**
     * @notice Confirm OTS anchor (called by OTS module after Bitcoin confirmation)
     * @param merkleRoot Merkle root
     * @param btcBlockHeight Bitcoin block height
     * @param btcTxHash Bitcoin transaction hash
     * @param otsProof OTS proof data (optional)
     * @param contentHashes Content hash list to update
     */
    function confirmAnchor(
        bytes32 merkleRoot,
        uint256 btcBlockHeight,
        bytes32 btcTxHash,
        bytes calldata otsProof,
        bytes32[] calldata contentHashes
    ) external onlySystem onlyInit {
        AnchorRecord storage record = anchorRecords[merkleRoot];
        if (record.anchorBlock == 0) revert AnchorNotFound();
        if (record.confirmed) revert AlreadyConfirmed();

        record.btcBlockHeight = btcBlockHeight;
        record.btcTxHash = btcTxHash;
        record.otsProof = otsProof;
        record.confirmed = true;

        // Update all related copyrights status to Confirmed
        CopyrightRegistry registry = CopyrightRegistry(COPYRIGHT_REGISTRY_ADDR);
        for (uint256 i = 0; i < contentHashes.length; i++) {
            bytes32 contentHash = contentHashes[i];
            // Compute proof hash for this content (simplified: use merkleRoot)
            bytes32 proofHash = keccak256(abi.encodePacked(merkleRoot, contentHash));
            registry.updateAnchorStatus(
                contentHash,
                CopyrightRegistry.AnchorStatus.Confirmed,
                proofHash,
                btcBlockHeight
            );
            emit CopyrightStatusUpdated(
                contentHash,
                merkleRoot,
                CopyrightRegistry.AnchorStatus.Confirmed
            );
        }

        emit AnchorConfirmed(merkleRoot, btcBlockHeight, btcTxHash);
    }

    /**
     * @notice Mark anchor as failed (OTS module call)
     * @param merkleRoot Merkle root
     * @param contentHashes Content hash list to update
     */
    function failAnchor(
        bytes32 merkleRoot,
        bytes32[] calldata contentHashes
    ) external onlySystem onlyInit {
        AnchorRecord storage record = anchorRecords[merkleRoot];
        if (record.anchorBlock == 0) revert AnchorNotFound();

        // Update all related copyrights status to Failed
        CopyrightRegistry registry = CopyrightRegistry(COPYRIGHT_REGISTRY_ADDR);
        for (uint256 i = 0; i < contentHashes.length; i++) {
            bytes32 contentHash = contentHashes[i];
            registry.updateAnchorStatus(
                contentHash,
                CopyrightRegistry.AnchorStatus.Failed,
                bytes32(0),
                0
            );
            emit CopyrightStatusUpdated(
                contentHash,
                merkleRoot,
                CopyrightRegistry.AnchorStatus.Failed
            );
        }
    }

    // ============ Admin Functions ============

    /**
     * @notice Add system caller
     * @param caller Caller address
     */
    function addSystemCaller(address caller) external onlyAdmin {
        systemCallers[caller] = true;
    }

    /**
     * @notice Remove system caller
     * @param caller Caller address
     */
    function removeSystemCaller(address caller) external onlyAdmin {
        systemCallers[caller] = false;
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
     * @notice Get anchor record
     * @param merkleRoot Merkle root
     * @return AnchorRecord struct
     */
    function getAnchorRecord(bytes32 merkleRoot) external view returns (AnchorRecord memory) {
        return anchorRecords[merkleRoot];
    }

    /**
     * @notice Get daily anchor
     * @param date Date (YYYYMMDD)
     * @return merkleRoot Merkle root for the date
     */
    function getDailyAnchor(uint256 date) external view returns (bytes32) {
        return dailyAnchors[date];
    }

    /**
     * @notice Get total anchor count
     * @return uint256 Count
     */
    function getTotalAnchors() external view returns (uint256) {
        return allMerkleRoots.length;
    }

    /**
     * @notice Check if anchor is confirmed
     * @param merkleRoot Merkle root
     * @return bool Whether confirmed
     */
    function isConfirmed(bytes32 merkleRoot) external view returns (bool) {
        return anchorRecords[merkleRoot].confirmed;
    }

    /**
     * @notice Verify content hash inclusion in merkle root
     * @dev Simplified version, should use proper Merkle Proof verification
     * @param contentHash Content hash
     * @param merkleRoot Merkle root
     * @param proof Merkle proof
     * @return bool Whether verification passed
     */
    function verifyInclusion(
        bytes32 contentHash,
        bytes32 merkleRoot,
        bytes32[] calldata proof
    ) external pure returns (bool) {
        bytes32 computedHash = contentHash;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            if (computedHash <= proofElement) {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }
        return computedHash == merkleRoot;
    }
}
