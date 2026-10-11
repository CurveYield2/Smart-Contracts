// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FuseAction} from "../interfaces/CurveYieldPhase2Interfaces.sol";
import {CurveYieldGateConfig, CurveYieldConfigKeys as K} from "../governance/CurveYieldGateConfig.sol";
import {CurveYieldMorphoLoopLib, CyLoopEnv, CyLoopSnapshot, CyUnwindPlan} from "./CurveYieldMorphoLoopLib.sol";
import {ICyStrategySet, ICyWithdrawManager, ICyErc20, ICyAvKat} from "../interfaces/CurveYieldPhase2Interfaces.sol";
import {CurveYieldBundleLib} from "../libraries/CurveYieldBundleLib.sol";
import {CurveYieldQuoteLib} from "../libraries/CurveYieldQuoteLib.sol";

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

interface ICySeasonedTotal {
    function seasonedManagedAvkat() external view returns (uint256);
}

/// @title CurveYieldMorphoLoopController (a PLANNER; vault market 14, Morpho market 0x80e6)
/// @notice Holds the loop's settings and PLANS: every plan is a bundle of IPOR's official fuses (Morpho collateral /
/// borrow / flash loan, UniversalTokenSwapperFuse through swap router v2) bracketed by the bundle guard. The adaptive
/// behaviour of the former loop fuses now lives in the executor, on-chain: it asks this planner for ONE cycle at a time
/// (`planCycle`) and wraps each in `try vault.execute`, stopping at the first cycle that reverts (IPOR_FUSE_CONFORMANCE_SPEC
/// B1). The wind-up swap buys avKAT (D12); there is no ERC-4626 deposit route. Wind-up profit is measured on the
/// conversion basis (D1) and enforced by the guard's `exit` (assets per share must rise by the cycle's required gain).
contract CurveYieldMorphoLoopController is ICyStrategySet, Ownable2Step, CurveYieldGateConfig {
    uint256 private constant BPS = 10_000;
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;
    uint256 public constant MIN_BORROW_KAT = 1e15; // a cycle stops below this borrow

    CyLoopEnv private _env;
    address public executor;
    address public allocation;

    error InvalidAddress();

    event ExecutorUpdated(address indexed executor);
    event AllocationUpdated(address indexed allocation);

    constructor(address owner_, CyLoopEnv memory env_, address configGate_)
        Ownable(owner_)
        CurveYieldGateConfig(configGate_)
    {
        if (
            env_.vault == address(0) || env_.morpho == address(0) || env_.avkat == address(0) ||
            env_.kat == address(0) || env_.collateralFuse == address(0) || env_.borrowFuse == address(0) ||
            env_.flashLoanFuse == address(0) || env_.swapFuse == address(0) || env_.router == address(0) ||
            env_.guardFuse == address(0) || env_.withdrawManager == address(0) ||
            env_.marketId == bytes32(0)
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

    /// @notice Wind-up cap on SEASONED avKAT (deposits count after seasoningDays), as the wind-up library computed it.
    function windupLimit() public view returns (uint256) {
        return ICySeasonedTotal(allocation).seasonedManagedAvkat() * params().allocationBps / BPS;
    }

    // ---------------------------------------------------------------- plans (ICyStrategySet)

    /// @notice #11: no wind-up while scheduled requests exist. #18: capacity 0 when at/over target, never a revert.
    /// The loop does not return a bundle here: the executor runs the cycles one at a time (`planCycle`) with the budget
    /// this returns, so the allocation controller can account for what the loop will draw.
    function planDeploy(uint256 budgetAvkat_, uint256)
        external view override returns (FuseAction[] memory actions_, uint256 consumedAvkat_)
    {
        if (budgetAvkat_ == 0 || hasScheduledRequests()) return (actions_, 0);
        uint256 limit = windupLimit();
        uint256 equity = CurveYieldMorphoLoopLib.snapshot(_env).netEquityAvkat;
        if (equity >= limit) return (actions_, 0);
        consumedAvkat_ = limit - equity;
        if (consumedAvkat_ > budgetAvkat_) consumedAvkat_ = budgetAvkat_;
    }

    /// @notice An over-target loop is not unwound (unwinding at a pool discount would lower PPS): it only stops
    /// taking new deploys and shrinks through scheduled withdrawals.
    function planReduce(uint256)
        external pure override returns (FuseAction[] memory actions_, uint256 releasedAvkat_)
    {
        return (actions_, releasedAvkat_);
    }

    /// @notice The loop is not an instant source; for scheduled withdrawals it unwinds within the loss buffer: ONE
    /// flash-loan bundle of official fuses, bracketed by the guard with the bounded loss (B3: no instant withdrawal).
    function planWithdraw(uint256 neededAvkat_, bool scheduled_)
        external view override returns (FuseAction[] memory actions_, uint256 providedAvkat_)
    {
        if (!scheduled_ || neededAvkat_ == 0) return (actions_, 0);
        CyLoopEnv memory e = _env;
        CyLoopSnapshot memory snap = CurveYieldMorphoLoopLib.snapshot(e);
        uint256 equity = snap.netEquityAvkat;
        providedAvkat_ = neededAvkat_ > equity ? equity : neededAvkat_;
        if (providedAvkat_ == 0) return (actions_, 0);
        // a withdrawal unwind is proportional: above target it keeps the current LTV instead of paying for a full
        // de-leverage (planCollateralTopUp does that swap-free); below target it unwinds to target as before
        uint16 target = params().targetLtvBps;
        if (snap.ltvBps > target) target = uint16(snap.ltvBps);
        CyUnwindPlan memory plan = CurveYieldMorphoLoopLib.planUnwind(e, snap, providedAvkat_, target);
        actions_ = CurveYieldMorphoLoopLib.unwindActions(e, plan);
        if (actions_.length == 0) return (actions_, 0);
        uint256 maxLoss = providedAvkat_ * allowedLossBps() / BPS;
        if (CurveYieldMorphoLoopLib.bookedUnwindLoss(e, plan.repayKat, plan.sellAvkat) > maxLoss) revert UnwindLossAboveFee();
        actions_ = CurveYieldBundleLib.wrapWithLoss(e.guardFuse, e.vault, actions_, maxLoss);
    }

    error UnwindLossAboveFee();

    /// @notice B1: ONE wind-up / re-lever cycle. `supplyAvkat_` = idle avKAT to add as collateral first (0 = pure
    /// re-lever, or while withdrawals wait). Borrows up to the target LTV, buys avKAT with the KAT through swap router v2
    /// and requires, through the guard, a gain of at least the profit the ramp asks at the resulting equity (#14). Empty
    /// when the cycle is below the minimum borrow or the router's protected minimum cannot clear the required profit.
    /// `directAvkat_` = the conversion value of the KAT borrowed (the gain is what the swap produced above it).
    function planCycle(uint256 supplyAvkat_)
        external view returns (FuseAction[] memory actions_, uint256 directAvkat_, uint256 requiredGainAvkat_)
    {
        CyLoopEnv memory e = _env;
        CyLoopSnapshot memory s = CurveYieldMorphoLoopLib.snapshot(e);
        uint256 price = CurveYieldMorphoLoopLib.oraclePrice(e);
        uint256 targetDebt = (s.collateralValueKat + supplyAvkat_ * price / ORACLE_PRICE_SCALE) * params().targetLtvBps / BPS;
        if (targetDebt <= s.debtKat + MIN_BORROW_KAT) return (actions_, 0, 0);
        uint256 borrow = targetDebt - s.debtKat;

        uint256 minimumOut = CurveYieldQuoteLib.minimumOut(e.router, e.kat, e.avkat, borrow);
        directAvkat_ = ICyAvKat(e.avkat).convertToShares(borrow);
        uint256 requiredBps = requiredWindupProfitBps(s.netEquityAvkat + supplyAvkat_, windupLimit());
        if (minimumOut <= directAvkat_ || (minimumOut - directAvkat_) * BPS < directAvkat_ * requiredBps) {
            return (actions_, 0, 0);
        }
        requiredGainAvkat_ = directAvkat_ * requiredBps / BPS;

        FuseAction[] memory cycle = new FuseAction[](supplyAvkat_ == 0 ? 2 : 3);
        uint256 k;
        if (supplyAvkat_ != 0) cycle[k++] = CurveYieldMorphoLoopLib.collateralAction(e, true, supplyAvkat_);
        cycle[k++] = CurveYieldMorphoLoopLib.borrowAction(e, true, borrow);
        cycle[k] = CurveYieldMorphoLoopLib.swapAction(e, e.kat, e.avkat, borrow, minimumOut);
        actions_ = CurveYieldBundleLib.wrapWithGain(e.guardFuse, e.vault, cycle, requiredGainAvkat_);
    }

    /// @notice #15: true when LTV has drifted below target by more than the tolerance (the executor then runs re-lever
    /// cycles with no new supply; while requests wait the produced avKAT stays idle for them).
    function needsRelever() external view returns (bool) {
        CyLoopSnapshot memory s = CurveYieldMorphoLoopLib.snapshot(_env);
        CyLoopParams memory p = params();
        return s.collateralAvkat != 0 && s.ltvBps + p.ltvRebalanceToleranceBps < p.targetLtvBps;
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
            uint256 limit = windupLimit();
            uint256 room = limit > s.netEquityAvkat ? limit - s.netEquityAvkat : 0;
            if (supply > room) supply = room;
        }
        actions_ = new FuseAction[]((repay != 0 ? 1 : 0) + (supply != 0 ? 1 : 0));
        uint256 k;
        if (repay != 0) actions_[k++] = CurveYieldMorphoLoopLib.borrowAction(e, false, repay);
        if (supply != 0) actions_[k] = CurveYieldMorphoLoopLib.collateralAction(e, true, supply);
    }

    /// @notice Emergency de-leverage; only above the emergency LTV. repayKat 0 = back down to the emergency target. Not
    /// guarded: the executor measures the loss and has the backstops (then the caller) pay it (PPS spec B5).
    function planEmergency(uint256 repayKat_) external view returns (FuseAction[] memory actions_) {
        CyLoopEnv memory e = _env;
        CyLoopSnapshot memory s = CurveYieldMorphoLoopLib.snapshot(e);
        CyLoopParams memory p = params();
        if (s.ltvBps <= p.emergencyLtvBps) return actions_;
        CyUnwindPlan memory plan;
        if (repayKat_ == 0) {
            plan = CurveYieldMorphoLoopLib.planDeleverage(e, s, p.emergencyTargetLtvBps);
        } else {
            if (repayKat_ > s.debtKat) revert InvalidRepayAmount(repayKat_, s.debtKat);
            plan = CurveYieldMorphoLoopLib.planPartialRepay(
                e, s, CurveYieldMorphoLoopLib.clampRepay(e, s, repayKat_, p.emergencyTargetLtvBps)
            );
        }
        actions_ = CurveYieldMorphoLoopLib.unwindActions(e, plan);
    }

    error InvalidRepayAmount(uint256 repay, uint256 debt);
}
