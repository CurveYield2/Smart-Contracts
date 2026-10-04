// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {
    HolderOpenData, HolderIncreaseData, HolderWithdrawData, HolderRebalanceData, HolderDeleverageData
} from "../generic/CurveYieldHolderFuses.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, MarketParams, Id, Market} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {IIrm} from "@morpho-org/morpho-blue/src/interfaces/IIrm.sol";
import {TickMath} from "contracts/fuses/uniswap/ext/TickMath.sol";
import {FuseAction, ICyStrategySet, ICyAvKat} from "../interfaces/CurveYieldPhase2Interfaces.sol";
import {CurveYieldGateConfig, CurveYieldConfigKeys as K, CurveYieldAddrKeys} from "../governance/CurveYieldGateConfig.sol";

interface ICyLpWithdrawFees {
    function getRequestFee() external view returns (uint256);
    function retainedWithdrawFeeBps() external view returns (uint256);
}
import {CurveYieldSushiLpHolder, CyLpPosition} from "./CurveYieldSushiLpHolder.sol";

struct CyLpParams {
    uint16 minBps; // allocation floor (D3: 2%)
    uint16 maxBps; // allocation ceiling (D3: 5%)
    uint16 advantageStartBps; // LP yield must beat lending by this much before rising above min (#19: +30%)
    uint16 advantageFullBps; // ... and by this much to reach max (#19: +100%)
    uint16 minKatBps; // lower tick moves down until KAT is at least this share of the position (5%)
    uint16 minInstantProfitBps; // instant exits: loss <= retained instant fee - this (the vault keeps this profit)
    uint16 minScheduledProfitBps; // scheduled exits: loss <= request fee - this
    uint16 targetLtvBps; // holder Morpho LTV (75%)
    uint16 emergencyLtvBps; // emergency only above this (76.6%)
    uint16 emergencyTargetLtvBps; // ... and only down to this (76.2%)
    uint16 slippageBps; // holder swaps (0.3%)
    uint32 yieldWindow; // trailing window for the LP yield (7 days)
}

/// @notice The generic holder fuses this controller plans for (fuse standardization). This controller is also the
/// holder fuses' hook: recordCheckpoint (vault context) and needsRebalance (the live re-check).
struct CyLpFuses {
    address open; // CurveYieldHolderOpenFuse
    address increase; // CurveYieldHolderIncreaseFuse
    address withdraw; // CurveYieldHolderWithdrawFuse
    address rebalance; // CurveYieldHolderRebalanceFuse
    address emergency; // CurveYieldHolderDeleverageFuse
}

/// @notice Sushi V3 1% avKAT/KAT LP set (#19, D3, D4). Holds settings, range rules and plans; the holder holds funds.
///
/// Range: upper = first 200-tick step strictly above the avKAT conversion rate; lower = step at/below the current tick,
/// moved down until KAT is >= `minKatBps` of the position. Rebalance when the optimal range differs by >= 1 step AND
/// closing returns at least the basis (D4). Allocation moves linearly from `minBps` (LP yield <= lending yield + 30%)
/// to `maxBps` (>= +100%).
contract CurveYieldSushiLpController is ICyStrategySet, Ownable2Step, CurveYieldGateConfig {

    uint256 private constant BPS = 10_000;
    int24 public constant TICK_SPACING = 200;
    uint256 private constant YEAR = 365 days;

    address public immutable VAULT;
    address public immutable AVKAT;
    IMorpho public immutable MORPHO;
    bytes32 public immutable LEND_MARKET; // yield benchmark (#19)
    /// @notice Wired in the gate (`CurveYieldAddrKeys.WITHDRAW_MANAGER`, GATE_CONFIG_SPEC §10). the vault's withdraw manager (fees for the exit loss limits)
    function WITHDRAW_MANAGER() public view returns (address) {
        return _addr(CurveYieldAddrKeys.WITHDRAW_MANAGER);
    }
    CyLpFuses private _fuses;
    CurveYieldSushiLpHolder public holder;
    address public executor;

    uint64 public anchorTime; // yield checkpoint
    uint192 public anchorValuePerBasis; // 1e18

    error InvalidAddress();
    error AlreadySet();
    error OnlyVault(address caller);
    error InvalidParams();

    event ExecutorUpdated(address indexed executor);
    event Wired(address holder, CyLpFuses fuses);
    event Checkpoint(uint256 valuePerBasis, uint256 at);

    constructor(
        address owner_, address vault_, address avkat_, address morpho_, bytes32 lendMarket_,
        address configGate_
    ) Ownable(owner_) CurveYieldGateConfig(configGate_) {
        if (vault_ == address(0) || avkat_ == address(0) || morpho_ == address(0)) {
            revert InvalidAddress();
        }
        VAULT = vault_;
        AVKAT = avkat_;
        MORPHO = IMorpho(morpho_);
        LEND_MARKET = lendMarket_;
    }

    // ---------------------------------------------------------------- configuration

    function setExecutor(address executor_) external onlyOwner {
        if (executor_ == address(0)) revert InvalidAddress();
        executor = executor_;
        emit ExecutorUpdated(executor_);
    }

    function wire(address holder_, CyLpFuses calldata fuses_) external onlyOwner {
        if (address(holder) != address(0)) revert AlreadySet();
        if (holder_ == address(0) || fuses_.open == address(0) || fuses_.increase == address(0) ||
            fuses_.withdraw == address(0) || fuses_.rebalance == address(0) || fuses_.emergency == address(0)) {
            revert InvalidAddress();
        }
        holder = CurveYieldSushiLpHolder(holder_);
        _fuses = fuses_;
        emit Wired(holder_, fuses_);
    }

    /// @notice The LP set's settings, read from the governance gate.
    function params() public view returns (CyLpParams memory p_) {
        bytes32[] memory k = new bytes32[](12);
        (k[0], k[1], k[2], k[3]) = (K.LP_MIN_BPS, K.LP_MAX_BPS, K.LP_ADVANTAGE_START_BPS, K.LP_ADVANTAGE_FULL_BPS);
        (k[4], k[5], k[6], k[7]) = (K.LP_MIN_KAT_BPS, K.LP_MIN_INSTANT_PROFIT_BPS, K.LP_MIN_SCHEDULED_PROFIT_BPS, K.LP_TARGET_LTV_BPS);
        (k[8], k[9], k[10], k[11]) = (K.LP_EMERGENCY_LTV_BPS, K.LP_EMERGENCY_TARGET_LTV_BPS, K.LP_SLIPPAGE_BPS, K.LP_YIELD_WINDOW);
        uint256[] memory v = _config(k);
        p_ = CyLpParams(
            uint16(v[0]), uint16(v[1]), uint16(v[2]), uint16(v[3]), uint16(v[4]), uint16(v[5]), uint16(v[6]),
            uint16(v[7]), uint16(v[8]), uint16(v[9]), uint16(v[10]), uint32(v[11])
        );
    }

    /// @notice Loss an INSTANT LP exit may take (bps of the basis withdrawn): the instant fee the vault keeps after any
    /// custody cut or split, minus minInstantProfitBps (0 if below), so the vault always keeps that profit.
    function instantLossBps() public view returns (uint256) {
        uint256 kept = ICyLpWithdrawFees(WITHDRAW_MANAGER()).retainedWithdrawFeeBps();
        uint256 keep = params().minInstantProfitBps;
        return kept > keep ? kept - keep : 0;
    }

    /// @notice Loss a SCHEDULED LP exit may take: request fee - minScheduledProfitBps (0 if below).
    function scheduledLossBps() public view returns (uint256) {
        uint256 fee = ICyLpWithdrawFees(WITHDRAW_MANAGER()).getRequestFee() * BPS / 1e18;
        uint256 keep = params().minScheduledProfitBps;
        return fee > keep ? fee - keep : 0;
    }

    function fuses() external view returns (CyLpFuses memory) {
        return _fuses;
    }

    /// @notice Read by the holder for every deploy / swap.
    function holderSettings() external view returns (uint256 targetLtvBps_, uint256 slippageBps_) {
        return (params().targetLtvBps, params().slippageBps);
    }

    /// @notice Yield checkpoint, called by the LP fuses (vault context) after each action.
    function recordCheckpoint() external {
        if (msg.sender != VAULT) revert OnlyVault(msg.sender);
        uint256 vpb = valuePerBasis();
        if (anchorTime == 0 || block.timestamp >= uint256(anchorTime) + params().yieldWindow || vpb == 0) {
            anchorTime = uint64(block.timestamp);
            anchorValuePerBasis = uint192(vpb);
            emit Checkpoint(vpb, block.timestamp);
        }
    }

    // ---------------------------------------------------------------- valuation

    /// @notice Net holder value in avKAT on the conversion basis (vault accounting, D1).
    function managedAvkat() public view override returns (uint256) {
        if (address(holder) == address(0)) return 0;
        CyLpPosition memory p = holder.position();
        uint256 kat = p.lpKat + p.idleKat;
        uint256 avkat = p.lpAvkat + p.collateralAvkat + p.idleAvkat;
        uint256 debtAvkat = ICyAvKat(AVKAT).previewWithdraw(p.debtKat);
        uint256 katAvkat = kat == 0 ? 0 : ICyAvKat(AVKAT).convertToShares(kat);
        return avkat + katAvkat > debtAvkat ? avkat + katAvkat - debtAvkat : 0;
    }

    /// @notice What closing everything would return in avKAT at the pool price after the 1% fee both ways (D4).
    function closeValueAvkat() public view returns (uint256) {
        if (address(holder) == address(0)) return 0;
        CyLpPosition memory p = holder.position();
        uint256 avkat = p.lpAvkat + p.collateralAvkat + p.idleAvkat;
        uint256 kat = p.lpKat + p.idleKat;
        uint256 price = _poolPriceX18(); // KAT per avKAT
        if (kat >= p.debtKat) return avkat + Math.mulDiv(kat - p.debtKat, 1e18 * 99, price * 100);
        uint256 cost = Math.mulDiv(p.debtKat - kat, 1e18 * 100, price * 99);
        return avkat > cost ? avkat - cost : 0;
    }

    function valuePerBasis() public view returns (uint256) {
        uint256 basis = address(holder) == address(0) ? 0 : holder.basisAvkat();
        return basis == 0 ? 0 : managedAvkat() * 1e18 / basis;
    }

    /// @notice Trailing LP yield (bps per year) since the checkpoint anchor; 0 until a window has passed.
    function lpYieldBps() public view returns (uint256) {
        uint256 anchorVpb = anchorValuePerBasis;
        if (anchorVpb == 0 || block.timestamp <= anchorTime) return 0;
        uint256 dt = block.timestamp - anchorTime;
        if (dt < params().yieldWindow / 7) return 0; // need at least a day of a 7-day window
        uint256 vpb = valuePerBasis();
        if (vpb <= anchorVpb) return 0;
        return (vpb - anchorVpb) * BPS * YEAR / anchorVpb / dt;
    }

    /// @notice Lending supply APY proxy (bps per year) of market 0x5c60: borrowRate * utilization * (1 - fee).
    function lendYieldBps() public view returns (uint256) {
        MarketParams memory mp = MORPHO.idToMarketParams(Id.wrap(LEND_MARKET));
        Market memory m = MORPHO.market(Id.wrap(LEND_MARKET));
        if (m.totalSupplyAssets == 0 || mp.irm == address(0)) return 0;
        uint256 ratePerSecond = IIrm(mp.irm).borrowRateView(mp, m);
        uint256 borrowApr = ratePerSecond * YEAR * BPS / 1e18;
        uint256 util = uint256(m.totalBorrowAssets) * 1e18 / m.totalSupplyAssets;
        return borrowApr * util / 1e18 * (1e18 - m.fee) / 1e18;
    }

    /// @notice #19: min until LP yield beats lending by `advantageStartBps`, linear to max at `advantageFullBps`.
    function targetAllocationBps() public view returns (uint256) {
        CyLpParams memory p = params();
        uint256 lp = lpYieldBps();
        uint256 lend = lendYieldBps();
        if (lp == 0) return p.minBps;
        uint256 advantage = lend == 0 ? type(uint256).max : (lp > lend ? (lp - lend) * BPS / lend : 0);
        if (advantage <= p.advantageStartBps) return p.minBps;
        if (advantage >= p.advantageFullBps) return p.maxBps;
        return p.minBps + (uint256(p.maxBps) - p.minBps) * (advantage - p.advantageStartBps)
            / (uint256(p.advantageFullBps) - p.advantageStartBps);
    }

    function allocationBps() external view override returns (uint256) {
        return targetAllocationBps();
    }

    // ---------------------------------------------------------------- range

    /// @notice Optimal [lower, upper) for the current prices; `valid_` false when the pool trades at/above the upper.
    function optimalRange() public view returns (int24 lower_, int24 upper_, bool valid_) {
        uint256 conversion = ICyAvKat(AVKAT).convertToAssets(1e18); // KAT per avKAT
        uint160 sqrtConv = uint160(Math.sqrt(Math.mulDiv(conversion, 1 << 192, 1e18)));
        int24 convTick = TickMath.getTickAtSqrtRatio(sqrtConv);
        upper_ = _floorTick(convTick) + TICK_SPACING; // first step strictly above the conversion tick
        int24 tick = holder.currentTick();
        if (tick >= upper_) return (0, upper_, false);
        lower_ = _floorTick(tick);
        for (uint256 i; i < 50 && holder.katShareBps(lower_, upper_) < params().minKatBps; ++i) {
            lower_ -= TICK_SPACING;
        }
        valid_ = true;
    }

    /// @notice Off the optimal range by >= 1 step AND closing returns at least the basis (D4).
    function needsRebalance() public view returns (bool) {
        if (address(holder) == address(0) || holder.tokenId() == 0) return false;
        (, int24 upper, bool valid) = optimalRange();
        if (!valid) return false;
        // Hysteresis: only when the conversion edge moved or the price left the range. Drift inside the range (e.g.
        // from the holder's own rebalance swap on a thin pool) does not re-trigger, so rebalances cannot churn.
        int24 tick = holder.currentTick();
        bool offRange = tick < holder.tickLower() || tick >= holder.tickUpper();
        if (upper == holder.tickUpper() && !offRange) return false;
        return closeValueAvkat() >= holder.basisAvkat();
    }

    // ---------------------------------------------------------------- plans

    function planDeploy(uint256 budgetAvkat_, uint256 managedTotal_)
        external view override returns (FuseAction[] memory actions_, uint256 consumedAvkat_)
    {
        if (address(holder) == address(0) || budgetAvkat_ == 0) return (actions_, 0);
        (int24 lower, int24 upper, bool valid) = optimalRange();
        if (!valid) return (actions_, 0);
        uint256 target = managedTotal_ * targetAllocationBps() / BPS;
        uint256 current = managedAvkat();
        if (current >= target) return (actions_, 0);
        consumedAvkat_ = target - current;
        if (consumedAvkat_ > budgetAvkat_) consumedAvkat_ = budgetAvkat_;
        if (consumedAvkat_ < 1e18) return (new FuseAction[](0), 0);
        actions_ = new FuseAction[](1);
        actions_[0] = holder.tokenId() == 0
            ? FuseAction(_fuses.open, abi.encodeWithSignature(
                "enter((address,uint256,int24,int24,address))",
                HolderOpenData(address(holder), consumedAvkat_, lower, upper, address(this))
            ))
            : FuseAction(_fuses.increase, abi.encodeWithSignature(
                "enter((address,uint256,address))", HolderIncreaseData(address(holder), consumedAvkat_, address(this))
            ));
    }

    /// @notice Rebalance when off-optimal and profitable; reduce an over-target position within the 1% gate.
    function planReduce(uint256 managedTotal_)
        external view override returns (FuseAction[] memory actions_, uint256 releasedAvkat_)
    {
        if (address(holder) == address(0) || holder.tokenId() == 0) return (actions_, 0);
        if (needsRebalance()) {
            (int24 lower, int24 upper,) = optimalRange();
            actions_ = new FuseAction[](1);
            actions_[0] = FuseAction(_fuses.rebalance, abi.encodeWithSignature(
                "enter((address,int24,int24,address,address))",
                HolderRebalanceData(address(holder), lower, upper, address(this), address(this))
            ));
            return (actions_, 0);
        }
        uint256 target = managedTotal_ * targetAllocationBps() / BPS;
        uint256 current = managedAvkat();
        if (current <= target || current == 0) return (actions_, 0);
        releasedAvkat_ = current - target;
        uint256 bps = Math.mulDiv(releasedAvkat_, BPS, current, Math.Rounding.Ceil);
        actions_ = new FuseAction[](1);
        actions_[0] = _withdrawAction(bps, 0); // reductions have no fee to pay a loss: none allowed
    }

    /// @notice Withdraw the needed share; instant uses the 1% gate, scheduled the 4% gate (#19).
    function planWithdraw(uint256 neededAvkat_, bool scheduled_)
        external view override returns (FuseAction[] memory actions_, uint256 providedAvkat_)
    {
        if (address(holder) == address(0) || holder.tokenId() == 0 || neededAvkat_ == 0) return (actions_, 0);
        uint256 current = managedAvkat();
        if (current == 0) return (actions_, 0);
        providedAvkat_ = neededAvkat_ > current ? current : neededAvkat_;
        uint256 bps = Math.mulDiv(providedAvkat_, BPS, current, Math.Rounding.Ceil);
        uint256 gate = scheduled_ ? scheduledLossBps() : instantLossBps();
        actions_ = new FuseAction[](1);
        actions_[0] = _withdrawAction(bps, gate);
    }

    /// @notice Instant withdrawals (through CurveYieldPlannedInstantWithdrawFuse): the standard 1% gate, pre-checked
    /// against the estimated close value so a hopeless attempt is not even planned (as the Phase 2 instant hook).
    function planInstantWithdraw(uint256 neededAvkat_) external view returns (FuseAction[] memory actions_) {
        if (address(holder) == address(0) || holder.tokenId() == 0 || neededAvkat_ == 0) return actions_;
        uint256 basis = holder.basisAvkat();
        if (basis == 0) return actions_;
        uint256 bps = Math.mulDiv(neededAvkat_, BPS, basis, Math.Rounding.Ceil);
        if (bps > BPS) bps = BPS;
        uint256 estimate = closeValueAvkat() * bps / BPS;
        uint256 basisShare = basis * bps / BPS;
        uint256 lossBps = instantLossBps();
        if (estimate + basisShare * lossBps / BPS < basisShare) return actions_;
        actions_ = new FuseAction[](1);
        actions_[0] = _withdrawAction(bps, lossBps);
    }

    function _withdrawAction(uint256 bps_, uint256 gateBps_) private view returns (FuseAction memory) {
        return FuseAction(_fuses.withdraw, abi.encodeWithSignature(
            "enter((address,uint256,uint256,bool,address))",
            HolderWithdrawData(address(holder), bps_, gateBps_, true, address(this))
        ));
    }

    function planEmergency() external view returns (FuseAction[] memory actions_) {
        if (address(holder) == address(0) || holder.position().ltvBps <= params().emergencyLtvBps) return actions_;
        actions_ = new FuseAction[](1);
        actions_[0] = FuseAction(_fuses.emergency, abi.encodeWithSignature(
            "enter((address,uint256,uint256))",
            HolderDeleverageData(address(holder), params().emergencyLtvBps, params().emergencyTargetLtvBps)
        ));
    }

    // ---------------------------------------------------------------- internal

    function _floorTick(int24 tick_) private pure returns (int24) {
        int24 q = tick_ / TICK_SPACING;
        if (tick_ < 0 && tick_ % TICK_SPACING != 0) q -= 1;
        return q * TICK_SPACING;
    }

    function _poolPriceX18() private view returns (uint256) {
        int24 tick = holder.currentTick();
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(tick);
        return Math.mulDiv(uint256(sqrtP) * uint256(sqrtP), 1e18, 1 << 192);
    }

}
