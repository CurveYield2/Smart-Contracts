// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CurveYieldVaultExecutor, CyExecutorDeps} from "../../src/executor/CurveYieldVaultExecutor.sol";
import {FuseAction} from "../../src/interfaces/CurveYieldPhase2Interfaces.sol";
import {CurveYieldConfigKeys as K} from "../../src/governance/CurveYieldGateConfig.sol";

/// @dev Minimal gate and dependency addresses; profitSplit does not require a live vault or fork.
contract DirectSplitGateMock {
    mapping(bytes32 => uint256) public settings;
    constructor() {
        settings[K.SPLIT_GROWTH_BPS] = 3_500;
        settings[K.SPLIT_CONTRIBUTORS_BPS] = 2_000;
        settings[K.SPLIT_VAULT_BPS] = 2_000;
        settings[K.SPLIT_REWARDS_MANAGER_BPS] = 2_500;
    }
    function set(bytes32 k_, uint256 v_) external { settings[k_] = v_; }
    function getMany(bytes32[] calldata ks_) external view returns (uint256[] memory out_) {
        out_ = new uint256[](ks_.length);
        for (uint256 i; i < ks_.length; ++i) out_[i] = settings[ks_[i]];
    }
}

contract DirectProfitSplitTest is Test {
    DirectSplitGateMock gate;
    CurveYieldVaultExecutor executor;
    function setUp() public {
        gate = new DirectSplitGateMock();
        executor = new CurveYieldVaultExecutor(address(this), address(0xA00), address(0xB00), CyExecutorDeps({
            allocation: address(0xA01), withdrawManager: address(0xA02),
            rewardsClaimManager: address(0xA03), transferFuse: address(0xA04), guardFuse: address(0xA05)
        }), address(gate));
    }
    function test_exactFourLegConservationAndRounding() public {
        (uint256 growth, uint256 contributors, uint256 vaultShare, uint256 rewards) = executor.profitSplit(101);
        assertEq(growth, 35);
        assertEq(contributors, 20);
        assertEq(rewards, 25);
        assertEq(vaultShare, 21);
        assertEq(growth + contributors + vaultShare + rewards, 101);
    }
    function testFuzz_conservesEveryInput(uint128 amount_) public {
        (uint256 g, uint256 c, uint256 v, uint256 r) = executor.profitSplit(amount_);
        assertEq(g + c + v + r, uint256(amount_));
        assertLe(g + c + r, uint256(amount_));
    }
    function test_invalidFeeScheduleAlwaysFailsClosed() public {
        gate.set(K.SPLIT_CONTRIBUTORS_BPS, 2_001);
        vm.expectRevert(CurveYieldVaultExecutor.InvalidProfitSplit.selector);
        executor.profitSplit(100 ether);
    }
    function test_executorBundleIsRestrictedToSelf() public {
        vm.expectRevert(CurveYieldVaultExecutor.OnlySelf.selector);
        executor.executeSelf(new FuseAction[](0));
    }
}
