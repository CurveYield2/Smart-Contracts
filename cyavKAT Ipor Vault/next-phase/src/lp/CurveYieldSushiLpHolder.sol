// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CurveYieldAddrKeys, ICurveYieldConfigGate} from "../governance/CurveYieldGateConfig.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {TickMath} from "contracts/fuses/uniswap/ext/TickMath.sol";
import {LiquidityAmounts} from "contracts/fuses/uniswap/ext/LiquidityAmounts.sol";
import {INonfungiblePositionManager} from "contracts/fuses/uniswap/ext/INonfungiblePositionManager.sol";
import {ICyMorphoOracle} from "../interfaces/CurveYieldPhase2Interfaces.sol";

interface ICyV3Pool {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);
    function ticks(int24 tick)
        external view returns (uint128, int128, uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128, int56, uint160, uint32, bool);
}

interface ICyFeeRouter {
    function swapExactInput(address tokenIn, address tokenOut, uint256 amountIn, uint256 minNetOut, address recipient, uint256 deadline)
        external returns (uint256 netAmountOut);
    function twapMinimumOut(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256);
}

interface ICyQuoterV2 {
    function quoteExactInput(bytes memory path, uint256 amountIn) external returns (uint256, uint160[] memory, uint32[] memory, uint256);
    function quoteExactOutput(bytes memory path, uint256 amountOut) external returns (uint256, uint160[] memory, uint32[] memory, uint256);
}

interface ICyLpHolderSettings {
    function holderSettings() external view returns (uint256 targetLtvBps, uint256 slippageBps);
}

struct CyLpPosition {
    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint256 lpAvkat; // avKAT in the LP at the current pool price
    uint256 lpKat; // KAT in the LP at the current pool price
    uint256 collateralAvkat; // Morpho 0x80e6 collateral
    uint256 debtKat; // Morpho 0x80e6 debt
    uint256 ltvBps; // Morpho LTV (oracle, conversion basis)
    uint256 basisAvkat; // avKAT put in, net of what was returned (#19)
    uint256 idleAvkat;
    uint256 idleKat;
}

/// @notice Holds the Sushi V3 1% avKAT/KAT LP NFT and its own Morpho position in market 0x80e6 (avKAT collateral, KAT
/// loan). Each unit of avKAT is split into Morpho collateral and LP avKAT; the KAT borrowed at the target LTV is the
/// LP's KAT side. Only the vault (through the LP fuses) can move funds; everything returns to the vault.
///
/// Tracks the exact avKAT basis put in (#19). Uncollected fees are not valued until collected: every action collects
/// them, and `collectFees` (permissionless) moves them into the holder's valued idle balances in between. Swaps go through the CurveYield fee router (TWAP floor) with a QuoterV2 slippage check.
contract CurveYieldSushiLpHolder is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MorphoBalancesLib for IMorpho;

    uint256 private constant BPS = 10_000;
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;
    uint24 public constant POOL_FEE = 10_000;

    address public immutable VAULT;
    /// @notice Wired in the gate (`CurveYieldAddrKeys.LP_CONTROLLER`, GATE_CONFIG_SPEC §10).
    function CONTROLLER() public view returns (address) {
        return ICurveYieldConfigGate(GATE).addr(CurveYieldAddrKeys.LP_CONTROLLER);
    }
    IMorpho public immutable MORPHO;
    bytes32 public immutable MARKET_ID;
    address public immutable AVKAT;
    address public immutable KAT;
    INonfungiblePositionManager public immutable NPM;
    address public immutable POOL;
    ICyFeeRouter public immutable ROUTER;
    ICyQuoterV2 public immutable QUOTER;

    uint256 public tokenId;
    int24 public tickLower;
    int24 public tickUpper;
    uint256 public basisAvkat;
    bytes32 private _flashHash;

    error OnlyVault(address caller);
    error InvalidAddress();
    error PositionExists();
    error NoPosition();
    error PriceOutsideRange();
    error InsufficientAvkatToRepay(uint256 needed, uint256 available);
    error InvalidFlashCallback();

    event Deployed(uint256 indexed tokenId, uint256 avkatIn, uint256 collateral, uint256 borrowedKat, uint128 liquidity);
    event Unwound(uint256 indexed tokenId, uint256 bps, uint256 avkatOut);
    event Deleveraged(uint256 repaidKat, uint256 soldAvkat, uint256 ltvAfter);

    modifier onlyVault() {
        if (msg.sender != VAULT) revert OnlyVault(msg.sender);
        _;
    }
    /// @notice The governance gate (wiring anchor, GATE_CONFIG_SPEC §10).
    address public immutable GATE;

    constructor(
        address vault_, address gate_, address morpho_, bytes32 marketId_, address avkat_, address kat_,
        address npm_, address pool_, address router_, address quoter_
    ) {
        if (vault_ == address(0) || gate_ == address(0) || morpho_ == address(0) || avkat_ == address(0) ||
            kat_ == address(0) || npm_ == address(0) || pool_ == address(0) || router_ == address(0) || quoter_ == address(0)
        ) revert InvalidAddress();
        VAULT = vault_;
        GATE = gate_;
        MORPHO = IMorpho(morpho_);
        MARKET_ID = marketId_;
        AVKAT = avkat_;
        KAT = kat_;
        NPM = INonfungiblePositionManager(npm_);
        POOL = pool_;
        ROUTER = ICyFeeRouter(router_);
        QUOTER = ICyQuoterV2(quoter_);
    }

    // ---------------------------------------------------------------- vault actions

    /// @notice Opens the position in [lower, upper) with all avKAT the vault has sent here.
    function open(int24 lower_, int24 upper_) external onlyVault nonReentrant {
        if (tokenId != 0) revert PositionExists();
        uint256 amount = IERC20(AVKAT).balanceOf(address(this));
        basisAvkat += amount;
        (tickLower, tickUpper) = (lower_, upper_);
        _deploy(amount);
    }

    /// @notice Adds the avKAT the vault has sent here to the existing range.
    function increase() external onlyVault nonReentrant {
        if (tokenId == 0) revert NoPosition();
        uint256 amount = IERC20(AVKAT).balanceOf(address(this));
        basisAvkat += amount;
        _deploy(amount);
    }

    /// @notice Unwinds `bps_` of the position (10,000 = all, which also burns the NFT) and sends the avKAT to the vault.
    function withdraw(uint256 bps_) external onlyVault nonReentrant returns (uint256 avkatOut_) {
        if (tokenId == 0) revert NoPosition();
        avkatOut_ = _unwind(bps_);
        uint256 basisOut = bps_ >= BPS ? basisAvkat : basisAvkat * bps_ / BPS;
        basisAvkat -= basisOut;
        IERC20(AVKAT).safeTransfer(VAULT, avkatOut_);
        emit Unwound(tokenId, bps_, avkatOut_);
        if (bps_ >= BPS) tokenId = 0;
    }

    /// @notice Closes and reopens all capital in a new range; nothing leaves the holder, the basis is unchanged.
    function rebalance(int24 lower_, int24 upper_) external onlyVault nonReentrant {
        if (tokenId == 0) revert NoPosition();
        uint256 id = tokenId;
        uint256 amount = _unwind(BPS);
        emit Unwound(id, BPS, amount);
        tokenId = 0;
        (tickLower, tickUpper) = (lower_, upper_);
        _deploy(amount);
    }

    /// @notice Collects the position's swap fees into the holder, where `position()` values them. Anyone may call it:
    /// nothing leaves the holder and no price is touched.
    function collectFees() external nonReentrant {
        if (tokenId == 0) return;
        NPM.collect(INonfungiblePositionManager.CollectParams({
            tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
        }));
    }

    /// @notice Emergency de-leverage of the holder's Morpho position to `targetLtvBps_` with a Morpho flash loan:
    /// repay debt, withdraw collateral, sell it for KAT. The LP itself is left untouched.
    function deleverage(uint256 targetLtvBps_) external onlyVault nonReentrant {
        (uint256 collateral, uint256 debt, uint256 value) = _morphoPosition();
        uint256 targetDebt = value * targetLtvBps_ / BPS;
        if (debt <= targetDebt) return;
        // Fixed point: repay R and sell W avKAT with W = inputFor(R) and R = debt - (C - W) * value/C * target.
        uint256 withdraw_;
        uint256 repay;
        for (uint256 i; i < 16; ++i) {
            uint256 remainingValue = (collateral - withdraw_) * value / collateral;
            repay = debt - remainingValue * targetLtvBps_ / BPS;
            uint256 sell = _avkatInFor(repay);
            if (sell <= withdraw_ + withdraw_ / 10_000 + 1) break;
            withdraw_ = sell + (sell - withdraw_) * 4; // over-relaxed: plain iteration closes ~20% per step
            if (withdraw_ >= collateral) withdraw_ = collateral - 1;
        }
        bytes memory data = abi.encode(repay, withdraw_);
        _flashHash = keccak256(data);
        MORPHO.flashLoan(KAT, repay, data);
        _flashHash = bytes32(0);
        _sweepKat();
        emit Deleveraged(repay, withdraw_, _ltvBps());
    }

    function onMorphoFlashLoan(uint256 assets_, bytes calldata data_) external {
        if (msg.sender != address(MORPHO) || _flashHash == bytes32(0) || keccak256(data_) != _flashHash) {
            revert InvalidFlashCallback();
        }
        (uint256 repay, uint256 withdraw_) = abi.decode(data_, (uint256, uint256));
        MarketParams memory p = MORPHO.idToMarketParams(Id.wrap(MARKET_ID));
        IERC20(KAT).forceApprove(address(MORPHO), assets_);
        MORPHO.repay(p, repay, 0, address(this), "");
        MORPHO.withdrawCollateral(p, withdraw_, address(this), address(this));
        _swap(AVKAT, KAT, withdraw_);
        IERC20(KAT).forceApprove(address(MORPHO), assets_); // Morpho pulls the flash repayment
    }

    // ---------------------------------------------------------------- views

    function position() public view returns (CyLpPosition memory p_) {
        p_.tokenId = tokenId;
        p_.tickLower = tickLower;
        p_.tickUpper = tickUpper;
        p_.basisAvkat = basisAvkat;
        p_.idleAvkat = IERC20(AVKAT).balanceOf(address(this));
        p_.idleKat = IERC20(KAT).balanceOf(address(this));
        if (tokenId != 0) {
            (,,,,,,, uint128 liquidity, uint256 last0, uint256 last1, uint128 owed0, uint128 owed1) = NPM.positions(tokenId);
            p_.liquidity = liquidity;
            (uint160 sqrtP, int24 tick,,,,,) = ICyV3Pool(POOL).slot0();
            (p_.lpAvkat, p_.lpKat) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtP, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity
            );
            // pending (uncollected) swap fees are part of the position's value; token0 = avKAT, token1 = KAT
            (uint256 fee0, uint256 fee1) = _pendingFees(tick, liquidity, last0, last1);
            p_.lpAvkat += fee0 + owed0;
            p_.lpKat += fee1 + owed1;
        }
        uint256 value;
        (p_.collateralAvkat, p_.debtKat, value) = _morphoPosition();
        p_.ltvBps = value == 0 ? 0 : p_.debtKat * BPS / value;
    }

    /// @notice Share of the position's value in KAT for a range at the current pool price (bps), used for the 5% rule.
    function katShareBps(int24 lower_, int24 upper_) public view returns (uint256) {
        (uint160 sqrtP,,,,,,) = ICyV3Pool(POOL).slot0();
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP, TickMath.getSqrtRatioAtTick(lower_), TickMath.getSqrtRatioAtTick(upper_), 1e24
        );
        uint256 a0InKat = Math.mulDiv(a0, _poolPriceX18(sqrtP), 1e18);
        return a0InKat + a1 == 0 ? 0 : a1 * BPS / (a0InKat + a1);
    }

    function currentTick() external view returns (int24 tick_) {
        (, tick_,,,,,) = ICyV3Pool(POOL).slot0();
    }

    // ---------------------------------------------------------------- internal: deploy / unwind

    /// @dev Split `amount_` avKAT into collateral C and LP avKAT (A - C); borrow K KAT at the target LTV for the LP's
    /// KAT side. With r = KAT per avKAT the range needs and Lp = targetLtv * oracle price: C = r*A / (Lp + r), K = Lp*C.
    function _deploy(uint256 amount_) private {
        if (amount_ == 0) return;
        (uint160 sqrtP,,,,,,) = ICyV3Pool(POOL).slot0();
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(tickUpper);
        if (sqrtP >= sqrtB) revert PriceOutsideRange(); // all-KAT range: nothing to pair the avKAT with
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, 1e24);
        uint256 r = a0 == 0 ? 0 : Math.mulDiv(a1, 1e18, a0); // KAT per avKAT, 1e18
        (uint256 targetLtv,) = ICyLpHolderSettings(CONTROLLER()).holderSettings();
        MarketParams memory mp = MORPHO.idToMarketParams(Id.wrap(MARKET_ID));
        uint256 lp = Math.mulDiv(ICyMorphoOracle(mp.oracle).price(), targetLtv, ORACLE_PRICE_SCALE / 1e18 * BPS); // 1e18
        uint256 collateral = r == 0 ? 0 : Math.mulDiv(amount_, r, lp + r);
        uint256 borrow = Math.mulDiv(collateral, lp, 1e18);

        if (collateral != 0) {
            IERC20(AVKAT).forceApprove(address(MORPHO), collateral);
            MORPHO.supplyCollateral(mp, collateral, address(this), "");
            MORPHO.borrow(mp, borrow, 0, address(this), address(this));
        }
        uint256 avkatForLp = IERC20(AVKAT).balanceOf(address(this));
        uint256 katForLp = IERC20(KAT).balanceOf(address(this));
        IERC20(AVKAT).forceApprove(address(NPM), avkatForLp);
        IERC20(KAT).forceApprove(address(NPM), katForLp);
        uint128 liquidity;
        if (tokenId == 0) {
            (tokenId, liquidity,,) = NPM.mint(INonfungiblePositionManager.MintParams({
                token0: AVKAT, token1: KAT, fee: POOL_FEE, tickLower: tickLower, tickUpper: tickUpper,
                amount0Desired: avkatForLp, amount1Desired: katForLp, amount0Min: 0, amount1Min: 0,
                recipient: address(this), deadline: block.timestamp
            }));
        } else {
            (liquidity,,) = NPM.increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId, amount0Desired: avkatForLp, amount1Desired: katForLp, amount0Min: 0, amount1Min: 0,
                deadline: block.timestamp
            }));
        }
        IERC20(AVKAT).forceApprove(address(NPM), 0);
        IERC20(KAT).forceApprove(address(NPM), 0);
        emit Deployed(tokenId, amount_, collateral, borrow, liquidity);
    }

    /// @dev Remove `bps_` of the liquidity (+ all fees), repay the same share of the debt (selling LP avKAT for any KAT
    /// shortfall), withdraw the same share of the collateral, and turn leftover KAT back into avKAT. Returns avKAT held.
    function _unwind(uint256 bps_) private returns (uint256 avkatOut_) {
        if (bps_ > BPS) bps_ = BPS;
        (,,,,,,, uint128 liquidity,,,,) = NPM.positions(tokenId);
        uint128 remove = bps_ >= BPS ? liquidity : uint128(uint256(liquidity) * bps_ / BPS);
        if (remove != 0) {
            NPM.decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: remove, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            }));
        }
        NPM.collect(INonfungiblePositionManager.CollectParams({
            tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
        }));
        if (bps_ >= BPS) NPM.burn(tokenId);

        (uint256 collateral, uint256 debt,) = _morphoPosition();
        uint256 repay = bps_ >= BPS ? debt : debt * bps_ / BPS;
        uint256 katHeld = IERC20(KAT).balanceOf(address(this));
        if (katHeld < repay) {
            uint256 need = repay - katHeld;
            uint256 sell = _avkatInFor(need);
            uint256 available = IERC20(AVKAT).balanceOf(address(this));
            if (sell > available) revert InsufficientAvkatToRepay(sell, available);
            _swap(AVKAT, KAT, sell);
        }
        MarketParams memory mp = MORPHO.idToMarketParams(Id.wrap(MARKET_ID));
        if (repay != 0) {
            IERC20(KAT).forceApprove(address(MORPHO), repay);
            if (bps_ >= BPS) {
                MORPHO.repay(mp, 0, MORPHO.position(Id.wrap(MARKET_ID), address(this)).borrowShares, address(this), "");
            } else {
                MORPHO.repay(mp, repay, 0, address(this), "");
            }
            IERC20(KAT).forceApprove(address(MORPHO), 0);
        }
        uint256 withdrawCollateral = bps_ >= BPS ? collateral : collateral * bps_ / BPS;
        if (withdrawCollateral != 0) MORPHO.withdrawCollateral(mp, withdrawCollateral, address(this), address(this));
        _sweepKat();
        avkatOut_ = IERC20(AVKAT).balanceOf(address(this));
    }

    // ---------------------------------------------------------------- internal: swaps / prices

    /// @dev avKAT input (with a 0.5% buffer) that buys at least `katOut_` KAT, via QuoterV2 exact-output.
    function _avkatInFor(uint256 katOut_) private returns (uint256) {
        if (katOut_ == 0) return 0;
        (uint256 amountIn,,,) = QUOTER.quoteExactOutput(abi.encodePacked(KAT, POOL_FEE, AVKAT), katOut_);
        return amountIn + amountIn / 200;
    }

    function _swap(address in_, address out_, uint256 amountIn_) private returns (uint256 out) {
        if (amountIn_ == 0) return 0;
        (, uint256 slippageBps) = ICyLpHolderSettings(CONTROLLER()).holderSettings();
        (uint256 quoted,,,) = QUOTER.quoteExactInput(abi.encodePacked(in_, POOL_FEE, out_), amountIn_);
        uint256 minOut = quoted * (BPS - slippageBps) / BPS;
        IERC20(in_).forceApprove(address(ROUTER), amountIn_);
        out = ROUTER.swapExactInput(in_, out_, amountIn_, minOut, address(this), block.timestamp);
        IERC20(in_).forceApprove(address(ROUTER), 0);
    }

    /// @dev Leftover KAT (after repaying) goes back to avKAT when it is large enough to quote.
    function _sweepKat() private {
        uint256 k = IERC20(KAT).balanceOf(address(this));
        if (k > 1e15) _swap(KAT, AVKAT, k);
    }

    function _morphoPosition() private view returns (uint256 collateral_, uint256 debt_, uint256 value_) {
        MarketParams memory mp = MORPHO.idToMarketParams(Id.wrap(MARKET_ID));
        collateral_ = MORPHO.position(Id.wrap(MARKET_ID), address(this)).collateral;
        debt_ = MORPHO.expectedBorrowAssets(mp, address(this));
        value_ = Math.mulDiv(collateral_, ICyMorphoOracle(mp.oracle).price(), ORACLE_PRICE_SCALE);
    }

    function _ltvBps() private view returns (uint256) {
        (, uint256 debt, uint256 value) = _morphoPosition();
        return value == 0 ? 0 : debt * BPS / value;
    }

    /// @dev Pool price in KAT per avKAT (token1 per token0), 1e18.
    /// @dev Uniswap V3 fee accounting: fees earned since the position's last poke (wrapping arithmetic by design).
    function _pendingFees(int24 tick_, uint128 liquidity_, uint256 last0_, uint256 last1_)
        private view returns (uint256 fee0_, uint256 fee1_)
    {
        if (liquidity_ == 0) return (0, 0);
        ICyV3Pool pool = ICyV3Pool(POOL);
        (,, uint256 lo0, uint256 lo1,,,,) = pool.ticks(tickLower);
        (,, uint256 hi0, uint256 hi1,,,,) = pool.ticks(tickUpper);
        uint256 g0 = pool.feeGrowthGlobal0X128();
        uint256 g1 = pool.feeGrowthGlobal1X128();
        unchecked {
            uint256 below0 = tick_ >= tickLower ? lo0 : g0 - lo0;
            uint256 below1 = tick_ >= tickLower ? lo1 : g1 - lo1;
            uint256 above0 = tick_ < tickUpper ? hi0 : g0 - hi0;
            uint256 above1 = tick_ < tickUpper ? hi1 : g1 - hi1;
            fee0_ = Math.mulDiv(g0 - below0 - above0 - last0_, liquidity_, 1 << 128);
            fee1_ = Math.mulDiv(g1 - below1 - above1 - last1_, liquidity_, 1 << 128);
        }
    }

    function _poolPriceX18(uint160 sqrtP_) private pure returns (uint256) {
        return Math.mulDiv(uint256(sqrtP_) * uint256(sqrtP_), 1e18, 1 << 192);
    }
}
