// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {FuseAction, ICyErc20, ICyAvKat, ICySwapFuse, ICyRewardsClaimManager} from "../interfaces/CurveYieldPhase2Interfaces.sol";
import {CurveYieldMorphoLoopLib, CyLoopEnv, CyLoopSnapshot, CyUnwindPlan} from "../morpho/CurveYieldMorphoLoopLib.sol";

struct LoopSplitLeg {
    address recipient; // typed substrate (3 << 160 | recipient)
    uint16 bps; // of each cycle's gain
}

struct LoopCycleData {
    bytes32 morphoMarketId;
    address collateralFuse;
    address borrowFuse;
    address swapFuse;
    uint256 idleBudget; // collateral token to add as new collateral (capped by the vault's balance); 0 = pure re-lever
    bool leaveProducedIdle; // keep bought collateral idle (re-lever while withdrawals wait)
    uint256 minBorrow;
    uint8 maxCycles;
    uint16 targetLtvBps;
    uint256 limit; // required-profit ramp reference (e.g. allocation x seasoned managed collateral)
    uint16 rampZoneBps;
    uint16 baseProfitBps;
    uint16 rampStartProfitBps;
    uint16 rampEndProfitBps;
    LoopSplitLeg[] profitSplit;
}

struct LoopCycleResult {
    uint256 cycles;
    uint256 suppliedIdle;
    uint256 borrowed;
    uint256 produced;
    uint256 profit;
    uint256 splitOut;
}

struct LoopUnwindData {
    bytes32 morphoMarketId;
    address collateralFuse;
    address borrowFuse;
    address flashLoanFuse;
    address swapFuse;
    uint8 mode; // 0 UNWIND (free `amount` collateral at targetLtv), 1 DELEVERAGE (to targetLtv), 2 PARTIAL (repay `amount`)
    uint256 amount;
    uint16 targetLtvBps;
    uint16 maxLossBps; // UNWIND: booked loss (conversion basis) <= amount x this
    uint16 minLtvBpsToAct; // DELEVERAGE / PARTIAL: only above this LTV (0 = always)
}

/// @notice Substrate checks shared by the generic loop fuses (market = IPOR MORPHO, 14):
///   the Morpho market id (IPOR's Morpho substrate, in MARKET_ID); component fuses `2 << 160 | fuse` and profit
///   recipients `3 << 160 | recipient` in SUBSTRATE_MARKET_ID.
/// Typed substrates live in a SUBSTRATE-ONLY market (the cyavKAT vault: 54, next to the vKAT list) so the vault's
/// accounting markets keep only IPOR's standard entries (the IPOR front end reads every market-14 substrate as a Morpho
/// market id and every market-7 substrate as a token).
/// The collateral must be an ERC-4626 whose asset is the loan token (e.g. avKAT / KAT).
abstract contract CurveYieldLoopFuseBase is IFuseCommon {
    uint256 public constant TYPE_COMPONENT = 2;
    uint256 public constant TYPE_RECIPIENT = 3;

    address public immutable VERSION;
    uint256 public immutable override MARKET_ID;
    address public immutable MORPHO;
    uint256 public immutable SUBSTRATE_MARKET_ID;

    error NotGranted(bytes32 substrate);
    error InvalidAddress();

    constructor(uint256 marketId_, address morpho_, uint256 substrateMarketId_) {
        if (morpho_ == address(0)) revert InvalidAddress();
        VERSION = address(this);
        MARKET_ID = marketId_;
        MORPHO = morpho_;
        SUBSTRATE_MARKET_ID = substrateMarketId_;
    }

    function typed(uint256 type_, address account_) public pure returns (bytes32) {
        return bytes32((type_ << 160) | uint256(uint160(account_)));
    }

    /// @dev Typed CurveYield substrates (components, recipients): the substrate-only market.
    function _require(bytes32 substrate_) internal view {
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(SUBSTRATE_MARKET_ID, substrate_)) revert NotGranted(substrate_);
    }

    /// @dev The loop environment for CurveYieldMorphoLoopLib, built from the call data and the Morpho market itself.
    function _env(bytes32 marketId_, address collateralFuse_, address borrowFuse_, address flashFuse_, address swapFuse_)
        internal view returns (CyLoopEnv memory env_)
    {
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, marketId_)) revert NotGranted(marketId_); // IPOR Morpho substrate
        _require(typed(TYPE_COMPONENT, collateralFuse_));
        _require(typed(TYPE_COMPONENT, borrowFuse_));
        _require(typed(TYPE_COMPONENT, swapFuse_));
        if (flashFuse_ != address(0)) _require(typed(TYPE_COMPONENT, flashFuse_));
        MarketParams memory mp = IMorpho(MORPHO).idToMarketParams(Id.wrap(marketId_));
        env_ = CyLoopEnv({
            vault: address(this), morpho: MORPHO, marketId: marketId_, avkat: mp.collateralToken, kat: mp.loanToken,
            collateralFuse: collateralFuse_, borrowFuse: borrowFuse_, flashLoanFuse: flashFuse_, swapFuse: swapFuse_,
            splitter: address(0), withdrawManager: address(0)
        });
    }
}

/// @title CurveYieldLoopCycleFuse (generic; replaces the wind-up and LTV re-lever fuses)
/// @notice Levers a Morpho loop cycle by cycle, exactly as CurveYieldMorphoWindupLib.run: each cycle borrows up to the
/// target LTV, quotes the swap (TWAP-guarded minimum), requires the profit given by the ramp at the current equity
/// (stops when the quote cannot clear it, reverts when the realised gain does not), swaps into more collateral, splits
/// the cycle's gain to the recipients and carries the rest into the next cycle.
contract CurveYieldLoopCycleFuse is CurveYieldLoopFuseBase {
    uint256 private constant BPS = 10_000;
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;

    event LoopCycled(address version, LoopCycleResult result);

    error ProfitBelowRequired(uint256 gain, uint256 required);
    error SplitAboveTotal(uint256 bps);

    constructor(uint256 marketId_, address morpho_, uint256 substrateMarketId_)
        CurveYieldLoopFuseBase(marketId_, morpho_, substrateMarketId_)
    {}

    function enter(LoopCycleData memory d_) external returns (LoopCycleResult memory r_) {
        CyLoopEnv memory env = _env(d_.morphoMarketId, d_.collateralFuse, d_.borrowFuse, address(0), d_.swapFuse);
        uint256 splitBps;
        for (uint256 i; i < d_.profitSplit.length; ++i) {
            _require(typed(TYPE_RECIPIENT, d_.profitSplit[i].recipient));
            splitBps += d_.profitSplit[i].bps;
        }
        if (splitBps > BPS) revert SplitAboveTotal(splitBps);

        uint256 idle = ICyErc20(env.avkat).balanceOf(address(this));
        uint256 idleLeft = d_.idleBudget > idle ? idle : d_.idleBudget;
        uint256 price = CurveYieldMorphoLoopLib.oraclePrice(env);
        uint256 carry;
        for (uint256 i; i < d_.maxCycles; ++i) {
            CyLoopSnapshot memory s = CurveYieldMorphoLoopLib.snapshot(env);
            uint256 supply = d_.leaveProducedIdle ? 0 : idleLeft + carry;
            uint256 targetDebt = (s.collateralValueKat + supply * price / ORACLE_PRICE_SCALE) * d_.targetLtvBps / BPS;
            if (targetDebt <= s.debtKat + d_.minBorrow) break;
            uint256 borrow = targetDebt - s.debtKat;

            (, uint256 minimumOut) = ICySwapFuse(env.swapFuse).quoteExactInput(env.kat, env.avkat, borrow);
            uint256 direct = ICyAvKat(env.avkat).convertToShares(borrow);
            uint256 requiredBps = _requiredProfitBps(d_, s.netEquityAvkat + supply);
            if (minimumOut <= direct || (minimumOut - direct) * BPS < direct * requiredBps) break;

            uint256 before = ICyErc20(env.avkat).balanceOf(address(this));
            FuseAction[] memory actions = new FuseAction[](supply == 0 ? 2 : 3);
            uint256 k;
            if (supply != 0) actions[k++] = CurveYieldMorphoLoopLib.collateralAction(env, true, supply);
            actions[k++] = CurveYieldMorphoLoopLib.borrowAction(env, true, borrow);
            actions[k] = CurveYieldMorphoLoopLib.swapAction(env, env.kat, env.avkat, borrow, minimumOut);
            CurveYieldMorphoLoopLib.executeMany(actions);

            uint256 produced = ICyErc20(env.avkat).balanceOf(address(this)) + supply - before;
            uint256 gain = produced > direct ? produced - direct : 0;
            uint256 requiredGain = direct * requiredBps / BPS;
            if (gain < requiredGain) revert ProfitBelowRequired(gain, requiredGain);
            uint256 out = _split(env.avkat, d_.profitSplit, gain);

            r_.suppliedIdle += idleLeft;
            r_.borrowed += borrow;
            r_.produced += produced;
            r_.profit += gain;
            r_.splitOut += out;
            r_.cycles = i + 1;
            idleLeft = 0;
            carry = produced - out;
        }
        emit LoopCycled(VERSION, r_);
    }

    /// @notice Same ramp as the loop controller's requiredWindupProfitBps (#14).
    function _requiredProfitBps(LoopCycleData memory d_, uint256 equity_) private pure returns (uint256) {
        if (d_.limit == 0) return d_.rampEndProfitBps;
        uint256 rampStart = d_.limit * (BPS - d_.rampZoneBps) / BPS;
        if (equity_ < rampStart || d_.rampZoneBps == 0) {
            return equity_ >= d_.limit ? d_.rampEndProfitBps : d_.baseProfitBps;
        }
        if (equity_ >= d_.limit) return d_.rampEndProfitBps;
        return d_.rampStartProfitBps
            + (uint256(d_.rampEndProfitBps) - d_.rampStartProfitBps) * (equity_ - rampStart) / (d_.limit - rampStart);
    }

    /// @dev Splits `gain_` to the legs (the rest stays in the loop); a leg that is the vault's IPOR rewards-claim
    /// manager is followed by updateBalance(), as CurveYieldProfitSplitLib does today.
    function _split(address token_, LoopSplitLeg[] memory legs_, uint256 gain_) private returns (uint256 out_) {
        if (gain_ == 0) return 0;
        address rcm = PlasmaVaultLib.getRewardsClaimManagerAddress();
        for (uint256 i; i < legs_.length; ++i) {
            uint256 amount = gain_ * legs_[i].bps / BPS;
            if (amount == 0) continue;
            if (!ICyErc20(token_).transfer(legs_[i].recipient, amount)) revert InvalidAddress();
            if (legs_[i].recipient == rcm) ICyRewardsClaimManager(rcm).updateBalance();
            out_ += amount;
        }
    }
}

/// @title CurveYieldLoopUnwindFuse (generic; replaces the unwind and emergency fuses)
/// @notice UNWIND frees `amount` collateral ending at the target LTV (secant search), DELEVERAGE returns to the target
/// LTV (fixed-point search), PARTIAL repays `amount` staying under LLTV — all exactly as CurveYieldMorphoLoopLib, then
/// the flash-loan unwind through IPOR MorphoFlashLoanFuse and the loan-token dust sweep.
contract CurveYieldLoopUnwindFuse is CurveYieldLoopFuseBase {
    uint256 private constant BPS = 10_000;

    event LoopUnwound(address version, uint8 mode, uint256 amount, uint256 repaid, uint256 sold, uint256 loss, uint256 ltvBefore);

    error PositionNotAboveTrigger(uint256 ltvBps, uint256 triggerBps);
    error InvalidRepayAmount(uint256 repay, uint256 debt);
    error InvalidMode(uint8 mode);

    constructor(uint256 marketId_, address morpho_, uint256 substrateMarketId_)
        CurveYieldLoopFuseBase(marketId_, morpho_, substrateMarketId_)
    {}

    function enter(LoopUnwindData memory d_) external returns (uint256 loss_) {
        CyLoopEnv memory env = _env(d_.morphoMarketId, d_.collateralFuse, d_.borrowFuse, d_.flashLoanFuse, d_.swapFuse);
        CyLoopSnapshot memory s = CurveYieldMorphoLoopLib.snapshot(env);
        CyUnwindPlan memory plan;
        if (d_.mode == 0) {
            if (d_.amount == 0) return 0;
            plan = CurveYieldMorphoLoopLib.planUnwind(env, s, d_.amount, d_.targetLtvBps);
            loss_ = CurveYieldMorphoLoopLib.enforceLoss(env, plan, d_.amount, d_.maxLossBps);
        } else if (d_.mode == 1 || d_.mode == 2) {
            if (d_.minLtvBpsToAct != 0 && s.ltvBps <= d_.minLtvBpsToAct) revert PositionNotAboveTrigger(s.ltvBps, d_.minLtvBpsToAct);
            if (d_.mode == 1) {
                plan = CurveYieldMorphoLoopLib.planDeleverage(env, s, d_.targetLtvBps);
            } else {
                if (d_.amount > s.debtKat) revert InvalidRepayAmount(d_.amount, s.debtKat);
                plan = CurveYieldMorphoLoopLib.planPartialRepay(env, s, _clampRepay(env, s, d_.amount, d_.targetLtvBps));
            }
        } else {
            revert InvalidMode(d_.mode);
        }
        CurveYieldMorphoLoopLib.performUnwind(env, plan);
        emit LoopUnwound(VERSION, d_.mode, d_.amount, plan.repayKat, plan.sellAvkat, loss_, s.ltvBps);
    }

    /// @dev PPS spec A4: PARTIAL repays at most what brings LTV down to `targetLtvBps_`: r = (D - t·Cv) / (1 - t·k), k =
    /// oracle value of one avKAT / the swap fuse's TWAP-floor KAT for one avKAT (the worst price the sale may get).
    function _clampRepay(CyLoopEnv memory env_, CyLoopSnapshot memory s_, uint256 amount_, uint256 targetLtvBps_)
        private view returns (uint256)
    {
        uint256 targetDebt = s_.collateralValueKat * targetLtvBps_ / BPS;
        if (s_.debtKat <= targetDebt) return 0;
        (, uint256 floorKat) = ICySwapFuse(env_.swapFuse).quoteExactInputView(env_.avkat, env_.kat, 1e18);
        if (floorKat == 0) return amount_;
        uint256 oracleKat = CurveYieldMorphoLoopLib.oraclePrice(env_) / 1e18; // KAT value of 1e18 avKAT (1e36 scale)
        uint256 tk = targetLtvBps_ * oracleKat / floorKat; // t·k in bps
        if (tk >= BPS) return amount_;
        uint256 maxRepay = (s_.debtKat - targetDebt) * BPS / (BPS - tk) + 1;
        return amount_ < maxRepay ? amount_ : maxRepay;
    }
}
