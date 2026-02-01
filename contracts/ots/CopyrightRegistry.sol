// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title CopyrightRegistry
 * @notice 版权时间戳注册合约 - 最小事实存储
 * @dev 链上只承载"不可争辩的最小事实"
 *      - claim: 占位声明 (隐藏 auid/puid 防三明治攻击)
 *      - publish: 公开发行 (揭示 auid/puid)
 *      - anchor: 批次锚定 (系统交易，BTC 时间戳)
 * @custom:address 0x0000000000000000000000000000000000009000
 */
contract CopyrightRegistry {

    // ==================== 数据结构 ====================

    /// @notice 版权记录
    struct CopyrightRecord {
        address claimant;      // 声明者地址
        uint64  submitBlock;   // 提交区块号
        bytes32 auid;          // 资产ID (publish后填充，初始为0)
        bytes32 puid;          // 身份ID (publish后填充，初始为0)
        bool    published;     // 是否已公开发行
    }

    /// @notice 批次记录
    struct BatchRecord {
        uint64  startBlock;    // 起始区块 (含)
        uint64  endBlock;      // 结束区块 (含)
        bytes32 batchRoot;     // Merkle Root of RUIDs
        bytes32 btcTxHash;     // BTC 交易哈希
        uint64  btcTimestamp;  // BTC 区块时间戳
    }

    // ==================== 状态变量 ====================

    /// @notice 版权记录: ruid => CopyrightRecord
    mapping(bytes32 => CopyrightRecord) public copyrights;

    /// @notice 批次记录: batchId => BatchRecord
    mapping(uint256 => BatchRecord) public batches;

    /// @notice 批次计数器
    uint256 public batchCount;

    /// @notice 上次锚定的结束区块号 (用于顺序批次强制)
    uint64 public lastAnchoredEndBlock;

    /// @notice 管理员地址
    address public admin;

    /// @notice 初始化标志
    bool public initialized;

    // ==================== 事件 ====================

    /// @notice 版权声明事件 (占位)
    event Claimed(
        bytes32 indexed ruid,
        address indexed claimant,
        uint64  submitBlock
    );

    /// @notice 批次锚定事件
    event Anchored(
        uint256 indexed batchId,
        uint64  startBlock,
        uint64  endBlock,
        bytes32 batchRoot,
        bytes32 btcTxHash,
        uint64  btcTimestamp
    );

    /// @notice 版权发行事件 (公开)
    event Published(
        bytes32 indexed ruid,
        bytes32 indexed auid,
        bytes32 indexed puid,
        address claimant
    );

    // ==================== 错误 ====================

    error AlreadyInitialized();
    error NotInitialized();
    error OnlyAdmin();
    error OnlyCoinbase();
    error OnlySystemTx();
    error InvalidRuid();
    error AlreadyClaimed();
    error NotClaimant();
    error AlreadyPublished();
    error InvalidBlockRange();
    error BatchNotSequential();

    // ==================== 修饰符 ====================

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    modifier onlyCoinbase() {
        if (msg.sender != block.coinbase) revert OnlyCoinbase();
        _;
    }

    modifier onlySystemTx() {
        if (tx.gasprice != 0) revert OnlySystemTx();
        _;
    }

    modifier onlyInit() {
        if (!initialized) revert NotInitialized();
        _;
    }

    // ==================== 初始化 ====================

    /**
     * @notice 初始化合约 (创世块调用一次)
     * @param _admin 管理员地址
     */
    function init(address _admin) external {
        if (initialized) revert AlreadyInitialized();
        require(_admin != address(0), "invalid admin");
        admin = _admin;
        initialized = true;
    }

    // ==================== 用户接口 ====================

    /**
     * @notice 声明版权 (占位，不公开 auid/puid)
     * @dev ruid = keccak256(puid, auid)，链下预计算
     *      防止三明治攻击：攻击者只能看到 ruid，无法推断 auid
     * @param ruid 版权唯一标识 (预计算)
     */
    function claim(bytes32 ruid) external onlyInit {
        if (ruid == bytes32(0)) revert InvalidRuid();
        if (copyrights[ruid].submitBlock != 0) revert AlreadyClaimed();

        copyrights[ruid] = CopyrightRecord({
            claimant:    msg.sender,
            submitBlock: uint64(block.number),
            auid:        bytes32(0),
            puid:        bytes32(0),
            published:   false
        });

        emit Claimed(ruid, msg.sender, uint64(block.number));
    }

    /**
     * @notice 发行版权 (公开 auid/puid)
     * @dev 验证 ruid == keccak256(puid, auid)
     *      只有原声明者可以发行
     * @param ruid 版权唯一标识
     * @param auid 资产标识
     * @param puid 身份标识
     */
    function publish(bytes32 ruid, bytes32 auid, bytes32 puid) external onlyInit {
        CopyrightRecord storage rec = copyrights[ruid];

        if (rec.submitBlock == 0) revert InvalidRuid();
        if (rec.claimant != msg.sender) revert NotClaimant();
        if (rec.published) revert AlreadyPublished();
        if (keccak256(abi.encodePacked(puid, auid)) != ruid) revert InvalidRuid();

        rec.auid = auid;
        rec.puid = puid;
        rec.published = true;

        emit Published(ruid, auid, puid, msg.sender);
    }

    // ==================== 系统接口 ====================

    /**
     * @notice 锚定批次 (系统交易)
     * @dev 仅 coinbase 可调用，gasPrice 必须为 0
     *      batchRoot = Merkle(RUIDs in [startBlock, endBlock] order by block,tx,log)
     *      顺序批次强制：startBlock 必须 == lastAnchoredEndBlock + 1
     *      空批次允许：batchRoot=0 表示该区块范围无 RUID
     * @param startBlock 起始区块号
     * @param endBlock 结束区块号
     * @param batchRoot 批次 Merkle 根 (空批次时为 0)
     * @param btcTxHash BTC 交易哈希 (空批次时为 0)
     * @param btcTimestamp BTC 区块时间戳 (空批次时为 0)
     */
    function anchor(
        uint64  startBlock,
        uint64  endBlock,
        bytes32 batchRoot,
        bytes32 btcTxHash,
        uint64  btcTimestamp
    ) external onlyInit onlyCoinbase onlySystemTx {
        // 验证区块范围
        if (startBlock > endBlock) revert InvalidBlockRange();

        // 顺序批次强制：startBlock 必须紧接上次 endBlock
        // 首次锚定时 lastAnchoredEndBlock == 0，允许任意 startBlock
        if (lastAnchoredEndBlock != 0 && startBlock != lastAnchoredEndBlock + 1) {
            revert BatchNotSequential();
        }

        // 递增批次ID
        uint256 batchId = ++batchCount;

        // 存储批次记录 (batchRoot 可以为 0，表示空批次)
        batches[batchId] = BatchRecord({
            startBlock:   startBlock,
            endBlock:     endBlock,
            batchRoot:    batchRoot,
            btcTxHash:    btcTxHash,
            btcTimestamp: btcTimestamp
        });

        // 更新锚定进度
        lastAnchoredEndBlock = endBlock;

        emit Anchored(
            batchId,
            startBlock,
            endBlock,
            batchRoot,
            btcTxHash,
            btcTimestamp
        );
    }

    // ==================== 管理接口 ====================

    /**
     * @notice 转移管理员
     * @param newAdmin 新管理员地址
     */
    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "invalid admin");
        admin = newAdmin;
    }

    // ==================== 查询接口 ====================

    /**
     * @notice 获取版权记录
     * @param ruid 版权唯一标识
     */
    function getCopyright(bytes32 ruid) external view returns (CopyrightRecord memory) {
        return copyrights[ruid];
    }

    /**
     * @notice 获取批次记录
     * @param batchId 批次ID
     */
    function getBatch(uint256 batchId) external view returns (BatchRecord memory) {
        return batches[batchId];
    }

    /**
     * @notice 检查 ruid 是否已声明
     * @param ruid 版权唯一标识
     */
    function isClaimed(bytes32 ruid) external view returns (bool) {
        return copyrights[ruid].submitBlock != 0;
    }

    /**
     * @notice 检查 ruid 是否已发行
     * @param ruid 版权唯一标识
     */
    function isPublished(bytes32 ruid) external view returns (bool) {
        return copyrights[ruid].published;
    }
}
