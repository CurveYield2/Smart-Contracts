// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CurveYieldGateConfig, CurveYieldConfigKeys as K} from "../../src/governance/CurveYieldGateConfig.sol";

/// @dev Minimal concrete harness: CurveYieldGateConfig is abstract.
contract GateConfigHarness is CurveYieldGateConfig {
    constructor(address gate_) CurveYieldGateConfig(gate_) {}

    function readOne(bytes32 key_) external view returns (uint256) {
        return _config1(key_);
    }

    function readMany(bytes32[] memory keys_) external view returns (uint256[] memory) {
        return _config(keys_);
    }
}

contract FakeConfigGate {
    mapping(bytes32 => uint256) public values;

    function set(bytes32 key_, uint256 value_) external {
        values[key_] = value_;
    }

    function getMany(bytes32[] calldata keys_) external view returns (uint256[] memory out_) {
        out_ = new uint256[](keys_.length);
        for (uint256 i; i < keys_.length; ++i) out_[i] = values[keys_[i]];
    }
}

/// @notice Unit tests of CurveYieldGateConfig: the base every gate-config'd contract shares.
contract GateConfigBaseTest is Test {
    FakeConfigGate gate1;
    FakeConfigGate gate2;
    GateConfigHarness client;
    address rnd = makeAddr("rnd");

    function setUp() public {
        gate1 = new FakeConfigGate();
        gate2 = new FakeConfigGate();
        client = new GateConfigHarness(address(gate1));
    }

    function test_constructor_setsTheGate_rejectsZero() public {
        assertEq(client.configGate(), address(gate1));
        vm.expectRevert(CurveYieldGateConfig.InvalidConfigGate.selector);
        new GateConfigHarness(address(0));
    }

    function test_setConfigGate_onlyTheCurrentGate() public {
        vm.prank(rnd);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGateConfig.NotConfigGate.selector, rnd));
        client.setConfigGate(address(gate2));

        vm.prank(address(gate1));
        client.setConfigGate(address(gate2));
        assertEq(client.configGate(), address(gate2));

        // the old gate has lost the ability to move it again
        vm.prank(address(gate1));
        vm.expectRevert(abi.encodeWithSelector(CurveYieldGateConfig.NotConfigGate.selector, address(gate1)));
        client.setConfigGate(address(gate1));
    }

    function test_setConfigGate_rejectsZero() public {
        vm.prank(address(gate1));
        vm.expectRevert(CurveYieldGateConfig.InvalidConfigGate.selector);
        client.setConfigGate(address(0));
    }

    function test_config1AndConfig_readThroughTheCurrentGate() public {
        gate1.set(K.WM_WITHDRAW_FEE, 111);
        gate1.set(K.WM_REQUEST_FEE, 222);
        assertEq(client.readOne(K.WM_WITHDRAW_FEE), 111);

        bytes32[] memory keys = new bytes32[](2);
        (keys[0], keys[1]) = (K.WM_WITHDRAW_FEE, K.WM_REQUEST_FEE);
        uint256[] memory vals = client.readMany(keys);
        assertEq(vals[0], 111);
        assertEq(vals[1], 222);

        // after moving to gate2, reads follow the new gate
        vm.prank(address(gate1));
        client.setConfigGate(address(gate2));
        gate2.set(K.WM_WITHDRAW_FEE, 999);
        assertEq(client.readOne(K.WM_WITHDRAW_FEE), 999);
    }
}
