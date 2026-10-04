// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CurveYieldGovernanceGate} from "../../src/governance/CurveYieldGovernanceGate.sol";
import {GovMockTarget, MockAccessManager} from "./GovMocks.sol";

/// @notice ADVERSARIAL tests of the governance gate: the DAO must never get a protected call through `execute`.
contract GovernanceGateTest is Test {
    CurveYieldGovernanceGate gate;
    GovMockTarget target;
    GovMockTarget other;
    MockAccessManager am;
    address dao = makeAddr("dao");
    address fee = makeAddr("feeAuthority");
    address fee2 = makeAddr("feeAuthority2");
    address guardian = makeAddr("guardian");
    address rnd = makeAddr("rnd");

    uint64 constant PROTECTED = 1; // e.g. OWNER
    uint64 constant PROTECTED2 = 100; // e.g. ATOMIST
    uint64 constant FREE = 200; // e.g. ALPHA: the DAO may manage it

    function setUp() public {
        gate = new CurveYieldGovernanceGate(dao, fee);
        target = new GovMockTarget(address(gate));
        other = new GovMockTarget(address(gate));
        am = new MockAccessManager();
        vm.startPrank(fee);
        gate.setAccessManager(address(am), true);
        uint64[] memory roles = new uint64[](2);
        roles[0] = PROTECTED;
        roles[1] = PROTECTED2;
        gate.setProtectedRoles(address(am), roles, true);
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = target.setAdmin.selector;
        gate.setProtectedCalls(address(target), sels, true);
        vm.stopPrank();
    }

    function _exec(address t_, bytes memory data_) internal returns (bytes memory) {
        vm.prank(dao);
        return gate.execute(t_, data_);
    }

    function _expectProtected(address t_, bytes memory data_) internal {
        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ProtectedCall.selector, t_, bytes4(data_)));
        gate.execute(t_, data_);
    }

    // ---------------------------------------------------------------- the DAO's normal path

    function test_daoExecutesNormalCalls_othersCannot() public {
        _exec(address(target), abi.encodeCall(GovMockTarget.setter, (42)));
        assertEq(target.value(), 42);
        assertEq(target.lastCaller(), address(gate));
        _exec(address(other), abi.encodeCall(GovMockTarget.ping, ()));
        assertEq(other.pings(), 1);
        // unprotected role management is fine
        _exec(address(am), abi.encodeWithSignature("grantRole(uint64,address,uint32)", FREE, rnd, uint32(0)));
        assertEq(am.callsLength(), 1);

        vm.prank(rnd);
        vm.expectRevert(CurveYieldGovernanceGate.NotDao.selector);
        gate.execute(address(target), abi.encodeCall(GovMockTarget.setter, (1)));
        vm.prank(fee);
        vm.expectRevert(CurveYieldGovernanceGate.NotDao.selector);
        gate.execute(address(target), abi.encodeCall(GovMockTarget.setter, (1)));
        // a failing call bubbles up
        vm.prank(dao);
        vm.expectRevert();
        gate.execute(address(0xdead), hex"12345678");
    }

    // ---------------------------------------------------------------- protected calls

    function test_protectedTargetSelector_reverts() public {
        _expectProtected(address(target), abi.encodeCall(GovMockTarget.setAdmin, (rnd)));
        // the same selector on another target is not protected
        _exec(address(other), abi.encodeCall(GovMockTarget.setAdmin, (rnd)));
        assertEq(other.admin(), rnd);
        // lifting the protection needs a fee authority
        vm.prank(dao);
        vm.expectRevert(CurveYieldGovernanceGate.NotFeeAuthority.selector);
        gate.setProtectedCalls(address(target), new bytes4[](0), false);
    }

    function test_ownershipMoves_areProtected_onAnyTarget() public {
        _expectProtected(address(target), abi.encodeWithSignature("transferOwnership(address)", dao));
        _expectProtected(address(target), abi.encodeWithSignature("renounceOwnership()"));
        _expectProtected(address(other), abi.encodeWithSignature("transferOwnership(address)", dao));
        _expectProtected(address(am), abi.encodeWithSignature("transferOwnership(address)", dao));
        _expectProtected(makeAddr("some external contract"), abi.encodeWithSignature("renounceOwnership()"));
        // the target is still owned by the gate
        assertEq(target.owner(), address(gate));
    }

    function test_theGateItselfAsTarget_isProtected() public {
        _expectProtected(address(gate), abi.encodeWithSignature("setDao(address)", rnd));
        _expectProtected(address(gate), abi.encodeWithSignature("setFeeAuthority(address,bool)", rnd, true));
        _expectProtected(address(gate), abi.encodeWithSignature("setProtectedCalls(address,bytes4[],bool)", address(target), new bytes4[](0), false));
        _expectProtected(address(gate), hex"");
        _expectProtected(address(gate), hex"deadbeef");
        assertEq(gate.dao(), dao);
    }

    function test_setTargetFunctionRole_onRegisteredAccessManager_isProtected() public {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = target.setter.selector;
        _expectProtected(address(am), abi.encodeWithSignature("setTargetFunctionRole(address,bytes4[],uint64)", address(target), sels, FREE));
        // not registered: the gate does not know it is an access manager
        MockAccessManager unregistered = new MockAccessManager();
        _exec(address(unregistered), abi.encodeWithSignature("setTargetFunctionRole(address,bytes4[],uint64)", address(target), sels, FREE));
    }

    /// @dev Fix for 3b (Phase4GovernanceFork): on a registered access manager, the DAO could grant itself a way to strip
    /// the gate's own roles by calling revokeRole / renounceRole with the GATE as the account argument (AccessManager
    /// lets any account renounce its own role; revokeRole from the gate's execute context is msg.sender == gate too, but
    /// the underlying AM would still act on whatever account arg was passed). grantRole is unaffected: it can only ever
    /// ADD a role, never strip the gate's.
    function test_revokeOrRenounceRole_targetingTheGateItself_isProtected() public {
        // FREE (200) is not in isProtectedRole, so a normal revoke/renounce on it is allowed for OTHER accounts...
        _exec(address(am), abi.encodeWithSignature("revokeRole(uint64,address)", FREE, rnd));
        _exec(address(am), abi.encodeWithSignature("renounceRole(uint64,address)", FREE, rnd));
        assertEq(am.callsLength(), 2);

        // ...but never when the account argument is the gate itself, even for a free role
        _expectProtected(address(am), abi.encodeWithSignature("revokeRole(uint64,address)", FREE, address(gate)));
        _expectProtected(address(am), abi.encodeWithSignature("renounceRole(uint64,address)", FREE, address(gate)));
        // also for an already-protected role, targeting the gate
        _expectProtected(address(am), abi.encodeWithSignature("revokeRole(uint64,address)", PROTECTED, address(gate)));
        _expectProtected(address(am), abi.encodeWithSignature("renounceRole(uint64,address)", PROTECTED, address(gate)));
        assertEq(am.callsLength(), 2, "a call targeting the gate reached the access manager");

        // grantRole targeting the gate is fine (it only ever adds a role to the gate, never strips one)
        _exec(address(am), abi.encodeWithSignature("grantRole(uint64,address,uint32)", FREE, address(gate), uint32(0)));
        assertEq(am.callsLength(), 3);

        // the fee authority CAN do it via executeProtected (deliberate, e.g. a DAO migration off this gate)
        vm.prank(fee);
        gate.executeProtected(address(am), abi.encodeWithSignature("revokeRole(uint64,address)", FREE, address(gate)));
        assertEq(am.callsLength(), 4);
    }

    function test_roleCallsTouchingProtectedRoles_areProtected() public {
        for (uint256 i; i < 2; ++i) {
            uint64 r = i == 0 ? PROTECTED : PROTECTED2;
            _expectProtected(address(am), abi.encodeWithSignature("grantRole(uint64,address,uint32)", r, rnd, uint32(0)));
            _expectProtected(address(am), abi.encodeWithSignature("revokeRole(uint64,address)", r, rnd));
            _expectProtected(address(am), abi.encodeWithSignature("renounceRole(uint64,address)", r, rnd));
            _expectProtected(address(am), abi.encodeWithSignature("setRoleAdmin(uint64,uint64)", r, FREE));
            _expectProtected(address(am), abi.encodeWithSignature("setRoleGuardian(uint64,uint64)", r, FREE));
            _expectProtected(address(am), abi.encodeWithSignature("setGrantDelay(uint64,uint32)", r, uint32(1)));
            // making a protected role the admin / guardian of a free one
            _expectProtected(address(am), abi.encodeWithSignature("setRoleAdmin(uint64,uint64)", FREE, r));
            _expectProtected(address(am), abi.encodeWithSignature("setRoleGuardian(uint64,uint64)", FREE, r));
        }
        assertEq(am.callsLength(), 0, "a protected call reached the access manager");
        // grant / revoke / renounce of a free role are allowed
        _exec(address(am), abi.encodeWithSignature("grantRole(uint64,address,uint32)", FREE, rnd, uint32(0)));
        _exec(address(am), abi.encodeWithSignature("revokeRole(uint64,address)", FREE, rnd));
        _exec(address(am), abi.encodeWithSignature("renounceRole(uint64,address)", FREE, rnd));
        assertEq(am.callsLength(), 3);
        // a registered access manager is allowlist-only for the DAO: the other role-management calls are protected even
        // on free roles
        _expectProtected(address(am), abi.encodeWithSignature("setRoleAdmin(uint64,uint64)", FREE, FREE + 1));
        _expectProtected(address(am), abi.encodeWithSignature("setRoleGuardian(uint64,uint64)", FREE, FREE + 1));
        _expectProtected(address(am), abi.encodeWithSignature("setGrantDelay(uint64,uint32)", FREE, uint32(1)));
        assertEq(am.callsLength(), 3);
    }

    function test_registeredAccessManager_isAllowlistOnly_labelRoleAllowed() public {
        _exec(address(am), abi.encodeWithSignature("labelRole(uint64,string)", FREE, "ALPHA"));
        assertEq(am.callsLength(), 1);
        // labelRole is fine even for a protected role id (a label is not a permission)
        _exec(address(am), abi.encodeWithSignature("labelRole(uint64,string)", PROTECTED, "OWNER"));
        assertEq(am.callsLength(), 2);
        // everything else on a registered access manager is refused: scheduling, cancelling, closing targets, rewiring
        _expectProtected(address(am), abi.encodeWithSignature("schedule(address,bytes,uint48)", address(target), hex"", uint48(0)));
        _expectProtected(address(am), abi.encodeWithSignature("cancel(address,address,bytes)", rnd, address(target), hex""));
        _expectProtected(address(am), abi.encodeWithSignature("consumeScheduledOp(address,bytes)", rnd, hex""));
        _expectProtected(address(am), abi.encodeWithSignature("updateAuthority(address,address)", address(target), rnd));
        _expectProtected(address(am), abi.encodeWithSignature("setTargetClosed(address,bool)", address(target), true));
        _expectProtected(address(am), abi.encodeWithSignature("updateTargetClosed(address,bool)", address(target), true));
        _expectProtected(address(am), abi.encodeWithSignature("setTargetAdminDelay(address,uint32)", address(target), uint32(0)));
        _expectProtected(address(am), abi.encodeWithSignature("setGrantDelay(uint64,uint32)", FREE, uint32(0)));
        _expectProtected(address(am), hex"");
        _expectProtected(address(am), hex"deadbeef");
        assertEq(am.callsLength(), 2);
    }

    function test_genericWrappers_areProtectedOnAnyTarget() public {
        MockAccessManager unregistered = new MockAccessManager(); // has multicall / execute but the gate does not know it
        bytes[] memory inner = new bytes[](0);
        _expectProtected(address(unregistered), abi.encodeWithSignature("multicall(bytes[])", inner));
        _expectProtected(address(unregistered), abi.encodeWithSignature("multicall(uint256,bytes[])", uint256(1), inner));
        _expectProtected(address(unregistered), abi.encodeWithSignature("execute(address,bytes)", address(target), hex""));
        _expectProtected(address(unregistered), abi.encodeWithSignature("execute(address,uint256,bytes)", address(target), uint256(0), hex""));
        _expectProtected(address(target), abi.encodeWithSignature("multicall(bytes[])", inner));
        _expectProtected(makeAddr("any external router"), abi.encodeWithSignature("execute(address,bytes)", address(target), hex""));
        // a plain call on the same unregistered contract still works
        _exec(address(unregistered), abi.encodeWithSignature("grantRole(uint64,address,uint32)", PROTECTED, rnd, uint32(0)));
        assertEq(unregistered.callsLength(), 1);
    }

    function test_guardianLaneRefusesGenericWrappersEvenIfAllowListed() public {
        MockAccessManager unregistered = new MockAccessManager();
        bytes4 mc = bytes4(keccak256("multicall(bytes[])"));
        bytes4 ex = bytes4(keccak256("execute(address,bytes)"));
        vm.startPrank(dao);
        gate.setGuardian(guardian);
        gate.setGuardianCall(address(unregistered), mc, true);
        gate.setGuardianCall(address(unregistered), ex, true);
        gate.setGuardianCall(address(am), mc, true);
        vm.stopPrank();
        bytes[] memory inner = new bytes[](0);
        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ProtectedCall.selector, address(unregistered), mc));
        gate.executeGuardian(address(unregistered), abi.encodeWithSignature("multicall(bytes[])", inner));
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ProtectedCall.selector, address(unregistered), ex));
        gate.executeGuardian(address(unregistered), abi.encodeWithSignature("execute(address,bytes)", address(target), hex""));
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ProtectedCall.selector, address(am), mc));
        gate.executeGuardian(address(am), abi.encodeWithSignature("multicall(bytes[])", inner));
        vm.stopPrank();
    }

    function test_roleSelectorsWithShortCalldata_areProtected() public {
        _expectProtected(address(am), abi.encodeWithSelector(bytes4(keccak256("grantRole(uint64,address,uint32)"))));
        _expectProtected(address(am), bytes.concat(bytes4(keccak256("revokeRole(uint64,address)")), hex"00"));
        _expectProtected(address(am), bytes.concat(bytes4(keccak256("setRoleAdmin(uint64,uint64)")), bytes31(0)));
    }

    function test_roleIdWithDirtyUpperBits_cannotHideAProtectedRole() public {
        // roleId is a uint64 in the ABI; a 256-bit word whose low 64 bits are the protected role must be treated as it:
        // the gate reads uint64(uint256(word)), the access manager's decoder rejects dirty words. Either way it must not pass.
        bytes memory data = abi.encodePacked(
            bytes4(keccak256("grantRole(uint64,address,uint32)")),
            bytes32(uint256(PROTECTED) | (uint256(1) << 200)),
            bytes32(uint256(uint160(rnd))),
            bytes32(0)
        );
        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ProtectedCall.selector, address(am), bytes4(data)));
        gate.execute(address(am), data);
    }

    /// @dev IPOR's IporFusionAccessManager extends OZ AccessManager, which inherits Multicall: a protected call wrapped in
    /// `multicall` runs with the gate as msg.sender and never shows its selector to the gate.
    function test_multicallCannotWrapAProtectedRoleCall() public {
        bytes[] memory inner = new bytes[](1);
        inner[0] = abi.encodeWithSignature("grantRole(uint64,address,uint32)", PROTECTED, rnd, uint32(0));
        vm.prank(dao);
        vm.expectRevert(); // ProtectedCall expected
        gate.execute(address(am), abi.encodeWithSignature("multicall(bytes[])", inner));
        assertEq(am.callsLength(), 0, "the DAO granted a protected role through multicall");
    }

    function test_multicallCannotWrapATargetFunctionRoleChange() public {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = target.setter.selector;
        bytes[] memory inner = new bytes[](1);
        inner[0] = abi.encodeWithSignature("setTargetFunctionRole(address,bytes4[],uint64)", address(target), sels, FREE);
        vm.prank(dao);
        vm.expectRevert();
        gate.execute(address(am), abi.encodeWithSignature("multicall(bytes[])", inner));
        assertEq(am.callsLength(), 0);
    }

    /// @dev AccessManager.execute(target, data) runs `data` on `target` as the manager; wrapped around a role call on the
    /// manager itself it performs the protected role change without the gate seeing the selector.
    function test_accessManagerExecuteCannotWrapAProtectedRoleCall() public {
        bytes memory inner = abi.encodeWithSignature("grantRole(uint64,address,uint32)", PROTECTED, rnd, uint32(0));
        vm.prank(dao);
        vm.expectRevert();
        gate.execute(address(am), abi.encodeWithSignature("execute(address,bytes)", address(am), inner));
        assertEq(am.callsLength(), 0, "the DAO granted a protected role through AccessManager.execute");
    }

    // ---------------------------------------------------------------- executeProtected

    function test_executeProtected_feeAuthorityOnly_neverTheGate() public {
        vm.prank(dao);
        vm.expectRevert(CurveYieldGovernanceGate.NotFeeAuthority.selector);
        gate.executeProtected(address(target), abi.encodeCall(GovMockTarget.setAdmin, (rnd)));
        vm.prank(rnd);
        vm.expectRevert(CurveYieldGovernanceGate.NotFeeAuthority.selector);
        gate.executeProtected(address(target), abi.encodeCall(GovMockTarget.setAdmin, (rnd)));

        vm.startPrank(fee);
        gate.executeProtected(address(target), abi.encodeCall(GovMockTarget.setAdmin, (rnd)));
        assertEq(target.admin(), rnd);
        // an ownership move is possible on this path
        gate.executeProtected(address(target), abi.encodeWithSignature("transferOwnership(address)", fee));
        assertEq(target.owner(), fee);
        // never the gate itself
        vm.expectRevert(CurveYieldGovernanceGate.InvalidAddress.selector);
        gate.executeProtected(address(gate), abi.encodeWithSignature("setDao(address)", rnd));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- fee authority administration

    function test_feeAuthority_grantRevoke_lastCannotBeRemoved() public {
        assertTrue(gate.isFeeAuthority(fee));
        assertEq(gate.feeAuthorityCount(), 1);
        vm.prank(fee);
        vm.expectRevert(CurveYieldGovernanceGate.LastFeeAuthority.selector);
        gate.setFeeAuthority(fee, false);
        vm.prank(fee);
        gate.setFeeAuthority(fee2, true);
        assertEq(gate.feeAuthorityCount(), 2);
        vm.prank(fee);
        gate.setFeeAuthority(fee2, true); // no-op
        assertEq(gate.feeAuthorityCount(), 2);
        vm.prank(fee2);
        gate.setFeeAuthority(fee, false);
        assertFalse(gate.isFeeAuthority(fee));
        assertEq(gate.feeAuthorityCount(), 1);
        vm.prank(fee2);
        vm.expectRevert(CurveYieldGovernanceGate.LastFeeAuthority.selector);
        gate.setFeeAuthority(fee2, false);
        vm.prank(fee2);
        gate.setFeeAuthority(rnd, false); // removing a non-holder is a no-op
        assertEq(gate.feeAuthorityCount(), 1);
        vm.prank(fee2);
        vm.expectRevert(CurveYieldGovernanceGate.InvalidAddress.selector);
        gate.setFeeAuthority(address(0), true);
    }

    function test_daoCannotTouchFeeAuthorityAdministration() public {
        vm.startPrank(dao);
        vm.expectRevert(CurveYieldGovernanceGate.NotFeeAuthority.selector);
        gate.setFeeAuthority(dao, true);
        vm.expectRevert(CurveYieldGovernanceGate.NotFeeAuthority.selector);
        gate.setProtectedCalls(address(target), new bytes4[](0), false);
        vm.expectRevert(CurveYieldGovernanceGate.NotFeeAuthority.selector);
        gate.setProtectedRoles(address(am), new uint64[](0), false);
        vm.expectRevert(CurveYieldGovernanceGate.NotFeeAuthority.selector);
        gate.setAccessManager(address(am), false);
        vm.stopPrank();
        assertFalse(gate.isFeeAuthority(dao));
    }

    function test_feeAuthorityCanManageProtections() public {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = target.setAdmin.selector;
        vm.startPrank(fee);
        gate.setProtectedCalls(address(target), sels, false);
        uint64[] memory roles = new uint64[](1);
        roles[0] = PROTECTED;
        gate.setProtectedRoles(address(am), roles, false);
        vm.stopPrank();
        _exec(address(target), abi.encodeCall(GovMockTarget.setAdmin, (rnd)));
        _exec(address(am), abi.encodeWithSignature("grantRole(uint64,address,uint32)", PROTECTED, rnd, uint32(0)));
        assertEq(am.callsLength(), 1);
        // the still-protected role stays protected
        _expectProtected(address(am), abi.encodeWithSignature("grantRole(uint64,address,uint32)", PROTECTED2, rnd, uint32(0)));
    }

    // ---------------------------------------------------------------- setDao / guardian settings

    function test_setDao_daoOrFeeAuthority_only_nonZero() public {
        address dao2 = makeAddr("dao2");
        vm.prank(rnd);
        vm.expectRevert(CurveYieldGovernanceGate.NotDao.selector);
        gate.setDao(dao2);
        vm.prank(dao);
        gate.setDao(dao2);
        assertEq(gate.dao(), dao2);
        vm.prank(fee);
        gate.setDao(dao);
        assertEq(gate.dao(), dao);
        vm.prank(fee);
        vm.expectRevert(CurveYieldGovernanceGate.InvalidAddress.selector);
        gate.setDao(address(0));
        // the old DAO loses execute after a migration
        vm.prank(dao);
        gate.setDao(dao2);
        vm.prank(dao);
        vm.expectRevert(CurveYieldGovernanceGate.NotDao.selector);
        gate.execute(address(target), abi.encodeCall(GovMockTarget.setter, (1)));
    }

    function test_setGuardianAndGuardianCall_daoOrFeeAuthority_only() public {
        vm.startPrank(rnd);
        vm.expectRevert(CurveYieldGovernanceGate.NotDao.selector);
        gate.setGuardian(guardian);
        vm.expectRevert(CurveYieldGovernanceGate.NotDao.selector);
        gate.setGuardianCall(address(target), target.setter.selector, true);
        vm.stopPrank();
        vm.prank(dao);
        gate.setGuardian(guardian);
        assertEq(gate.guardian(), guardian);
        vm.prank(fee);
        gate.setGuardian(rnd);
        assertEq(gate.guardian(), rnd);
        vm.prank(dao);
        gate.setGuardianCall(address(target), target.setter.selector, true);
        assertTrue(gate.isGuardianCall(address(target), target.setter.selector));
        vm.prank(fee);
        gate.setGuardianCall(address(target), target.setter.selector, false);
        assertFalse(gate.isGuardianCall(address(target), target.setter.selector));
    }

    // ---------------------------------------------------------------- guardian lane

    function test_guardianLane_onlyAllowListed_neverProtected() public {
        vm.startPrank(dao);
        gate.setGuardian(guardian);
        gate.setGuardianCall(address(target), target.setter.selector, true);
        gate.setGuardianCall(address(target), target.setAdmin.selector, true); // allow-listed but protected
        gate.setGuardianCall(address(target), bytes4(keccak256("transferOwnership(address)")), true); // ownership move
        gate.setGuardianCall(address(gate), gate.setDao.selector, true); // the gate itself
        gate.setGuardianCall(address(am), bytes4(keccak256("grantRole(uint64,address,uint32)")), true);
        vm.stopPrank();

        bytes memory ok = abi.encodeCall(GovMockTarget.setter, (7));
        vm.prank(guardian);
        gate.executeGuardian(address(target), ok);
        assertEq(target.value(), 7);
        assertEq(target.lastCaller(), address(gate));

        // not the guardian
        vm.prank(rnd);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotGuardianCall.selector, address(target), target.setter.selector));
        gate.executeGuardian(address(target), ok);
        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotGuardianCall.selector, address(target), target.setter.selector));
        gate.executeGuardian(address(target), ok);
        // not allow-listed
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotGuardianCall.selector, address(target), target.ping.selector));
        gate.executeGuardian(address(target), abi.encodeCall(GovMockTarget.ping, ()));
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotGuardianCall.selector, address(other), other.setter.selector));
        gate.executeGuardian(address(other), ok);

        // allow-listed but protected: refused
        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ProtectedCall.selector, address(target), target.setAdmin.selector));
        gate.executeGuardian(address(target), abi.encodeCall(GovMockTarget.setAdmin, (rnd)));
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ProtectedCall.selector, address(target), bytes4(keccak256("transferOwnership(address)"))));
        gate.executeGuardian(address(target), abi.encodeWithSignature("transferOwnership(address)", guardian));
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ProtectedCall.selector, address(gate), gate.setDao.selector));
        gate.executeGuardian(address(gate), abi.encodeCall(gate.setDao, (guardian)));
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ProtectedCall.selector, address(am), bytes4(keccak256("grantRole(uint64,address,uint32)"))));
        gate.executeGuardian(address(am), abi.encodeWithSignature("grantRole(uint64,address,uint32)", PROTECTED, guardian, uint32(0)));
        vm.stopPrank();
        assertEq(target.owner(), address(gate));
        assertEq(gate.dao(), dao);
        // a free role grant through the lane is fine
        vm.prank(guardian);
        gate.executeGuardian(address(am), abi.encodeWithSignature("grantRole(uint64,address,uint32)", FREE, guardian, uint32(0)));
        assertEq(am.callsLength(), 1);
    }

    // ---------------------------------------------------------------- fuzz

    /// @dev Whatever the DAO sends, a call the gate classifies as protected never goes through, and the classification
    /// covers every ownership move, the gate itself and protected (target, selector) pairs.
    function testFuzz_daoNeverGetsAProtectedCallThrough(address t_, bytes calldata data_) public {
        vm.assume(t_ != address(vm) && t_ != address(this) && uint160(t_) > 0xff);
        bool prot = gate.isProtected(t_, data_);
        bytes4 sel = data_.length >= 4 ? bytes4(data_[:4]) : bytes4(0);
        // the classification itself must include these cases
        if (t_ == address(gate)) assertTrue(prot, "gate as target not protected");
        if (sel == bytes4(keccak256("transferOwnership(address)")) || sel == bytes4(keccak256("renounceOwnership()"))) {
            assertTrue(prot, "ownership move not protected");
        }
        if (t_ == address(target) && sel == target.setAdmin.selector) assertTrue(prot, "protected pair not protected");
        if (prot) {
            vm.prank(dao);
            vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ProtectedCall.selector, t_, sel));
            gate.execute(t_, data_);
        }
    }

    /// @dev Protected role ids in either position of a role call, with random other arguments, never pass.
    function testFuzz_protectedRoleSelectorsNeverPass(uint8 which_, uint64 other_, address who_, uint32 delay_, bool second_) public {
        uint64 pr = which_ % 2 == 0 ? PROTECTED : PROTECTED2;
        bytes memory data;
        uint256 k = uint256(which_) % 6;
        if (k == 0) data = abi.encodeWithSignature("grantRole(uint64,address,uint32)", pr, who_, delay_);
        else if (k == 1) data = abi.encodeWithSignature("revokeRole(uint64,address)", pr, who_);
        else if (k == 2) data = abi.encodeWithSignature("renounceRole(uint64,address)", pr, who_);
        else if (k == 3) data = second_ ? abi.encodeWithSignature("setRoleAdmin(uint64,uint64)", other_, pr) : abi.encodeWithSignature("setRoleAdmin(uint64,uint64)", pr, other_);
        else if (k == 4) data = second_ ? abi.encodeWithSignature("setRoleGuardian(uint64,uint64)", other_, pr) : abi.encodeWithSignature("setRoleGuardian(uint64,uint64)", pr, other_);
        else data = abi.encodeWithSignature("setGrantDelay(uint64,uint32)", pr, delay_);
        // setGrantDelay / grant with the protected role in position 1 only; setRole* checked in both positions
        if (k == 5 || k < 3) second_ = false;
        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ProtectedCall.selector, address(am), bytes4(data)));
        gate.execute(address(am), data);
        assertEq(am.callsLength(), 0);
    }
}
