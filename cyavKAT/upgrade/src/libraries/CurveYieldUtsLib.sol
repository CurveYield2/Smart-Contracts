// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    UniversalTokenSwapperFuse,
    UniversalTokenSwapperEnterData,
    UniversalTokenSwapperData
} from "contracts/fuses/universal_token_swapper/UniversalTokenSwapperFuse.sol";
import {FuseAction} from "../interfaces/CurveYieldPhase2Interfaces.sol";

interface ICyRouterSwap {
    function swapExactInput(
        address tokenIn, address tokenOut, uint256 amountIn, uint256 minNetAmountOut, address recipient, uint256 deadline
    ) external returns (uint256 netOut);
}

/// @title CurveYieldUtsLib
/// @notice Builds the vault's swap action: IPOR's `UniversalTokenSwapperFuse` (market 12) with swap router v2 as the only
/// router Target (D4). The SwapExecutor approves the router for the input and calls `swapExactInput` with itself as the
/// recipient; the fuse then returns the output to the vault. The fuse checks the Token / Target substrates, the USD
/// slippage (Slippage substrate, through the vault oracle) and `minAmountOut`; the router adds its protected TWAP /
/// hook-oracle minimum on every call, whoever the caller is.
library CurveYieldUtsLib {
    /// @dev Seconds the router deadline is set ahead of the planning block (the bundle runs in the same transaction).
    uint256 internal constant DEADLINE_WINDOW = 600;

    function swapAction(
        address utsFuse_, address router_, address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 minAmountOut_
    ) internal view returns (FuseAction memory) {
        address executor = UniversalTokenSwapperFuse(utsFuse_).EXECUTOR();
        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);
        targets[0] = tokenIn_;
        data[0] = abi.encodeCall(IERC20.approve, (router_, amountIn_));
        targets[1] = router_;
        data[1] = abi.encodeCall(
            ICyRouterSwap.swapExactInput,
            (tokenIn_, tokenOut_, amountIn_, minAmountOut_, executor, block.timestamp + DEADLINE_WINDOW)
        );
        return FuseAction(utsFuse_, abi.encodeCall(
            UniversalTokenSwapperFuse.enter,
            (UniversalTokenSwapperEnterData({
                tokenIn: tokenIn_,
                tokenOut: tokenOut_,
                amountIn: amountIn_,
                minAmountOut: minAmountOut_,
                data: UniversalTokenSwapperData({targets: targets, data: data})
            }))
        ));
    }
}
