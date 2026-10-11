// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {CurveYieldGovernanceGate} from "../../src/governance/CurveYieldGovernanceGate.sol";
import {CurveYieldAddrKeys} from "../../src/governance/CurveYieldGateConfig.sol";
import {IporRoleMock, IporOwnedOperationalTarget} from "./IporRoleMocks.sol";
contract GateWiringTest is Test {
    IporRoleMock am;
    CurveYieldGovernanceGate gate;
    address owner = makeAddr("iporOwner");
    address operator = makeAddr("iporAtomist");
    address outsider = makeAddr("outsider");
    IporOwnedOperationalTarget a;
    IporOwnedOperationalTarget b;
    function setUp() public {
        am = new IporRoleMock();
        gate = new CurveYieldGovernanceGate(address(am), owner);
        am.setRole(1,owner,true,0);
        am.setRole(100,operator,true,0);
        a = new IporOwnedOperationalTarget(owner);
        b = new IporOwnedOperationalTarget(owner);
    }
    function test_iporOperatorControlsWiring_NotAnInternalDaoRole() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotIporRole.selector, uint64(100), outsider));
        gate.registerAddr(CurveYieldAddrKeys.SWAP_ROUTER,address(a));
        vm.prank(operator);
        gate.registerAddr(CurveYieldAddrKeys.SWAP_ROUTER,address(a));
        assertEq(gate.addr(CurveYieldAddrKeys.SWAP_ROUTER),address(a));
        vm.prank(operator);
        gate.setAddr(CurveYieldAddrKeys.SWAP_ROUTER,address(b));
        assertEq(gate.addr(CurveYieldAddrKeys.SWAP_ROUTER),address(b));
        assertEq(gate.adminReceiver(),owner);
    }
    function test_feeSensitiveWiringIsAdminFeeRoleOnly() public {
        bytes32 revenueKey = keccak256("addr.revenueCustody");
        bytes32 splitKey = CurveYieldAddrKeys.LOOP_CONTRIBUTORS_RECIPIENT;
        vm.startPrank(owner);
        gate.registerAddr(revenueKey, address(a));
        gate.registerAddr(splitKey, address(a));
        vm.stopPrank();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotAdminFeeRole.selector, operator));
        gate.setAddr(revenueKey, address(b));
        vm.prank(owner);
        gate.setAddr(revenueKey, address(b));
        vm.prank(owner);
        gate.setAddr(splitKey, address(b));
        assertEq(gate.addr(revenueKey), address(b));
        assertEq(gate.addr(splitKey), address(b));
        bytes32 liveKey = CurveYieldAddrKeys.LOOP_GROWTH_RECIPIENT;
        vm.prank(owner); gate.registerAddr(liveKey, address(a));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotAdminFeeRole.selector, operator));
        gate.setAddr(liveKey, address(b));
        vm.prank(owner); gate.setAddr(liveKey, address(b));
        assertEq(gate.addr(liveKey), address(b));
    }

    function test_wiringRequiresContractAddressAndSingleRegistration() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NoCode.selector, outsider));
        gate.registerAddr(CurveYieldAddrKeys.SWAP_ROUTER,outsider);
        gate.registerAddr(CurveYieldAddrKeys.SWAP_ROUTER,address(a));
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.AddrExists.selector, CurveYieldAddrKeys.SWAP_ROUTER));
        gate.registerAddr(CurveYieldAddrKeys.SWAP_ROUTER,address(b));
        vm.stopPrank();
    }
}
