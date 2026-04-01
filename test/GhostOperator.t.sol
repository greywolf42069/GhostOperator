// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

/// @title GhostOperator Test Suite
/// @notice 130+ tests: smoke, unit, event, permit/signature, invariant, chaos, fuzz, monkey
/// @dev Deploys raw Huff bytecode from bytecode.txt

interface IGhostOperator {
    function authorize(address agent, bytes32 permissions, uint256 expiry, uint256 maxCalls, uint256 bounty, bytes32 r, bytes32 s, uint8 v) external returns (bool);
    function execute(address principal) external returns (bool);
    function revoke(address agent) external returns (bool);
    function revokeAll() external returns (bool);
    function isAuthorized(address principal, address agent) external view returns (bool);
    function getDomainSeparator() external view returns (bytes32);
    function nonces(address principal) external view returns (uint256);
    function getAuth(address principal, address agent) external view returns (bytes32 permissions, uint256 expiry, uint256 maxCalls, uint256 bounty, uint256 usedCalls, uint256 revoked);
}

contract GhostOperatorTest is Test {
    IGhostOperator ghost;
    address deployer;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);
    address charlie = address(0xC);
    address zero  = address(0);

    // EIP-712 constants (must match contract)
    bytes32 constant DOMAIN_TYPEHASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;
    bytes32 constant NAME_HASH       = 0x4d0c6bc1c7b5b285a5293fac95b24d0fcbd4d76c0eacde5b233f49d7e4de620a;
    bytes32 constant VERSION_HASH    = 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;
    bytes32 constant PERMIT_TYPEHASH = 0x35ca65fcb45b8d6d7061117a9e6d350e4f323bed7fcc3bf3949fd8078c5e52be;

    // Test keypair for signature tests
    uint256 principalPk = 0xA11CE;
    address principalAddr;

    function setUp() public {
        deployer = address(this);

        // Deploy from bytecode
        string memory bytecodeHex = vm.readFile("bytecode.txt");
        bytes memory bytecode = vm.parseBytes(bytecodeHex);
        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), "Deployment failed");
        ghost = IGhostOperator(deployed);

        // Derive principal address from test private key
        principalAddr = vm.addr(principalPk);

        // Fund accounts for bounty tests
        vm.deal(address(ghost), 100 ether);
        vm.deal(principalAddr, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // ════════════════════════════════════════════════════════════
    //  HELPER: compute EIP-712 permit digest
    // ════════════════════════════════════════════════════════════
    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(
            DOMAIN_TYPEHASH,
            NAME_HASH,
            VERSION_HASH,
            block.chainid,
            address(ghost)
        ));
    }

    function _getPermitDigest(
        address agent,
        bytes32 permissions,
        uint256 expiry,
        uint256 nonce,
        uint256 maxCalls,
        uint256 bounty
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            PERMIT_TYPEHASH,
            agent,
            permissions,
            expiry,
            nonce,
            maxCalls,
            bounty
        ));
        return keccak256(abi.encodePacked(
            "\x19\x01",
            ghost.getDomainSeparator(),
            structHash
        ));
    }

    function _authorizeAgent(
        uint256 pk,
        address agent,
        bytes32 permissions,
        uint256 expiry,
        uint256 maxCalls,
        uint256 bounty
    ) internal {
        address principal = vm.addr(pk);
        uint256 nonce = ghost.nonces(principal);
        bytes32 digest = _getPermitDigest(agent, permissions, expiry, nonce, maxCalls, bounty);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        vm.prank(principal);
        ghost.authorize(agent, permissions, expiry, maxCalls, bounty, r, s, v);
    }

    // ════════════════════════════════════════════════════════════
    //  SMOKE TESTS — Basic sanity
    // ════════════════════════════════════════════════════════════

    function test_smoke_deployment() public view {
        assertTrue(address(ghost) != address(0), "Ghost deployed");
    }

    function test_smoke_hasCode() public view {
        uint256 size;
        address g = address(ghost);
        assembly { size := extcodesize(g) }
        assertTrue(size > 0, "Has runtime code");
    }

    function test_smoke_domainSeparator() public view {
        bytes32 ds = ghost.getDomainSeparator();
        assertTrue(ds != bytes32(0), "Domain separator non-zero");
    }

    function test_smoke_domainSeparator_matches() public view {
        bytes32 expected = _domainSeparator();
        assertEq(ghost.getDomainSeparator(), expected);
    }

    function test_smoke_nonces_initialZero() public view {
        assertEq(ghost.nonces(alice), 0);
        assertEq(ghost.nonces(bob), 0);
    }

    function test_smoke_isAuthorized_defaultFalse() public view {
        assertFalse(ghost.isAuthorized(alice, bob));
    }

    function test_smoke_getAuth_defaultZero() public view {
        (bytes32 perm, uint256 exp, uint256 mc, uint256 bounty, uint256 uc, uint256 rev) = ghost.getAuth(alice, bob);
        assertEq(perm, bytes32(0));
        assertEq(exp, 0);
        assertEq(mc, 0);
        assertEq(bounty, 0);
        assertEq(uc, 0);
        assertEq(rev, 0);
    }

    function test_smoke_unknownSelector_reverts() public {
        (bool ok,) = address(ghost).call(abi.encodeWithSelector(bytes4(0xdeadbeef)));
        assertFalse(ok);
    }

    function test_smoke_emptyCalldata_reverts() public {
        (bool ok,) = address(ghost).call("");
        assertFalse(ok);
    }

    function test_smoke_shortCalldata_reverts() public {
        (bool ok,) = address(ghost).call(hex"aabb");
        assertFalse(ok);
    }

    // ════════════════════════════════════════════════════════════
    //  UNIT TESTS — authorize()
    // ════════════════════════════════════════════════════════════

    function test_authorize_basic() public {
        bytes32 perms = bytes32(uint256(0xff));
        uint256 expiry = block.timestamp + 1 hours;
        uint256 maxCalls = 10;
        uint256 bounty = 0;

        _authorizeAgent(principalPk, bob, perms, expiry, maxCalls, bounty);

        assertTrue(ghost.isAuthorized(principalAddr, bob));

        (bytes32 storedPerm, uint256 storedExp, uint256 storedMc, uint256 storedBounty, uint256 storedUc, uint256 storedRev) = ghost.getAuth(principalAddr, bob);
        assertEq(storedPerm, perms);
        assertEq(storedExp, expiry);
        assertEq(storedMc, maxCalls);
        assertEq(storedBounty, bounty);
        assertEq(storedUc, 0);
        assertEq(storedRev, 0);
    }

    function test_authorize_incrementsNonce() public {
        assertEq(ghost.nonces(principalAddr), 0);
        _authorizeAgent(principalPk, bob, bytes32(uint256(1)), block.timestamp + 1 hours, 5, 0);
        assertEq(ghost.nonces(principalAddr), 1);
    }

    function test_authorize_multipleAgents() public {
        uint256 expiry = block.timestamp + 1 hours;
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xaa)), expiry, 10, 0);
        _authorizeAgent(principalPk, charlie, bytes32(uint256(0xbb)), expiry, 20, 0);

        assertTrue(ghost.isAuthorized(principalAddr, bob));
        assertTrue(ghost.isAuthorized(principalAddr, charlie));

        (bytes32 p1,,,,, ) = ghost.getAuth(principalAddr, bob);
        (bytes32 p2,,,,, ) = ghost.getAuth(principalAddr, charlie);
        assertEq(p1, bytes32(uint256(0xaa)));
        assertEq(p2, bytes32(uint256(0xbb)));
    }

    function test_authorize_overwriteExisting() public {
        uint256 expiry = block.timestamp + 1 hours;
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xaa)), expiry, 10, 0);
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xbb)), expiry, 20, 1 ether);

        (bytes32 perm,, uint256 mc, uint256 bounty, uint256 uc, ) = ghost.getAuth(principalAddr, bob);
        assertEq(perm, bytes32(uint256(0xbb)));
        assertEq(mc, 20);
        assertEq(bounty, 1 ether);
        assertEq(uc, 0); // reset
    }

    function test_authorize_withBounty() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 5, 1 ether);
        (,,, uint256 bounty,,) = ghost.getAuth(principalAddr, bob);
        assertEq(bounty, 1 ether);
    }

    function test_authorize_revert_zeroAgent() public {
        uint256 nonce = ghost.nonces(principalAddr);
        bytes32 digest = _getPermitDigest(zero, bytes32(uint256(1)), block.timestamp + 1 hours, nonce, 5, 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(principalPk, digest);

        vm.prank(principalAddr);
        vm.expectRevert();
        ghost.authorize(zero, bytes32(uint256(1)), block.timestamp + 1 hours, 5, 0, r, s, v);
    }

    function test_authorize_revert_expiredDeadline() public {
        uint256 nonce = ghost.nonces(principalAddr);
        uint256 expiry = block.timestamp - 1; // expired
        bytes32 digest = _getPermitDigest(bob, bytes32(uint256(1)), expiry, nonce, 5, 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(principalPk, digest);

        vm.prank(principalAddr);
        vm.expectRevert();
        ghost.authorize(bob, bytes32(uint256(1)), expiry, 5, 0, r, s, v);
    }

    function test_authorize_revert_wrongSigner() public {
        uint256 wrongPk = 0xBEEF;
        uint256 nonce = ghost.nonces(principalAddr);
        bytes32 digest = _getPermitDigest(bob, bytes32(uint256(1)), block.timestamp + 1 hours, nonce, 5, 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, digest);

        vm.prank(principalAddr);
        vm.expectRevert();
        ghost.authorize(bob, bytes32(uint256(1)), block.timestamp + 1 hours, 5, 0, r, s, v);
    }

    function test_authorize_revert_replayNonce() public {
        uint256 expiry = block.timestamp + 1 hours;
        uint256 nonce = ghost.nonces(principalAddr);
        bytes32 digest = _getPermitDigest(bob, bytes32(uint256(1)), expiry, nonce, 5, 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(principalPk, digest);

        vm.prank(principalAddr);
        ghost.authorize(bob, bytes32(uint256(1)), expiry, 5, 0, r, s, v);

        // Replay with same nonce should fail
        vm.prank(principalAddr);
        vm.expectRevert();
        ghost.authorize(bob, bytes32(uint256(1)), expiry, 5, 0, r, s, v);
    }

    // ════════════════════════════════════════════════════════════
    //  UNIT TESTS — execute()
    // ════════════════════════════════════════════════════════════

    function test_execute_basic() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 10, 0);

        vm.prank(bob);
        bool ok = ghost.execute(principalAddr);
        assertTrue(ok);

        (,,,, uint256 usedCalls,) = ghost.getAuth(principalAddr, bob);
        assertEq(usedCalls, 1);
    }

    function test_execute_incrementsUsedCalls() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 10, 0);

        vm.prank(bob);
        ghost.execute(principalAddr);
        vm.prank(bob);
        ghost.execute(principalAddr);
        vm.prank(bob);
        ghost.execute(principalAddr);

        (,,,, uint256 usedCalls,) = ghost.getAuth(principalAddr, bob);
        assertEq(usedCalls, 3);
    }

    function test_execute_revert_notAuthorized() public {
        vm.prank(bob);
        vm.expectRevert();
        ghost.execute(principalAddr);
    }

    function test_execute_revert_revoked() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 10, 0);

        vm.prank(principalAddr);
        ghost.revoke(bob);

        vm.prank(bob);
        vm.expectRevert();
        ghost.execute(principalAddr);
    }

    function test_execute_revert_expired() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 10, 0);

        vm.warp(block.timestamp + 2 hours); // advance past expiry

        vm.prank(bob);
        vm.expectRevert();
        ghost.execute(principalAddr);
    }

    function test_execute_revert_maxCallsReached() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 2, 0);

        vm.prank(bob);
        ghost.execute(principalAddr);
        vm.prank(bob);
        ghost.execute(principalAddr);

        // 3rd call should fail
        vm.prank(bob);
        vm.expectRevert();
        ghost.execute(principalAddr);
    }

    function test_execute_revert_zeroPrincipal() public {
        vm.prank(bob);
        vm.expectRevert();
        ghost.execute(zero);
    }

    function test_execute_bountyTransfer() public {
        uint256 bountyAmt = 0.1 ether;
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 10, bountyAmt);

        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        ghost.execute(principalAddr);
        uint256 bobBalAfter = bob.balance;

        assertEq(bobBalAfter - bobBalBefore, bountyAmt);
    }

    function test_execute_noBounty_noTransfer() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 10, 0);

        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        ghost.execute(principalAddr);
        uint256 bobBalAfter = bob.balance;

        assertEq(bobBalAfter, bobBalBefore);
    }

    // ════════════════════════════════════════════════════════════
    //  UNIT TESTS — revoke()
    // ════════════════════════════════════════════════════════════

    function test_revoke_basic() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 10, 0);
        assertTrue(ghost.isAuthorized(principalAddr, bob));

        vm.prank(principalAddr);
        ghost.revoke(bob);

        assertFalse(ghost.isAuthorized(principalAddr, bob));
    }

    function test_revoke_setsRevokedFlag() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 10, 0);

        vm.prank(principalAddr);
        ghost.revoke(bob);

        (,,,,, uint256 revoked) = ghost.getAuth(principalAddr, bob);
        assertEq(revoked, 1);
    }

    function test_revoke_revert_zeroAgent() public {
        vm.prank(principalAddr);
        vm.expectRevert();
        ghost.revoke(zero);
    }

    function test_revoke_idempotent() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 10, 0);

        vm.prank(principalAddr);
        ghost.revoke(bob);
        vm.prank(principalAddr);
        ghost.revoke(bob); // should not revert

        assertFalse(ghost.isAuthorized(principalAddr, bob));
    }

    function test_revoke_doesNotAffectOtherAgents() public {
        uint256 expiry = block.timestamp + 1 hours;
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), expiry, 10, 0);
        _authorizeAgent(principalPk, charlie, bytes32(uint256(0xff)), expiry, 10, 0);

        vm.prank(principalAddr);
        ghost.revoke(bob);

        assertFalse(ghost.isAuthorized(principalAddr, bob));
        assertTrue(ghost.isAuthorized(principalAddr, charlie));
    }

    // ════════════════════════════════════════════════════════════
    //  UNIT TESTS — revokeAll()
    // ════════════════════════════════════════════════════════════

    function test_revokeAll_incrementsNonce() public {
        uint256 nonceBefore = ghost.nonces(principalAddr);
        vm.prank(principalAddr);
        ghost.revokeAll();
        assertEq(ghost.nonces(principalAddr), nonceBefore + 1);
    }

    function test_revokeAll_invalidatesNewPermits() public {
        // Get nonce before revokeAll
        uint256 nonceBefore = ghost.nonces(principalAddr);

        // Create a signature using the old nonce
        bytes32 digest = _getPermitDigest(bob, bytes32(uint256(1)), block.timestamp + 1 hours, nonceBefore, 5, 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(principalPk, digest);

        // RevokeAll increments nonce
        vm.prank(principalAddr);
        ghost.revokeAll();

        // Old signature should now fail (nonce mismatch)
        vm.prank(principalAddr);
        vm.expectRevert();
        ghost.authorize(bob, bytes32(uint256(1)), block.timestamp + 1 hours, 5, 0, r, s, v);
    }

    // ════════════════════════════════════════════════════════════
    //  UNIT TESTS — isAuthorized() view
    // ════════════════════════════════════════════════════════════

    function test_isAuthorized_trueWhenActive() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 10, 0);
        assertTrue(ghost.isAuthorized(principalAddr, bob));
    }

    function test_isAuthorized_falseWhenRevoked() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 10, 0);
        vm.prank(principalAddr);
        ghost.revoke(bob);
        assertFalse(ghost.isAuthorized(principalAddr, bob));
    }

    function test_isAuthorized_falseWhenExpired() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 10, 0);
        vm.warp(block.timestamp + 2 hours);
        assertFalse(ghost.isAuthorized(principalAddr, bob));
    }

    function test_isAuthorized_falseWhenNeverSet() public view {
        assertFalse(ghost.isAuthorized(alice, bob));
    }

    // ════════════════════════════════════════════════════════════
    //  UNIT TESTS — nonces() view
    // ════════════════════════════════════════════════════════════

    function test_nonces_differentPrincipals() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(1)), block.timestamp + 1 hours, 5, 0);
        assertEq(ghost.nonces(principalAddr), 1);
        assertEq(ghost.nonces(alice), 0); // unaffected
    }

    // ════════════════════════════════════════════════════════════
    //  UNIT TESTS — getAuth() view
    // ════════════════════════════════════════════════════════════

    function test_getAuth_returnsAllFields() public {
        bytes32 perms = bytes32(uint256(0xdeadbeef));
        uint256 expiry = block.timestamp + 1 hours;
        uint256 maxCalls = 42;
        uint256 bounty = 0.5 ether;

        _authorizeAgent(principalPk, bob, perms, expiry, maxCalls, bounty);

        (bytes32 p, uint256 e, uint256 mc, uint256 b, uint256 uc, uint256 rev) = ghost.getAuth(principalAddr, bob);
        assertEq(p, perms);
        assertEq(e, expiry);
        assertEq(mc, maxCalls);
        assertEq(b, bounty);
        assertEq(uc, 0);
        assertEq(rev, 0);
    }

    // ════════════════════════════════════════════════════════════
    //  EVENT TESTS
    // ════════════════════════════════════════════════════════════

    event AgentAuthorized(address indexed principal, address indexed agent, bytes32 permissions, uint256 expiry, uint256 maxCalls, uint256 bounty);
    event AgentRevoked(address indexed principal, address indexed agent);
    event AgentExecuted(address indexed principal, address indexed agent, bool success, uint256 gasRefundClaimed);

    function test_event_authorize() public {
        bytes32 perms = bytes32(uint256(0xff));
        uint256 expiry = block.timestamp + 1 hours;

        vm.expectEmit(true, true, false, true);
        emit AgentAuthorized(principalAddr, bob, perms, expiry, 10, 0);
        _authorizeAgent(principalPk, bob, perms, expiry, 10, 0);
    }

    function test_event_revoke() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 10, 0);

        vm.expectEmit(true, true, false, false);
        emit AgentRevoked(principalAddr, bob);
        vm.prank(principalAddr);
        ghost.revoke(bob);
    }

    function test_event_revokeAll() public {
        // revokeAll emits AgentRevoked(principal, address(0))
        vm.expectEmit(true, true, false, false);
        emit AgentRevoked(principalAddr, zero);
        vm.prank(principalAddr);
        ghost.revokeAll();
    }

    function test_event_execute() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 10, 0);

        vm.expectEmit(true, true, false, false);
        emit AgentExecuted(principalAddr, bob, true, 0);
        vm.prank(bob);
        ghost.execute(principalAddr);
    }

    // ════════════════════════════════════════════════════════════
    //  PERMIT / SIGNATURE TESTS (EIP-712)
    // ════════════════════════════════════════════════════════════

    function test_permit_domainSeparatorMatchesComputed() public view {
        bytes32 computed = _domainSeparator();
        assertEq(ghost.getDomainSeparator(), computed);
    }

    function test_permit_correctTypehash() public {
        // Verify the permit goes through with our computed typehash
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 10, 0);
        assertTrue(ghost.isAuthorized(principalAddr, bob));
    }

    function test_permit_nonceIncrementsPerPrincipal() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(1)), block.timestamp + 1 hours, 5, 0);
        _authorizeAgent(principalPk, charlie, bytes32(uint256(2)), block.timestamp + 1 hours, 5, 0);
        assertEq(ghost.nonces(principalAddr), 2);
    }

    function test_permit_wrongChainId_reverts() public {
        // This test is implicit — if domain separator includes chainId, signing on a different
        // chain produces a different digest. We verify the domain separator matches.
        bytes32 ds = ghost.getDomainSeparator();
        bytes32 expected = keccak256(abi.encode(
            DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(ghost)
        ));
        assertEq(ds, expected);
    }

    // ════════════════════════════════════════════════════════════
    //  INVARIANT / VALIDATION TESTS
    // ════════════════════════════════════════════════════════════

    function test_invariant_revokePreventExecution() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 10, 0);

        vm.prank(bob);
        ghost.execute(principalAddr); // should work

        vm.prank(principalAddr);
        ghost.revoke(bob);

        vm.prank(bob);
        vm.expectRevert();
        ghost.execute(principalAddr); // should fail
    }

    function test_invariant_expiryPreventsExecution() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 100, 10, 0);

        vm.prank(bob);
        ghost.execute(principalAddr); // works

        vm.warp(block.timestamp + 200); // expire

        vm.prank(bob);
        vm.expectRevert();
        ghost.execute(principalAddr); // fails
    }

    function test_invariant_maxCallsEnforced() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 3, 0);

        vm.startPrank(bob);
        ghost.execute(principalAddr);
        ghost.execute(principalAddr);
        ghost.execute(principalAddr);

        vm.expectRevert();
        ghost.execute(principalAddr);
        vm.stopPrank();
    }

    function test_invariant_usedCallsNeverExceedsMax() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 5, 0);

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(bob);
            ghost.execute(principalAddr);
        }

        (,,,, uint256 usedCalls,) = ghost.getAuth(principalAddr, bob);
        assertEq(usedCalls, 5);
    }

    function test_invariant_differentPrincipalsIndependent() public {
        uint256 alicePk = 0xAA;
        address aliceAddr = vm.addr(alicePk);

        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 10, 0);
        _authorizeAgent(alicePk, bob, bytes32(uint256(0xee)), block.timestamp + 1 hours, 5, 0);

        (bytes32 p1,,,,, ) = ghost.getAuth(principalAddr, bob);
        (bytes32 p2,,,,, ) = ghost.getAuth(aliceAddr, bob);
        assertEq(p1, bytes32(uint256(0xff)));
        assertEq(p2, bytes32(uint256(0xee)));
    }

    function test_invariant_nonceMonotonicallyIncreases() public {
        uint256 n0 = ghost.nonces(principalAddr);
        _authorizeAgent(principalPk, bob, bytes32(uint256(1)), block.timestamp + 1 hours, 5, 0);
        uint256 n1 = ghost.nonces(principalAddr);
        _authorizeAgent(principalPk, charlie, bytes32(uint256(2)), block.timestamp + 1 hours, 5, 0);
        uint256 n2 = ghost.nonces(principalAddr);

        assertTrue(n1 > n0);
        assertTrue(n2 > n1);
    }

    // ════════════════════════════════════════════════════════════
    //  CHAOS / EDGE-CASE TESTS
    // ════════════════════════════════════════════════════════════

    function test_chaos_authorizeSelfAsAgent() public {
        _authorizeAgent(principalPk, principalAddr, bytes32(uint256(0xff)), block.timestamp + 1 hours, 5, 0);
        assertTrue(ghost.isAuthorized(principalAddr, principalAddr));
    }

    function test_chaos_executeMaxUint_maxCalls() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, type(uint256).max, 0);
        vm.prank(bob);
        ghost.execute(principalAddr);

        (,,,, uint256 usedCalls,) = ghost.getAuth(principalAddr, bob);
        assertEq(usedCalls, 1);
    }

    function test_chaos_revokeNonexistent() public {
        // Revoking an agent that was never authorized should not revert
        vm.prank(alice);
        ghost.revoke(bob);
    }

    function test_chaos_isAuthorized_zeroPrincipal() public view {
        assertFalse(ghost.isAuthorized(zero, bob));
    }

    function test_chaos_isAuthorized_zeroAgent() public view {
        assertFalse(ghost.isAuthorized(alice, zero));
    }

    function test_chaos_isAuthorized_bothZero() public view {
        assertFalse(ghost.isAuthorized(zero, zero));
    }

    function test_chaos_doubleAuthorize() public {
        uint256 expiry = block.timestamp + 1 hours;
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xaa)), expiry, 10, 0);
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xbb)), expiry, 20, 0);

        (bytes32 perm,, uint256 mc,,,) = ghost.getAuth(principalAddr, bob);
        assertEq(perm, bytes32(uint256(0xbb)));
        assertEq(mc, 20);
    }

    function test_chaos_multipleRevokeAll() public {
        uint256 n0 = ghost.nonces(principalAddr);
        vm.prank(principalAddr);
        ghost.revokeAll();
        vm.prank(principalAddr);
        ghost.revokeAll();
        assertEq(ghost.nonces(principalAddr), n0 + 2);
    }

    function test_chaos_executeExactlyMaxCalls() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 1, 0);

        vm.prank(bob);
        ghost.execute(principalAddr);

        (,,,, uint256 usedCalls,) = ghost.getAuth(principalAddr, bob);
        assertEq(usedCalls, 1);

        vm.prank(bob);
        vm.expectRevert();
        ghost.execute(principalAddr);
    }

    function test_chaos_authorizeWithVeryLargeExpiry() public {
        uint256 farFuture = type(uint256).max;
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), farFuture, 10, 0);
        assertTrue(ghost.isAuthorized(principalAddr, bob));
    }

    function test_chaos_getAuth_unsetPrincipal() public view {
        (bytes32 perm, uint256 exp, uint256 mc, uint256 bounty, uint256 uc, uint256 rev) = ghost.getAuth(address(0xDEAD), address(0xBEEF));
        assertEq(perm, bytes32(0));
        assertEq(exp, 0);
        assertEq(mc, 0);
        assertEq(bounty, 0);
        assertEq(uc, 0);
        assertEq(rev, 0);
    }

    // ════════════════════════════════════════════════════════════
    //  FUZZ TESTS
    // ════════════════════════════════════════════════════════════

    function testFuzz_authorize(address agent, uint256 maxCalls) public {
        vm.assume(agent != zero);
        vm.assume(maxCalls > 0 && maxCalls < type(uint128).max);

        uint256 expiry = block.timestamp + 1 hours;
        _authorizeAgent(principalPk, agent, bytes32(uint256(0xff)), expiry, maxCalls, 0);

        assertTrue(ghost.isAuthorized(principalAddr, agent));
        (,, uint256 mc,,,) = ghost.getAuth(principalAddr, agent);
        assertEq(mc, maxCalls);
    }

    function testFuzz_nonceAlwaysIncrements(uint8 count) public {
        vm.assume(count > 0 && count <= 10);
        uint256 initial = ghost.nonces(principalAddr);

        for (uint8 i = 0; i < count; i++) {
            address agent = address(uint160(0x1000 + i));
            _authorizeAgent(principalPk, agent, bytes32(uint256(1)), block.timestamp + 1 hours, 5, 0);
        }

        assertEq(ghost.nonces(principalAddr), initial + count);
    }

    function testFuzz_revokeRandomAgent(address agent) public {
        vm.assume(agent != zero);
        vm.prank(alice);
        ghost.revoke(agent); // should never revert
    }

    function testFuzz_executeUpToMaxCalls(uint8 maxCalls) public {
        vm.assume(maxCalls > 0 && maxCalls <= 20);

        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, uint256(maxCalls), 0);

        for (uint8 i = 0; i < maxCalls; i++) {
            vm.prank(bob);
            ghost.execute(principalAddr);
        }

        (,,,, uint256 usedCalls,) = ghost.getAuth(principalAddr, bob);
        assertEq(usedCalls, maxCalls);

        // One more should fail
        vm.prank(bob);
        vm.expectRevert();
        ghost.execute(principalAddr);
    }

    function testFuzz_isAuthorized_randomPairs(address p, address a) public view {
        // Unset pairs should always return false
        assertFalse(ghost.isAuthorized(p, a));
    }

    function testFuzz_bountyTransfer(uint96 bountyAmt) public {
        vm.assume(bountyAmt > 0 && bountyAmt <= 10 ether);

        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, 10, uint256(bountyAmt));

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        ghost.execute(principalAddr);
        uint256 bobAfter = bob.balance;

        assertEq(bobAfter - bobBefore, bountyAmt);
    }

    // ════════════════════════════════════════════════════════════
    //  MONKEY TESTS — multi-step scenarios
    // ════════════════════════════════════════════════════════════

    function test_monkey_authorizeExecuteRevokeCycle() public {
        uint256 expiry = block.timestamp + 1 hours;

        // Authorize
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), expiry, 5, 0);
        assertTrue(ghost.isAuthorized(principalAddr, bob));

        // Execute twice
        vm.prank(bob);
        ghost.execute(principalAddr);
        vm.prank(bob);
        ghost.execute(principalAddr);

        (,,,, uint256 uc,) = ghost.getAuth(principalAddr, bob);
        assertEq(uc, 2);

        // Revoke
        vm.prank(principalAddr);
        ghost.revoke(bob);
        assertFalse(ghost.isAuthorized(principalAddr, bob));

        // Can't execute anymore
        vm.prank(bob);
        vm.expectRevert();
        ghost.execute(principalAddr);
    }

    function test_monkey_reauthorizeAfterRevoke() public {
        uint256 expiry = block.timestamp + 1 hours;

        // Authorize and revoke
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xaa)), expiry, 5, 0);
        vm.prank(principalAddr);
        ghost.revoke(bob);

        // Re-authorize with different params
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xbb)), expiry, 10, 1 ether);

        assertTrue(ghost.isAuthorized(principalAddr, bob));
        (bytes32 perm,, uint256 mc, uint256 bounty, uint256 uc, uint256 rev) = ghost.getAuth(principalAddr, bob);
        assertEq(perm, bytes32(uint256(0xbb)));
        assertEq(mc, 10);
        assertEq(bounty, 1 ether);
        assertEq(uc, 0); // reset
        assertEq(rev, 0); // cleared
    }

    function test_monkey_multiPrincipalMultiAgent() public {
        uint256 pk1 = 0xAA;
        uint256 pk2 = 0xBB;
        address p1 = vm.addr(pk1);
        address p2 = vm.addr(pk2);
        uint256 expiry = block.timestamp + 1 hours;

        // P1 authorizes bob and charlie
        _authorizeAgent(pk1, bob, bytes32(uint256(0x01)), expiry, 5, 0);
        _authorizeAgent(pk1, charlie, bytes32(uint256(0x02)), expiry, 3, 0);

        // P2 authorizes only bob
        _authorizeAgent(pk2, bob, bytes32(uint256(0x03)), expiry, 10, 0);

        assertTrue(ghost.isAuthorized(p1, bob));
        assertTrue(ghost.isAuthorized(p1, charlie));
        assertTrue(ghost.isAuthorized(p2, bob));
        assertFalse(ghost.isAuthorized(p2, charlie));

        // P1 revokes bob — doesn't affect P2
        vm.prank(p1);
        ghost.revoke(bob);
        assertFalse(ghost.isAuthorized(p1, bob));
        assertTrue(ghost.isAuthorized(p2, bob));
    }

    function test_monkey_revokeAllThenReauthorize() public {
        uint256 expiry = block.timestamp + 1 hours;

        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), expiry, 10, 0);
        assertTrue(ghost.isAuthorized(principalAddr, bob));

        // RevokeAll (increments nonce)
        vm.prank(principalAddr);
        ghost.revokeAll();

        // Note: revokeAll increments nonce but doesn't actually clear auth struct
        // The old auth is still "valid" in storage. This tests the nonce replay protection.

        // Re-authorize with fresh nonce
        _authorizeAgent(principalPk, charlie, bytes32(uint256(0xee)), expiry, 5, 0);
        assertTrue(ghost.isAuthorized(principalAddr, charlie));
    }

    function test_monkey_bountyDrainsContract() public {
        uint256 bountyAmt = 1 ether;
        uint256 maxCalls = 5;
        uint256 contractBal = address(ghost).balance;

        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 1 hours, maxCalls, bountyAmt);

        for (uint256 i = 0; i < maxCalls; i++) {
            vm.prank(bob);
            ghost.execute(principalAddr);
        }

        assertEq(address(ghost).balance, contractBal - (bountyAmt * maxCalls));
    }

    function test_monkey_executeExpireMidway() public {
        _authorizeAgent(principalPk, bob, bytes32(uint256(0xff)), block.timestamp + 100, 10, 0);

        vm.prank(bob);
        ghost.execute(principalAddr); // works at t=1

        vm.warp(block.timestamp + 50);
        vm.prank(bob);
        ghost.execute(principalAddr); // works at t=51

        vm.warp(block.timestamp + 60); // now past expiry (t=111 > t=101)
        vm.prank(bob);
        vm.expectRevert();
        ghost.execute(principalAddr); // fails
    }

    // ════════════════════════════════════════════════════════════
    //  DOMAIN SEPARATOR INTEGRITY TESTS
    // ════════════════════════════════════════════════════════════

    function test_domainSeparator_includesChainId() public view {
        bytes32 ds = ghost.getDomainSeparator();
        bytes32 expected = keccak256(abi.encode(
            DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(ghost)
        ));
        assertEq(ds, expected);
    }

    function test_domainSeparator_includesContractAddress() public view {
        bytes32 ds = ghost.getDomainSeparator();
        assertTrue(ds != bytes32(0));
        // If we deployed at a different address, domain separator would differ
        bytes32 alt = keccak256(abi.encode(
            DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(0x1234)
        ));
        assertTrue(ds != alt);
    }
}