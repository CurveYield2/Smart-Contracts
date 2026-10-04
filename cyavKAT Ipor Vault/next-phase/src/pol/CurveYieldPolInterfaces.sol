// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ---------------------------------------------------------------- Balancer v3 (CurveYield DEX), minimal

enum BalV3TokenType {
    STANDARD,
    WITH_RATE
}

struct BalV3TokenInfo {
    BalV3TokenType tokenType;
    address rateProvider;
    bool paysYieldFees;
}

interface IBalV3Vault {
    function getPoolTokenInfo(address pool)
        external
        view
        returns (
            IERC20[] memory tokens,
            BalV3TokenInfo[] memory tokenInfo,
            uint256[] memory balancesRaw,
            uint256[] memory lastBalancesLiveScaled18
        );
}

interface IBalV3Router {
    function swapSingleTokenExactIn(
        address pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 exactAmountIn,
        uint256 minAmountOut,
        uint256 deadline,
        bool wethIsEth,
        bytes calldata userData
    ) external payable returns (uint256 amountOut);

    function addLiquidityProportional(
        address pool,
        uint256[] memory maxAmountsIn,
        uint256 exactBptAmountOut,
        bool wethIsEth,
        bytes memory userData
    ) external payable returns (uint256[] memory amountsIn);

    function removeLiquidityProportional(
        address pool,
        uint256 exactBptAmountIn,
        uint256[] memory minAmountsOut,
        bool wethIsEth,
        bytes memory userData
    ) external payable returns (uint256[] memory amountsOut);
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

// ---------------------------------------------------------------- Sushi V3 (Uniswap V3 compatible)

interface ISushiV3Pool {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface ISushiSwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

interface ISushiQuoterV2 {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );
}

// ---------------------------------------------------------------- Charm Alpha Vault (v2 AlphaProVault), minimal

interface IAlphaVault {
    function deposit(uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min, address to)
        external
        returns (uint256 shares, uint256 amount0, uint256 amount1);
    function withdraw(uint256 shares, uint256 amount0Min, uint256 amount1Min, address to)
        external
        returns (uint256 amount0, uint256 amount1);
    function getTotalAmounts() external view returns (uint256 total0, uint256 total1);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

// ---------------------------------------------------------------- cyavKAT (IPOR PlasmaVault) + its withdraw manager

interface ICyPolVault {
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function decimals() external view returns (uint8);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function getWithdrawManager() external view returns (address);
}

interface ICyPolWithdrawManager {
    function armBurnOnlyFee() external;
    function getWithdrawFee() external view returns (uint256);
}

/// @notice One swap route on Sushi V3: the encoded path plus its pools / tokens in order (for the TWAP guard).
struct CySushiRoute {
    bytes path; // tokenIn | fee | token | fee | ... | tokenOut
    address[] pools; // pools[i] trades tokens[i] -> tokens[i + 1]
    address[] tokens;
}
