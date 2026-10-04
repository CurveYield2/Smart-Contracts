// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

/**
 * @title CurveYield System Component
 * @notice CurveYield is a decentralized NGO building optimized DeFi systems for the good of all.
 *
 * @dev CurveYield integrates specialized AMM infrastructure, tokenized yield strategies, credit
 * markets, and protocol-owned liquidity into a unified, capital-efficient liquidity stack governed
 * by an open, international DAO community.
 *
 * Protocol operations are enhanced by cross-chain bridging and messaging, MEV capture systems,
 * off-chain to on-chain automation, and peer-to-peer data networks.
 *
 * This contract is one component of the CurveYield system.
 *
 * CurveYield uses proven DeFi primitives where possible and adds targeted coordination and
 * capital-efficiency-enhancing contracts where needed. Users and integrators must review
 * CurveYield documentation before use.
 *
 * Learn more:
 * Documentation: https://docs.curveyield.com
 * dApp: https://curveyield.online
 * GitHub: https://github.com/curveyield
 *
 * Decentralized links may have limited or delayed availability during periods of high network activity:
 * https://curveyield.eth.limo
 * https://curveyield.dao
 *
 * Note: curveyield.dao may require a Brave Browser or an Unstoppable Domains browser plugin to use.
 */

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/libraries/FullMath.sol';
import '@uniswap/v3-core/contracts/libraries/SafeCast.sol';
import '@uniswap/v3-core/contracts/libraries/TickMath.sol';
import '@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol';
import '@uniswap/v3-periphery/contracts/libraries/Path.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';

interface IRouterBalanceToken {
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Katana-only Sushi V3 exact-input router with a configurable output-token fee.
/// @dev Pool-swap and callback structure follows the verified Katana Sushi SwapRouter.
contract CurveYieldSushiV3FeeRouter {
    using Path for bytes;
    using SafeCast for uint256;

    address private constant FACTORY = 0x203e8740894c8955cB8950759876d7E7E45E04c1;
    bytes32 private constant KATANA_POOL_INIT_CODE_HASH =
        0xe040f12c7cee3904b78f24f8fc395629c2e69525c2815da7a659f7483e378ecb;
    address private constant AVKAT = 0x7231dbaCdFc968E07656D12389AB20De82FbfCeB;
    address private constant KAT = 0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d;
    uint16 private constant MAX_FEE_BPS = 2000;
    uint32 public constant DEFAULT_TWAP_WINDOW = 900;
    uint16 public constant DEFAULT_TWAP_DEVIATION_BPS = 330;
    uint16 private constant MAX_TWAP_DEVIATION_BPS = 2000;

    address public owner;
    address private feeRecipient;
    uint16 private feeBps;
    mapping(bytes32 => bytes) private routes;
    mapping(bytes32 => uint16) private routeFeeBps;
    mapping(bytes32 => bool) private routeFeeConfigured;
    struct TwapGuard {
        uint32 window;
        uint16 maxDeviationBps;
        bool configured;
    }
    mapping(bytes32 => TwapGuard) private routeTwapGuards;
    uint256 private unlocked = 1;
    address private activePool;
    address private activePayer;
    uint256 private activeAmountIn;
    bool private callbackConsumed;

    struct SwapCallbackData {
        bytes path;
        address payer;
    }

    event RouteTwapGuardUpdated(address indexed tokenIn, address indexed tokenOut, uint32 window, uint16 maxDeviationBps);

    modifier onlyOwner() {
        require(msg.sender == owner, 'NOT_OWNER');
        _;
    }

    modifier lock() {
        require(unlocked == 1, 'LOCKED');
        unlocked = 2;
        _;
        unlocked = 1;
    }

    constructor(
        address initialOwner,
        address initialFeeRecipient,
        bytes memory avkatToKatPath,
        bytes memory katToAvkatPath
    ) {
        uint256 currentChainId;
        assembly { currentChainId := chainid() }
        require(currentChainId == 747474, 'WRONG_CHAIN');
        require(initialOwner != address(0), 'ZERO_OWNER');
        require(initialFeeRecipient != address(0) && initialFeeRecipient != address(this), 'BAD_FEE_RECIPIENT');
        owner = initialOwner;
        feeRecipient = initialFeeRecipient;
        feeBps = 0;
        require(avkatToKatPath.length == 43 && katToAvkatPath.length == 43, 'INITIAL_ROUTES_NOT_DIRECT');
        _setRoute(AVKAT, KAT, avkatToKatPath);
        _setRoute(KAT, AVKAT, katToAvkatPath);
        bytes32 forwardKey = _routeKey(AVKAT, KAT);
        bytes32 reverseKey = _routeKey(KAT, AVKAT);
        routeFeeBps[forwardKey] = 0;
        routeFeeConfigured[forwardKey] = true;
        routeFeeBps[reverseKey] = 0;
        routeFeeConfigured[reverseKey] = true;
    }

    function transferOwnership(address nextOwner) external onlyOwner {
        require(nextOwner != address(0), 'ZERO_OWNER');
        owner = nextOwner;
    }

    function setFeeRecipient(address nextRecipient) external onlyOwner {
        require(nextRecipient != address(0) && nextRecipient != address(this), 'BAD_FEE_RECIPIENT');
        feeRecipient = nextRecipient;
    }

    function setFeeBps(uint16 value) external onlyOwner {
        require(value <= MAX_FEE_BPS, 'FEE_TOO_HIGH');
        feeBps = value;
    }

    function setRoute(address tokenIn, address tokenOut, bytes calldata path) external onlyOwner {
        _setRoute(tokenIn, tokenOut, path);
    }

    function removeRoute(address tokenIn, address tokenOut) external onlyOwner {
        bytes32 key = _routeKey(tokenIn, tokenOut);
        require(routes[key].length != 0, 'ROUTE_MISSING');
        delete routes[key];
        delete routeFeeBps[key];
        delete routeFeeConfigured[key];
        delete routeTwapGuards[key];
    }

    function routeFor(address tokenIn, address tokenOut) external view returns (bytes memory) {
        return routes[_routeKey(tokenIn, tokenOut)];
    }

    function setRouteFeeBps(address tokenIn, address tokenOut, uint16 value) external onlyOwner {
        bytes32 key = _routeKey(tokenIn, tokenOut);
        require(routes[key].length != 0, 'ROUTE_MISSING');
        require(value <= MAX_FEE_BPS, 'FEE_TOO_HIGH');
        routeFeeBps[key] = value;
        routeFeeConfigured[key] = true;
    }

    function clearRouteFee(address tokenIn, address tokenOut) external onlyOwner {
        bytes32 key = _routeKey(tokenIn, tokenOut);
        require(routes[key].length != 0, 'ROUTE_MISSING');
        delete routeFeeBps[key];
        delete routeFeeConfigured[key];
    }

    function setRouteTwapGuard(address tokenIn, address tokenOut, uint32 window, uint16 maxDeviationBps)
        external onlyOwner
    {
        bytes32 key = _routeKey(tokenIn, tokenOut);
        require(routes[key].length != 0, 'ROUTE_MISSING');
        require(window != 0, 'TWAP_WINDOW_ZERO');
        require(maxDeviationBps <= MAX_TWAP_DEVIATION_BPS, 'TWAP_DEVIATION_TOO_HIGH');
        routeTwapGuards[key] = TwapGuard(window, maxDeviationBps, true);
        emit RouteTwapGuardUpdated(tokenIn, tokenOut, window, maxDeviationBps);
    }

    function routeTwapGuard(address tokenIn, address tokenOut)
        external view returns (uint32 window, uint16 maxDeviationBps, bool configured)
    {
        TwapGuard memory guard = routeTwapGuards[_routeKey(tokenIn, tokenOut)];
        return (guard.window, guard.maxDeviationBps, guard.configured);
    }

    function twapMinimumOut(address tokenIn, address tokenOut, uint256 amountIn)
        external view returns (uint256 minimumNetAmountOut)
    {
        bytes32 key = _routeKey(tokenIn, tokenOut);
        bytes memory path = routes[key];
        require(path.length != 0, 'ROUTE_MISSING');
        TwapGuard memory guard = routeTwapGuards[key];
        require(guard.configured, 'TWAP_NOT_CONFIGURED');
        uint256 gross = _twapQuote(path, amountIn, guard.window);
        uint16 applicableFee = routeFeeConfigured[key] ? routeFeeBps[key] : feeBps;
        uint256 net = FullMath.mulDiv(gross, 10000 - applicableFee, 10000);
        minimumNetAmountOut = FullMath.mulDiv(net, 10000 - guard.maxDeviationBps, 10000);
    }

    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minNetAmountOut,
        address recipient,
        uint256 deadline
    ) external lock returns (uint256 netAmountOut) {
        require(block.timestamp <= deadline, 'EXPIRED');
        require(amountIn > 0, 'ZERO_INPUT');
        require(recipient != address(0) && recipient != address(this), 'BAD_RECIPIENT');
        bytes32 key = _routeKey(tokenIn, tokenOut);
        bytes memory path = routes[key];
        require(path.length != 0, 'ROUTE_MISSING');
        require(routeTwapGuards[key].configured, 'TWAP_NOT_CONFIGURED');
        uint16 applicableFee = routeFeeConfigured[key] ? routeFeeBps[key] : feeBps;
        uint256 effectiveMinimum = _minimumWithTwap(key, path, amountIn, applicableFee, minNetAmountOut);
        uint256 beforeOut = IRouterBalanceToken(tokenOut).balanceOf(address(this));
        uint256 grossOut = _exactInput(path, amountIn);
        uint256 afterOut = IRouterBalanceToken(tokenOut).balanceOf(address(this));
        require(afterOut >= beforeOut, 'OUTPUT_DECREASED');
        uint256 observedOut = afterOut - beforeOut;
        require(observedOut == grossOut, 'NONSTANDARD_OUTPUT');
        uint256 feeAmount = FullMath.mulDiv(observedOut, applicableFee, 10000);
        netAmountOut = observedOut - feeAmount;
        require(netAmountOut >= effectiveMinimum, 'TOO_LITTLE_NET');
        if (feeAmount != 0) TransferHelper.safeTransfer(tokenOut, feeRecipient, feeAmount);
        TransferHelper.safeTransfer(tokenOut, recipient, netAmountOut);
        require(IRouterBalanceToken(tokenOut).balanceOf(address(this)) == beforeOut, 'OUTPUT_RESIDUE');
    }

    /// @dev Only the Katana factory's deterministic pool for the encoded hop can invoke this.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        require(unlocked == 2, 'NO_ACTIVE_SWAP');
        require((amount0Delta > 0 && amount1Delta <= 0) || (amount1Delta > 0 && amount0Delta <= 0), 'BAD_DELTA');
        SwapCallbackData memory decoded = abi.decode(data, (SwapCallbackData));
        (address tokenIn, address tokenOut, uint24 poolFee) = decoded.path.decodeFirstPool();
        require(msg.sender == _poolFor(tokenIn, tokenOut, poolFee), 'INVALID_POOL');
        require(msg.sender == activePool && decoded.payer == activePayer && !callbackConsumed, 'UNEXPECTED_CALLBACK');
        bool zeroForOne = tokenIn < tokenOut;
        int256 inputDelta = zeroForOne ? amount0Delta : amount1Delta;
        require(inputDelta > 0 && uint256(inputDelta) <= activeAmountIn, 'BAD_INPUT_DELTA');
        uint256 amountToPay = uint256(inputDelta);
        callbackConsumed = true;
        if (decoded.payer == address(this)) {
            TransferHelper.safeTransfer(tokenIn, msg.sender, amountToPay);
        } else {
            TransferHelper.safeTransferFrom(tokenIn, decoded.payer, msg.sender, amountToPay);
        }
    }

    function _exactInput(bytes memory path, uint256 amountIn) private returns (uint256 amountOut) {
        address payer = msg.sender;
        while (true) {
            bool multiple = path.hasMultiplePools();
            amountIn = _exactInputInternal(amountIn, path.getFirstPool(), payer);
            if (multiple) {
                payer = address(this);
                path = path.skipToken();
            } else {
                amountOut = amountIn;
                break;
            }
        }
    }

    function _exactInputInternal(uint256 amountIn, bytes memory poolPath, address payer)
        private returns (uint256 amountOut)
    {
        (address tokenIn, address tokenOut, uint24 poolFee) = poolPath.decodeFirstPool();
        bool zeroForOne = tokenIn < tokenOut;
        int256 outputDelta = _poolSwap(
            _poolFor(tokenIn, tokenOut, poolFee), zeroForOne, amountIn, poolPath, payer
        );
        amountOut = uint256(-outputDelta);
    }

    function _poolSwap(address pool, bool zeroForOne, uint256 amountIn, bytes memory poolPath, address payer)
        private returns (int256 outputDelta)
    {
        require(activePool == address(0), 'NESTED_POOL_SWAP');
        activePool = pool;
        activePayer = payer;
        activeAmountIn = amountIn;
        callbackConsumed = false;
        (int256 amount0, int256 amount1) = IUniswapV3Pool(pool).swap(
            address(this),
            zeroForOne,
            amountIn.toInt256(),
            zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            abi.encode(SwapCallbackData({path: poolPath, payer: payer}))
        );
        require(callbackConsumed, 'CALLBACK_MISSING');
        activePool = address(0);
        activePayer = address(0);
        activeAmountIn = 0;
        outputDelta = zeroForOne ? amount1 : amount0;
    }

    function _setRoute(address tokenIn, address tokenOut, bytes memory path) private {
        require(tokenIn != address(0) && tokenOut != address(0) && tokenIn != tokenOut, 'BAD_ENDPOINTS');
        require(path.length >= 43 && (path.length - 20) % 23 == 0, 'BAD_PATH_LENGTH');
        uint256 pools = path.numPools();
        address[] memory seen = new address[](pools + 1);
        bytes memory remaining = path;
        for (uint256 i = 0; i < pools; i++) {
            (address a, address b, uint24 poolFee) = remaining.decodeFirstPool();
            require(a != address(0) && b != address(0) && a != b, 'BAD_HOP');
            for (uint256 j = 0; j <= i; j++) require(seen[j] != b, 'REPEATED_TOKEN');
            if (i == 0) {
                require(a == tokenIn, 'WRONG_INPUT');
                seen[0] = a;
            } else {
                require(a == seen[i], 'DISCONNECTED_PATH');
            }
            seen[i + 1] = b;
            address pool = _poolFor(a, b, poolFee);
            require(pool == IUniswapV3Factory(FACTORY).getPool(a, b, poolFee), 'POOL_MISMATCH');
            uint256 size;
            assembly { size := extcodesize(pool) }
            require(size != 0, 'POOL_MISSING');
            IUniswapV3Pool verified = IUniswapV3Pool(pool);
            require(verified.factory() == FACTORY && verified.fee() == poolFee, 'POOL_METADATA');
            require(verified.token0() == (a < b ? a : b) && verified.token1() == (a < b ? b : a), 'POOL_TOKENS');
            if (i + 1 < pools) remaining = remaining.skipToken();
        }
        require(seen[pools] == tokenOut, 'WRONG_OUTPUT');
        bytes32 key = _routeKey(tokenIn, tokenOut);
        routes[key] = path;
        delete routeFeeBps[key];
        delete routeFeeConfigured[key];
        if (!routeTwapGuards[key].configured) {
            routeTwapGuards[key] = TwapGuard(DEFAULT_TWAP_WINDOW, DEFAULT_TWAP_DEVIATION_BPS, true);
        }
    }

    function _routeKey(address tokenIn, address tokenOut) private pure returns (bytes32) {
        return keccak256(abi.encode(tokenIn, tokenOut));
    }

    function _twapQuote(bytes memory path, uint256 amountIn, uint32 window)
        private view returns (uint256 amountOut)
    {
        require(amountIn > 0, 'ZERO_INPUT');
        amountOut = amountIn;
        bytes memory remaining = path;
        while (true) {
            (address tokenIn, address tokenOut, uint24 poolFee) = remaining.decodeFirstPool();
            address pool = _poolFor(tokenIn, tokenOut, poolFee);
            (int24 meanTick, ) = OracleLibrary.consult(pool, window);
            amountOut = _quoteAtTick(meanTick, amountOut, tokenIn, tokenOut);
            amountOut = FullMath.mulDiv(amountOut, 1000000 - poolFee, 1000000);
            if (!remaining.hasMultiplePools()) break;
            remaining = remaining.skipToken();
        }
    }

    function _minimumWithTwap(
        bytes32 key,
        bytes memory path,
        uint256 amountIn,
        uint16 applicableFee,
        uint256 configuredMinimum
    ) private view returns (uint256 minimum) {
        TwapGuard memory guard = routeTwapGuards[key];
        minimum = FullMath.mulDiv(_twapQuote(path, amountIn, guard.window), 10000 - applicableFee, 10000);
        minimum = FullMath.mulDiv(minimum, 10000 - guard.maxDeviationBps, 10000);
        if (configuredMinimum > minimum) minimum = configuredMinimum;
    }

    function _quoteAtTick(int24 tick, uint256 baseAmount, address baseToken, address quoteToken)
        private pure returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
        if (sqrtRatioX96 <= uint160(type(uint128).max)) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }

    function _poolFor(address tokenA, address tokenB, uint24 poolFee) private pure returns (address) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 salt = keccak256(abi.encode(token0, token1, poolFee));
        return address(uint160(uint256(keccak256(abi.encodePacked(hex'ff', FACTORY, salt, KATANA_POOL_INIT_CODE_HASH)))));
    }
}
