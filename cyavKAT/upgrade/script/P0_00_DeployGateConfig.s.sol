// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {CurveYieldGovernanceGate} from "../src/governance/CurveYieldGovernanceGate.sol";
import {CurveYieldConfigKeys as K} from "../src/governance/CurveYieldGateConfig.sol";

/// Phase 0: deploy the NEW V4 operational/ADMIN_FEE gate backed entirely by the existing IPOR
/// Access Manager. Fee rates/recipients are administrable only by a separate self-managed ADMIN_FEE role. The original factory vault/base/Access Manager remain intact.
/// Output: deployments/katana-gate-v4.json (PHASE0_DEPLOYMENTS override).
contract P0_00_DeployGateConfig is Phase2Base {
    uint8 internal constant FEE = 1;
    uint8 internal constant DAO = 2;
    uint8 internal constant GUARDIAN = 3;
    uint8 internal constant SUM_EQ = 1;
    uint8 internal constant SUM_LE = 2;
    uint8 internal constant ORDER_LE = 3;
    uint8 internal constant ORDER_LT = 4;

    CurveYieldGovernanceGate internal gate;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        (bool owner,) = IIporGateRoleP0(ACCESS_MANAGER).hasRole(1, DEPLOYER);
        require(owner, "IPOR OWNER role required to initialize governance gate");
        string memory output = vm.envOr("PHASE0_DEPLOYMENTS", string("deployments/katana-gate-v4.json"));
        require(!vm.exists(output), "V4 gate deployment record already exists; do not overwrite");
        _start();
        // Factory IPOR roles stay within IPOR Access Manager; only ADMIN_FEE is gate-local
        // so that IPOR ADMIN cannot override its self-administered membership.
        gate = new CurveYieldGovernanceGate(ACCESS_MANAGER, ADMIN_FEE_SAFE);
        _registerWithdrawManager();
        _registerAllocationLoop();
        _registerLend();
        _registerSplitPol();
        _registerCustodyRouter();
        gate.sealFeeConfiguration(); // Keep registry schema fixed; values remain ADMIN_FEE-editable.
        require(gate.feeConfigRegistrationSealed(), "fee registry must be sealed");
        _stop();
        string memory json = vm.serializeAddress("p0", "governanceGate", address(gate));
        vm.writeJson(json, output);
        console2.log("governance gate (config registry)", address(gate));
    }

    function _reg(bytes32 key_, uint8 class_, uint256 min_, uint256 max_, uint256 value_) internal {
        gate.registerConfig(key_, class_, min_, max_, value_);
        if (class_ == GUARDIAN) gate.setGuardianRange(key_, min_, max_);
    }

    function _rule(uint8 kind_, uint256 bound_, bytes32 a_, bytes32 b_) internal {
        bytes32[] memory k = new bytes32[](2);
        (k[0], k[1]) = (a_, b_);
        gate.addRule(kind_, bound_, k, address(0), bytes4(0));
    }

    function _rule3(uint8 kind_, uint256 bound_, bytes32 a_, bytes32 b_, bytes32 c_) internal {
        bytes32[] memory k = new bytes32[](3);
        (k[0], k[1], k[2]) = (a_, b_, c_);
        gate.addRule(kind_, bound_, k, address(0), bytes4(0));
    }

    function _rule4(uint8 kind_, uint256 bound_, bytes32 a_, bytes32 b_, bytes32 c_, bytes32 d_) internal {
        bytes32[] memory k = new bytes32[](4);
        (k[0], k[1], k[2], k[3]) = (a_, b_, c_, d_);
        gate.addRule(kind_, bound_, k, address(0), bytes4(0));
    }

    function _registerWithdrawManager() internal {
        _reg(K.WM_WITHDRAW_FEE, FEE, 0, 0.04e18, 0.009e18); // ONBOARDING_FEE_SPEC: 0.90% instant, 100% burned (was 1.25%)
        _reg(K.WM_REQUEST_FEE, FEE, 0, 0.125e18, IWmFeesP0(WM_OLD).getRequestFee()); // live 8.75%
        _reg(K.WM_SPLIT_BPS_0, FEE, 0, 5_000, 0);
        _reg(K.WM_SPLIT_BPS_1, FEE, 0, 5_000, 0);
        _reg(K.WM_SPLIT_BPS_2, FEE, 0, 5_000, 0);
        _rule3(SUM_LE, 7_500, K.WM_SPLIT_BPS_0, K.WM_SPLIT_BPS_1, K.WM_SPLIT_BPS_2);
    }

    function _registerAllocationLoop() internal {
        _reg(K.ALLOC_VAULT_FLOOR_BPS, GUARDIAN, 1_000, 5_000, 3_000);
        _reg(K.ALLOC_SEASONING_DAYS, DAO, 0, 14, 7);
        _reg(K.LOOP_ALLOCATION_BPS, GUARDIAN, 0, 8_000, 7_500);
        _reg(K.LOOP_RAMP_ZONE_BPS, DAO, 0, 5_000, 4_000);
        _reg(K.LOOP_BASE_WINDUP_PROFIT_BPS, DAO, 100, 1_000, 225);
        _reg(K.LOOP_RAMP_START_PROFIT_BPS, DAO, 300, 2_000, 300);
        _reg(K.LOOP_RAMP_END_PROFIT_BPS, DAO, 300, 2_000, 700);
        _rule(ORDER_LE, 0, K.LOOP_RAMP_START_PROFIT_BPS, K.LOOP_RAMP_END_PROFIT_BPS);
        _reg(K.LOOP_MIN_UNWIND_PROFIT_BPS, DAO, 10, 500, 40);
        _reg(K.LOOP_TARGET_LTV_BPS, DAO, 5_000, 7_600, 7_500);
        _reg(K.LOOP_EMERGENCY_TARGET_LTV_BPS, DAO, 5_000, 7_680, 7_620);
        _reg(K.LOOP_EMERGENCY_LTV_BPS, DAO, 5_001, 7_690, 7_660);
        _rule(ORDER_LE, 0, K.LOOP_TARGET_LTV_BPS, K.LOOP_EMERGENCY_TARGET_LTV_BPS);
        _rule(ORDER_LT, 0, K.LOOP_EMERGENCY_TARGET_LTV_BPS, K.LOOP_EMERGENCY_LTV_BPS);
        _reg(K.LOOP_LTV_TOLERANCE_BPS, DAO, 0, 500, 25);
        _reg(K.LOOP_MAX_CYCLES, DAO, 1, 16, 8);
    }

    function _registerLend() internal {
        _reg(K.LEND_CAP_BPS, GUARDIAN, 0, 5_500, 2_000);
        _reg(K.LEND_OWNERSHIP_TRIGGER_BPS, DAO, 500, 5_000, 2_000);
        _reg(K.LEND_DECAY_BPS, GUARDIAN, 0, 2_500, 1_000);
        _reg(K.LEND_DECAY_INTERVAL, DAO, 1 hours, 48 hours, 12 hours);
        _reg(K.LEND_LIQUIDITY_FLOOR_BPS, DAO, 0, 2_000, 300);
        _reg(K.LEND_OWNERSHIP_EXEMPT_AVKAT, DAO, 0, 50_000e18, 10_000e18);
    }

    function _registerSplitPol() internal {
        _reg(K.SPLIT_GROWTH_BPS, FEE, 0, 5_000, 3_500);
        _reg(K.SPLIT_CONTRIBUTORS_BPS, FEE, 0, 5_000, 2_000);
        _reg(K.SPLIT_VAULT_BPS, FEE, 0, 5_000, 2_000);
        _reg(K.SPLIT_REWARDS_MANAGER_BPS, FEE, 0, 5_000, 2_500);
        _rule4(SUM_EQ, 10_000, K.SPLIT_GROWTH_BPS, K.SPLIT_CONTRIBUTORS_BPS, K.SPLIT_VAULT_BPS, K.SPLIT_REWARDS_MANAGER_BPS);
        _reg(K.POL_CAP_BPS, GUARDIAN, 0, 1_000, 300);
        _reg(K.POL_TRIGGER_BPS, DAO, 50, 2_000, 300);
        _reg(K.POL_MIN_GAIN_BPS, DAO, 10, 1_000, 100);
        _rule(ORDER_LE, 0, K.POL_MIN_GAIN_BPS, K.POL_TRIGGER_BPS);
        _reg(K.POL_MAX_PER_RUN_BPS, DAO, 0, 2_500, 1_000);
        _reg(K.POL_BUYBACK_BUDGET_BPS, DAO, 0, 5_000, 3_500);
        _reg(K.POL_COOLDOWN, DAO, 1 hours, 7 days, 12 hours);
        _reg(K.POL_MIN_POL_PROFIT_BPS, DAO, 0, 500, 50);
        _reg(K.POL_MAX_CHARGE_DISCOUNT_BPS, DAO, 0, 1_500, 1_000);
        _reg(K.POL_MAX_SLIPPAGE_BPS, DAO, 10, 500, 100);
        _reg(K.POL_TWAP_WINDOW, DAO, 5 minutes, 1 days, 30 minutes);
        _reg(K.POL_IDLE_BUYBACK, DAO, 0, 1, 0);
        _reg(K.POL_MAX_IDLE_BPS, DAO, 0, 500, 100);
        _reg(K.POL_ADD_HAIRCUT_BPS, DAO, 0, 50, 1);
        _reg(K.POL_YIELD_FEE_BPS, FEE, 0, 2_000, 1_000);
        _reg(K.POLC_MAX_PREMIUM_BPS, DAO, 0, 200, 0);
    }

    function _registerCustodyRouter() internal {
        _reg(K.CUSTODY_REVENUE_SHARE_BPS, FEE, 0, 3_500, 3_000);
        _reg(K.CUSTODY_REWARD_MANAGER_BPS, FEE, 1_000, 3_000, 1_600);
        _reg(K.CUSTODY_FEE_RECIPIENT_BPS, FEE, 500, 2_000, 900);
        // custody allocation (CUSTODY_FARM_SPEC, user 2026-09-29): loop 30-80% (default 60%); farm deploy loss <= 0.1-3%
        _reg(K.CUSTODY_LOOP_TARGET_BPS, DAO, 3_000, 8_000, 6_000);
        _reg(K.FARM_MAX_DEPLOY_LOSS_BPS, DAO, 10, 300, 100);
        _reg(K.ROUTER_PROTECTION_BPS, DAO, 30, 300, 200);
        // keeper rewards: rate <= 1%, payout <= 10 avKAT (2026-09-29)
        _reg(K.EXEC_DEPLOY_REWARD_BPS, DAO, 0, 100, 20);
        _reg(K.EXEC_DEPLOY_REWARD_CAP, DAO, 0, 10e18, 10e18);
        _reg(K.EXEC_FULFIL_REWARD_BPS, DAO, 0, 100, 20);
        _reg(K.EXEC_FULFIL_REWARD_CAP, DAO, 0, 10e18, 10e18);
        _reg(K.ROUTER_TWAP_WINDOW, DAO, 1 minutes, 4 hours, 15 minutes);
        // IPOR_FUSE_CONFORMANCE_SPEC 4.3: USDC strategy: <= 10% of managed avKAT as collateral, target LTV 33%, guard ceiling 35%
        _reg(K.USDC_LOOP_MAX_TVL_BPS, DAO, 0, 5_000, 1_000);
        _reg(K.USDC_LOOP_TARGET_LTV_BPS, DAO, 1_000, 5_000, 3_300);
        _reg(K.USDC_LOOP_MAX_LTV_BPS, DAO, 1_000, 5_500, 3_500);
        _rule(ORDER_LE, 0, K.USDC_LOOP_TARGET_LTV_BPS, K.USDC_LOOP_MAX_LTV_BPS);
        // settings written as substrates (R5). UTS slippage: the POL sale may go below NAV within the request-fee headroom,
        // so the default sits above that headroom (4% > fee 3.9%); the router's protected minimum and each action's own
        // floor remain the real bounds. The live value (20%) comes down.
        _reg(K.SWAP_SLIPPAGE_WAD, DAO, 0.001e18, 0.2e18, 0.04e18);
        _reg(K.GUARD_MAX_PPS_DROP_BPS, DAO, 0, 1_000, 500); // ceiling of a bounded loss (withdrawal unwinds), bps of assets
        _reg(K.TRANSFER_MAX_PER_CALL_AVKAT, DAO, 1e18, 100e18, 10e18);
    }
}

interface IWmFeesP0 {
    function getWithdrawFee() external view returns (uint256);
    function getRequestFee() external view returns (uint256);
}

interface IIporGateRoleP0 { function hasRole(uint64 roleId, address account) external view returns (bool, uint32); }
