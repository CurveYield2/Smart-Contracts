// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {CurveYieldGovernanceGate} from "../src/governance/CurveYieldGovernanceGate.sol";
import {CurveYieldConfigKeys as K} from "../src/governance/CurveYieldGateConfig.sol";

/// Phase 0 (GATE_CONFIG_SPEC): deploy the governance gate FIRST and register every numerical setting of the cyavKAT
/// system with its immutable hard caps, class, default and group rules. Every Phase 2-5 contract then reads the gate.
///   - The deployer is DAO and fee authority for setup only. P3_03 / P3_04 hand the gate to the DAO and the fee Safe
///     (setDao, setFeeAuthority(FEE_SAFE, true)); the finalize step removes the deployer (setFeeAuthority(deployer,
///     false)) after P4 / P5 have added their rules (the leaderboard season lock needs the leaderboard address).
///   - Hard caps are today's hard-coded limits plus the 2026-09-29 decisions (withdraw fee <= 4%, request fee <= 12.5%,
///     voter cuts <= 80%, POL feeder <= 30%, POL buyback budget <= 50% / per run <= 25%, minGain >= 0.1%, router
///     protection 0.3-3%, TWAP window 1 min-4 h, bond 10-10,000 cyavKAT, min-profit settings 0.1-5%).
///   - Defaults = the live / approved values (fees read from the live withdraw manager).
/// Writes deployments/katana-gate.json (PHASE0_DEPLOYMENTS overrides).
///   forge script script/P0_00_DeployGateConfig.s.sol --root <phase2 path> --rpc-url katana     # dry run
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
        _start();
        gate = new CurveYieldGovernanceGate(DEPLOYER, DEPLOYER);
        _registerWithdrawManager();
        _registerAllocationLoopVkat();
        _registerLendLp();
        _registerSplitPol();
        _registerCustodyRouter();
        _registerGovernance();
        gate.setAdminReceiver(ADMIN_FEE_SAFE); // harvest admin share (fee authority only)
        _stop();
        string memory json = vm.serializeAddress("p0", "governanceGate", address(gate));
        vm.writeJson(json, vm.envOr("PHASE0_DEPLOYMENTS", string("deployments/katana-gate.json")));
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

    function _registerAllocationLoopVkat() internal {
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
        _reg(K.VKAT_ALLOCATION_BPS, GUARDIAN, 0, 9_000, 0);
        _reg(K.VKAT_NATIVE_EXIT_MAX_LTV_BPS, DAO, 7_500, 7_620, 7_620);
        _reg(K.VKAT_DEPLOY_WINDOW, DAO, 0, 7 days, 3 days);
    }

    function _registerLendLp() internal {
        _reg(K.LEND_CAP_BPS, GUARDIAN, 0, 5_500, 2_000);
        _reg(K.LEND_OWNERSHIP_TRIGGER_BPS, DAO, 500, 5_000, 2_000);
        _reg(K.LEND_DECAY_BPS, GUARDIAN, 0, 2_500, 1_000);
        _reg(K.LEND_DECAY_INTERVAL, DAO, 1 hours, 48 hours, 12 hours);
        _reg(K.LEND_LIQUIDITY_FLOOR_BPS, DAO, 0, 2_000, 300);
        _reg(K.LEND_OWNERSHIP_EXEMPT_AVKAT, DAO, 0, 50_000e18, 10_000e18);
        _reg(K.LP_MIN_BPS, DAO, 0, 5_500, 200);
        _reg(K.LP_MAX_BPS, GUARDIAN, 0, 5_500, 500);
        _rule(ORDER_LE, 0, K.LP_MIN_BPS, K.LP_MAX_BPS);
        _reg(K.LP_ADVANTAGE_START_BPS, DAO, 0, 50_000, 3_000);
        _reg(K.LP_ADVANTAGE_FULL_BPS, DAO, 0, 50_000, 10_000);
        _rule(ORDER_LE, 0, K.LP_ADVANTAGE_START_BPS, K.LP_ADVANTAGE_FULL_BPS);
        _reg(K.LP_MIN_KAT_BPS, DAO, 0, 2_000, 500);
        _reg(K.LP_MIN_INSTANT_PROFIT_BPS, DAO, 10, 500, 25); // 0.25% (user, 2026-09-29)
        _reg(K.LP_MIN_SCHEDULED_PROFIT_BPS, DAO, 10, 500, 40);
        _reg(K.LP_TARGET_LTV_BPS, DAO, 5_000, 7_690, 7_500);
        _reg(K.LP_EMERGENCY_TARGET_LTV_BPS, DAO, 5_000, 7_690, 7_620);
        _reg(K.LP_EMERGENCY_LTV_BPS, DAO, 5_000, 7_690, 7_660);
        _rule(ORDER_LE, 0, K.LP_TARGET_LTV_BPS, K.LP_EMERGENCY_TARGET_LTV_BPS);
        _rule(ORDER_LT, 0, K.LP_EMERGENCY_TARGET_LTV_BPS, K.LP_EMERGENCY_LTV_BPS);
        _reg(K.LP_SLIPPAGE_BPS, DAO, 0, 100, 30);
        _reg(K.LP_YIELD_WINDOW, DAO, 1 days, 30 days, 7 days);
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
        _reg(K.POLC_TWAP_WINDOW, DAO, 5 minutes, 1 days, 30 minutes);
        _reg(K.POLC_MAX_SLIPPAGE_BPS, DAO, 10, 500, 100);
        _reg(K.POLC_MAX_PREMIUM_BPS, DAO, 0, 200, 0);
        _reg(K.POL_FEEDER_INCOMING_BPS, FEE, 0, 3_000, 2_000);
        _reg(K.POL_FEEDER_YIELD_BPS, FEE, 0, 3_000, 1_500);
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
        _reg(K.EXEC_HARVEST_REWARD_BPS, DAO, 0, 100, 20);
        _reg(K.EXEC_HARVEST_REWARD_CAP, DAO, 0, 10e18, 5e18);
        _reg(K.ROUTER_TWAP_WINDOW, DAO, 1 minutes, 4 hours, 15 minutes);
        // USDC_SUPPLY_LOOP_SPEC: harvest split 10% admin (fixed) / 60% vesting / 30% custody; vesting 10%..90%
        _reg(K.HARVEST_VEST_BPS, DAO, 1_000, 9_000, 6_000);
        _reg(K.USDC_LOOP_MAX_TVL_BPS, DAO, 0, 5_000, 3_000); // USDC supply loop: <= 30% of TVL as collateral
    }

    function _registerGovernance() internal {
        _reg(K.BOND_AMOUNT, DAO, 10e20, 10_000e20, 200e20); // cyavKAT (20 decimals)
        _reg(K.BOND_PROPOSER_REWARD, DAO, 0, 1_000e18, 100e18);
        _reg(K.BOND_INTAKE_WINDOW, DAO, 1 days, 30 days, 7 days);
        _reg(K.VOTER_POOL, DAO, 0, 1_000e18, 100e18);
        _reg(K.VOTER_DELEGATOR_HAIRCUT_BPS, DAO, 0, 8_000, 5_000);
        _reg(K.VOTER_DELEGATEE_CUT_BPS, DAO, 0, 8_000, 2_000);
        _reg(K.ENGAGEMENT_MIN_EPOCH_INTERVAL, DAO, 1 days, 90 days, 7 days);
        _reg(K.LEADERBOARD_BUY_SPLIT_0, FEE, 0, 5_000, 3_000); // admin leg
        _reg(K.LEADERBOARD_BUY_SPLIT_1, DAO, 0, 5_000, 4_000);
        _reg(K.LEADERBOARD_BUY_SPLIT_2, DAO, 0, 5_000, 2_000);
        _reg(K.LEADERBOARD_BUY_SPLIT_3, DAO, 0, 5_000, 1_000);
        _rule4(SUM_EQ, 10_000, K.LEADERBOARD_BUY_SPLIT_0, K.LEADERBOARD_BUY_SPLIT_1, K.LEADERBOARD_BUY_SPLIT_2, K.LEADERBOARD_BUY_SPLIT_3);
        _reg(K.REFERRALS_CLAIM_FEE, FEE, 0, 100e20, 0);
    }
}

interface IWmFeesP0 {
    function getWithdrawFee() external view returns (uint256);
    function getRequestFee() external view returns (uint256);
}
