// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FuseAction} from "../interfaces/CurveYieldPhase2Interfaces.sol";
import {LoopCycleData, LoopUnwindData, LoopSplitLeg} from "../generic/CurveYieldLoopFuses.sol";
import {CurveYieldGateConfig, CurveYieldConfigKeys as K} from "../governance/CurveYieldGateConfig.sol";
import {CurveYieldMorphoLoopLib, CyLoopEnv, CyLoopSnapshot} from "./CurveYieldMorphoLoopLib.sol";
import {ICyStrategySet, ICyWithdrawManager, ICyErc20} from "../interfaces/CurveYieldPhase2Interfaces.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Settings of the loop, read from the governance gate (GATE_CONFIG_SPEC: ranges, hard caps and classes there).
struct CyLoopParams {
    uint16 allocationBps; // loop share of total managed avKAT
    uint16 rampZoneBps; // last share of the loop allocation where the required profit ramps up (#14)
    uint16 baseWindupProfitBps; // required below the ramp zone (#14: 2.25%)
    uint16 rampStartProfitBps; // required at the start of the ramp zone (#14: 3%)
    uint16 rampEndProfitBps; // required at the end of the ramp zone (#14: 7%)
    uint16 minUnwindProfitBps; // part of the request fee the vault always keeps; unwind loss <= request fee - this
    uint16 targetLtvBps;
    uint16 emergencyLtvBps; // emergency de-leverage only above this (spec: 76.6%)
    uint16 emergencyTargetLtvBps; // emergency de-leverages down to this (spec: 76.2%, a small, cheap shift)
    uint16 ltvRebalanceToleranceBps; // re-lever only when LTV is this far below target
    uint8 maxCycles;
}

/// @notice The generic loop fuses this controller plans for (fuse standardization: stateless, IPOR style; every
/// parameter comes from this controller's bounded settings in the call data). Set once after deployment.
struct CyLoopFuses {
    address cycle; // CurveYieldLoopCycleFuse (wind-up, LTV re-lever)
    address unwind; // CurveYieldLoopUnwindFuse (unwind, emergency de-leverage / partial repay)
}

interface ICyLoopSplitterView {
    function growthBps() external view returns (uint16);
    function contributorsBps() external view returns (uint16);
    function rewardsManagerBps() external view returns (uint16);
    function growthCustody() external view returns (address);
    function contributorsRecipient() external view returns (address);
    function REWARDS_CLAIM_MANAGER() external view returns (address);
}

/// @notice Morpho avKAT/KAT loop controller (vault market 14, Morpho market 0x80e6). Holds settings and PLANS: every
/// plan is a call to a generic loop fuse with explicit parameters. Wind-up profit is measured on the conversion basis (D1).
interface ICySeasonedTotal {
    function seasonedManagedAvkat() external view returns (uint256);
}

contract CurveYieldMorphoLoopController is ICyStrategySet, Ownable2Step, CurveYieldGateConfig {

    uint256 private constant BPS = 10_000;
    uint256 public constant MIN_BORROW_KAT = 1e15; // a cycle stops below this borrow (as the Phase 2 fuses)

    CyLoopEnv private _env;
    CyLoopFuses private _fuses;
    address public executor;
    address public allocation;

    error InvalidAddress();
    error FusesAlreadySet();
    error InvalidRampProfits(uint256 start, uint256 end);
    error EmergencyBelowTarget(uint256 emergency, uint256 target);

    event ParamsUpdated(CyLoopParams params);
    event ExecutorUpdated(address indexed executor);
    event AllocationUpdated(address indexed allocation);
    event FusesSet(CyLoopFuses fuses);

    constructor(address owner_, CyLoopEnv memory env_, address configGate_)
        Ownable(owner_)
        CurveYieldGateConfig(configGate_)
    {
        if (
            env_.vault == address(0) || env_.morpho == address(0) || env_.avkat == address(0) ||
            env_.kat == address(0) || env_.collateralFuse == address(0) || env_.borrowFuse == address(0) ||
            env_.flashLoanFuse == address(0) || env_.swapFuse == address(0) || env_.splitter == address(0) ||
            env_.withdrawManager == address(0) || env_.marketId == bytes32(0)
        ) revert InvalidAddress();
        _env = env_;
    }

    // ---------------------------------------------------------------- configuration

    function setExecutor(address executor_) external onlyOwner {
        if (executor_ == address(0)) revert InvalidAddress();
        executor = executor_;
        emit ExecutorUpdated(executor_);
    }

    function setAllocation(address allocation_) external onlyOwner {
        if (allocation_ == address(0)) revert InvalidAddress();
        allocation = allocation_;
        emit AllocationUpdated(allocation_);
    }

    /// @notice One-time wiring of the loop fuses (each fuse's constructor takes this controller's address).
    function setFuses(CyLoopFuses calldata fuses_) external onlyOwner {
        if (_fuses.cycle != address(0)) revert FusesAlreadySet();
        if (fuses_.cycle == address(0) || fuses_.unwind == address(0)) revert InvalidAddress();
        _fuses = fuses_;
        emit FusesSet(fuses_);
    }

    function env() external view returns (CyLoopEnv memory) {
        return _env;
    }

    /// @notice The loop's settings, read from the governance gate in one call.
    function params() public view returns (CyLoopParams memory p_) {
        bytes32[] memory k = new bytes32[](11);
        (k[0], k[1], k[2], k[3]) = (K.LOOP_ALLOCATION_BPS, K.LOOP_RAMP_ZONE_BPS, K.LOOP_BASE_WINDUP_PROFIT_BPS, K.LOOP_RAMP_START_PROFIT_BPS);
        (k[4], k[5], k[6], k[7]) = (K.LOOP_RAMP_END_PROFIT_BPS, K.LOOP_MIN_UNWIND_PROFIT_BPS, K.LOOP_TARGET_LTV_BPS, K.LOOP_EMERGENCY_LTV_BPS);
        (k[8], k[9], k[10]) = (K.LOOP_EMERGENCY_TARGET_LTV_BPS, K.LOOP_LTV_TOLERANCE_BPS, K.LOOP_MAX_CYCLES);
        uint256[] memory v = _config(k);
        p_ = CyLoopParams({
            allocationBps: uint16(v[0]), rampZoneBps: uint16(v[1]), baseWindupProfitBps: uint16(v[2]),
            rampStartProfitBps: uint16(v[3]), rampEndProfitBps: uint16(v[4]), minUnwindProfitBps: uint16(v[5]),
            targetLtvBps: uint16(v[6]), emergencyLtvBps: uint16(v[7]), emergencyTargetLtvBps: uint16(v[8]),
            ltvRebalanceToleranceBps: uint16(v[9]), maxCycles: uint8(v[10])
        });
    }

    /// @notice Unwind loss a scheduled fulfilment may take, bps of the avKAT released: request fee - minUnwindProfit
    /// (0 when the fee is below it), so no setting can make a fulfilment lower PPS (GATE_CONFIG_SPEC §6b).
    function allowedLossBps() public view returns (uint256) {
        uint256 feeBps = ICyWithdrawManager(_env.withdrawManager).getRequestFee() * BPS / 1e18;
        uint256 keep = params().minUnwindProfitBps;
        return feeBps > keep ? feeBps - keep : 0;
    }

    function fuses() external view returns (CyLoopFuses memory) {
        return _fuses;
    }

    // ---------------------------------------------------------------- views

    function snapshot() public view returns (CyLoopSnapshot memory) {
        return CurveYieldMorphoLoopLib.snapshot(_env);
    }

    function managedAvkat() external view override returns (uint256) {
        return CurveYieldMorphoLoopLib.snapshot(_env).netEquityAvkat;
    }

    function allocationBps() external view override returns (uint256) {
        return params().allocationBps;
    }

    /// @notice Required wind-up profit (bps of the conversion value of the KAT borrowed) at a given loop equity (#14).
    /// Below the ramp zone: base. Inside it: linear from rampStart to rampEnd. At or above the limit: rampEnd.
    function requiredWindupProfitBps(uint256 equityAvkat_, uint256 limitAvkat_) public view returns (uint256) {
        CyLoopParams memory p = params();
        if (limitAvkat_ == 0) return p.rampEndProfitBps;
        uint256 rampStart = limitAvkat_ * (BPS - p.rampZoneBps) / BPS;
        if (equityAvkat_ < rampStart || p.rampZoneBps == 0) {
            return equityAvkat_ >= limitAvkat_ ? p.rampEndProfitBps : p.baseWindupProfitBps;
        }
        if (equityAvkat_ >= limitAvkat_) return p.rampEndProfitBps;
        return p.rampStartProfitBps +
            (uint256(p.rampEndProfitBps) - p.rampStartProfitBps) * (equityAvkat_ - rampStart) / (limitAvkat_ - rampStart);
    }


    function hasScheduledRequests() public view returns (bool) {
        return ICyWithdrawManager(_env.withdrawManager).activeUnreleasedShares() != 0;
    }

    // ---------------------------------------------------------------- plans (ICyStrategySet)

    /// @notice #11: no wind-up while scheduled requests exist. #18: capacity 0 when at/over target, never a revert.
    function planDeploy(uint256 budgetAvkat_, uint256 managedTotal_)
        external view override returns (FuseAction[] memory actions_, uint256 consumedAvkat_)
    {
        if (budgetAvkat_ == 0 || hasScheduledRequests()) return (actions_, 0);
        // wind-up cap on SEASONED avKAT (deposits count after seasoningDays); managedTotal_ still sizes reduce/withdraw
        managedTotal_;
        uint256 limit = _windupLimit();
        uint256 equity = CurveYieldMorphoLoopLib.snapshot(_env).netEquityAvkat;
        if (equity >= limit) return (actions_, 0);
        consumedAvkat_ = limit - equity;
        if (consumedAvkat_ > budgetAvkat_) consumedAvkat_ = budgetAvkat_;
        actions_ = new FuseAction[](1);
        actions_[0] = _cycleAction(consumedAvkat_, false, limit);
    }

    /// @notice An over-target loop is not unwound (unwinding at a pool discount would lower PPS): it only stops
    /// taking new deploys and shrinks through scheduled withdrawals.
    function planReduce(uint256)
        external pure override returns (FuseAction[] memory actions_, uint256 releasedAvkat_)
    {
        return (actions_, releasedAvkat_);
    }

    /// @notice The loop is not an instant source; for scheduled withdrawals it unwinds within the loss buffer.
    function planWithdraw(uint256 neededAvkat_, bool scheduled_)
        external view override returns (FuseAction[] memory actions_, uint256 providedAvkat_)
    {
        if (!scheduled_ || neededAvkat_ == 0) return (actions_, 0);
        CyLoopSnapshot memory snap = CurveYieldMorphoLoopLib.snapshot(_env);
        uint256 equity = snap.netEquityAvkat;
        providedAvkat_ = neededAvkat_ > equity ? equity : neededAvkat_;
        if (providedAvkat_ == 0) return (actions_, 0);
        // a withdrawal unwind is proportional: above target it keeps the current LTV instead of paying for a full
        // de-leverage (planCollateralTopUp does that swap-free); below target it unwinds to target as before
        uint16 target = params().targetLtvBps;
        if (snap.ltvBps > target) target = uint16(snap.ltvBps);
        actions_ = new FuseAction[](1);
        actions_[0] = _unwindAction(0, providedAvkat_, target, uint16(allowedLossBps()), 0);
    }

    /// @notice #15: re-lever when LTV has drifted below target. The fuse leaves the proceeds idle for scheduled
    /// withdrawals when requests exist, otherwise re-supplies them.
    function planLtvRebalance() external view returns (FuseAction[] memory actions_) {
        CyLoopSnapshot memory s = CurveYieldMorphoLoopLib.snapshot(_env);
        if (s.collateralAvkat == 0 || s.ltvBps + params().ltvRebalanceToleranceBps >= params().targetLtvBps) {
            return actions_;
        }
        actions_ = new FuseAction[](1);
        actions_[0] = _cycleAction(0, hasScheduledRequests(), _windupLimit());
    }

    /// @notice PPS spec B5.1: free de-leverage when LTV is above target + tolerance. Repays debt with idle KAT, then
    /// supplies idle avKAT as collateral with no new borrow, just enough to return to target. Never lifts loop equity
    /// above its allocation cap (the seasoned wind-up limit). No swap: the share price cannot drop.
    function planCollateralTopUp() external view returns (FuseAction[] memory actions_) {
        CyLoopEnv memory e = _env;
        CyLoopSnapshot memory s = CurveYieldMorphoLoopLib.snapshot(e);
        CyLoopParams memory p = params();
        if (s.collateralAvkat == 0 || s.ltvBps <= uint256(p.targetLtvBps) + p.ltvRebalanceToleranceBps) return actions_;
        uint256 repay = ICyErc20(e.kat).balanceOf(e.vault);
        if (repay > s.debtKat) repay = s.debtKat;
        uint256 debtAfter = s.debtKat - repay;
        uint256 supply;
        uint256 targetValue = debtAfter * BPS / p.targetLtvBps; // collateral value (KAT) the target needs
        if (targetValue > s.collateralValueKat) {
            supply = Math.mulDiv(targetValue - s.collateralValueKat, 1e36, CurveYieldMorphoLoopLib.oraclePrice(e), Math.Rounding.Ceil);
            uint256 idle = ICyErc20(e.avkat).balanceOf(e.vault);
            if (supply > idle) supply = idle;
            uint256 limit = _windupLimit();
            uint256 room = limit > s.netEquityAvkat ? limit - s.netEquityAvkat : 0;
            if (supply > room) supply = room;
        }
        actions_ = new FuseAction[]((repay != 0 ? 1 : 0) + (supply != 0 ? 1 : 0));
        uint256 k;
        if (repay != 0) actions_[k++] = CurveYieldMorphoLoopLib.borrowAction(e, false, repay);
        if (supply != 0) actions_[k] = CurveYieldMorphoLoopLib.collateralAction(e, true, supply);
    }

    /// @notice Emergency de-leverage; only above the emergency LTV. repayKat 0 = back down to the emergency target.
    function planEmergency(uint256 repayKat_) external view returns (FuseAction[] memory actions_) {
        if (CurveYieldMorphoLoopLib.snapshot(_env).ltvBps <= params().emergencyLtvBps) return actions_;
        actions_ = new FuseAction[](1);
        actions_[0] = repayKat_ == 0
            ? _unwindAction(1, 0, params().emergencyTargetLtvBps, 0, params().emergencyLtvBps)
            : _unwindAction(2, repayKat_, params().emergencyTargetLtvBps, 0, params().emergencyLtvBps);
    }

    // ---------------------------------------------------------------- generic fuse calls

    /// @dev Wind-up cap on SEASONED avKAT, as the wind-up library computed it.
    function _windupLimit() private view returns (uint256) {
        return ICySeasonedTotal(allocation).seasonedManagedAvkat() * params().allocationBps / BPS;
    }

    function _cycleAction(uint256 idleBudget_, bool leaveProducedIdle_, uint256 limit_) private view returns (FuseAction memory) {
        CyLoopParams memory p = params();
        LoopCycleData memory d;
        d.morphoMarketId = _env.marketId;
        d.collateralFuse = _env.collateralFuse;
        d.borrowFuse = _env.borrowFuse;
        d.swapFuse = _env.swapFuse;
        d.idleBudget = idleBudget_;
        d.leaveProducedIdle = leaveProducedIdle_;
        d.minBorrow = MIN_BORROW_KAT;
        d.maxCycles = p.maxCycles;
        d.targetLtvBps = p.targetLtvBps;
        d.limit = limit_;
        d.rampZoneBps = p.rampZoneBps;
        d.baseProfitBps = p.baseWindupProfitBps;
        d.rampStartProfitBps = p.rampStartProfitBps;
        d.rampEndProfitBps = p.rampEndProfitBps;
        d.profitSplit = _splitLegs();
        return FuseAction(_fuses.cycle, abi.encodeWithSignature(
            "enter((bytes32,address,address,address,uint256,bool,uint256,uint8,uint16,uint256,uint16,uint16,uint16,uint16,(address,uint16)[]))",
            d
        ));
    }

    function _unwindAction(uint8 mode_, uint256 amount_, uint16 targetLtvBps_, uint16 maxLossBps_, uint16 minLtvBpsToAct_)
        private view returns (FuseAction memory)
    {
        LoopUnwindData memory d = LoopUnwindData({
            morphoMarketId: _env.marketId, collateralFuse: _env.collateralFuse, borrowFuse: _env.borrowFuse,
            flashLoanFuse: _env.flashLoanFuse, swapFuse: _env.swapFuse, mode: mode_, amount: amount_,
            targetLtvBps: targetLtvBps_, maxLossBps: maxLossBps_, minLtvBpsToAct: minLtvBpsToAct_
        });
        return FuseAction(_fuses.unwind, abi.encodeWithSignature(
            "enter((bytes32,address,address,address,address,uint8,uint256,uint16,uint16,uint16))", d
        ));
    }

    /// @dev The #16 profit split as transfer legs (read live from the splitter: growth custody, contributors, rewards
    /// manager; the vault share stays in the loop).
    function _splitLegs() private view returns (LoopSplitLeg[] memory legs_) {
        ICyLoopSplitterView sp = ICyLoopSplitterView(_env.splitter);
        legs_ = new LoopSplitLeg[](3);
        legs_[0] = LoopSplitLeg(sp.growthCustody(), sp.growthBps());
        legs_[1] = LoopSplitLeg(sp.contributorsRecipient(), sp.contributorsBps());
        legs_[2] = LoopSplitLeg(sp.REWARDS_CLAIM_MANAGER(), sp.rewardsManagerBps());
    }

    // ---------------------------------------------------------------- internal

}
