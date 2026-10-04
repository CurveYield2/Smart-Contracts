// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CurveYieldGovernanceGate} from "../../src/governance/CurveYieldGovernanceGate.sol";
import {GovMockTarget} from "./GovMocks.sol";

/// @notice Unit tests of the config registry half of CurveYieldGovernanceGate (GATE_CONFIG_SPEC): registerConfig,
/// setConfigs, setConfigRange, setConfigByGuardian, group rules, getMany, and the arg-range passthrough on
/// execute / executeProtected / executeGuardian. No fork: the gate is the only contract under test.
contract GateConfigRegistryTest is Test {
    CurveYieldGovernanceGate gate;
    GovMockTarget target;
    address dao = makeAddr("dao");
    address fee = makeAddr("feeAuthority");
    address guardian = makeAddr("guardian");
    address rnd = makeAddr("rnd");

    bytes32 constant KEY_FEE = keccak256("test.fee.key");
    bytes32 constant KEY_DAO = keccak256("test.dao.key");
    bytes32 constant KEY_GUARDIAN = keccak256("test.guardian.key");

    function setUp() public {
        gate = new CurveYieldGovernanceGate(dao, fee);
        target = new GovMockTarget(address(gate));
        vm.startPrank(fee);
        gate.registerConfig(KEY_FEE, 1, 0, 10_000, 1_000);
        gate.registerConfig(KEY_DAO, 2, 0, 10_000, 2_000);
        gate.registerConfig(KEY_GUARDIAN, 3, 0, 10_000, 3_000);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- registerConfig

    function test_registerConfig_onceOnly_feeAuthorityOnly_valueInsideHardCaps() public {
        vm.prank(dao);
        vm.expectRevert(CurveYieldGovernanceGate.NotFeeAuthority.selector);
        gate.registerConfig(keccak256("x"), 2, 0, 100, 50);

        vm.startPrank(fee);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.KeyExists.selector, KEY_FEE));
        gate.registerConfig(KEY_FEE, 1, 0, 10_000, 1);

        vm.expectRevert(); // BadRule: class out of range
        gate.registerConfig(keccak256("bad class"), 0, 0, 100, 50);
        vm.expectRevert(); // BadRule: class out of range
        gate.registerConfig(keccak256("bad class 2"), 4, 0, 100, 50);
        vm.expectRevert(); // BadRule: hardMin > hardMax
        gate.registerConfig(keccak256("bad range"), 2, 100, 50, 60);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.OutOfRange.selector, keccak256("oor"), 200, 0, 100));
        gate.registerConfig(keccak256("oor"), 2, 0, 100, 200);
        vm.stopPrank();

        CurveYieldGovernanceGate.Config memory c = gate.getConfig(KEY_FEE);
        assertEq(c.value, 1_000);
        assertEq(c.min, 0);
        assertEq(c.max, 10_000);
        assertEq(c.hardMin, 0);
        assertEq(c.hardMax, 10_000);
        assertTrue(c.registered);
    }

    function test_getConfig_unknownKey_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.UnknownKey.selector, keccak256("nope")));
        gate.getConfig(keccak256("nope"));
    }

    // ---------------------------------------------------------------- setConfigs class rules

    function test_setConfigs_feeKey_feeAuthorityOnly() public {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = KEY_FEE;
        uint256[] memory vals = new uint256[](1);
        vals[0] = 500;

        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotAllowed.selector, KEY_FEE, dao));
        gate.setConfigs(keys, vals);
        vm.prank(rnd);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotAllowed.selector, KEY_FEE, rnd));
        gate.setConfigs(keys, vals);

        vm.prank(fee);
        gate.setConfigs(keys, vals);
        assertEq(gate.getConfig(KEY_FEE).value, 500);
    }

    function test_setConfigs_daoKey_daoOrFeeAuthority() public {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = KEY_DAO;
        uint256[] memory vals = new uint256[](1);
        vals[0] = 3_000;

        vm.prank(rnd);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotAllowed.selector, KEY_DAO, rnd));
        gate.setConfigs(keys, vals);

        vm.prank(dao);
        gate.setConfigs(keys, vals);
        assertEq(gate.getConfig(KEY_DAO).value, 3_000);

        vals[0] = 4_000;
        vm.prank(fee);
        gate.setConfigs(keys, vals);
        assertEq(gate.getConfig(KEY_DAO).value, 4_000);
    }

    function test_setConfigs_lengthMismatch_reverts() public {
        bytes32[] memory keys = new bytes32[](2);
        uint256[] memory vals = new uint256[](1);
        vm.prank(fee);
        vm.expectRevert(CurveYieldGovernanceGate.BadRule.selector);
        gate.setConfigs(keys, vals);
    }

    function test_setConfigs_valueOutsideCurrentRange_reverts() public {
        vm.prank(fee);
        gate.setConfigRange(KEY_DAO, 0, 5_000);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = KEY_DAO;
        uint256[] memory vals = new uint256[](1);
        vals[0] = 5_001;
        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.OutOfRange.selector, KEY_DAO, 5_001, 0, 5_000));
        gate.setConfigs(keys, vals);
    }

    function test_setConfigs_unknownKey_reverts() public {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = keccak256("nope");
        uint256[] memory vals = new uint256[](1);
        vm.prank(fee);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.UnknownKey.selector, keccak256("nope")));
        gate.setConfigs(keys, vals);
    }

    // ---------------------------------------------------------------- setConfigRange

    function test_setConfigRange_daoForDaoClass_feeAuthorityForFeeClass() public {
        vm.prank(rnd);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotAllowed.selector, KEY_DAO, rnd));
        gate.setConfigRange(KEY_DAO, 0, 5_000);
        vm.prank(dao);
        gate.setConfigRange(KEY_DAO, 0, 5_000);
        assertEq(gate.getConfig(KEY_DAO).max, 5_000);

        // FEE class: the DAO cannot narrow it, only a fee authority
        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotAllowed.selector, KEY_FEE, dao));
        gate.setConfigRange(KEY_FEE, 0, 5_000);
        vm.prank(fee);
        gate.setConfigRange(KEY_FEE, 0, 5_000);
        assertEq(gate.getConfig(KEY_FEE).max, 5_000);
    }

    function test_setConfigRange_mustStayInsideHardCaps_andContainTheCurrentValue() public {
        vm.startPrank(fee);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.OutOfRange.selector, KEY_FEE, 0, 0, 10_000));
        gate.setConfigRange(KEY_FEE, 0, 20_000); // beyond hardMax
        // value 1,000 must stay inside the new range
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.OutOfRange.selector, KEY_FEE, 1_000, 1_100, 2_000));
        gate.setConfigRange(KEY_FEE, 1_100, 2_000);
        gate.setConfigRange(KEY_FEE, 500, 1_500); // fine: contains 1,000
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- guardian lane (config)

    function test_setConfigByGuardian_onlyGuardianClass_onlyGuardian_insideGuardianRange() public {
        vm.prank(dao);
        gate.setGuardian(guardian);
        vm.prank(dao);
        gate.setGuardianRange(KEY_GUARDIAN, 2_000, 4_000);

        vm.prank(rnd);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotAllowed.selector, KEY_GUARDIAN, rnd));
        gate.setConfigByGuardian(KEY_GUARDIAN, 2_500);

        // a non-GUARDIAN-class key is refused even for the guardian
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotAllowed.selector, KEY_DAO, guardian));
        gate.setConfigByGuardian(KEY_DAO, 100);

        vm.startPrank(guardian);
        gate.setConfigByGuardian(KEY_GUARDIAN, 2_500);
        assertEq(gate.getConfig(KEY_GUARDIAN).value, 2_500);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.OutOfRange.selector, KEY_GUARDIAN, 1_999, 2_000, 4_000));
        gate.setConfigByGuardian(KEY_GUARDIAN, 1_999);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.OutOfRange.selector, KEY_GUARDIAN, 4_001, 2_000, 4_000));
        gate.setConfigByGuardian(KEY_GUARDIAN, 4_001);
        vm.stopPrank();
    }

    /// @dev The guardian's effective bounds are the intersection of its own range and the key's DAO-set range.
    function test_setConfigByGuardian_boundedByTheKeysOwnRangeToo() public {
        vm.prank(dao);
        gate.setGuardian(guardian);
        vm.prank(dao);
        gate.setGuardianRange(KEY_GUARDIAN, 0, 10_000);
        vm.prank(dao);
        gate.setConfigRange(KEY_GUARDIAN, 0, 3_500); // narrower than the guardian's own range
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.OutOfRange.selector, KEY_GUARDIAN, 4_000, 0, 3_500));
        gate.setConfigByGuardian(KEY_GUARDIAN, 4_000);
        vm.prank(guardian);
        gate.setConfigByGuardian(KEY_GUARDIAN, 3_500);
        assertEq(gate.getConfig(KEY_GUARDIAN).value, 3_500);
    }

    function test_setGuardianRange_onlyGuardianClass_daoOrFeeAuthority() public {
        vm.prank(rnd);
        vm.expectRevert(CurveYieldGovernanceGate.NotDao.selector);
        gate.setGuardianRange(KEY_GUARDIAN, 0, 100);
        vm.prank(dao);
        vm.expectRevert(CurveYieldGovernanceGate.BadRule.selector);
        gate.setGuardianRange(KEY_DAO, 0, 100); // not a GUARDIAN-class key
        vm.prank(fee);
        gate.setGuardianRange(KEY_GUARDIAN, 100, 200);
        assertEq(gate.getConfig(KEY_GUARDIAN).guardianMin, 100);
        assertEq(gate.getConfig(KEY_GUARDIAN).guardianMax, 200);
    }

    // ---------------------------------------------------------------- group rules

    function test_ruleSumEq_checkedAfterTheWholeBatch() public {
        bytes32[] memory keys = new bytes32[](2);
        (keys[0], keys[1]) = (KEY_DAO, KEY_GUARDIAN);
        vm.prank(fee);
        gate.addRule(1, 5_000, keys, address(0), bytes4(0)); // matches the current sum 2,000 + 3,000

        // re-splitting 2,000 + 3,000 = 5,000 into 1,000 + 4,000 = 5,000 in ONE call must pass (checked after the batch,
        // even though the first key alone would overshoot nothing here — the point is both writes land before the check)
        uint256[] memory vals = new uint256[](2);
        (vals[0], vals[1]) = (1_000, 4_000);
        vm.prank(dao);
        gate.setConfigs(keys, vals);
        assertEq(gate.getConfig(KEY_DAO).value, 1_000);
        assertEq(gate.getConfig(KEY_GUARDIAN).value, 4_000);

        // a single-key change that breaks the sum reverts
        bytes32[] memory k1 = new bytes32[](1);
        k1[0] = KEY_DAO;
        uint256[] memory v1 = new uint256[](1);
        v1[0] = 1_001;
        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.RuleViolated.selector, 0));
        gate.setConfigs(k1, v1);
    }

    function test_addRule_sumEq_checkedImmediatelyIfAlreadyViolated() public {
        bytes32[] memory keys = new bytes32[](2);
        (keys[0], keys[1]) = (KEY_DAO, KEY_GUARDIAN); // 2,000 + 3,000 = 5,000
        vm.prank(fee);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.RuleViolated.selector, 0));
        gate.addRule(1, 10_000, keys, address(0), bytes4(0));
    }

    function test_ruleSumLe() public {
        bytes32[] memory keys = new bytes32[](2);
        (keys[0], keys[1]) = (KEY_DAO, KEY_GUARDIAN); // 2,000 + 3,000 = 5,000
        vm.prank(fee);
        gate.addRule(2, 5_000, keys, address(0), bytes4(0));
        bytes32[] memory k1 = new bytes32[](1);
        k1[0] = KEY_DAO;
        uint256[] memory v1 = new uint256[](1);
        v1[0] = 2_001; // sum becomes 5,001
        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.RuleViolated.selector, 0));
        gate.setConfigs(k1, v1);
        v1[0] = 2_000;
        vm.prank(dao);
        gate.setConfigs(k1, v1); // sum stays 5,000: fine
    }

    function test_ruleOrderLe_andOrderLt() public {
        bytes32 keyA = keccak256("order.a");
        bytes32 keyB = keccak256("order.b");
        vm.startPrank(fee);
        gate.registerConfig(keyA, 2, 0, 10_000, 100);
        gate.registerConfig(keyB, 2, 0, 10_000, 200);
        bytes32[] memory keys = new bytes32[](2);
        (keys[0], keys[1]) = (keyA, keyB);
        gate.addRule(3, 0, keys, address(0), bytes4(0)); // a <= b
        vm.stopPrank();

        bytes32[] memory k1 = new bytes32[](1);
        k1[0] = keyA;
        uint256[] memory v1 = new uint256[](1);
        v1[0] = 200; // a == b: LE holds
        vm.prank(dao);
        gate.setConfigs(k1, v1);
        v1[0] = 201; // a > b: violates LE
        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.RuleViolated.selector, 0));
        gate.setConfigs(k1, v1);

        // a fresh ORDER_LT rule on the same pair: equality must now fail
        bytes32 keyC = keccak256("order.c");
        vm.prank(fee);
        gate.registerConfig(keyC, 2, 0, 10_000, 300); // keyA is at 200 now; c must start above it for ORDER_LT to add cleanly
        bytes32[] memory keysLt = new bytes32[](2);
        (keysLt[0], keysLt[1]) = (keyA, keyC); // a (200) < c (300): holds
        vm.prank(fee);
        gate.addRule(4, 0, keysLt, address(0), bytes4(0));
        v1[0] = 300; // a == c: violates strict LT (rule 1) — rule 0 (a <= b, b still 200) is violated first and reported
        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.RuleViolated.selector, 0));
        gate.setConfigs(k1, v1);
        // raise b out of the way so rule 0 is satisfied and rule 1 (a < c) is the one that fires
        vm.prank(dao);
        bytes32[] memory kb = new bytes32[](1);
        kb[0] = keyB;
        uint256[] memory vb = new uint256[](1);
        vb[0] = 9_000;
        gate.setConfigs(kb, vb);
        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.RuleViolated.selector, 1));
        gate.setConfigs(k1, v1);
    }

    function test_addRule_orderRules_needAtLeastTwoKeys() public {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = KEY_DAO;
        vm.prank(fee);
        vm.expectRevert(CurveYieldGovernanceGate.BadRule.selector);
        gate.addRule(3, 0, keys, address(0), bytes4(0));
    }

    function test_ruleEachLe() public {
        bytes32[] memory keys = new bytes32[](2);
        (keys[0], keys[1]) = (KEY_DAO, KEY_GUARDIAN);
        vm.prank(fee);
        gate.addRule(5, 5_000, keys, address(0), bytes4(0));
        bytes32[] memory k1 = new bytes32[](1);
        k1[0] = KEY_GUARDIAN;
        uint256[] memory v1 = new uint256[](1);
        v1[0] = 5_001;
        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.RuleViolated.selector, 0));
        gate.setConfigs(k1, v1);
        v1[0] = 5_000;
        vm.prank(dao);
        gate.setConfigs(k1, v1);
    }

    /// @dev RULE_LOCK: refused while `lockTarget.lockSelector()` returns true (e.g. an active season).
    function test_ruleLock_refusesWhileLocked() public {
        LockableMock lockable = new LockableMock();
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = KEY_DAO;
        vm.prank(fee);
        uint256 ruleId = gate.addRule(6, 0, keys, address(lockable), lockable.locked.selector);

        lockable.setLocked(true);
        uint256[] memory v1 = new uint256[](1);
        v1[0] = 9_000;
        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.RuleViolated.selector, ruleId));
        gate.setConfigs(keys, v1);

        lockable.setLocked(false);
        vm.prank(dao);
        gate.setConfigs(keys, v1);
        assertEq(gate.getConfig(KEY_DAO).value, 9_000);
    }

    function test_addRule_lock_needsALockTarget() public {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = KEY_DAO;
        vm.prank(fee);
        vm.expectRevert(CurveYieldGovernanceGate.BadRule.selector);
        gate.addRule(6, 0, keys, address(0), bytes4(keccak256("locked()")));
    }

    function test_addRule_unknownKey_reverts() public {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = keccak256("unregistered");
        vm.prank(fee);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.UnknownKey.selector, keccak256("unregistered")));
        gate.addRule(2, 100, keys, address(0), bytes4(0));
    }

    function test_addRule_feeAuthorityOnly() public {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = KEY_DAO;
        vm.prank(dao);
        vm.expectRevert(CurveYieldGovernanceGate.NotFeeAuthority.selector);
        gate.addRule(5, 100, keys, address(0), bytes4(0));
    }

    // ---------------------------------------------------------------- getMany

    function test_getMany_returnsValuesInOrder() public view {
        bytes32[] memory keys = new bytes32[](3);
        (keys[0], keys[1], keys[2]) = (KEY_GUARDIAN, KEY_FEE, KEY_DAO);
        uint256[] memory vals = gate.getMany(keys);
        assertEq(vals[0], 3_000);
        assertEq(vals[1], 1_000);
        assertEq(vals[2], 2_000);
    }

    function test_getMany_unknownKey_reverts() public {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = keccak256("nope");
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.UnknownKey.selector, keccak256("nope")));
        gate.getMany(keys);
    }

    function test_configKeys_listsEveryRegisteredKey() public view {
        bytes32[] memory keys = gate.configKeys();
        assertEq(keys.length, 3);
        assertEq(keys[0], KEY_FEE);
        assertEq(keys[1], KEY_DAO);
        assertEq(keys[2], KEY_GUARDIAN);
    }

    // ---------------------------------------------------------------- passthrough arg ranges

    function test_registerArgRange_feeClass_makesTheCallProtected_daoCannotReachItEvenInRange() public {
        vm.startPrank(fee);
        gate.registerArgRange(address(target), target.setter.selector, 0, 1, 0, 1_000);
        vm.stopPrank();
        assertTrue(gate.isProtectedCall(address(target), target.setter.selector), "FEE arg range did not protect the call");

        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ProtectedCall.selector, address(target), target.setter.selector));
        gate.execute(address(target), abi.encodeCall(GovMockTarget.setter, (500))); // in range, still protected

        vm.prank(fee);
        gate.executeProtected(address(target), abi.encodeCall(GovMockTarget.setter, (500)));
        assertEq(target.value(), 500);
    }

    function test_registerArgRange_daoClass_argCheckedOnExecute_outOfRangeReverts() public {
        vm.prank(fee);
        gate.registerArgRange(address(target), target.setter.selector, 0, 2, 0, 1_000);
        assertFalse(gate.isProtectedCall(address(target), target.setter.selector));

        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ArgOutOfRange.selector, address(target), target.setter.selector, 0, 1_001));
        gate.execute(address(target), abi.encodeCall(GovMockTarget.setter, (1_001)));

        vm.prank(dao);
        gate.execute(address(target), abi.encodeCall(GovMockTarget.setter, (1_000)));
        assertEq(target.value(), 1_000);
    }

    function test_argRange_checkedOnExecuteProtectedAndExecuteGuardian_too() public {
        vm.startPrank(fee);
        gate.registerArgRange(address(target), target.setter.selector, 0, 2, 0, 1_000);
        vm.stopPrank();

        vm.prank(fee);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ArgOutOfRange.selector, address(target), target.setter.selector, 0, 2_000));
        gate.executeProtected(address(target), abi.encodeCall(GovMockTarget.setter, (2_000)));

        vm.prank(dao);
        gate.setGuardian(guardian);
        vm.prank(dao);
        gate.setGuardianCall(address(target), target.setter.selector, true);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ArgOutOfRange.selector, address(target), target.setter.selector, 0, 2_000));
        gate.executeGuardian(address(target), abi.encodeCall(GovMockTarget.setter, (2_000)));
        vm.prank(guardian);
        gate.executeGuardian(address(target), abi.encodeCall(GovMockTarget.setter, (999)));
        assertEq(target.value(), 999);
    }

    function test_registerArgRange_onceOnly_hardCapsImmutable() public {
        vm.startPrank(fee);
        gate.registerArgRange(address(target), target.setter.selector, 0, 2, 0, 1_000);
        vm.expectRevert(CurveYieldGovernanceGate.BadRule.selector);
        gate.registerArgRange(address(target), target.setter.selector, 0, 2, 0, 2_000);
        vm.stopPrank();
    }

    function test_setArgRange_narrowingRespectsClassAndHardCaps() public {
        vm.prank(fee);
        gate.registerArgRange(address(target), target.setter.selector, 0, 2, 0, 1_000);

        vm.prank(rnd);
        vm.expectRevert(CurveYieldGovernanceGate.NotDao.selector);
        gate.setArgRange(address(target), target.setter.selector, 0, 0, 500);

        vm.prank(dao);
        gate.setArgRange(address(target), target.setter.selector, 0, 0, 500);
        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ArgOutOfRange.selector, address(target), target.setter.selector, 0, 600));
        gate.execute(address(target), abi.encodeCall(GovMockTarget.setter, (600)));

        vm.prank(dao);
        vm.expectRevert(CurveYieldGovernanceGate.BadRule.selector);
        gate.setArgRange(address(target), target.setter.selector, 0, 0, 1_001); // beyond the hard cap
    }

    function test_setArgRange_unregistered_reverts() public {
        vm.prank(dao);
        vm.expectRevert(CurveYieldGovernanceGate.BadRule.selector);
        gate.setArgRange(address(target), target.setter.selector, 0, 0, 100);
    }

    function test_passRead_isAPlainStaticCall() public {
        bytes memory ret = gate.passRead(address(target), abi.encodeWithSignature("value()"));
        assertEq(abi.decode(ret, (uint256)), 0);
    }
}

contract LockableMock {
    bool public locked;

    function setLocked(bool locked_) external {
        locked = locked_;
    }
}
