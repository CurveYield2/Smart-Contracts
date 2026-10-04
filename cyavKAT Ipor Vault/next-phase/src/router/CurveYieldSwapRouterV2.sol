// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "contracts/fuses/uniswap/ext/TickMath.sol";
import {CurveYieldGateConfig, CurveYieldConfigKeys as K} from "../governance/CurveYieldGateConfig.sol";

interface IV3Pool {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external returns (int256 amount0, int256 amount1);
    function observe(uint32[] calldata secondsAgos)
        external view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function factory() external view returns (address);
    function fee() external view returns (uint24);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

struct BalHooksConfig {
    bool enableHookAdjustedAmounts;
    bool shouldCallBeforeInitialize;
    bool shouldCallAfterInitialize;
    bool shouldCallComputeDynamicSwapFee;
    bool shouldCallBeforeSwap;
    bool shouldCallAfterSwap;
    bool shouldCallBeforeAddLiquidity;
    bool shouldCallAfterAddLiquidity;
    bool shouldCallBeforeRemoveLiquidity;
    bool shouldCallAfterRemoveLiquidity;
    address hooksContract;
}

interface IBalVaultHooks {
    function getHooksConfig(address pool) external view returns (BalHooksConfig memory);
}

interface IBalRouter {
    function getPermit2() external view returns (address);
    function swapSingleTokenExactIn(
        address pool, address tokenIn, address tokenOut, uint256 exactAmountIn, uint256 minAmountOut, uint256 deadline,
        bool wethIsEth, bytes calldata userData
    ) external payable returns (uint256 amountOut);
}

interface IPermit2Approve {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice The CurveYield DEX pool hook's time-weighted quote (ICurveYieldPoolObservation).
interface ICurveYieldPoolOracle {
    function quoteOracleProtectedSwapOut(address pool, address tokenIn, address tokenOut, uint256 amountInRaw)
        external view returns (uint256 oracleExpectedAmountOut, uint256 oracleMinAmountOut);
}

/// @notice One hop of a route: a Sushi V3 pool (token pair + fee tier) or a CurveYield DEX (Balancer V3) pool.
struct CyHop {
    uint8 venue; // 1 = SUSHI, 2 = BALANCER
    address tokenIn;
    address tokenOut;
    address pool; // Sushi: the factory's pool for (tokenIn, tokenOut, fee); Balancer: the CurveYield DEX pool
    uint24 fee; // Sushi fee tier (ignored for Balancer)
}

/// @title CurveYieldSwapRouterV2 (SWAP_ROUTING_SPEC)
/// @notice Every vault swap, on Sushi V3 and the CurveYield DEX, in multi-hop routes that may mix both. A flat 0.1%
/// admin fee (hard-coded) is taken from every output. Every swap is held to a manipulation-resistant minimum: the
/// expected output chained hop by hop (Sushi: the pool's TWAP over the router-wide window, minus the pool fee;
/// Balancer: the pool hook's time-weighted expected output), times (1 - protection) and (1 - fee). The protection
/// setting (0.3-3%) and the TWAP window (1 min-4 h) live in the governance gate. v1-compatible `twapMinimumOut` and
/// `swapExactInput`. Owner (routes, fee receiver) = the governance gate.
contract CurveYieldSwapRouterV2 is Ownable2Step, CurveYieldGateConfig {
    using SafeERC20 for IERC20;

    uint8 public constant SUSHI = 1;
    uint8 public constant BALANCER = 2;
    uint256 public constant FEE_BPS = 10; // 0.1% on every swap, fixed
    uint256 private constant BPS = 10_000;

    address public immutable SUSHI_FACTORY;
    bytes32 public immutable SUSHI_POOL_INIT_CODE_HASH;
    address public balancerVault; // CurveYield DEX (set once, when the DEX is live)
    address public balancerRouter;

    address public feeRecipient;
    mapping(bytes32 routeKey => CyHop[]) private _routes;

    // Sushi callback guard (one pool swap at a time)
    address private _activePool;
    address private _activeTokenIn;
    uint256 private _activeAmountIn;
    bool private _callbackConsumed;
    uint256 private _locked = 1;

    event RouteSet(address indexed tokenIn, address indexed tokenOut, uint256 hops);
    event RouteRemoved(address indexed tokenIn, address indexed tokenOut);
    event FeeRecipientUpdated(address indexed recipient);
    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 netOut, uint256 fee, address recipient);

    error BadRoute();
    error RouteMissing(address tokenIn, address tokenOut);
    error Expired();
    error TooLittleOut(uint256 netOut, uint256 minimum);
    error BadCallback();
    error Reentrant();
    error ZeroAmount();
    error BadRecipient();

    modifier lock() {
        if (_locked != 1) revert Reentrant();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(
        address owner_, address configGate_, address feeRecipient_, address sushiFactory_, bytes32 sushiInitCodeHash_
    ) Ownable(owner_) CurveYieldGateConfig(configGate_) {
        if (feeRecipient_ == address(0) || sushiFactory_ == address(0)) revert BadRoute();
        feeRecipient = feeRecipient_;
        SUSHI_FACTORY = sushiFactory_;
        SUSHI_POOL_INIT_CODE_HASH = sushiInitCodeHash_;
        emit FeeRecipientUpdated(feeRecipient_);
    }

    // ---------------------------------------------------------------- configuration (owner = the gate)

    /// @notice Receiver of the 0.1% fee (fee authority only, through the gate's protected list).
    function setFeeRecipient(address recipient_) external onlyOwner {
        if (recipient_ == address(0)) revert BadRecipient();
        feeRecipient = recipient_;
        emit FeeRecipientUpdated(recipient_);
    }

    /// @notice Wires the CurveYield DEX (Balancer V3 vault + router) once, when it is live.
    function setBalancer(address vault_, address router_) external onlyOwner {
        if (balancerVault != address(0) || vault_ == address(0) || router_ == address(0)) revert BadRoute();
        (balancerVault, balancerRouter) = (vault_, router_);
    }

    /// @notice Sets the route tokenIn -> tokenOut (hops in order, each output feeding the next input).
    function setRoute(address tokenIn_, address tokenOut_, CyHop[] calldata hops_) external onlyOwner {
        if (hops_.length == 0 || tokenIn_ == tokenOut_ || hops_[0].tokenIn != tokenIn_ ||
            hops_[hops_.length - 1].tokenOut != tokenOut_) revert BadRoute();
        bytes32 key = _key(tokenIn_, tokenOut_);
        delete _routes[key];
        for (uint256 i; i < hops_.length; ++i) {
            CyHop calldata h = hops_[i];
            if (i != 0 && h.tokenIn != hops_[i - 1].tokenOut) revert BadRoute();
            if (h.tokenIn == address(0) || h.tokenOut == address(0) || h.tokenIn == h.tokenOut) revert BadRoute();
            if (h.venue == SUSHI) {
                address pool = _sushiPoolFor(h.tokenIn, h.tokenOut, h.fee);
                if (h.pool != pool || pool != IV3Factory(SUSHI_FACTORY).getPool(h.tokenIn, h.tokenOut, h.fee) ||
                    pool.code.length == 0) revert BadRoute();
            } else if (h.venue == BALANCER) {
                if (balancerVault == address(0) || IBalVaultHooks(balancerVault).getHooksConfig(h.pool).hooksContract == address(0)) revert BadRoute();
            } else {
                revert BadRoute();
            }
            _routes[key].push(h);
        }
        emit RouteSet(tokenIn_, tokenOut_, hops_.length);
    }

    function removeRoute(address tokenIn_, address tokenOut_) external onlyOwner {
        delete _routes[_key(tokenIn_, tokenOut_)];
        emit RouteRemoved(tokenIn_, tokenOut_);
    }

    function routeHops(address tokenIn_, address tokenOut_) external view returns (CyHop[] memory) {
        return _routes[_key(tokenIn_, tokenOut_)];
    }

    /// @notice Router-wide protection (bps) and Sushi TWAP window (seconds), from the governance gate.
    function protection() public view returns (uint256 protectionBps_, uint32 twapWindow_) {
        bytes32[] memory k = new bytes32[](2);
        (k[0], k[1]) = (K.ROUTER_PROTECTION_BPS, K.ROUTER_TWAP_WINDOW);
        uint256[] memory v = _config(k);
        return (v[0], uint32(v[1]));
    }

    // ---------------------------------------------------------------- quotes

    /// @notice Time-weighted expected net output (after the 0.1% fee) and the protected minimum for a swap.
    function protectedQuote(address tokenIn_, address tokenOut_, uint256 amountIn_)
        public view returns (uint256 expectedNet_, uint256 minimumNet_)
    {
        CyHop[] storage hops = _routeOf(tokenIn_, tokenOut_);
        (uint256 protectionBps, uint32 window) = protection();
        uint256 amount = amountIn_;
        for (uint256 i; i < hops.length; ++i) amount = _hopExpected(hops[i], amount, window);
        expectedNet_ = amount * (BPS - FEE_BPS) / BPS;
        minimumNet_ = expectedNet_ * (BPS - protectionBps) / BPS;
    }

    /// @notice v1-compatible: the protected minimum net output.
    function twapMinimumOut(address tokenIn_, address tokenOut_, uint256 amountIn_) external view returns (uint256 minimum_) {
        (, minimum_) = protectedQuote(tokenIn_, tokenOut_, amountIn_);
    }

    // ---------------------------------------------------------------- swap

    /// @notice Swaps `amountIn_` of tokenIn along the route; the net output (after the 0.1% fee) must reach
    /// max(the protected minimum, `minNetAmountOut_`). Input is pulled from the caller.
    function swapExactInput(
        address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 minNetAmountOut_, address recipient_, uint256 deadline_
    ) external lock returns (uint256 netOut_) {
        if (block.timestamp > deadline_) revert Expired();
        if (amountIn_ == 0) revert ZeroAmount();
        if (recipient_ == address(0) || recipient_ == address(this)) revert BadRecipient();
        (, uint256 protectedMin) = protectedQuote(tokenIn_, tokenOut_, amountIn_);
        uint256 minimum = protectedMin > minNetAmountOut_ ? protectedMin : minNetAmountOut_;

        IERC20(tokenIn_).safeTransferFrom(msg.sender, address(this), amountIn_);
        CyHop[] storage hops = _routeOf(tokenIn_, tokenOut_);
        uint256 amount = amountIn_;
        for (uint256 i; i < hops.length; ++i) amount = _hopSwap(hops[i], amount, deadline_);

        uint256 fee = amount * FEE_BPS / BPS;
        netOut_ = amount - fee;
        if (netOut_ < minimum) revert TooLittleOut(netOut_, minimum);
        if (fee != 0) IERC20(tokenOut_).safeTransfer(feeRecipient, fee);
        IERC20(tokenOut_).safeTransfer(recipient_, netOut_);
        emit Swapped(tokenIn_, tokenOut_, amountIn_, netOut_, fee, recipient_);
    }

    /// @notice Sushi V3 pool callback: only the active, factory-derived pool, once, for at most the hop's input.
    function uniswapV3SwapCallback(int256 amount0Delta_, int256 amount1Delta_, bytes calldata) external {
        if (msg.sender != _activePool || _callbackConsumed) revert BadCallback();
        int256 inputDelta = amount0Delta_ > 0 ? amount0Delta_ : amount1Delta_;
        if (inputDelta <= 0 || uint256(inputDelta) > _activeAmountIn) revert BadCallback();
        _callbackConsumed = true;
        IERC20(_activeTokenIn).safeTransfer(msg.sender, uint256(inputDelta));
    }

    // ---------------------------------------------------------------- internals

    function _hopExpected(CyHop storage h_, uint256 amountIn_, uint32 window_) private view returns (uint256) {
        if (h_.venue == SUSHI) {
            int24 meanTick = _meanTick(h_.pool, window_);
            uint256 out = _quoteAtTick(meanTick, amountIn_, h_.tokenIn, h_.tokenOut);
            return out * (1_000_000 - h_.fee) / 1_000_000;
        }
        address hook = IBalVaultHooks(balancerVault).getHooksConfig(h_.pool).hooksContract;
        (uint256 expected,) = ICurveYieldPoolOracle(hook).quoteOracleProtectedSwapOut(h_.pool, h_.tokenIn, h_.tokenOut, amountIn_);
        return expected;
    }

    function _hopSwap(CyHop storage h_, uint256 amountIn_, uint256 deadline_) private returns (uint256 out_) {
        if (h_.venue == SUSHI) {
            bool zeroForOne = h_.tokenIn < h_.tokenOut;
            (_activePool, _activeTokenIn, _activeAmountIn, _callbackConsumed) = (h_.pool, h_.tokenIn, amountIn_, false);
            (int256 a0, int256 a1) = IV3Pool(h_.pool).swap(
                address(this), zeroForOne, int256(amountIn_),
                zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1, ""
            );
            if (!_callbackConsumed) revert BadCallback();
            (_activePool, _activeTokenIn, _activeAmountIn) = (address(0), address(0), 0);
            int256 outDelta = zeroForOne ? a1 : a0;
            return uint256(-outDelta);
        }
        address permit2 = IBalRouter(balancerRouter).getPermit2();
        IERC20(h_.tokenIn).forceApprove(permit2, amountIn_);
        IPermit2Approve(permit2).approve(h_.tokenIn, balancerRouter, uint160(amountIn_), uint48(block.timestamp));
        out_ = IBalRouter(balancerRouter).swapSingleTokenExactIn(
            h_.pool, h_.tokenIn, h_.tokenOut, amountIn_, 0, deadline_, false, ""
        );
        IPermit2Approve(permit2).approve(h_.tokenIn, balancerRouter, 0, 0);
        IERC20(h_.tokenIn).forceApprove(permit2, 0);
    }

    function _routeOf(address tokenIn_, address tokenOut_) private view returns (CyHop[] storage hops_) {
        hops_ = _routes[_key(tokenIn_, tokenOut_)];
        if (hops_.length == 0) revert RouteMissing(tokenIn_, tokenOut_);
    }

    function _meanTick(address pool_, uint32 window_) private view returns (int24 tick_) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = window_;
        (int56[] memory cumulatives,) = IV3Pool(pool_).observe(ago);
        int56 delta = cumulatives[1] - cumulatives[0];
        tick_ = int24(delta / int56(uint56(window_)));
        if (delta < 0 && (delta % int56(uint56(window_)) != 0)) tick_--;
    }

    function _quoteAtTick(int24 tick_, uint256 baseAmount_, address baseToken_, address quoteToken_)
        private pure returns (uint256)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick_);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            return baseToken_ < quoteToken_
                ? Math.mulDiv(ratioX192, baseAmount_, 1 << 192)
                : Math.mulDiv(1 << 192, baseAmount_, ratioX192);
        }
        uint256 ratioX128 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
        return baseToken_ < quoteToken_
            ? Math.mulDiv(ratioX128, baseAmount_, 1 << 128)
            : Math.mulDiv(1 << 128, baseAmount_, ratioX128);
    }

    function _sushiPoolFor(address tokenA_, address tokenB_, uint24 fee_) private view returns (address) {
        (address t0, address t1) = tokenA_ < tokenB_ ? (tokenA_, tokenB_) : (tokenB_, tokenA_);
        bytes32 salt = keccak256(abi.encode(t0, t1, fee_));
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", SUSHI_FACTORY, salt, SUSHI_POOL_INIT_CODE_HASH)))));
    }

    function _key(address tokenIn_, address tokenOut_) private pure returns (bytes32) {
        return keccak256(abi.encode(tokenIn_, tokenOut_));
    }
}
