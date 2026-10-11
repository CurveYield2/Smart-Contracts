// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {
    MorphoCollateralFuse, MorphoCollateralFuseEnterData, MorphoCollateralFuseExitData
} from "contracts/fuses/morpho/MorphoCollateralFuse.sol";
import {
    MorphoBorrowFuse, MorphoBorrowFuseEnterData, MorphoBorrowFuseExitData
} from "contracts/fuses/morpho/MorphoBorrowFuse.sol";
import {MorphoFlashLoanFuse, MorphoFlashLoanFuseEnterData} from "contracts/fuses/morpho/MorphoFlashLoanFuse.sol";
import {FuseAction, ICyAvKat, ICyMorphoOracle} from "../interfaces/CurveYieldPhase2Interfaces.sol";
import {CurveYieldQuoteLib} from "../libraries/CurveYieldQuoteLib.sol";
import {CurveYieldUtsLib} from "../libraries/CurveYieldUtsLib.sol";

/// @notice Addresses the loop works with (Katana: Morpho 0xD50F…, market 0x80e6…, avKAT, KAT, IPOR's Morpho collateral /
/// borrow / flash-loan fuses, IPOR's UniversalTokenSwapperFuse and swap router v2, the bundle guard).
struct CyLoopEnv {
    address vault;
    address morpho;
    bytes32 marketId;
    address avkat;
    address kat;
    address collateralFuse; // IPOR MorphoCollateralFuse (market 14)
    address borrowFuse; // IPOR MorphoBorrowFuse (market 14)
    address flashLoanFuse; // IPOR MorphoFlashLoanFuse (market 19), unmodified
    address swapFuse; // IPOR UniversalTokenSwapperFuse (market 12); its only router Target is `router`
    address router; // CurveYieldSwapRouterV2
    address guardFuse; // CurveYieldBundleGuardFuse
    address withdrawManager;
}

struct CyLoopSnapshot {
    uint256 collateralAvkat;
    uint256 debtKat;
    uint256 collateralValueKat;
    uint256 ltvBps;
    uint256 netEquityAvkat;
}

struct CyUnwindPlan {
    uint256 repayKat;
    uint256 withdrawAvkat;
    uint256 sellAvkat;
}

/// @notice Loop math and bundle builders (pure views). Every action is an IPOR fuse call: Morpho collateral / borrow /
/// flash loan, and UniversalTokenSwapperFuse through swap router v2. Snapshot, repay-for-withdrawal and the unwind
/// searches come from the audited CurveYieldMorphoStrategyFuse; quotes now come from the router's protected quote.
library CurveYieldMorphoLoopLib {
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant BPS = 10_000;
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;
    uint256 private constant MAX_SEARCH_ITERATIONS = 12;

    error InsufficientMorphoCollateral();
    error UnwindNotSafe();

    // ------------------------------------------------------------ views

    function snapshot(CyLoopEnv memory env_) internal view returns (CyLoopSnapshot memory s_) {
        IMorpho morpho = IMorpho(env_.morpho);
        Id id = Id.wrap(env_.marketId);
        MarketParams memory params = morpho.idToMarketParams(id);
        s_.collateralAvkat = morpho.position(id, env_.vault).collateral;
        s_.debtKat = morpho.expectedBorrowAssets(params, env_.vault);
        s_.collateralValueKat =
            Math.mulDiv(s_.collateralAvkat, ICyMorphoOracle(params.oracle).price(), ORACLE_PRICE_SCALE);
        s_.ltvBps = s_.collateralValueKat == 0 ? 0 : s_.debtKat * BPS / s_.collateralValueKat;
        uint256 debtInAvkat = s_.debtKat == 0 ? 0 : ICyAvKat(env_.avkat).previewWithdraw(s_.debtKat);
        s_.netEquityAvkat = s_.collateralAvkat > debtInAvkat ? s_.collateralAvkat - debtInAvkat : 0;
    }

    function oraclePrice(CyLoopEnv memory env_) internal view returns (uint256) {
        MarketParams memory params = IMorpho(env_.morpho).idToMarketParams(Id.wrap(env_.marketId));
        return ICyMorphoOracle(params.oracle).price();
    }

    function lltv(CyLoopEnv memory env_) internal view returns (uint256) {
        return IMorpho(env_.morpho).idToMarketParams(Id.wrap(env_.marketId)).lltv;
    }

    /// @notice KAT that must be repaid so the position stays at `targetLtvBps_` after withdrawing `withdrawAvkat_`.
    function repayRequiredForWithdrawal(CyLoopSnapshot memory s_, uint256 withdrawAvkat_, uint256 targetLtvBps_)
        internal pure returns (uint256)
    {
        if (withdrawAvkat_ > s_.collateralAvkat) revert InsufficientMorphoCollateral();
        uint256 remainingValue = s_.collateralAvkat == 0 ? 0 : Math.mulDiv(
            s_.collateralAvkat - withdrawAvkat_, s_.collateralValueKat, s_.collateralAvkat
        );
        uint256 targetDebt = remainingValue * targetLtvBps_ / BPS;
        return s_.debtKat > targetDebt ? s_.debtKat - targetDebt : 0;
    }

    /// @notice Booked loss of selling `sellAvkat_` to repay `repayKat_` of debt, on the conversion basis (D1).
    function bookedUnwindLoss(CyLoopEnv memory env_, uint256 repayKat_, uint256 sellAvkat_)
        internal view returns (uint256)
    {
        if (repayKat_ == 0) return 0;
        uint256 debtAvkat = ICyAvKat(env_.avkat).previewWithdraw(repayKat_);
        return sellAvkat_ > debtAvkat ? sellAvkat_ - debtAvkat : 0;
    }

    // ------------------------------------------------------------ unwind planning (router quotes)

    /// @notice Unwind that frees `neededAvkat_` net while ending at the target LTV (from _planWithdrawalUnwind).
    function planUnwind(CyLoopEnv memory env_, CyLoopSnapshot memory s_, uint256 neededAvkat_, uint256 targetLtvBps_)
        internal view returns (CyUnwindPlan memory plan_)
    {
        if (neededAvkat_ == 0) return plan_;
        // Solve gap(W) = needed + sell(W) - W = 0 by secant. At 75% LTV each withdrawn avKAT needs ~0.8 avKAT sold and
        // the ratio rises with pool price impact, so plain fixed-point iteration (the audited v1 search) closes only
        // ~20% of the gap per step and cannot converge for large unwinds.
        uint256 cap = s_.collateralAvkat;
        if (neededAvkat_ >= cap) revert InsufficientMorphoCollateral();
        uint256 w0 = neededAvkat_;
        int256 g0 = _unwindGap(env_, s_, neededAvkat_, w0, targetLtvBps_);
        uint256 withdraw = w0;
        if (g0 > 0) {
            uint256 w1 = w0 + uint256(g0) * 5; // ~ needed / (1 - 0.8): a second point on the far side
            if (w1 >= cap) w1 = cap - 1;
            int256 g1 = _unwindGap(env_, s_, neededAvkat_, w1, targetLtvBps_);
            uint256 tolerance = neededAvkat_ / 1_000 + 1;
            for (uint256 i; i < MAX_SEARCH_ITERATIONS && !(g1 <= 0 && uint256(-g1) <= tolerance); ++i) {
                if (g1 == g0) break;
                int256 next = int256(w1) - g1 * (int256(w1) - int256(w0)) / (g1 - g0);
                if (next <= int256(neededAvkat_)) next = int256(neededAvkat_) + 1;
                if (next >= int256(cap)) next = int256(cap) - 1;
                (w0, g0) = (w1, g1);
                w1 = uint256(next);
                g1 = _unwindGap(env_, s_, neededAvkat_, w1, targetLtvBps_);
            }
            if (g1 > 0) revert InsufficientMorphoCollateral();
            withdraw = w1;
        }
        plan_.repayKat = repayRequiredForWithdrawal(s_, withdraw, targetLtvBps_);
        plan_.sellAvkat =
            plan_.repayKat == 0 ? 0 : _requiredInput(env_, plan_.repayKat, s_.collateralAvkat);
        plan_.withdrawAvkat = withdraw;
        if (withdraw < neededAvkat_ + plan_.sellAvkat) revert UnwindNotSafe();
    }

    /// @notice De-leverage to target without releasing avKAT (from _planEmergencyFull).
    function planDeleverage(CyLoopEnv memory env_, CyLoopSnapshot memory s_, uint256 targetLtvBps_)
        internal view returns (CyUnwindPlan memory plan_)
    {
        // Fixed point W = sell(repay(W)); repay(W) = a + b*W with a = repay(0) and b = target * KAT value per avKAT.
        // With c = sell/repay from one probe, W0 = c*a / (1 - c*b); then refine (same convergence issue as planUnwind).
        uint256 withdraw;
        {
            uint256 repay0 = repayRequiredForWithdrawal(s_, 0, targetLtvBps_);
            if (repay0 == 0) return plan_;
            uint256 sell0 = _requiredInput(env_, repay0, s_.collateralAvkat);
            uint256 cb = Math.mulDiv(sell0 * targetLtvBps_, s_.collateralValueKat, repay0 * BPS * s_.collateralAvkat / 1e18);
            if (cb >= 1e18) revert UnwindNotSafe();
            withdraw = Math.mulDiv(sell0, 1e18, 1e18 - cb, Math.Rounding.Ceil);
            if (withdraw >= s_.collateralAvkat) revert UnwindNotSafe();
        }
        for (uint256 i; i < MAX_SEARCH_ITERATIONS; ++i) {
            uint256 repay = repayRequiredForWithdrawal(s_, withdraw, targetLtvBps_);
            uint256 sell = repay == 0 ? 0 : _requiredInput(env_, repay, s_.collateralAvkat);
            if (sell <= withdraw + withdraw / 10_000 + 1) break; // 0.01%: each requiredInput is a binary search of quotes
            withdraw = sell;
            if (withdraw >= s_.collateralAvkat) revert UnwindNotSafe();
        }
        plan_.repayKat = repayRequiredForWithdrawal(s_, withdraw, targetLtvBps_);
        plan_.sellAvkat =
            plan_.repayKat == 0 ? 0 : _requiredInput(env_, plan_.repayKat, s_.collateralAvkat);
        plan_.withdrawAvkat = plan_.sellAvkat;
    }

    /// @notice Repay a fixed KAT amount, selling just enough collateral; must stay under LLTV (from _planEmergencyPartial).
    function planPartialRepay(CyLoopEnv memory env_, CyLoopSnapshot memory s_, uint256 repayKat_)
        internal view returns (CyUnwindPlan memory plan_)
    {
        uint256 sell = _requiredInput(env_, repayKat_, s_.collateralAvkat);
        if (sell >= s_.collateralAvkat) revert UnwindNotSafe();
        uint256 remainingValue = s_.collateralValueKat - Math.mulDiv(sell, s_.collateralValueKat, s_.collateralAvkat);
        if (s_.debtKat - repayKat_ > Math.mulDiv(remainingValue, lltv(env_), 1e18)) revert UnwindNotSafe();
        plan_ = CyUnwindPlan(repayKat_, sell, sell);
    }

    /// @dev PPS spec A4: PARTIAL repays at most what brings LTV down to `targetLtvBps_`: r = (D - t·Cv) / (1 - t·k), k =
    /// oracle value of one avKAT / the router's protected-minimum KAT for one avKAT (the worst price the sale may get).
    function clampRepay(CyLoopEnv memory env_, CyLoopSnapshot memory s_, uint256 amount_, uint256 targetLtvBps_)
        internal view returns (uint256)
    {
        uint256 targetDebt = s_.collateralValueKat * targetLtvBps_ / BPS;
        if (s_.debtKat <= targetDebt) return 0;
        uint256 floorKat = CurveYieldQuoteLib.minimumOut(env_.router, env_.avkat, env_.kat, 1e18);
        if (floorKat == 0) return amount_;
        uint256 oracleKat = oraclePrice(env_) / 1e18; // KAT value of 1e18 avKAT (1e36 scale)
        uint256 tk = targetLtvBps_ * oracleKat / floorKat; // t·k in bps
        if (tk >= BPS) return amount_;
        uint256 maxRepay = (s_.debtKat - targetDebt) * BPS / (BPS - tk) + 1;
        return amount_ < maxRepay ? amount_ : maxRepay;
    }

    // ------------------------------------------------------------ bundle builders (IPOR fuses)

    /// @notice Flash-borrow KAT, repay debt, withdraw collateral, sell avKAT to cover the flash: ONE action (the official
    /// MorphoFlashLoanFuse runs the callback actions itself). No dust sweep: leftover KAT stays in the vault (market 7)
    /// and the free collateral top-up repays debt with it.
    function unwindActions(CyLoopEnv memory env_, CyUnwindPlan memory plan_) internal view returns (FuseAction[] memory actions_) {
        if (plan_.withdrawAvkat == 0) return actions_;
        actions_ = new FuseAction[](1);
        if (plan_.repayKat == 0) {
            actions_[0] = collateralAction(env_, false, plan_.withdrawAvkat);
            return actions_;
        }
        FuseAction[] memory callback = new FuseAction[](3);
        callback[0] = borrowAction(env_, false, plan_.repayKat);
        callback[1] = collateralAction(env_, false, plan_.withdrawAvkat);
        callback[2] = swapAction(env_, env_.avkat, env_.kat, plan_.sellAvkat, plan_.repayKat);
        actions_[0] = FuseAction(env_.flashLoanFuse, abi.encodeCall(
            MorphoFlashLoanFuse.enter,
            (MorphoFlashLoanFuseEnterData({token: env_.kat, tokenAmount: plan_.repayKat, callbackFuseActionsData: abi.encode(callback)}))
        ));
    }

    function collateralAction(CyLoopEnv memory env_, bool enter_, uint256 amount_)
        internal pure returns (FuseAction memory)
    {
        return FuseAction(env_.collateralFuse, enter_
            ? abi.encodeCall(MorphoCollateralFuse.enter, (MorphoCollateralFuseEnterData(env_.marketId, amount_)))
            : abi.encodeCall(MorphoCollateralFuse.exit, (MorphoCollateralFuseExitData(env_.marketId, amount_))));
    }

    function borrowAction(CyLoopEnv memory env_, bool enter_, uint256 amount_) internal pure returns (FuseAction memory) {
        return FuseAction(env_.borrowFuse, enter_
            ? abi.encodeCall(MorphoBorrowFuse.enter, (MorphoBorrowFuseEnterData(env_.marketId, amount_, 0)))
            : abi.encodeCall(MorphoBorrowFuse.exit, (MorphoBorrowFuseExitData(env_.marketId, amount_, 0))));
    }

    function swapAction(CyLoopEnv memory env_, address in_, address out_, uint256 amount_, uint256 minimum_)
        internal view returns (FuseAction memory)
    {
        return CurveYieldUtsLib.swapAction(env_.swapFuse, env_.router, in_, out_, amount_, minimum_);
    }

    // ------------------------------------------------------------ internal

    /// @notice needed + avKAT to sell for the repay a withdrawal of `withdraw_` requires - withdraw_ (> 0: withdraw more).
    function _unwindGap(
        CyLoopEnv memory env_, CyLoopSnapshot memory s_, uint256 needed_, uint256 withdraw_, uint256 targetLtvBps_
    ) private view returns (int256) {
        uint256 repay = repayRequiredForWithdrawal(s_, withdraw_, targetLtvBps_);
        uint256 sell = repay == 0 ? 0 : _requiredInput(env_, repay, s_.collateralAvkat);
        return int256(needed_ + sell) - int256(withdraw_);
    }

    function _requiredInput(CyLoopEnv memory env_, uint256 requiredKat_, uint256 maximumAvkat_) private view returns (uint256) {
        return CurveYieldQuoteLib.requiredInput(env_.router, env_.avkat, env_.kat, requiredKat_, maximumAvkat_);
    }
}
