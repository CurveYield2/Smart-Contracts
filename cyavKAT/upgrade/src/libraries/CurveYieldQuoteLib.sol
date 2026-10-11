// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @notice Swap router v2 quote surface (CurveYieldSwapRouterV2).
interface ICyRouterQuote {
    function protectedQuote(address tokenIn, address tokenOut, uint256 amountIn)
        external view returns (uint256 expectedNet, uint256 minimumNet);
}

/// @title CurveYieldQuoteLib
/// @notice Planner-side quote helpers over the swap router v2's protected quote (a pure view). The planners size their
/// bundles with them; the router enforces the same protected minimum on the swap itself (D4).
library CurveYieldQuoteLib {
    uint256 private constant MAX_SEARCH_ITERATIONS = 48;
    uint256 private constant MAX_SEARCH_EXPANSIONS = 12;

    error CurveYieldQuoteLibInvalidAmount();
    error CurveYieldQuoteLibRequiredOutputUnavailable(uint256 required, uint256 available);

    /// @notice The router's protected minimum net output for `amountIn_` (0 for a zero input).
    function minimumOut(address router_, address tokenIn_, address tokenOut_, uint256 amountIn_)
        internal view returns (uint256 minimumNet_)
    {
        if (amountIn_ == 0) return 0;
        (, minimumNet_) = ICyRouterQuote(router_).protectedQuote(tokenIn_, tokenOut_, amountIn_);
    }

    /// @notice Smallest input whose protected minimum output reaches `requiredNetOut_` (at most `maximumInput_`).
    function requiredInput(address router_, address tokenIn_, address tokenOut_, uint256 requiredNetOut_, uint256 maximumInput_)
        internal view returns (uint256 input_)
    {
        if (requiredNetOut_ == 0) return 0;
        if (maximumInput_ == 0) revert CurveYieldQuoteLibInvalidAmount();
        uint256 maxOut = minimumOut(router_, tokenIn_, tokenOut_, maximumInput_);
        if (maxOut < requiredNetOut_) revert CurveYieldQuoteLibRequiredOutputUnavailable(requiredNetOut_, maxOut);
        uint256 low = 1;
        uint256 high = maximumInput_ * requiredNetOut_ / maxOut + 1;
        if (high > maximumInput_) high = maximumInput_;
        uint256 highOut = minimumOut(router_, tokenIn_, tokenOut_, high);
        for (uint256 i; i < MAX_SEARCH_EXPANSIONS && highOut < requiredNetOut_; ++i) {
            low = high + 1;
            uint256 expanded = high + high / 8 + 1;
            high = expanded < maximumInput_ ? expanded : maximumInput_;
            highOut = minimumOut(router_, tokenIn_, tokenOut_, high);
        }
        if (highOut < requiredNetOut_) revert CurveYieldQuoteLibRequiredOutputUnavailable(requiredNetOut_, highOut);
        for (uint256 i; i < MAX_SEARCH_ITERATIONS && low < high; ++i) {
            uint256 mid = low + (high - low) / 2;
            if (minimumOut(router_, tokenIn_, tokenOut_, mid) >= requiredNetOut_) high = mid;
            else low = mid + 1;
        }
        input_ = high;
    }
}
