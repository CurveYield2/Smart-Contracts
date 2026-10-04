// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {FuseAction} from "../interfaces/CurveYieldPhase2Interfaces.sol";
import {
    ICyPlasmaVault, ICyAvKat, ICyErc20, ICyMorphoOracle, ICySwapFuse
} from "../interfaces/CurveYieldPhase2Interfaces.sol";

/// @notice Addresses the loop works with (Katana: Morpho 0xD50F…, market 0x80e6…, avKAT, KAT, the IPOR
/// collateral/borrow/flash fuses and the CurveYield router swap fuse).
struct CyLoopEnv {
    address vault;
    address morpho;
    bytes32 marketId;
    address avkat;
    address kat;
    address collateralFuse;
    address borrowFuse;
    address flashLoanFuse;
    address swapFuse;
    address splitter;
    address withdrawManager;
}

struct CyLoopSnapshot {
    uint256 collateralAvkat;
    uint256 debtKat;
    uint256 collateralValueKat;
    uint256 ltvBps;
    uint256 netEquityAvkat;
}

/// @notice ABI-identical to IPOR MorphoFlashLoanFuseEnterData.
struct CyFlashLoanData {
    address token;
    uint256 tokenAmount;
    bytes callbackFuseActionsData;
}

struct CyUnwindPlan {
    uint256 repayKat;
    uint256 withdrawAvkat;
    uint256 sellAvkat;
}

/// @notice Loop math and vault-context execution helpers shared by the loop fuses.
/// Snapshot, repay-for-withdrawal, unwind search and the flash-loan unwind are carried over from the audited
/// CurveYieldMorphoStrategyFuse; quotes now use the live (non-view) swap-fuse quotes (#5).
library CurveYieldMorphoLoopLib {
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant BPS = 10_000;
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;
    uint256 private constant MAX_SEARCH_ITERATIONS = 12;

    error InsufficientMorphoCollateral();
    error UnwindNotSafe();
    error UnwindLossTooHigh(uint256 lossAvkat, uint256 maximumLossAvkat);

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

    // ------------------------------------------------------------ planning with live quotes (vault context)

    /// @notice Unwind that frees `neededAvkat_` net while ending at the target LTV (from _planWithdrawalUnwind).
    function planUnwind(CyLoopEnv memory env_, CyLoopSnapshot memory s_, uint256 neededAvkat_, uint256 targetLtvBps_)
        internal returns (CyUnwindPlan memory plan_)
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
            plan_.repayKat == 0 ? 0 : _requiredInput(env_, env_.avkat, env_.kat, plan_.repayKat, s_.collateralAvkat);
        plan_.withdrawAvkat = withdraw;
        if (withdraw < neededAvkat_ + plan_.sellAvkat) revert UnwindNotSafe();
    }

    /// @notice De-leverage to target without releasing avKAT (from _planEmergencyFull).
    function planDeleverage(CyLoopEnv memory env_, CyLoopSnapshot memory s_, uint256 targetLtvBps_)
        internal returns (CyUnwindPlan memory plan_)
    {
        // Fixed point W = sell(repay(W)); repay(W) = a + b*W with a = repay(0) and b = target * KAT value per avKAT.
        // With c = sell/repay from one probe, W0 = c*a / (1 - c*b); then refine (same convergence issue as planUnwind).
        uint256 withdraw;
        {
            uint256 repay0 = repayRequiredForWithdrawal(s_, 0, targetLtvBps_);
            if (repay0 == 0) return plan_;
            uint256 sell0 = _requiredInput(env_, env_.avkat, env_.kat, repay0, s_.collateralAvkat);
            uint256 cb = Math.mulDiv(sell0 * targetLtvBps_, s_.collateralValueKat, repay0 * BPS * s_.collateralAvkat / 1e18);
            if (cb >= 1e18) revert UnwindNotSafe();
            withdraw = Math.mulDiv(sell0, 1e18, 1e18 - cb, Math.Rounding.Ceil);
            if (withdraw >= s_.collateralAvkat) revert UnwindNotSafe();
        }
        for (uint256 i; i < MAX_SEARCH_ITERATIONS; ++i) {
            uint256 repay = repayRequiredForWithdrawal(s_, withdraw, targetLtvBps_);
            uint256 sell = repay == 0 ? 0 : _requiredInput(env_, env_.avkat, env_.kat, repay, s_.collateralAvkat);
            if (sell <= withdraw + withdraw / 10_000 + 1) break; // 0.01%: each requiredInput costs ~3.4M gas
            withdraw = sell;
            if (withdraw >= s_.collateralAvkat) revert UnwindNotSafe();
        }
        plan_.repayKat = repayRequiredForWithdrawal(s_, withdraw, targetLtvBps_);
        plan_.sellAvkat =
            plan_.repayKat == 0 ? 0 : _requiredInput(env_, env_.avkat, env_.kat, plan_.repayKat, s_.collateralAvkat);
        plan_.withdrawAvkat = plan_.sellAvkat;
    }

    /// @notice Repay a fixed KAT amount, selling just enough collateral; must stay under LLTV (from _planEmergencyPartial).
    function planPartialRepay(CyLoopEnv memory env_, CyLoopSnapshot memory s_, uint256 repayKat_)
        internal returns (CyUnwindPlan memory plan_)
    {
        uint256 sell = _requiredInput(env_, env_.avkat, env_.kat, repayKat_, s_.collateralAvkat);
        if (sell >= s_.collateralAvkat) revert UnwindNotSafe();
        uint256 remainingValue = s_.collateralValueKat - Math.mulDiv(sell, s_.collateralValueKat, s_.collateralAvkat);
        if (s_.debtKat - repayKat_ > Math.mulDiv(remainingValue, lltv(env_), 1e18)) revert UnwindNotSafe();
        plan_ = CyUnwindPlan(repayKat_, sell, sell);
    }

    // ------------------------------------------------------------ execution (vault context)

    /// @notice Flash-borrow KAT, repay debt, withdraw collateral, sell avKAT to cover the flash (from _performUnwind).
    function performUnwind(CyLoopEnv memory env_, CyUnwindPlan memory plan_) internal {
        if (plan_.withdrawAvkat == 0) return;
        if (plan_.repayKat == 0) {
            executeOne(collateralAction(env_, false, plan_.withdrawAvkat));
            return;
        }
        FuseAction[] memory callback = new FuseAction[](3);
        callback[0] = borrowAction(env_, false, plan_.repayKat);
        callback[1] = collateralAction(env_, false, plan_.withdrawAvkat);
        callback[2] = swapAction(env_, env_.avkat, env_.kat, plan_.sellAvkat, plan_.repayKat);
        executeOne(FuseAction(
            env_.flashLoanFuse,
            // Encode as ONE tuple: the struct holds dynamic bytes, so three flat arguments do not match the ABI
            // (the flat encoding in the live v1 fuse is rejected by MorphoFlashLoanFuse).
            abi.encodeWithSignature(
                "enter((address,uint256,bytes))", CyFlashLoanData(env_.kat, plan_.repayKat, abi.encode(callback))
            )
        ));
        sweepKatDust(env_);
    }

    /// @notice Swaps leftover KAT back to avKAT when the amount is large enough to quote.
    function sweepKatDust(CyLoopEnv memory env_) internal {
        uint256 dust = ICyErc20(env_.kat).balanceOf(env_.vault);
        if (dust == 0) return;
        (, uint256 minimum) = ICySwapFuse(env_.swapFuse).quoteExactInputView(env_.kat, env_.avkat, dust);
        if (minimum != 0) executeOne(swapAction(env_, env_.kat, env_.avkat, dust, 0));
    }

    function enforceLoss(CyLoopEnv memory env_, CyUnwindPlan memory plan_, uint256 basisAvkat_, uint256 maxLossBps_)
        internal view returns (uint256 loss_)
    {
        loss_ = bookedUnwindLoss(env_, plan_.repayKat, plan_.sellAvkat);
        uint256 maximum = basisAvkat_ * maxLossBps_ / BPS;
        if (loss_ > maximum) revert UnwindLossTooHigh(loss_, maximum);
    }

    function collateralAction(CyLoopEnv memory env_, bool enter_, uint256 amount_)
        internal pure returns (FuseAction memory)
    {
        return FuseAction(env_.collateralFuse, enter_
            ? abi.encodeWithSignature("enter((bytes32,uint256))", env_.marketId, amount_)
            : abi.encodeWithSignature("exit((bytes32,uint256))", env_.marketId, amount_));
    }

    function borrowAction(CyLoopEnv memory env_, bool enter_, uint256 amount_) internal pure returns (FuseAction memory) {
        return FuseAction(env_.borrowFuse, enter_
            ? abi.encodeWithSignature("enter((bytes32,uint256,uint256))", env_.marketId, amount_, 0)
            : abi.encodeWithSignature("exit((bytes32,uint256,uint256))", env_.marketId, amount_, 0));
    }

    function swapAction(CyLoopEnv memory env_, address in_, address out_, uint256 amount_, uint256 minimum_)
        internal pure returns (FuseAction memory)
    {
        return FuseAction(env_.swapFuse, abi.encodeWithSignature(
            "enter((address,address,uint256,uint256))", in_, out_, amount_, minimum_
        ));
    }

    function executeOne(FuseAction memory action_) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = action_;
        ICyPlasmaVault(address(this)).executeInternal(actions);
    }

    function executeMany(FuseAction[] memory actions_) internal {
        ICyPlasmaVault(address(this)).executeInternal(actions_);
    }

    /// @notice needed + avKAT to sell for the repay a withdrawal of `withdraw_` requires - withdraw_ (> 0: withdraw more).
    function _unwindGap(
        CyLoopEnv memory env_, CyLoopSnapshot memory s_, uint256 needed_, uint256 withdraw_, uint256 targetLtvBps_
    ) private returns (int256) {
        uint256 repay = repayRequiredForWithdrawal(s_, withdraw_, targetLtvBps_);
        uint256 sell = repay == 0 ? 0 : _requiredInput(env_, env_.avkat, env_.kat, repay, s_.collateralAvkat);
        return int256(needed_ + sell) - int256(withdraw_);
    }

    function _requiredInput(CyLoopEnv memory env_, address in_, address out_, uint256 amount_, uint256 maximum_)
        private returns (uint256)
    {
        return ICySwapFuse(env_.swapFuse).requiredInput(in_, out_, amount_, maximum_);
    }
}
