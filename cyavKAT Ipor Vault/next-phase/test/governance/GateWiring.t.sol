// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CurveYieldGovernanceGate} from "../../src/governance/CurveYieldGovernanceGate.sol";
import {CurveYieldGateConfig, CurveYieldAddrKeys} from "../../src/governance/CurveYieldGateConfig.sol";
import {Phase2Base} from "../../script/Phase2Base.s.sol";

/// @dev Exposes Phase2Base._wireAddr (the deploy scripts' wiring helper) so its idempotency is tested on its own.
contract WireHarness is Phase2Base {
    function wire(address gate_, bytes32 key_, address addr_) external {
        _wireAddr(gate_, key_, addr_);
    }
}

/// @dev A stack contract that reads one of its dependencies through the gate at call time (as every consumer does).
contract WiringConsumer is CurveYieldGateConfig {
    constructor(address gate_) CurveYieldGateConfig(gate_) {}

    function swapRouter() external view returns (address) {
        return _addr(CurveYieldAddrKeys.SWAP_ROUTER);
    }

    function withdrawManager() external view returns (address) {
        return _addr(CurveYieldAddrKeys.WITHDRAW_MANAGER);
    }
}

contract WiringTarget {}

/// @notice Unit tests of the gate's wiring registry (GATE_CONFIG_SPEC section 10): registerAddr / setAddr / addr and the
/// deploy-script helper `_wireAddr`.
contract GateWiringTest is Test {
    CurveYieldGovernanceGate gate;
    WiringConsumer consumerA;
    WiringConsumer consumerB;
    WireHarness harness;
    address dao = makeAddr("dao");
    address fee = makeAddr("feeAuthority");
    address rnd = makeAddr("rnd");
    address router1;
    address router2;
    address wm1;
    address wm2;

    event AddrSet(bytes32 indexed key, address indexed oldAddr, address indexed newAddr);

    function setUp() public {
        gate = new CurveYieldGovernanceGate(dao, fee);
        consumerA = new WiringConsumer(address(gate));
        consumerB = new WiringConsumer(address(gate));
        harness = new WireHarness();
        router1 = address(new WiringTarget());
        router2 = address(new WiringTarget());
        wm1 = address(new WiringTarget());
        wm2 = address(new WiringTarget());
    }

    // ---------------------------------------------------------------- registerAddr

    function test_registerAddr_daoOrFeeAuthorityOnly() public {
        vm.prank(rnd);
        vm.expectRevert(); // neither DAO nor fee authority
        gate.registerAddr(CurveYieldAddrKeys.SWAP_ROUTER, router1);

        vm.prank(dao);
        gate.registerAddr(CurveYieldAddrKeys.SWAP_ROUTER, router1);
        vm.prank(fee);
        gate.registerAddr(CurveYieldAddrKeys.WITHDRAW_MANAGER, wm1);
        assertEq(gate.addr(CurveYieldAddrKeys.SWAP_ROUTER), router1);
        assertEq(gate.addr(CurveYieldAddrKeys.WITHDRAW_MANAGER), wm1);
        assertEq(gate.addrKeys().length, 2);
    }

    function test_registerAddr_firstTimeOnly_AddrExists() public {
        vm.startPrank(dao);
        gate.registerAddr(CurveYieldAddrKeys.SWAP_ROUTER, router1);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.AddrExists.selector, CurveYieldAddrKeys.SWAP_ROUTER));
        gate.registerAddr(CurveYieldAddrKeys.SWAP_ROUTER, router2);
        // even the same address cannot be registered twice
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.AddrExists.selector, CurveYieldAddrKeys.SWAP_ROUTER));
        gate.registerAddr(CurveYieldAddrKeys.SWAP_ROUTER, router1);
        vm.stopPrank();
        assertEq(gate.addr(CurveYieldAddrKeys.SWAP_ROUTER), router1, "a refused re-registration changed the wiring");
        assertEq(gate.addrKeys().length, 1, "the key was listed twice");
    }

    function test_registerAddr_mustHaveCode_NoCode() public {
        address eoa = makeAddr("eoa");
        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NoCode.selector, eoa));
        gate.registerAddr(CurveYieldAddrKeys.SWAP_ROUTER, eoa);
        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NoCode.selector, address(0)));
        gate.registerAddr(CurveYieldAddrKeys.SWAP_ROUTER, address(0));
        vm.expectRevert(); // nothing was stored
        gate.addr(CurveYieldAddrKeys.SWAP_ROUTER);
    }

    // ---------------------------------------------------------------- setAddr

    function test_setAddr_daoOnly_keyMustAlreadyBeSet_newAddressMustHaveCode() public {
        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.AddrUnset.selector, CurveYieldAddrKeys.SWAP_ROUTER));
        gate.setAddr(CurveYieldAddrKeys.SWAP_ROUTER, router1); // unset key

        vm.prank(dao);
        gate.registerAddr(CurveYieldAddrKeys.SWAP_ROUTER, router1);

        vm.prank(fee);
        vm.expectRevert(CurveYieldGovernanceGate.NotDao.selector); // the fee authority cannot repoint
        gate.setAddr(CurveYieldAddrKeys.SWAP_ROUTER, router2);
        vm.prank(rnd);
        vm.expectRevert(CurveYieldGovernanceGate.NotDao.selector);
        gate.setAddr(CurveYieldAddrKeys.SWAP_ROUTER, router2);

        address eoa = makeAddr("eoa");
        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.NoCode.selector, eoa));
        gate.setAddr(CurveYieldAddrKeys.SWAP_ROUTER, eoa);

        vm.expectEmit(true, true, true, true, address(gate));
        emit AddrSet(CurveYieldAddrKeys.SWAP_ROUTER, router1, router2);
        vm.prank(dao);
        gate.setAddr(CurveYieldAddrKeys.SWAP_ROUTER, router2);
        assertEq(gate.addr(CurveYieldAddrKeys.SWAP_ROUTER), router2);
    }

    // ---------------------------------------------------------------- addr / addrOrZero on an unset key

    function test_addr_unsetKey_reverts_addrOrZero_returnsZero() public {
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.AddrUnset.selector, CurveYieldAddrKeys.LEADERBOARD));
        gate.addr(CurveYieldAddrKeys.LEADERBOARD);
        assertEq(gate.addrOrZero(CurveYieldAddrKeys.LEADERBOARD), address(0));
        // a consumer that needs the key reverts instead of reading zero
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGovernanceGate.AddrUnset.selector, CurveYieldAddrKeys.SWAP_ROUTER));
        consumerA.swapRouter();
    }

    // ---------------------------------------------------------------- single-contract redeploy

    /// @dev After a DAO setAddr every consumer uses the new address without being redeployed or touched.
    function test_setAddr_everyConsumerFollowsTheNewAddress_noRedeploy() public {
        vm.startPrank(dao);
        gate.registerAddr(CurveYieldAddrKeys.SWAP_ROUTER, router1);
        gate.registerAddr(CurveYieldAddrKeys.WITHDRAW_MANAGER, wm1);
        vm.stopPrank();
        assertEq(consumerA.swapRouter(), router1);
        assertEq(consumerB.swapRouter(), router1);
        assertEq(consumerA.withdrawManager(), wm1);

        vm.startPrank(dao);
        gate.setAddr(CurveYieldAddrKeys.SWAP_ROUTER, router2);
        gate.setAddr(CurveYieldAddrKeys.WITHDRAW_MANAGER, wm2);
        vm.stopPrank();
        assertEq(consumerA.swapRouter(), router2);
        assertEq(consumerB.swapRouter(), router2);
        assertEq(consumerA.withdrawManager(), wm2);
        assertEq(consumerB.withdrawManager(), wm2);
        assertEq(consumerA.configGate(), address(gate), "a consumer was repointed instead of the gate wiring");
    }

    // ---------------------------------------------------------------- admin receiver (harvest admin share)

    event AdminReceiverSet(address indexed oldReceiver, address indexed newReceiver);

    function test_setAdminReceiver_feeAuthorityOnly_neverTheDao_noZero() public {
        address rx = makeAddr("adminRx");
        assertEq(gate.adminReceiver(), address(0), "unset at deployment");

        vm.prank(dao);
        vm.expectRevert(CurveYieldGovernanceGate.NotFeeAuthority.selector); // admin fees are never the DAO's
        gate.setAdminReceiver(rx);
        vm.prank(rnd);
        vm.expectRevert(CurveYieldGovernanceGate.NotFeeAuthority.selector);
        gate.setAdminReceiver(rx);
        vm.prank(fee);
        vm.expectRevert(CurveYieldGovernanceGate.InvalidAddress.selector);
        gate.setAdminReceiver(address(0));

        vm.expectEmit(true, true, false, false, address(gate));
        emit AdminReceiverSet(address(0), rx);
        vm.prank(fee);
        gate.setAdminReceiver(rx);
        assertEq(gate.adminReceiver(), rx);

        address rx2 = makeAddr("adminRx2");
        vm.prank(fee);
        gate.setAdminReceiver(rx2);
        assertEq(gate.adminReceiver(), rx2);
    }

    /// @dev The DAO reaches the gate's own functions only through its direct calls: execute() can never target the gate, and
    /// setAdminReceiver is not reachable through executeProtected either (never to the gate itself).
    function test_adminReceiver_notReachableThroughTheGateWrappers() public {
        bytes memory data = abi.encodeCall(CurveYieldGovernanceGate.setAdminReceiver, (makeAddr("x")));
        vm.prank(dao);
        vm.expectRevert(); // the gate itself is a protected target for the DAO
        gate.execute(address(gate), data);
        vm.prank(fee);
        vm.expectRevert(CurveYieldGovernanceGate.InvalidAddress.selector); // executeProtected never targets the gate
        gate.executeProtected(address(gate), data);
    }

    // ---------------------------------------------------------------- _wireAddr (deploy scripts)

    function test_wireAddr_sameAddressRerun_isNoOp_differentAddressReverts() public {
        vm.prank(dao);
        gate.setDao(address(harness)); // the harness plays the deployer: DAO of this gate

        harness.wire(address(gate), CurveYieldAddrKeys.SWAP_ROUTER, router1); // first wiring
        assertEq(gate.addr(CurveYieldAddrKeys.SWAP_ROUTER), router1);
        uint256 keys = gate.addrKeys().length;

        harness.wire(address(gate), CurveYieldAddrKeys.SWAP_ROUTER, router1); // re-run: no-op
        assertEq(gate.addr(CurveYieldAddrKeys.SWAP_ROUTER), router1);
        assertEq(gate.addrKeys().length, keys, "a re-run listed the key twice");

        vm.expectRevert(bytes("wiring key already set: replace it with the DAO's setAddr"));
        harness.wire(address(gate), CurveYieldAddrKeys.SWAP_ROUTER, router2);
        assertEq(gate.addr(CurveYieldAddrKeys.SWAP_ROUTER), router1, "a different address overwrote the wiring");
    }
}
