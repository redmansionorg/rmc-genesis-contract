// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../../contracts/ots/CopyrightRegistry.sol";

/**
 * @title CopyrightRegistryTest
 * @notice Foundry tests for the unified CopyrightRegistry contract
 * @dev Run with: forge test --match-path test/ots/OTS.t.sol -vvv
 *
 * New Design:
 * - Single contract at 0x9000
 * - claim(ruid) - placeholder claim (hides auid/puid for sandwich attack prevention)
 * - publish(ruid, auid, puid) - reveal identities
 * - anchor(startBlock, endBlock, batchRoot, btcTxHash, btcTimestamp) - system tx
 */
contract CopyrightRegistryTest is Test {
    // Contract address
    address constant CONTRACT_ADDR = 0x0000000000000000000000000000000000009000;

    CopyrightRegistry public registry;

    address public admin;
    address public user1;
    address public user2;
    address public coinbase;

    // Sample test data
    bytes32 public samplePuid;
    bytes32 public sampleAuid;
    bytes32 public sampleRuid;

    // Events (matching contract)
    event Claimed(
        bytes32 indexed ruid,
        address indexed claimant,
        uint64  submitBlock
    );

    event Published(
        bytes32 indexed ruid,
        bytes32 indexed auid,
        bytes32 indexed puid,
        address claimant
    );

    event Anchored(
        uint256 indexed batchId,
        uint64  startBlock,
        uint64  endBlock,
        bytes32 batchRoot,
        bytes32 btcTxHash,
        uint64  btcTimestamp
    );

    function setUp() public {
        admin = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        coinbase = makeAddr("coinbase");

        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);

        // Create sample data
        samplePuid = keccak256(abi.encodePacked("user1", "identity"));
        sampleAuid = keccak256(abi.encodePacked("asset", "content"));
        sampleRuid = keccak256(abi.encodePacked(samplePuid, sampleAuid));

        // Deploy contract to fixed address
        vm.etch(CONTRACT_ADDR, address(new CopyrightRegistry()).code);
        registry = CopyrightRegistry(CONTRACT_ADDR);

        // Initialize contract
        registry.init(admin);
    }

    // ============ Initialization Tests ============

    function test_Init() public {
        assertEq(registry.admin(), admin);
        assertTrue(registry.initialized());
        assertEq(registry.batchCount(), 0);
        assertEq(registry.lastAnchoredEndBlock(), 0);
    }

    function test_Init_RevertAlreadyInitialized() public {
        vm.expectRevert(CopyrightRegistry.AlreadyInitialized.selector);
        registry.init(user1);
    }

    // ============ Claim Tests ============

    function test_Claim() public {
        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit Claimed(sampleRuid, user1, uint64(block.number));
        registry.claim(sampleRuid);

        CopyrightRegistry.CopyrightRecord memory rec = registry.getCopyright(sampleRuid);
        assertEq(rec.claimant, user1);
        assertEq(rec.submitBlock, uint64(block.number));
        assertEq(rec.auid, bytes32(0)); // Not revealed yet
        assertEq(rec.puid, bytes32(0)); // Not revealed yet
        assertFalse(rec.published);
    }

    function test_Claim_RevertInvalidRuid() public {
        vm.prank(user1);
        vm.expectRevert(CopyrightRegistry.InvalidRuid.selector);
        registry.claim(bytes32(0));
    }

    function test_Claim_RevertAlreadyClaimed() public {
        vm.prank(user1);
        registry.claim(sampleRuid);

        vm.prank(user2);
        vm.expectRevert(CopyrightRegistry.AlreadyClaimed.selector);
        registry.claim(sampleRuid);
    }

    function test_IsClaimed() public {
        assertFalse(registry.isClaimed(sampleRuid));

        vm.prank(user1);
        registry.claim(sampleRuid);

        assertTrue(registry.isClaimed(sampleRuid));
    }

    // ============ Publish Tests ============

    function test_Publish() public {
        // First claim
        vm.prank(user1);
        registry.claim(sampleRuid);

        // Then publish
        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit Published(sampleRuid, sampleAuid, samplePuid, user1);
        registry.publish(sampleRuid, sampleAuid, samplePuid);

        CopyrightRegistry.CopyrightRecord memory rec = registry.getCopyright(sampleRuid);
        assertEq(rec.auid, sampleAuid);
        assertEq(rec.puid, samplePuid);
        assertTrue(rec.published);
    }

    function test_Publish_RevertInvalidRuid() public {
        vm.prank(user1);
        vm.expectRevert(CopyrightRegistry.InvalidRuid.selector);
        registry.publish(sampleRuid, sampleAuid, samplePuid);
    }

    function test_Publish_RevertNotClaimant() public {
        vm.prank(user1);
        registry.claim(sampleRuid);

        vm.prank(user2);
        vm.expectRevert(CopyrightRegistry.NotClaimant.selector);
        registry.publish(sampleRuid, sampleAuid, samplePuid);
    }

    function test_Publish_RevertAlreadyPublished() public {
        vm.startPrank(user1);
        registry.claim(sampleRuid);
        registry.publish(sampleRuid, sampleAuid, samplePuid);

        vm.expectRevert(CopyrightRegistry.AlreadyPublished.selector);
        registry.publish(sampleRuid, sampleAuid, samplePuid);
        vm.stopPrank();
    }

    function test_Publish_RevertMismatchedRuid() public {
        vm.prank(user1);
        registry.claim(sampleRuid);

        bytes32 wrongAuid = keccak256("wrong asset");
        vm.prank(user1);
        vm.expectRevert(CopyrightRegistry.InvalidRuid.selector);
        registry.publish(sampleRuid, wrongAuid, samplePuid);
    }

    function test_IsPublished() public {
        assertFalse(registry.isPublished(sampleRuid));

        vm.prank(user1);
        registry.claim(sampleRuid);
        assertFalse(registry.isPublished(sampleRuid));

        vm.prank(user1);
        registry.publish(sampleRuid, sampleAuid, samplePuid);
        assertTrue(registry.isPublished(sampleRuid));
    }

    // ============ Anchor Tests ============

    function test_Anchor() public {
        uint64 startBlock = 1;
        uint64 endBlock = 100;
        bytes32 batchRoot = keccak256("batch root");
        bytes32 btcTxHash = keccak256("btc tx");
        uint64 btcTimestamp = 1700000000;

        // Set coinbase and gasPrice
        vm.coinbase(coinbase);
        vm.txGasPrice(0);

        vm.prank(coinbase);
        vm.expectEmit(true, false, false, true);
        emit Anchored(1, startBlock, endBlock, batchRoot, btcTxHash, btcTimestamp);
        registry.anchor(startBlock, endBlock, batchRoot, btcTxHash, btcTimestamp);

        // Verify batch record
        CopyrightRegistry.BatchRecord memory batch = registry.getBatch(1);
        assertEq(batch.startBlock, startBlock);
        assertEq(batch.endBlock, endBlock);
        assertEq(batch.batchRoot, batchRoot);
        assertEq(batch.btcTxHash, btcTxHash);
        assertEq(batch.btcTimestamp, btcTimestamp);

        assertEq(registry.batchCount(), 1);
        assertEq(registry.lastAnchoredEndBlock(), endBlock);
    }

    function test_Anchor_EmptyBatch() public {
        uint64 startBlock = 1;
        uint64 endBlock = 100;
        bytes32 batchRoot = bytes32(0); // Empty batch
        bytes32 btcTxHash = bytes32(0);
        uint64 btcTimestamp = 0;

        vm.coinbase(coinbase);
        vm.txGasPrice(0);

        vm.prank(coinbase);
        registry.anchor(startBlock, endBlock, batchRoot, btcTxHash, btcTimestamp);

        CopyrightRegistry.BatchRecord memory batch = registry.getBatch(1);
        assertEq(batch.batchRoot, bytes32(0));
        assertEq(registry.batchCount(), 1);
    }

    function test_Anchor_SequentialBatches() public {
        vm.coinbase(coinbase);
        vm.txGasPrice(0);

        // First batch: blocks 1-100
        vm.prank(coinbase);
        registry.anchor(1, 100, keccak256("root1"), bytes32(0), 0);
        assertEq(registry.lastAnchoredEndBlock(), 100);

        // Second batch: blocks 101-200 (sequential)
        vm.prank(coinbase);
        registry.anchor(101, 200, keccak256("root2"), bytes32(0), 0);
        assertEq(registry.lastAnchoredEndBlock(), 200);

        // Third batch: blocks 201-300 (sequential)
        vm.prank(coinbase);
        registry.anchor(201, 300, keccak256("root3"), bytes32(0), 0);
        assertEq(registry.lastAnchoredEndBlock(), 300);
        assertEq(registry.batchCount(), 3);
    }

    function test_Anchor_RevertNotSequential() public {
        vm.coinbase(coinbase);
        vm.txGasPrice(0);

        // First batch: blocks 1-100
        vm.prank(coinbase);
        registry.anchor(1, 100, keccak256("root1"), bytes32(0), 0);

        // Try to anchor non-sequential batch (should start at 101)
        vm.prank(coinbase);
        vm.expectRevert(CopyrightRegistry.BatchNotSequential.selector);
        registry.anchor(102, 200, keccak256("root2"), bytes32(0), 0);
    }

    function test_Anchor_RevertInvalidBlockRange() public {
        vm.coinbase(coinbase);
        vm.txGasPrice(0);

        vm.prank(coinbase);
        vm.expectRevert(CopyrightRegistry.InvalidBlockRange.selector);
        registry.anchor(100, 1, keccak256("root"), bytes32(0), 0); // startBlock > endBlock
    }

    function test_Anchor_RevertNotCoinbase() public {
        vm.coinbase(coinbase);
        vm.txGasPrice(0);

        vm.prank(user1);
        vm.expectRevert(CopyrightRegistry.OnlyCoinbase.selector);
        registry.anchor(1, 100, keccak256("root"), bytes32(0), 0);
    }

    function test_Anchor_RevertNotSystemTx() public {
        vm.coinbase(coinbase);
        vm.txGasPrice(1 gwei); // Non-zero gas price

        vm.prank(coinbase);
        vm.expectRevert(CopyrightRegistry.OnlySystemTx.selector);
        registry.anchor(1, 100, keccak256("root"), bytes32(0), 0);
    }

    // ============ Admin Tests ============

    function test_TransferAdmin() public {
        address newAdmin = makeAddr("newAdmin");
        registry.transferAdmin(newAdmin);
        assertEq(registry.admin(), newAdmin);
    }

    function test_TransferAdmin_RevertNotAdmin() public {
        vm.prank(user1);
        vm.expectRevert(CopyrightRegistry.OnlyAdmin.selector);
        registry.transferAdmin(user1);
    }

    function test_TransferAdmin_RevertZeroAddress() public {
        vm.expectRevert("invalid admin");
        registry.transferAdmin(address(0));
    }

    // ============ Full Flow Tests ============

    function test_FullFlow_ClaimPublishAnchor() public {
        // 1. User claims copyright (placeholder)
        vm.prank(user1);
        registry.claim(sampleRuid);

        CopyrightRegistry.CopyrightRecord memory rec = registry.getCopyright(sampleRuid);
        assertEq(rec.claimant, user1);
        assertFalse(rec.published);

        // 2. User publishes (reveals auid/puid)
        vm.prank(user1);
        registry.publish(sampleRuid, sampleAuid, samplePuid);

        rec = registry.getCopyright(sampleRuid);
        assertTrue(rec.published);
        assertEq(rec.auid, sampleAuid);
        assertEq(rec.puid, samplePuid);

        // 3. System anchors batch
        vm.coinbase(coinbase);
        vm.txGasPrice(0);

        vm.prank(coinbase);
        registry.anchor(
            1,
            uint64(block.number),
            keccak256(abi.encodePacked(sampleRuid)),
            keccak256("btc tx"),
            1700000000
        );

        // Verify batch
        CopyrightRegistry.BatchRecord memory batch = registry.getBatch(1);
        assertEq(batch.startBlock, 1);
        assertEq(batch.btcTimestamp, 1700000000);
    }

    function test_MultipleClaims() public {
        bytes32[] memory ruids = new bytes32[](5);

        for (uint i = 0; i < 5; i++) {
            bytes32 puid = keccak256(abi.encodePacked("user", i));
            bytes32 auid = keccak256(abi.encodePacked("asset", i));
            ruids[i] = keccak256(abi.encodePacked(puid, auid));

            vm.prank(user1);
            registry.claim(ruids[i]);
        }

        // Verify all claimed
        for (uint i = 0; i < 5; i++) {
            assertTrue(registry.isClaimed(ruids[i]));
        }
    }

    function test_SandwichAttackPrevention() public {
        // Attacker sees user1's claim transaction in mempool
        // But they only see the ruid, not auid/puid

        // User1 claims (only ruid is visible)
        vm.prank(user1);
        registry.claim(sampleRuid);

        // Attacker cannot front-run because:
        // 1. They don't know auid/puid (hidden until publish)
        // 2. The same ruid cannot be claimed twice

        vm.prank(user2);
        vm.expectRevert(CopyrightRegistry.AlreadyClaimed.selector);
        registry.claim(sampleRuid);

        // Only original claimant can publish
        vm.prank(user2);
        vm.expectRevert(CopyrightRegistry.NotClaimant.selector);
        registry.publish(sampleRuid, sampleAuid, samplePuid);

        // User1 can still publish their claim
        vm.prank(user1);
        registry.publish(sampleRuid, sampleAuid, samplePuid);
        assertTrue(registry.isPublished(sampleRuid));
    }
}
