// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {CurveYieldGovernanceGate} from "../../src/governance/CurveYieldGovernanceGate.sol";
import {IporRoleMock} from "./IporRoleMocks.sol";
contract GateConfigRegistryTest is Test {
    IporRoleMock am;
    CurveYieldGovernanceGate gate;
    address owner = makeAddr("iporOwner");
    address operator = makeAddr("atomist");
    address guardian = makeAddr("guardian");
    bytes32 constant ADMIN_BPS = keccak256("test.adminFeeBps");
    bytes32 constant OP_A = keccak256("test.operationalA");
    bytes32 constant OP_B = keccak256("test.operationalB");
    bytes32 constant GUARD = keccak256("test.guard");
    function setUp() public {
        am = new IporRoleMock();
        gate = new CurveYieldGovernanceGate(address(am),owner);
        am.setRole(1,owner,true,0);
        am.setRole(100,operator,true,0);
        am.setRole(2,guardian,true,0);
        vm.startPrank(owner);
        gate.registerConfig(ADMIN_BPS,1,0,1_000,100);
        gate.registerConfig(OP_A,2,0,100,20);
        gate.registerConfig(OP_B,2,0,100,80);
        gate.registerConfig(GUARD,3,0,100,25);
        gate.setGuardianRange(GUARD,10,50);
        gate.sealFeeConfiguration();
        bytes32[] memory keys = new bytes32[](2);
        keys[0]=OP_A;keys[1]=OP_B;
        gate.addRule(1,100,keys,address(0),bytes4(0));
        vm.stopPrank();
    }
    function test_canNeverRegisterAnotherFeeKeyAfterSealing() public {
        vm.prank(owner);
        vm.expectRevert(CurveYieldGovernanceGate.FeeConfigRegistrySealed.selector);
        gate.registerConfig(keccak256("extra.fee"),1,0,500,100);
    }
    function test_onlyAdminFeeRoleCanChangeFeeSettingsAndRanges() public {
        bytes32[] memory keys = new bytes32[](1);
        uint256[] memory values = new uint256[](1);
        keys[0]=ADMIN_BPS;values[0]=101;
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotAdminFeeRole.selector, operator));
        gate.setConfigs(keys,values);
        vm.prank(owner);
        gate.setConfigs(keys,values);
        assertEq(gate.getConfig(ADMIN_BPS).value,101);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotAdminFeeRole.selector, operator));
        gate.setConfigRange(ADMIN_BPS,0,200);
        vm.prank(owner);
        gate.setConfigRange(ADMIN_BPS,0,200);
        assertEq(gate.getConfig(ADMIN_BPS).max,200);
    }
    function test_operationalGroupChangeAtomicAndRuleChecked() public {
        bytes32[] memory keys = new bytes32[](2);
        uint256[] memory values = new uint256[](2);
        keys[0]=OP_A;keys[1]=OP_B;values[0]=40;values[1]=60;
        vm.prank(operator);
        gate.setConfigs(keys,values);
        assertEq(gate.getConfig(OP_A).value,40);
        values[0]=41;
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.RuleViolated.selector, uint256(0)));
        gate.setConfigs(keys,values);
        assertEq(gate.getConfig(OP_A).value,40);
    }
    function test_iporGuardianLimitedToGuardianValues() public {
        vm.prank(guardian);
        gate.setConfigByGuardian(GUARD,40);
        assertEq(gate.getConfig(GUARD).value,40);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.OutOfRange.selector, GUARD, uint256(51), uint256(10), uint256(50)));
        gate.setConfigByGuardian(GUARD,51);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotAllowed.selector, OP_A, guardian));
        gate.setConfigByGuardian(OP_A,20);
    }
    function test_feeArgRangeIsFeeRoleOnly() public {
        vm.prank(owner);
        gate.registerArgRange(address(0xBEEF),bytes4(keccak256("setFee(uint256)")),0,1,0,100);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotAdminFeeRole.selector, operator));
        gate.setArgRange(address(0xBEEF),bytes4(keccak256("setFee(uint256)")),0,0,90);
        vm.prank(owner);
        gate.setArgRange(address(0xBEEF),bytes4(keccak256("setFee(uint256)")),0,0,90);
    }

}
