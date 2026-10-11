// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {CurveYieldGovernanceGate} from "../../src/governance/CurveYieldGovernanceGate.sol";
import {IporRoleMock, IporOwnedOperationalTarget} from "./IporRoleMocks.sol";

contract GovernanceGateTest is Test {
    CurveYieldGovernanceGate gate;
    IporRoleMock access;
    IporOwnedOperationalTarget operational;
    IporOwnedOperationalTarget feeOwned;
    address safe = makeAddr("feeSafe");
    address operator = makeAddr("iporAtomist");
    address guardian = makeAddr("iporGuardian");
    address outsider = makeAddr("outsider");

    function setUp() public {
        access = new IporRoleMock();
        gate = new CurveYieldGovernanceGate(address(access), safe);
        access.setRole(1, safe, true, 0);
        access.setRole(100, operator, true, 0);
        access.setRole(2, guardian, true, 0);
        operational = new IporOwnedOperationalTarget(address(this));
        operational.transferOwnership(address(gate));
        vm.prank(safe);
        gate.acceptContractOwnership(address(operational));
        feeOwned = new IporOwnedOperationalTarget(address(this));
        feeOwned.transferOwnership(address(gate));
        vm.prank(safe);
        gate.acceptContractOwnership(address(feeOwned));
        bytes4[] memory receiver = new bytes4[](1);
        receiver[0] = feeOwned.setAdminReceiver.selector;
        vm.prank(safe);
        gate.registerAdminFeeCalls(address(feeOwned), receiver);
    }

    function test_iporManagerControlsAllOperationalRoles() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotIporRole.selector, uint64(100), outsider));
        gate.execute(address(operational), abi.encodeCall(operational.updateValue, (1)));
        vm.prank(operator);
        gate.execute(address(operational), abi.encodeCall(operational.updateValue, (25)));
        assertEq(operational.value(), 25);
        access.setRole(100, operator, false, 0);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotIporRole.selector, uint64(100), operator));
        gate.execute(address(operational), abi.encodeCall(operational.updateValue, (26)));
    }

    function test_cannotBypassIporExecutionDelay() public {
        access.setRole(100, operator, true, 10);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotIporRole.selector, uint64(100), operator));
        gate.execute(address(operational), abi.encodeCall(operational.updateValue, (2)));
    }

    function test_onlyDedicatedFeeRoleCanChangeReceiverAndRates() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ProtectedCall.selector, address(feeOwned), feeOwned.setAdminReceiver.selector));
        gate.execute(address(feeOwned), abi.encodeCall(feeOwned.setAdminReceiver, (outsider)));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotAdminFeeRole.selector, operator));
        gate.executeAdminFee(address(feeOwned), abi.encodeCall(feeOwned.setAdminReceiver, (outsider)));
        vm.prank(safe);
        gate.executeAdminFee(address(feeOwned), abi.encodeCall(feeOwned.setAdminReceiver, (outsider)));
        assertEq(feeOwned.adminReceiver(), outsider);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotAdminFeeCall.selector, address(feeOwned), feeOwned.updateValue.selector));
        gate.executeAdminFee(address(feeOwned), abi.encodeCall(feeOwned.updateValue, (7)));
    }

    function test_feeSafeRetainsIporOwnerWithGateOwnedFeeContract() public {
        (bool isOwner, uint32 delay) = access.hasRole(1, safe);
        assertTrue(isOwner);
        assertEq(delay, 0);
        assertEq(feeOwned.owner(), address(gate));
        assertEq(gate.adminFeeRoleHolder(), safe);

        // Rotation of the gate-local fee administrator does not touch native IPOR OWNER.
        vm.prank(safe);
        gate.transferAdminFeeRole(outsider);
        (isOwner, delay) = access.hasRole(1, safe);
        assertTrue(isOwner);
        assertEq(delay, 0);
        assertEq(feeOwned.owner(), address(gate));
        assertEq(gate.adminFeeRoleHolder(), outsider);
    }

    function test_feeRoleCanOnlyBeTransferredByItself() public {
        assertEq(gate.adminFeeRoleHolder(), safe);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotAdminFeeRole.selector, operator));
        gate.transferAdminFeeRole(operator);
        vm.prank(safe);
        gate.transferAdminFeeRole(outsider);
        assertEq(gate.adminFeeRoleHolder(), outsider);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotAdminFeeRole.selector, safe));
        gate.transferAdminFeeRole(safe);
        vm.prank(outsider);
        gate.transferAdminFeeRole(operator);
        assertEq(gate.adminFeeRoleHolder(), operator);
        // A fee-role transfer never changes the underlying initial receiver.
        assertEq(gate.adminReceiver(), safe);
    }

    function test_feeBearingOwnershipCannotEscapeFeeGate() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.FeeOwnershipCannotEscape.selector, address(feeOwned)));
        gate.transferContractOwnershipToAdminSafe(address(feeOwned));
        assertEq(feeOwned.owner(), address(gate));
    }

    function test_feeHandoverLocksStaticRecipientsToAdminFeeRole() public {
        vm.prank(safe);
        gate.activateFeeHandover();
        bytes32[] memory entries = new bytes32[](1);
        entries[0] = bytes32(uint256(12));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotAdminFeeRole.selector, operator));
        gate.setStaticSubstrates(0, entries);
        vm.prank(safe);
        gate.setStaticSubstrates(0, entries);
    }

    function test_unregisteredFeeFunctionNotCallableFromFeeLane() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotAdminFeeCall.selector, address(operational), operational.setFeeBps.selector));
        gate.executeAdminFee(address(operational), abi.encodeCall(operational.setFeeBps, (uint16(25))));
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotAdminFeeCall.selector, address(access), bytes4(keccak256("setRole(uint64,address,bool,uint32)"))));
        gate.executeAdminFee(address(access), abi.encodeWithSignature("setRole(uint64,address,bool,uint32)",
            uint64(100), outsider, true, uint32(0)));
    }

    function test_feeOwnedModuleMustBeGateOwned() public {
        IporOwnedOperationalTarget externalOwner = new IporOwnedOperationalTarget(safe);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = externalOwner.setAdminReceiver.selector;
        vm.prank(safe);
        gate.registerAdminFeeCalls(address(externalOwner), selectors);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ProtectedCall.selector, address(externalOwner), bytes4(0)));
        gate.executeAdminFee(address(externalOwner), abi.encodeCall(externalOwner.setAdminReceiver, (outsider)));
    }

    function test_iporAccessManagerCannotBeTargetedByGate() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ProtectedCall.selector, address(access), bytes4(keccak256("setRole(uint64,address,bool,uint32)"))));
        gate.execute(address(access), abi.encodeWithSignature("setRole(uint64,address,bool,uint32)",
            uint64(100), outsider, true, uint32(0)));
    }

    function test_noOwnershipMoveThroughGeneralExecute_butSafeRecoveryOnly() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ProtectedCall.selector, address(operational), bytes4(keccak256("transferOwnership(address)"))));
        gate.execute(address(operational), abi.encodeWithSignature("transferOwnership(address)", outsider));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotAdminFeeRole.selector, operator));
        gate.transferContractOwnershipToAdminSafe(address(operational));
        vm.prank(safe);
        gate.transferContractOwnershipToAdminSafe(address(operational));
        assertEq(operational.pendingOwner(), safe);
        vm.prank(safe);
        operational.acceptOwnership();
        assertEq(operational.owner(), safe);
    }

    function test_protectionIsMonotonic_andGuardianCannotRunFees() public {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = operational.updateValue.selector;
        vm.prank(safe);
        gate.setProtectedCalls(address(operational), sels, true);
        vm.prank(safe);
        vm.expectRevert(CurveYieldGovernanceGate.ProtectionCannotBeRemoved.selector);
        gate.setProtectedCalls(address(operational), sels, false);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ProtectedCall.selector, address(operational), operational.updateValue.selector));
        gate.execute(address(operational), abi.encodeCall(operational.updateValue, (3)));
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.ProtectedCall.selector, address(operational), operational.setAdminReceiver.selector));
        gate.setGuardianCall(address(operational), operational.setAdminReceiver.selector, true);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NotGuardianCall.selector, address(operational), operational.updateValue.selector));
        gate.executeGuardian(address(operational), abi.encodeCall(operational.updateValue, (3)));
    }
}
