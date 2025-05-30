// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import "./Base.t.sol";
import {MockSampleDelegateCallTarget} from "./utils/mocks/MockSampleDelegateCallTarget.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";

contract AccountTest is BaseTest {
    struct _TestExecuteWithSignatureTemps {
        TargetFunctionPayload[] targetFunctionPayloads;
        ERC7821.Call[] calls;
        uint256 n;
        uint256 nonce;
        bytes opData;
        bytes executionData;
    }

    function testExecuteWithSignature(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        vm.deal(d.eoa, 100 ether);

        _TestExecuteWithSignatureTemps memory t;
        t.n = _bound(_randomUniform(), 1, 5);
        t.targetFunctionPayloads = new TargetFunctionPayload[](t.n);
        t.calls = new ERC7821.Call[](t.n);
        for (uint256 i; i < t.n; ++i) {
            uint256 value = _random() % 0.1 ether;
            bytes memory data = _truncateBytes(_randomBytes(), 0xff);
            t.calls[i] = _thisTargetFunctionCall(value, data);
            t.targetFunctionPayloads[i].value = value;
            t.targetFunctionPayloads[i].data = data;
        }
        t.nonce = d.d.getNonce(0);
        bytes memory signature = _sig(d, d.d.computeDigest(t.calls, t.nonce));
        t.opData = abi.encodePacked(t.nonce, signature);
        t.executionData = abi.encode(t.calls, t.opData);

        if (_randomChance(32)) {
            signature = _sig(_randomEIP7702DelegatedEOA(), d.d.computeDigest(t.calls, t.nonce));
            t.opData = abi.encodePacked(t.nonce, signature);
            t.executionData = abi.encode(t.calls, t.opData);
            vm.expectRevert(bytes4(keccak256("Unauthorized()")));
            d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);
            return;
        }

        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);

        if (_randomChance(32)) {
            vm.expectRevert(bytes4(keccak256("InvalidNonce()")));
            d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);
        }

        if (_randomChance(32)) {
            t.nonce = d.d.getNonce(0);
            signature = _sig(d, d.d.computeDigest(t.calls, t.nonce));
            t.opData = abi.encodePacked(t.nonce, signature);
            t.executionData = abi.encode(t.calls, t.opData);
            d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);
            return;
        }

        for (uint256 i; i < t.n; ++i) {
            assertEq(targetFunctionPayloads[i].by, d.eoa);
            assertEq(targetFunctionPayloads[i].value, t.targetFunctionPayloads[i].value);
            assertEq(targetFunctionPayloads[i].data, t.targetFunctionPayloads[i].data);
        }
    }

    function testSignatureCheckerApproval(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory k = _randomSecp256k1PassKey();

        k.k.isSuperAdmin = _randomChance(32);

        vm.prank(d.eoa);
        d.d.authorize(k.k);

        address[] memory checkers = new address[](_bound(_random(), 1, 3));
        for (uint256 i; i < checkers.length; ++i) {
            checkers[i] = _randomUniqueHashedAddress();
            vm.prank(d.eoa);
            d.d.setSignatureCheckerApproval(k.keyHash, checkers[i], true);
        }
        assertEq(d.d.approvedSignatureCheckers(k.keyHash).length, checkers.length);

        bytes32 digest = bytes32(_randomUniform());
        bytes memory sig = _sig(k, digest);
        assertEq(
            d.d.isValidSignature(digest, sig) == PortoAccount.isValidSignature.selector,
            k.k.isSuperAdmin
        );

        vm.prank(checkers[_randomUniform() % checkers.length]);
        assertEq(d.d.isValidSignature(digest, sig), PortoAccount.isValidSignature.selector);

        vm.prank(d.eoa);
        d.d.revoke(_hash(k.k));

        vm.expectRevert(bytes4(keccak256("KeyDoesNotExist()")));
        d.d.isValidSignature(digest, sig);

        if (k.k.isSuperAdmin) k.k.isSuperAdmin = _randomChance(2);
        vm.prank(d.eoa);
        d.d.authorize(k.k);

        assertEq(
            d.d.isValidSignature(digest, sig) == PortoAccount.isValidSignature.selector,
            k.k.isSuperAdmin
        );
        assertEq(d.d.approvedSignatureCheckers(k.keyHash).length, 0);
    }

    struct _TestUpgradeAccountWithPassKeyTemps {
        uint256 randomVersion;
        address implementation;
        ERC7821.Call[] calls;
        uint256 nonce;
        bytes opData;
        bytes executionData;
    }

    function testUpgradeAccountWithPassKey(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory k = _randomSecp256k1PassKey();

        k.k.isSuperAdmin = true;

        vm.prank(d.eoa);
        d.d.authorize(k.k);

        _TestUpgradeAccountWithPassKeyTemps memory t;
        t.randomVersion = _randomUniform();
        t.implementation = address(new MockSampleDelegateCallTarget(t.randomVersion));

        t.calls = new ERC7821.Call[](1);
        t.calls[0].data = abi.encodeWithSignature("upgradeProxyAccount(address)", t.implementation);

        t.nonce = d.d.getNonce(0);
        bytes memory signature = _sig(d, d.d.computeDigest(t.calls, t.nonce));
        t.opData = abi.encodePacked(t.nonce, signature);
        t.executionData = abi.encode(t.calls, t.opData);

        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);

        assertEq(MockSampleDelegateCallTarget(d.eoa).version(), t.randomVersion);
        assertEq(MockSampleDelegateCallTarget(d.eoa).upgradeHookCounter(), 1);
    }

    function testApproveAndRevokeKey(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PortoAccount.Key memory k;
        PortoAccount.Key memory kRetrieved;

        k.keyType = PortoAccount.KeyType(_randomUniform() & 1);
        k.expiry = uint40(_bound(_random(), 0, 2 ** 40 - 1));
        k.publicKey = _truncateBytes(_randomBytes(), 0x1ff);

        assertEq(d.d.keyCount(), 0);

        vm.prank(d.eoa);
        d.d.authorize(k);

        assertEq(d.d.keyCount(), 1);

        kRetrieved = d.d.keyAt(0);
        assertEq(uint8(kRetrieved.keyType), uint8(k.keyType));
        assertEq(kRetrieved.expiry, k.expiry);
        assertEq(kRetrieved.publicKey, k.publicKey);

        k.expiry = uint40(_bound(_random(), 0, 2 ** 40 - 1));

        vm.prank(d.eoa);
        d.d.authorize(k);

        assertEq(d.d.keyCount(), 1);

        kRetrieved = d.d.keyAt(0);
        assertEq(uint8(kRetrieved.keyType), uint8(k.keyType));
        assertEq(kRetrieved.expiry, k.expiry);
        assertEq(kRetrieved.publicKey, k.publicKey);

        kRetrieved = d.d.getKey(_hash(k));
        assertEq(uint8(kRetrieved.keyType), uint8(k.keyType));
        assertEq(kRetrieved.expiry, k.expiry);
        assertEq(kRetrieved.publicKey, k.publicKey);

        vm.prank(d.eoa);
        d.d.revoke(_hash(k));

        assertEq(d.d.keyCount(), 0);

        vm.expectRevert(bytes4(keccak256("IndexOutOfBounds()")));
        d.d.keyAt(0);

        vm.expectRevert(bytes4(keccak256("KeyDoesNotExist()")));
        kRetrieved = d.d.getKey(_hash(k));
    }

    function testManyKeys() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PortoAccount.Key memory k;
        k.keyType = PortoAccount.KeyType(_randomUniform() & 1);

        for (uint40 i = 0; i < 20; i++) {
            k.expiry = i;
            k.publicKey = abi.encode(i);
            vm.prank(d.eoa);
            d.d.authorize(k);
        }

        vm.warp(5);

        (PortoAccount.Key[] memory keys, bytes32[] memory keyHashes) = d.d.getKeys();

        assert(keys.length == keyHashes.length);
        assert(keys.length == 16);

        assert(keys[0].expiry == 0);
        assert(keys[1].expiry == 5);
    }

    function testAddDisallowedSuperAdminKeyTypeReverts() public {
        address orchestrator = address(new Orchestrator(address(this)));
        address accountImplementation = address(new PortoAccount(address(orchestrator)));
        address accountProxy = address(LibEIP7702.deployProxy(accountImplementation, address(0)));
        account = MockAccount(payable(accountProxy));

        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        PassKey memory k = _randomSecp256k1PassKey();
        k.k.isSuperAdmin = true;

        vm.startPrank(d.eoa);

        d.d.authorize(k.k);

        k = _randomSecp256r1PassKey();
        k.k.isSuperAdmin = true;
        vm.expectRevert(bytes4(keccak256("KeyTypeCannotBeSuperAdmin()")));
        d.d.authorize(k.k);

        vm.stopPrank();
    }

    function testPause() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        vm.deal(d.eoa, 100 ether);
        address pauseAuthority = _randomAddress();
        
        // Test the new timelock mechanism for setting pause authority
        oc.proposeNewAuthority(pauseAuthority);

        // Check that the change is proposed but not yet effective
        (address proposedAuthority, uint40 effectiveTime) = oc.getProposedAuthority();
        assertEq(proposedAuthority, pauseAuthority);
        assertEq(effectiveTime, block.timestamp + 48 hours);
        
        // Try to execute before timelock expires
        vm.expectRevert(bytes4(keccak256("TimelockNotExpired()")));
        oc.executeNewAuthority();
        
        // Warp to after timelock expires and execute the change
        vm.warp(block.timestamp + 48 hours + 1);
        oc.executeNewAuthority();

        (address ocPauseAuthority, uint40 lastUnpaused) = oc.getPauseConfig();
        assertEq(ocPauseAuthority, pauseAuthority);
        assertEq(lastUnpaused, 0);

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);

        // Setup a mock call
        calls[0] = _transferCall(address(0), address(0x1234), 1 ether);
        uint256 nonce = d.d.getNonce(0);
        bytes32 digest = d.d.computeDigest(calls, nonce);
        bytes memory signature = _sig(d, digest);

        // Check isValidSignature passes before pause.
        assertEq(
            d.d.isValidSignature(digest, signature),
            bytes4(keccak256("isValidSignature(bytes32,bytes)"))
        );

        // The block timestamp needs to be realistic for pause cooldown
        vm.warp(block.timestamp + 49 hours); // More than 48 hours to allow pausing

        vm.startPrank(pauseAuthority);
        oc.pause(true);

        assertEq(oc.pauseFlag(), 1);
        (ocPauseAuthority, lastUnpaused) = oc.getPauseConfig();
        assertEq(ocPauseAuthority, pauseAuthority);
        // When paused, getPauseConfig returns lastPaused timestamp
        assertEq(lastUnpaused, block.timestamp); // This is now lastPaused timestamp
        vm.stopPrank();

        // Check that execute fails
        bytes memory opData = abi.encodePacked(nonce, signature);
        bytes memory executionData = abi.encode(calls, opData);

        vm.expectRevert(bytes4(keccak256("Paused()")));
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, executionData);

        // Check that isValidSignature fails
        vm.expectRevert(bytes4(keccak256("Paused()")));
        d.d.isValidSignature(digest, signature);

        // Check that intent fails
        Orchestrator.Intent memory u;
        u.eoa = d.eoa;
        u.nonce = d.d.getNonce(0);
        u.combinedGas = 1000000;
        u.executionData = _transferExecutionData(address(0), address(0xabcd), 1 ether);
        u.signature = _eoaSig(d.privateKey, u);

        assertEq(oc.execute(abi.encode(u)), bytes4(keccak256("VerificationError()")));

        vm.startPrank(pauseAuthority);
        // Try to pause already paused account.
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        oc.pause(true);

        oc.pause(false);
        assertEq(oc.pauseFlag(), 0);
        (ocPauseAuthority, lastUnpaused) = oc.getPauseConfig();
        assertEq(ocPauseAuthority, pauseAuthority);
        assertEq(lastUnpaused, block.timestamp); // Now this is lastUnpaused timestamp

        // Cannot immediately repause again - need to wait 48 hours from lastUnpaused
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        oc.pause(true);
        vm.stopPrank();

        // Intent should now succeed.
        assertEq(oc.execute(abi.encode(u)), 0);

        // Can pause again, after the 48-hour cooldown period.
        vm.warp(lastUnpaused + 48 hours + 1);
        vm.startPrank(pauseAuthority);
        oc.pause(true);
        vm.stopPrank();

        assertEq(oc.pauseFlag(), 1);
        (ocPauseAuthority, lastUnpaused) = oc.getPauseConfig();
        assertEq(ocPauseAuthority, pauseAuthority);
        // When paused, this returns lastPaused timestamp
        assertEq(lastUnpaused, block.timestamp); // This is now lastPaused timestamp

        // Anyone can unpause after 4 weeks from when it was paused.
        vm.warp(block.timestamp + 4 weeks + 1); // 4 weeks from pause time
        oc.pause(false);
        assertEq(oc.pauseFlag(), 0);
        (ocPauseAuthority, lastUnpaused) = oc.getPauseConfig();
        assertEq(ocPauseAuthority, pauseAuthority);
        assertEq(lastUnpaused, block.timestamp); // Updated to current time on unpause

        address orchestratorAddress = address(oc);

        // Try setting pauseAuthority with dirty bits.
        assembly ("memory-safe") {
            mstore(0x00, 0x4b90364f) // `setPauseAuthority(address)`
            mstore(0x20, 0xffffffffffffffffffffffffffffffffffffffff)

            let success := call(gas(), orchestratorAddress, 0, 0x1c, 0x24, 0x00, 0x00)
            if success { revert(0, 0) }
        }
    }

    function testPauseAuthorityTimelock() public {
        address currentAuthority = _randomAddress();
        address newAuthority = _randomAddress();
        
        // Set initial pause authority using timelock
        oc.proposeNewAuthority(currentAuthority);
        vm.warp(block.timestamp + 48 hours + 1);
        oc.executeNewAuthority();
        
        // Verify current authority is set
        (address authority,) = oc.getPauseConfig();
        assertEq(authority, currentAuthority);
        
        vm.startPrank(currentAuthority);
        
        // Propose a new pause authority change
        oc.proposeNewAuthority(newAuthority);
        
        // Check that the change is proposed
        (address proposedAuthority, uint40 effectiveTime) = oc.getProposedAuthority();
        assertEq(proposedAuthority, newAuthority);
        assertEq(effectiveTime, block.timestamp + 48 hours);
        
        // Try to execute before timelock expires
        vm.expectRevert(bytes4(keccak256("TimelockNotExpired()")));
        oc.executeNewAuthority();
        
        // Warp to just before timelock expires
        vm.warp(block.timestamp + 48 hours - 1);
        vm.expectRevert(bytes4(keccak256("TimelockNotExpired()")));
        oc.executeNewAuthority();
        
        // Warp to exactly when timelock expires
        vm.warp(block.timestamp + 1);
        oc.executeNewAuthority();
        
        // Verify the authority has been changed
        (authority,) = oc.getPauseConfig();
        assertEq(authority, newAuthority);
        
        // Verify the proposed change has been cleared
        (proposedAuthority, effectiveTime) = oc.getProposedAuthority();
        assertEq(proposedAuthority, address(0));
        assertEq(effectiveTime, 0);
        
        vm.stopPrank();
        
        // Test that only current authority can propose changes
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        oc.proposeNewAuthority(_randomAddress());
        
        // Test that only current authority can execute changes
        vm.startPrank(newAuthority);
        oc.proposeNewAuthority(_randomAddress());
        vm.warp(block.timestamp + 48 hours + 1);
        vm.stopPrank();
        
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        oc.executeNewAuthority();
    }
}
