// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../../contracts/ots/CopyrightRegistry.sol";
import "../../contracts/ots/OTSAnchor.sol";

/**
 * @title OTSTest
 * @notice Foundry tests for OTS contracts (CopyrightRegistry + OTSAnchor)
 * @dev Run with: forge test --match-path test/ots/OTS.t.sol -vvv
 */
contract OTSTest is Test {
    // Contract addresses
    address constant COPYRIGHT_REGISTRY_ADDR = 0x0000000000000000000000000000000000009000;
    address constant OTS_ANCHOR_ADDR = 0x0000000000000000000000000000000000009001;

    CopyrightRegistry public copyrightRegistry;
    OTSAnchor public otsAnchor;

    address public admin;
    address public user1;
    address public user2;
    address public validator;

    bytes32 public sampleContentHash;
    string public sampleTitle = "Test Work";
    string public sampleAuthor = "Test Author";

    event CopyrightClaimed(
        bytes32 indexed contentHash,
        address indexed owner,
        string title,
        string author,
        uint256 registeredAt,
        uint256 registeredBlock
    );

    event AnchorStatusUpdated(
        bytes32 indexed contentHash,
        CopyrightRegistry.AnchorStatus status,
        bytes32 otsProofHash,
        uint256 btcBlockHeight
    );

    event AnchorSubmitted(
        bytes32 indexed merkleRoot,
        uint256 indexed date,
        uint256 anchorBlock,
        bytes32[] contentHashes
    );

    event AnchorConfirmed(
        bytes32 indexed merkleRoot,
        uint256 btcBlockHeight,
        bytes32 btcTxHash
    );

    function setUp() public {
        admin = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        validator = makeAddr("validator");

        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        vm.deal(validator, 10 ether);

        sampleContentHash = keccak256("Sample content for testing");

        // Deploy contracts to fixed addresses
        bytes memory registryCode = type(CopyrightRegistry).creationCode;
        bytes memory anchorCode = type(OTSAnchor).creationCode;

        vm.etch(COPYRIGHT_REGISTRY_ADDR, address(new CopyrightRegistry()).code);
        vm.etch(OTS_ANCHOR_ADDR, address(new OTSAnchor()).code);

        copyrightRegistry = CopyrightRegistry(COPYRIGHT_REGISTRY_ADDR);
        otsAnchor = OTSAnchor(OTS_ANCHOR_ADDR);

        // Initialize contracts
        copyrightRegistry.init(admin);
        otsAnchor.init(admin);
    }

    // ============ CopyrightRegistry Tests ============

    function test_Registry_Init() public view {
        assertEq(copyrightRegistry.admin(), admin);
        assertTrue(copyrightRegistry.initialized());
    }

    function test_Registry_ClaimCopyright() public {
        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit CopyrightClaimed(
            sampleContentHash,
            user1,
            sampleTitle,
            sampleAuthor,
            block.timestamp,
            block.number
        );
        copyrightRegistry.claimCopyright(sampleContentHash, sampleTitle, sampleAuthor);

        CopyrightRegistry.Copyright memory c = copyrightRegistry.getCopyright(sampleContentHash);
        assertEq(c.contentHash, sampleContentHash);
        assertEq(c.owner, user1);
        assertEq(c.title, sampleTitle);
        assertEq(c.author, sampleAuthor);
        assertEq(uint8(c.status), uint8(CopyrightRegistry.AnchorStatus.Pending));
    }

    function test_Registry_ClaimCopyright_RevertDuplicate() public {
        vm.prank(user1);
        copyrightRegistry.claimCopyright(sampleContentHash, sampleTitle, sampleAuthor);

        vm.prank(user2);
        vm.expectRevert(CopyrightRegistry.AlreadyRegistered.selector);
        copyrightRegistry.claimCopyright(sampleContentHash, "Other Title", "Other Author");
    }

    function test_Registry_ClaimCopyright_RevertInvalidHash() public {
        vm.prank(user1);
        vm.expectRevert(CopyrightRegistry.InvalidContentHash.selector);
        copyrightRegistry.claimCopyright(bytes32(0), sampleTitle, sampleAuthor);
    }

    function test_Registry_ClaimCopyright_RevertEmptyTitle() public {
        vm.prank(user1);
        vm.expectRevert(CopyrightRegistry.TitleRequired.selector);
        copyrightRegistry.claimCopyright(sampleContentHash, "", sampleAuthor);
    }

    function test_Registry_ClaimCopyright_RevertEmptyAuthor() public {
        vm.prank(user1);
        vm.expectRevert(CopyrightRegistry.AuthorRequired.selector);
        copyrightRegistry.claimCopyright(sampleContentHash, sampleTitle, "");
    }

    function test_Registry_PendingAnchors() public {
        vm.prank(user1);
        copyrightRegistry.claimCopyright(sampleContentHash, sampleTitle, sampleAuthor);

        bytes32[] memory pending = copyrightRegistry.getPendingAnchors();
        assertEq(pending.length, 1);
        assertEq(pending[0], sampleContentHash);
        assertEq(copyrightRegistry.getPendingCount(), 1);
    }

    function test_Registry_OwnerCopyrights() public {
        bytes32 hash1 = keccak256("content 1");
        bytes32 hash2 = keccak256("content 2");

        vm.startPrank(user1);
        copyrightRegistry.claimCopyright(hash1, "Work 1", "Author 1");
        copyrightRegistry.claimCopyright(hash2, "Work 2", "Author 2");
        vm.stopPrank();

        bytes32[] memory owned = copyrightRegistry.getCopyrightsByOwner(user1);
        assertEq(owned.length, 2);
    }

    function test_Registry_IsRegistered() public {
        assertFalse(copyrightRegistry.isRegistered(sampleContentHash));

        vm.prank(user1);
        copyrightRegistry.claimCopyright(sampleContentHash, sampleTitle, sampleAuthor);

        assertTrue(copyrightRegistry.isRegistered(sampleContentHash));
    }

    function test_Registry_UpdateStatus_RevertNotAnchor() public {
        vm.prank(user1);
        copyrightRegistry.claimCopyright(sampleContentHash, sampleTitle, sampleAuthor);

        vm.prank(user1);
        vm.expectRevert(CopyrightRegistry.OnlyOTSAnchor.selector);
        copyrightRegistry.updateAnchorStatus(
            sampleContentHash,
            CopyrightRegistry.AnchorStatus.Confirmed,
            bytes32(0),
            800000
        );
    }

    // ============ OTSAnchor Tests ============

    function test_Anchor_Init() public view {
        assertEq(otsAnchor.admin(), admin);
        assertTrue(otsAnchor.initialized());
    }

    function test_Anchor_SubmitAnchor() public {
        // First register a copyright
        vm.prank(user1);
        copyrightRegistry.claimCopyright(sampleContentHash, sampleTitle, sampleAuthor);

        // Submit anchor (admin can call as system caller)
        bytes32 merkleRoot = keccak256("merkle root");
        uint256 date = 20250101;
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = sampleContentHash;

        vm.expectEmit(true, true, false, true);
        emit AnchorSubmitted(merkleRoot, date, block.number, hashes);
        otsAnchor.submitAnchor(merkleRoot, date, hashes);

        // Check anchor record
        OTSAnchor.AnchorRecord memory record = otsAnchor.getAnchorRecord(merkleRoot);
        assertEq(record.merkleRoot, merkleRoot);
        assertFalse(record.confirmed);

        // Check copyright status updated
        CopyrightRegistry.Copyright memory c = copyrightRegistry.getCopyright(sampleContentHash);
        assertEq(uint8(c.status), uint8(CopyrightRegistry.AnchorStatus.Anchoring));
    }

    function test_Anchor_SubmitAnchor_SystemCall() public {
        // Register copyright
        vm.prank(user1);
        copyrightRegistry.claimCopyright(sampleContentHash, sampleTitle, sampleAuthor);

        // Add validator as system caller
        otsAnchor.addSystemCaller(validator);

        // Submit anchor with gasPrice = 0 (system transaction simulation)
        bytes32 merkleRoot = keccak256("merkle root");
        uint256 date = 20250101;
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = sampleContentHash;

        vm.prank(validator);
        vm.txGasPrice(0); // Simulate system transaction
        otsAnchor.submitAnchor(merkleRoot, date, hashes);

        assertTrue(otsAnchor.getDailyAnchor(date) == merkleRoot);
    }

    function test_Anchor_SubmitAnchor_RevertDuplicateDate() public {
        vm.prank(user1);
        copyrightRegistry.claimCopyright(sampleContentHash, sampleTitle, sampleAuthor);

        bytes32 merkleRoot1 = keccak256("root 1");
        bytes32 merkleRoot2 = keccak256("root 2");
        uint256 date = 20250101;
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = sampleContentHash;

        otsAnchor.submitAnchor(merkleRoot1, date, hashes);

        vm.expectRevert(OTSAnchor.DateAlreadyAnchored.selector);
        otsAnchor.submitAnchor(merkleRoot2, date, hashes);
    }

    function test_Anchor_ConfirmAnchor() public {
        // Setup: register and submit anchor
        vm.prank(user1);
        copyrightRegistry.claimCopyright(sampleContentHash, sampleTitle, sampleAuthor);

        bytes32 merkleRoot = keccak256("merkle root");
        uint256 date = 20250101;
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = sampleContentHash;

        otsAnchor.submitAnchor(merkleRoot, date, hashes);

        // Confirm anchor
        uint256 btcBlockHeight = 800000;
        bytes32 btcTxHash = keccak256("btc tx");

        vm.expectEmit(true, false, false, true);
        emit AnchorConfirmed(merkleRoot, btcBlockHeight, btcTxHash);
        otsAnchor.confirmAnchor(merkleRoot, btcBlockHeight, btcTxHash, "", hashes);

        // Check anchor confirmed
        assertTrue(otsAnchor.isConfirmed(merkleRoot));

        // Check copyright status
        CopyrightRegistry.Copyright memory c = copyrightRegistry.getCopyright(sampleContentHash);
        assertEq(uint8(c.status), uint8(CopyrightRegistry.AnchorStatus.Confirmed));
        assertEq(c.btcBlockHeight, btcBlockHeight);
    }

    function test_Anchor_ConfirmAnchor_RevertNotFound() public {
        bytes32 merkleRoot = keccak256("unknown root");
        bytes32[] memory hashes = new bytes32[](0);

        vm.expectRevert(OTSAnchor.AnchorNotFound.selector);
        otsAnchor.confirmAnchor(merkleRoot, 800000, bytes32(0), "", hashes);
    }

    function test_Anchor_ConfirmAnchor_RevertAlreadyConfirmed() public {
        vm.prank(user1);
        copyrightRegistry.claimCopyright(sampleContentHash, sampleTitle, sampleAuthor);

        bytes32 merkleRoot = keccak256("merkle root");
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = sampleContentHash;

        otsAnchor.submitAnchor(merkleRoot, 20250101, hashes);
        otsAnchor.confirmAnchor(merkleRoot, 800000, bytes32(0), "", hashes);

        vm.expectRevert(OTSAnchor.AlreadyConfirmed.selector);
        otsAnchor.confirmAnchor(merkleRoot, 800001, bytes32(0), "", hashes);
    }

    function test_Anchor_FailAnchor() public {
        vm.prank(user1);
        copyrightRegistry.claimCopyright(sampleContentHash, sampleTitle, sampleAuthor);

        bytes32 merkleRoot = keccak256("merkle root");
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = sampleContentHash;

        otsAnchor.submitAnchor(merkleRoot, 20250101, hashes);
        otsAnchor.failAnchor(merkleRoot, hashes);

        CopyrightRegistry.Copyright memory c = copyrightRegistry.getCopyright(sampleContentHash);
        assertEq(uint8(c.status), uint8(CopyrightRegistry.AnchorStatus.Failed));
    }

    // ============ Merkle Proof Tests ============

    function test_Anchor_VerifyInclusion() public view {
        // Build simple merkle tree with 2 leaves
        bytes32 leaf1 = keccak256("leaf1");
        bytes32 leaf2 = keccak256("leaf2");

        // Compute root
        bytes32 root;
        if (leaf1 <= leaf2) {
            root = keccak256(abi.encodePacked(leaf1, leaf2));
        } else {
            root = keccak256(abi.encodePacked(leaf2, leaf1));
        }

        // Verify leaf1 with proof [leaf2]
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;

        assertTrue(otsAnchor.verifyInclusion(leaf1, root, proof));
    }

    // ============ Admin Tests ============

    function test_Registry_TransferAdmin() public {
        address newAdmin = makeAddr("newAdmin");
        copyrightRegistry.transferAdmin(newAdmin);
        assertEq(copyrightRegistry.admin(), newAdmin);
    }

    function test_Anchor_TransferAdmin() public {
        address newAdmin = makeAddr("newAdmin");
        otsAnchor.transferAdmin(newAdmin);
        assertEq(otsAnchor.admin(), newAdmin);
    }

    function test_Anchor_AddRemoveSystemCaller() public {
        address caller = makeAddr("caller");

        assertFalse(otsAnchor.systemCallers(caller));

        otsAnchor.addSystemCaller(caller);
        assertTrue(otsAnchor.systemCallers(caller));

        otsAnchor.removeSystemCaller(caller);
        assertFalse(otsAnchor.systemCallers(caller));
    }

    // ============ Full Flow Test ============

    function test_FullFlow_RegisterToConfirm() public {
        // 1. User registers copyright
        vm.prank(user1);
        copyrightRegistry.claimCopyright(sampleContentHash, sampleTitle, sampleAuthor);

        CopyrightRegistry.Copyright memory c = copyrightRegistry.getCopyright(sampleContentHash);
        assertEq(uint8(c.status), uint8(CopyrightRegistry.AnchorStatus.Pending));

        // 2. OTS module submits anchor
        bytes32 merkleRoot = keccak256(abi.encodePacked(sampleContentHash));
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = sampleContentHash;

        otsAnchor.submitAnchor(merkleRoot, 20250101, hashes);

        c = copyrightRegistry.getCopyright(sampleContentHash);
        assertEq(uint8(c.status), uint8(CopyrightRegistry.AnchorStatus.Anchoring));

        // 3. Bitcoin confirms, OTS module confirms anchor
        uint256 btcHeight = 800000;
        bytes32 btcTx = keccak256("btc transaction");

        otsAnchor.confirmAnchor(merkleRoot, btcHeight, btcTx, "", hashes);

        c = copyrightRegistry.getCopyright(sampleContentHash);
        assertEq(uint8(c.status), uint8(CopyrightRegistry.AnchorStatus.Confirmed));
        assertEq(c.btcBlockHeight, btcHeight);

        // 4. Verify copyright removed from pending
        assertEq(copyrightRegistry.getPendingCount(), 0);

        // 5. Verify total counts
        assertEq(copyrightRegistry.getTotalRegistered(), 1);
        assertEq(otsAnchor.getTotalAnchors(), 1);
    }
}
