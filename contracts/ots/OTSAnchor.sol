// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./CopyrightRegistry.sol";

/**
 * @title OTSAnchor
 * @notice OTS anchoring system contract - Receives system transactions from OTS module
 * @dev Only allows coinbase (block producer) with gasPrice=0 system transactions
 *      NO per-RUID loops in this contract - all updates delegated to CopyrightRegistry
 * @custom:address 0x0000000000000000000000000000000000009001
 *
 * System call flow:
 * 1. OTS module builds system transaction in FinalizeHook
 * 2. Block producer executes updateOtsStatus with gasPrice=0
 * 3. This contract records batch and forwards RUID updates to CopyrightRegistry
 */
contract OTSAnchor {
    // ============ Constants ============

    address public constant COPYRIGHT_REGISTRY_ADDR = 0x0000000000000000000000000000000000009000;

    // ============ Structs ============

    struct BatchRecord {
        bytes32 batchRoot;        // Merkle root of all RUIDs in the batch
        uint64 startBlock;        // First RMC block in batch (inclusive)
        uint64 endBlock;          // Last RMC block in batch (inclusive)
        uint64 anchorBlock;       // RMC block where anchored
        uint64 anchorTime;        // RMC timestamp when anchored
        uint64 btcBlockHeight;    // Bitcoin block height
        uint64 btcTimestamp;      // Bitcoin block timestamp (OTS timestamp)
        uint32 ruidCount;         // Number of RUIDs in batch
    }

    // ============ State Variables ============

    /// @notice Batch records: batchRoot => BatchRecord
    mapping(bytes32 => BatchRecord) public batchRecords;

    /// @notice EndBlock to batchRoot mapping for lookup
    mapping(uint64 => bytes32) public endBlockToBatch;

    /// @notice All batch roots list (for iteration if needed)
    bytes32[] public allBatchRoots;

    /// @notice Contract admin (for emergency only)
    address public admin;

    /// @notice Initialization flag
    bool public initialized;

    // ============ Events ============

    /// @notice Batch anchored event - emitted when BTC confirmation is written
    event BatchAnchored(
        bytes32 indexed batchRoot,
        uint64 indexed endBlock,
        uint64 startBlock,
        uint64 btcBlockHeight,
        uint64 btcTimestamp,
        uint32 ruidCount
    );

    // ============ Errors ============

    error AlreadyInitialized();
    error NotInitialized();
    error OnlyAdmin();
    error NotSystemCall();
    error InvalidBatchRoot();
    error InvalidBlockRange();
    error BatchAlreadyAnchored();
    error EmptyRUIDs();

    // ============ Modifiers ============

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    /**
     * @notice System call modifier - strictly gasPrice=0 && coinbase
     * @dev In consensus, only block producers can inject system txs with gasPrice=0
     *      msg.sender == block.coinbase ensures this is the block producer
     */
    modifier onlySystem() {
        if (tx.gasprice != 0) revert NotSystemCall();
        if (msg.sender != block.coinbase) revert NotSystemCall();
        _;
    }

    modifier onlyInit() {
        if (!initialized) revert NotInitialized();
        _;
    }

    // ============ Initialization ============

    /**
     * @notice Initialize the contract (called once at genesis)
     * @param _admin Admin address (for emergency only)
     */
    function init(address _admin) external {
        if (initialized) revert AlreadyInitialized();
        admin = _admin;
        initialized = true;
    }

    // ============ System Functions (Called by OTS Module) ============

    /**
     * @notice Update OTS status for a batch (system transaction from block producer)
     * @dev Called via FinalizeHook when BTC confirmation is received
     *      Matches Go signature: updateOtsStatus(bytes32[],bytes32,uint64,uint64,uint64)
     * @param ruids Array of RUIDs in the batch (sorted by SortKey)
     * @param batchRoot Merkle root of the batch
     * @param otsTimestamp Bitcoin block timestamp (OTS timestamp)
     * @param startBlock First RMC block in batch
     * @param endBlock Last RMC block in batch
     */
    function updateOtsStatus(
        bytes32[] calldata ruids,
        bytes32 batchRoot,
        uint64 otsTimestamp,
        uint64 startBlock,
        uint64 endBlock
    ) external onlySystem onlyInit {
        if (batchRoot == bytes32(0)) revert InvalidBatchRoot();
        if (startBlock > endBlock) revert InvalidBlockRange();
        if (ruids.length == 0) revert EmptyRUIDs();
        if (batchRecords[batchRoot].anchorBlock != 0) revert BatchAlreadyAnchored();

        // Record batch
        BatchRecord storage record = batchRecords[batchRoot];
        record.batchRoot = batchRoot;
        record.startBlock = startBlock;
        record.endBlock = endBlock;
        record.anchorBlock = uint64(block.number);
        record.anchorTime = uint64(block.timestamp);
        record.btcBlockHeight = 0; // Will be filled from otsTimestamp lookup if needed
        record.btcTimestamp = otsTimestamp;
        record.ruidCount = uint32(ruids.length);

        endBlockToBatch[endBlock] = batchRoot;
        allBatchRoots.push(batchRoot);

        // Forward RUID updates to CopyrightRegistry (single call, registry handles loop)
        CopyrightRegistry registry = CopyrightRegistry(COPYRIGHT_REGISTRY_ADDR);
        registry.updateOtsStatus(ruids, batchRoot, 0, otsTimestamp);

        emit BatchAnchored(
            batchRoot,
            endBlock,
            startBlock,
            0,
            otsTimestamp,
            uint32(ruids.length)
        );
    }

    // ============ Admin Functions (Emergency Only) ============

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
     * @notice Get batch record by root
     * @param batchRoot Merkle root
     * @return BatchRecord struct
     */
    function getBatchRecord(bytes32 batchRoot) external view returns (BatchRecord memory) {
        return batchRecords[batchRoot];
    }

    /**
     * @notice Get batch root by end block
     * @param endBlock End block number
     * @return batchRoot Merkle root for the batch
     */
    function getBatchByEndBlock(uint64 endBlock) external view returns (bytes32) {
        return endBlockToBatch[endBlock];
    }

    /**
     * @notice Get total batch count
     * @return uint256 Count
     */
    function getTotalBatches() external view returns (uint256) {
        return allBatchRoots.length;
    }

    /**
     * @notice Check if batch exists
     * @param batchRoot Merkle root
     * @return bool Whether anchored
     */
    function isBatchAnchored(bytes32 batchRoot) external view returns (bool) {
        return batchRecords[batchRoot].anchorBlock != 0;
    }

    /**
     * @notice Verify RUID inclusion in batch merkle root
     * @dev Standard Merkle proof verification
     * @param ruid RUID to verify
     * @param batchRoot Merkle root
     * @param proof Merkle proof path
     * @return bool Whether verification passed
     */
    function verifyInclusion(
        bytes32 ruid,
        bytes32 batchRoot,
        bytes32[] calldata proof
    ) external pure returns (bool) {
        bytes32 computedHash = ruid;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            if (computedHash <= proofElement) {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }
        return computedHash == batchRoot;
    }
}
