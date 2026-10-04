// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

interface ICurveYieldConfigGate {
    function getMany(bytes32[] calldata keys) external view returns (uint256[] memory values);
    function addr(bytes32 key) external view returns (address);
    function adminReceiver() external view returns (address);
}

/// @title CurveYieldGateConfig
/// @notice Base for contracts whose numerical settings live in the governance gate (GATE_CONFIG_SPEC): they read them
/// with one `getMany` call and never store them. The gate address can only be changed by the gate itself.
abstract contract CurveYieldGateConfig {
    address public configGate;

    event ConfigGateUpdated(address indexed gate);

    error NotConfigGate(address caller);
    error InvalidConfigGate();

    constructor(address gate_) {
        if (gate_ == address(0)) revert InvalidConfigGate();
        configGate = gate_;
        emit ConfigGateUpdated(gate_);
    }

    /// @notice Moves this contract to a new gate (called by the current gate only).
    function setConfigGate(address gate_) external {
        if (msg.sender != configGate) revert NotConfigGate(msg.sender);
        if (gate_ == address(0)) revert InvalidConfigGate();
        configGate = gate_;
        emit ConfigGateUpdated(gate_);
    }

    function _config(bytes32[] memory keys_) internal view returns (uint256[] memory) {
        return ICurveYieldConfigGate(configGate).getMany(keys_);
    }

    function _config1(bytes32 key_) internal view returns (uint256) {
        bytes32[] memory k = new bytes32[](1);
        k[0] = key_;
        return ICurveYieldConfigGate(configGate).getMany(k)[0];
    }

    /// @dev A stack-internal dependency, looked up in the gate's wiring registry at call time (GATE_CONFIG_SPEC §10).
    function _addr(bytes32 key_) internal view returns (address) {
        return ICurveYieldConfigGate(configGate).addr(key_);
    }
}

/// @title CurveYieldAddrKeys
/// @notice Wiring keys of the cyavKAT stack (GATE_CONFIG_SPEC §10): keccak256 of the key name.
library CurveYieldAddrKeys {
    bytes32 internal constant LP_CONTROLLER = keccak256("addr.lpController");
    bytes32 internal constant VKAT_CONTROLLER = keccak256("addr.vkatController");
    bytes32 internal constant WITHDRAW_MANAGER = keccak256("addr.withdrawManager");
    bytes32 internal constant REWARDS_CLAIM_MANAGER = keccak256("addr.rewardsClaimManager");
    bytes32 internal constant SWAP_ROUTER = keccak256("addr.swapRouter");
    bytes32 internal constant REVENUE_CUSTODY = keccak256("addr.revenueCustody");
    bytes32 internal constant LEADERBOARD = keccak256("addr.leaderboard");
    bytes32 internal constant REFERRALS = keccak256("addr.referrals");
    bytes32 internal constant LOOP_PROFIT_SPLITTER = keccak256("addr.loopProfitSplitter");
    bytes32 internal constant TRANSFER_FUSE = keccak256("addr.transferFuse");
    bytes32 internal constant PLUS_DEPOSIT_ROUTER = keccak256("addr.plusDepositRouter");
    bytes32 internal constant PLUS_CONTROLLER = keccak256("addr.plusController");
}

/// @title CurveYieldConfigKeys
/// @notice The gate keys of the cyavKAT system (GATE_CONFIG_SPEC §6): keccak256 of the key name.
library CurveYieldConfigKeys {
    // withdraw manager v2
    bytes32 internal constant WM_WITHDRAW_FEE = keccak256("wm.withdrawFee"); // WAD
    bytes32 internal constant WM_REQUEST_FEE = keccak256("wm.requestFee"); // WAD
    bytes32 internal constant WM_SPLIT_BPS_0 = keccak256("wm.feeSplitBps0");
    bytes32 internal constant WM_SPLIT_BPS_1 = keccak256("wm.feeSplitBps1");
    bytes32 internal constant WM_SPLIT_BPS_2 = keccak256("wm.feeSplitBps2");
    // allocation
    bytes32 internal constant ALLOC_VAULT_FLOOR_BPS = keccak256("alloc.vaultFloorBps");
    bytes32 internal constant ALLOC_SEASONING_DAYS = keccak256("alloc.seasoningDays");
    // loop
    bytes32 internal constant LOOP_ALLOCATION_BPS = keccak256("loop.allocationBps");
    bytes32 internal constant LOOP_RAMP_ZONE_BPS = keccak256("loop.rampZoneBps");
    bytes32 internal constant LOOP_BASE_WINDUP_PROFIT_BPS = keccak256("loop.baseWindupProfitBps");
    bytes32 internal constant LOOP_RAMP_START_PROFIT_BPS = keccak256("loop.rampStartProfitBps");
    bytes32 internal constant LOOP_RAMP_END_PROFIT_BPS = keccak256("loop.rampEndProfitBps");
    bytes32 internal constant LOOP_MIN_UNWIND_PROFIT_BPS = keccak256("loop.minUnwindProfitBps");
    bytes32 internal constant LOOP_TARGET_LTV_BPS = keccak256("loop.targetLtvBps");
    bytes32 internal constant LOOP_EMERGENCY_LTV_BPS = keccak256("loop.emergencyLtvBps");
    bytes32 internal constant LOOP_EMERGENCY_TARGET_LTV_BPS = keccak256("loop.emergencyTargetLtvBps");
    bytes32 internal constant LOOP_LTV_TOLERANCE_BPS = keccak256("loop.ltvRebalanceToleranceBps");
    bytes32 internal constant LOOP_MAX_CYCLES = keccak256("loop.maxCycles");
    // vKAT
    bytes32 internal constant VKAT_ALLOCATION_BPS = keccak256("vkat.allocationBps");
    bytes32 internal constant VKAT_NATIVE_EXIT_MAX_LTV_BPS = keccak256("vkat.nativeExitMaxLtvBps");
    bytes32 internal constant VKAT_DEPLOY_WINDOW = keccak256("vkat.deployWindow");
    // lending
    bytes32 internal constant LEND_CAP_BPS = keccak256("lend.capBps");
    bytes32 internal constant LEND_OWNERSHIP_TRIGGER_BPS = keccak256("lend.ownershipTriggerBps");
    bytes32 internal constant LEND_DECAY_BPS = keccak256("lend.decayBps");
    bytes32 internal constant LEND_DECAY_INTERVAL = keccak256("lend.decayInterval");
    bytes32 internal constant LEND_LIQUIDITY_FLOOR_BPS = keccak256("lend.liquidityFloorBps");
    bytes32 internal constant LEND_OWNERSHIP_EXEMPT_AVKAT = keccak256("lend.ownershipExemptAvkat");
    // Sushi LP holder
    bytes32 internal constant LP_MIN_BPS = keccak256("lp.minBps");
    bytes32 internal constant LP_MAX_BPS = keccak256("lp.maxBps");
    bytes32 internal constant LP_ADVANTAGE_START_BPS = keccak256("lp.advantageStartBps");
    bytes32 internal constant LP_ADVANTAGE_FULL_BPS = keccak256("lp.advantageFullBps");
    bytes32 internal constant LP_MIN_KAT_BPS = keccak256("lp.minKatBps");
    bytes32 internal constant LP_MIN_INSTANT_PROFIT_BPS = keccak256("lp.minInstantProfitBps");
    bytes32 internal constant LP_MIN_SCHEDULED_PROFIT_BPS = keccak256("lp.minScheduledProfitBps");
    bytes32 internal constant LP_TARGET_LTV_BPS = keccak256("lp.targetLtvBps");
    bytes32 internal constant LP_EMERGENCY_LTV_BPS = keccak256("lp.emergencyLtvBps");
    bytes32 internal constant LP_EMERGENCY_TARGET_LTV_BPS = keccak256("lp.emergencyTargetLtvBps");
    bytes32 internal constant LP_SLIPPAGE_BPS = keccak256("lp.slippageBps");
    bytes32 internal constant LP_YIELD_WINDOW = keccak256("lp.yieldWindow");
    // loop profit splitter
    bytes32 internal constant SPLIT_GROWTH_BPS = keccak256("split.growthBps");
    bytes32 internal constant SPLIT_CONTRIBUTORS_BPS = keccak256("split.contributorsBps");
    bytes32 internal constant SPLIT_VAULT_BPS = keccak256("split.vaultBps");
    bytes32 internal constant SPLIT_REWARDS_MANAGER_BPS = keccak256("split.rewardsManagerBps");
    // POL (position A)
    bytes32 internal constant POL_CAP_BPS = keccak256("pol.capBps");
    bytes32 internal constant POL_TRIGGER_BPS = keccak256("pol.triggerBps");
    bytes32 internal constant POL_MIN_GAIN_BPS = keccak256("pol.minGainBps");
    bytes32 internal constant POL_MAX_PER_RUN_BPS = keccak256("pol.maxPerRunBps");
    bytes32 internal constant POL_BUYBACK_BUDGET_BPS = keccak256("pol.buybackBudgetBps");
    bytes32 internal constant POL_COOLDOWN = keccak256("pol.cooldown");
    bytes32 internal constant POL_MIN_POL_PROFIT_BPS = keccak256("pol.minPolProfitBps");
    bytes32 internal constant POL_MAX_CHARGE_DISCOUNT_BPS = keccak256("pol.maxChargeDiscountBps");
    bytes32 internal constant POL_MAX_SLIPPAGE_BPS = keccak256("pol.maxSlippageBps");
    bytes32 internal constant POL_TWAP_WINDOW = keccak256("pol.twapWindow");
    bytes32 internal constant POL_IDLE_BUYBACK = keccak256("pol.idleBuyback"); // 0 / 1
    bytes32 internal constant POL_MAX_IDLE_BPS = keccak256("pol.maxIdleBps");
    bytes32 internal constant POL_ADD_HAIRCUT_BPS = keccak256("pol.addHaircutBps");
    bytes32 internal constant POL_YIELD_FEE_BPS = keccak256("pol.yieldFeeBps");
    // POL custody (position B) and feeder
    bytes32 internal constant POLC_TWAP_WINDOW = keccak256("polCustody.twapWindow");
    bytes32 internal constant POLC_MAX_SLIPPAGE_BPS = keccak256("polCustody.maxSlippageBps");
    bytes32 internal constant POLC_MAX_PREMIUM_BPS = keccak256("polCustody.maxPremiumBps");
    bytes32 internal constant POL_FEEDER_INCOMING_BPS = keccak256("polFeeder.incomingBps"); // growth leg -> POL custody
    bytes32 internal constant POL_FEEDER_YIELD_BPS = keccak256("polFeeder.yieldBps"); // custody fee leg -> POL custody
    // revenue custody v2
    bytes32 internal constant CUSTODY_REVENUE_SHARE_BPS = keccak256("custody.revenueShareBps");
    bytes32 internal constant CUSTODY_REWARD_MANAGER_BPS = keccak256("custody.rewardManagerDistributionBps");
    bytes32 internal constant CUSTODY_FEE_RECIPIENT_BPS = keccak256("custody.feeRecipientDistributionBps");
    // custody allocation (CUSTODY_FARM_SPEC): loop share of the custody's value; farm pro-rata deploy loss bound
    bytes32 internal constant CUSTODY_LOOP_TARGET_BPS = keccak256("custody.loopTargetBps");
    bytes32 internal constant FARM_MAX_DEPLOY_LOSS_BPS = keccak256("farm.maxDeployLossBps");
    // keeper rewards (replace the Caller Reward Fuse's per-action config): bps of the work basis + a per-payout cap
    bytes32 internal constant EXEC_DEPLOY_REWARD_BPS = keccak256("exec.deployRewardBps");
    bytes32 internal constant EXEC_DEPLOY_REWARD_CAP = keccak256("exec.deployRewardCap");
    bytes32 internal constant EXEC_FULFIL_REWARD_BPS = keccak256("exec.fulfilRewardBps");
    bytes32 internal constant EXEC_FULFIL_REWARD_CAP = keccak256("exec.fulfilRewardCap");
    bytes32 internal constant EXEC_HARVEST_REWARD_BPS = keccak256("exec.harvestRewardBps");
    bytes32 internal constant EXEC_HARVEST_REWARD_CAP = keccak256("exec.harvestRewardCap");
    // swap router v2
    bytes32 internal constant ROUTER_PROTECTION_BPS = keccak256("router.protectionBps");
    bytes32 internal constant ROUTER_TWAP_WINDOW = keccak256("router.twapWindow");
    /// @dev USDC_SUPPLY_LOOP_SPEC: share of harvested rewards (after the keeper reward) vested via the rewards claim manager
    bytes32 internal constant HARVEST_VEST_BPS = keccak256("harvest.vestBps");
    /// @dev USDC_SUPPLY_LOOP_SPEC: max avKAT collateral in the USDC supply loop, bps of the vault's total assets
    bytes32 internal constant USDC_LOOP_MAX_TVL_BPS = keccak256("usdcLoop.maxTvlBps");
    // governance / leaderboard / referrals
    bytes32 internal constant BOND_AMOUNT = keccak256("bond.bondAmount");
    bytes32 internal constant BOND_PROPOSER_REWARD = keccak256("bond.proposerReward");
    bytes32 internal constant BOND_INTAKE_WINDOW = keccak256("bond.intakeWindow");
    bytes32 internal constant VOTER_POOL = keccak256("voter.pool");
    bytes32 internal constant VOTER_DELEGATOR_HAIRCUT_BPS = keccak256("voter.delegatorHaircutBps");
    bytes32 internal constant VOTER_DELEGATEE_CUT_BPS = keccak256("voter.delegateeCutBps");
    bytes32 internal constant ENGAGEMENT_MIN_EPOCH_INTERVAL = keccak256("engagement.minEpochInterval");
    bytes32 internal constant LEADERBOARD_BUY_SPLIT_0 = keccak256("leaderboard.buySplit0");
    bytes32 internal constant LEADERBOARD_BUY_SPLIT_1 = keccak256("leaderboard.buySplit1");
    bytes32 internal constant LEADERBOARD_BUY_SPLIT_2 = keccak256("leaderboard.buySplit2");
    bytes32 internal constant LEADERBOARD_BUY_SPLIT_3 = keccak256("leaderboard.buySplit3");
    bytes32 internal constant REFERRALS_CLAIM_FEE = keccak256("referrals.claimFee");
}
