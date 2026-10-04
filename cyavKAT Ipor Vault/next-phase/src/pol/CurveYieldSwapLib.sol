// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TickMath} from "contracts/fuses/uniswap/ext/TickMath.sol";
import {FullMath} from "contracts/fuses/uniswap/ext/FullMath.sol";
import {
    CySushiRoute, ISushiV3Pool, ISushiSwapRouter, ISushiQuoterV2, IBalV3Router, IPermit2
} from "./CurveYieldPolInterfaces.sol";

/// @title CurveYieldSwapLib (POL spec)
/// @notice Sushi V3 swaps over several candidate routes: every route is quoted (QuoterV2) and the best is taken, and
/// the chosen route must also clear a TWAP guard (min out = TWAP value x (1 - slippage)). Plus Balancer v3 swaps
/// through the CurveYield DEX router (Permit2 approvals). Works from a delegatecalled fuse or a normal contract.
library CurveYieldSwapLib {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;

    error NoRoute();
    error TwapDeviation(uint256 quoted, uint256 minOut);
    error AmountTooLarge();

    // ---------------------------------------------------------------- TWAP

    /// @notice tokenOut received for `amountIn_` of `tokenIn_` at the pool's arithmetic-mean tick over `window_`.
    function twapOut(address pool_, address tokenIn_, uint256 amountIn_, uint32 window_) internal view returns (uint256) {
        if (amountIn_ > type(uint128).max) revert AmountTooLarge();
        uint32[] memory ago = new uint32[](2);
        ago[0] = window_;
        (int56[] memory cum,) = ISushiV3Pool(pool_).observe(ago);
        int56 delta = cum[1] - cum[0];
        int24 tick = int24(delta / int56(uint56(window_)));
        if (delta < 0 && (delta % int56(uint56(window_)) != 0)) tick--;
        address token0 = ISushiV3Pool(pool_).token0();
        return _quoteAtTick(tick, uint128(amountIn_), tokenIn_ == token0);
    }

    /// @notice TWAP value of a whole route (hop by hop).
    function twapOutRoute(CySushiRoute memory r_, uint256 amountIn_, uint32 window_) internal view returns (uint256 out_) {
        out_ = amountIn_;
        for (uint256 i; i < r_.pools.length; ++i) out_ = twapOut(r_.pools[i], r_.tokens[i], out_, window_);
    }

    function _quoteAtTick(int24 tick_, uint128 baseAmount_, bool baseIsToken0_) private pure returns (uint256 quote_) {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick_);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quote_ = baseIsToken0_
                ? FullMath.mulDiv(ratioX192, baseAmount_, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount_, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quote_ = baseIsToken0_
                ? FullMath.mulDiv(ratioX128, baseAmount_, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount_, ratioX128);
        }
    }

    // ---------------------------------------------------------------- Sushi: best route

    /// @notice Quotes every route (QuoterV2; a failing route is skipped) and returns the best.
    function bestRoute(address quoter_, CySushiRoute[] memory routes_, uint256 amountIn_)
        internal returns (uint256 index_, uint256 quoted_)
    {
        bool found;
        for (uint256 i; i < routes_.length; ++i) {
            try ISushiQuoterV2(quoter_).quoteExactInput(routes_[i].path, amountIn_) returns (
                uint256 out, uint160[] memory, uint32[] memory, uint256
            ) {
                if (!found || out > quoted_) (index_, quoted_, found) = (i, out, true);
            } catch {}
        }
        if (!found) revert NoRoute();
    }

    /// @notice Swaps `amountIn_` on the best route, guarded by that route's TWAP (min out) and its live quote.
    function swapBest(
        address router_,
        address quoter_,
        CySushiRoute[] memory routes_,
        uint256 amountIn_,
        uint32 window_,
        uint256 maxSlippageBps_,
        address recipient_
    ) internal returns (uint256 out_) {
        if (amountIn_ == 0) return 0;
        (uint256 idx, uint256 quoted) = bestRoute(quoter_, routes_, amountIn_);
        CySushiRoute memory r = routes_[idx];
        uint256 minOut = twapOutRoute(r, amountIn_, window_) * (BPS - maxSlippageBps_) / BPS;
        if (quoted < minOut) revert TwapDeviation(quoted, minOut);
        IERC20(r.tokens[0]).forceApprove(router_, amountIn_);
        out_ = ISushiSwapRouter(router_).exactInput(
            ISushiSwapRouter.ExactInputParams(r.path, recipient_, block.timestamp, amountIn_, minOut)
        );
        IERC20(r.tokens[0]).forceApprove(router_, 0);
    }

    // ---------------------------------------------------------------- Balancer v3 (CurveYield DEX)

    /// @notice Lets the Balancer router pull `amount_` of `token_` through Permit2 (this block only).
    function permit2Approve(address permit2_, address router_, address token_, uint256 amount_) internal {
        IERC20(token_).forceApprove(permit2_, amount_);
        IPermit2(permit2_).approve(token_, router_, uint160(amount_), uint48(block.timestamp));
    }

    /// @notice Exact-in swap in a CurveYield DEX pool; reverts in the router if `minOut_` is not met.
    function balancerSwap(
        address router_, address permit2_, address pool_, address tokenIn_, address tokenOut_, uint256 amountIn_,
        uint256 minOut_
    ) internal returns (uint256 out_) {
        if (amountIn_ == 0) return 0;
        permit2Approve(permit2_, router_, tokenIn_, amountIn_);
        out_ = IBalV3Router(router_).swapSingleTokenExactIn(
            pool_, IERC20(tokenIn_), IERC20(tokenOut_), amountIn_, minOut_, block.timestamp, false, ""
        );
    }
}
