// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "contracts/fuses/uniswap/ext/TickMath.sol";
import {LiquidityAmounts} from "contracts/fuses/uniswap/ext/LiquidityAmounts.sol";

interface IFarmPlannerView {
    function AVKAT() external view returns (address);
    function ROUTER() external view returns (address);
    function NPM() external view returns (address);
    function twapWindow() external view returns (uint32);
    function tokens() external view returns (address[] memory);
    function positionIds() external view returns (uint256[] memory);
    function charmVaults() external view returns (address[] memory);
}

interface IFarmRouterQuote {
    function protectedQuote(address tokenIn, address tokenOut, uint256 amountIn)
        external view returns (uint256 expectedNet, uint256 minimumNet);
}

interface IFarmNpmView {
    function factory() external view returns (address);
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

interface IFarmV3FactoryView {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IFarmV3PoolView {
    function observe(uint32[] calldata secondsAgos)
        external view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

interface IFarmCharmView {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function getTotalAmounts() external view returns (uint256 total0, uint256 total1);
}

/// @notice One farm position's share of a pro-rata deploy: how much avKAT to turn into each of its two tokens.
struct FarmDeployLeg {
    uint8 kind; // 1 = Sushi V3 NFT, 2 = Charm vault
    uint256 tokenId; // kind 1
    address vault; // kind 2
    address token0;
    address token1;
    uint256 avkatFor0;
    uint256 avkatFor1;
}

/// @title CurveYieldCustodyFarmPlanner
/// @notice View-only planning for CurveYieldCustodyFarm (CUSTODY_FARM_SPEC): values every farm holding in avKAT and
/// sizes the pro-rata deploy of new avKAT over the active positions. It holds nothing and changes nothing.
///   - token values: the swap router v2's protected quote to avKAT (hook-oracle / Sushi TWAP based), avKAT 1:1;
///   - Sushi V3 positions: amounts of their liquidity at the pool's TWAP price (router window) + owed tokens;
///   - Charm vaults: the farm's share of `getTotalAmounts()`.
contract CurveYieldCustodyFarmPlanner {
    uint8 public constant KIND_SUSHI = 1;
    uint8 public constant KIND_CHARM = 2;

    /// @notice avKAT value of `amount_` of `token_` (0 when the router cannot quote it).
    function valueInAvkat(address farm_, address token_, uint256 amount_) public view returns (uint256) {
        if (amount_ == 0) return 0;
        address avkat = IFarmPlannerView(farm_).AVKAT();
        if (token_ == avkat) return amount_;
        try IFarmRouterQuote(IFarmPlannerView(farm_).ROUTER()).protectedQuote(token_, avkat, amount_) returns (
            uint256 expected, uint256
        ) {
            return expected;
        } catch {
            return 0;
        }
    }

    /// @notice Token amounts of a Sushi V3 position (liquidity at the pool's TWAP price + tokens owed).
    function sushiAmounts(address farm_, uint256 tokenId_)
        public view returns (address token0_, address token1_, uint256 amount0_, uint256 amount1_)
    {
        address npm = IFarmPlannerView(farm_).NPM();
        (,, address t0, address t1, uint24 fee, int24 lower, int24 upper, uint128 liquidity,,, uint128 owed0, uint128 owed1)
        = IFarmNpmView(npm).positions(tokenId_);
        (token0_, token1_) = (t0, t1);
        if (liquidity != 0) {
            address pool = IFarmV3FactoryView(IFarmNpmView(npm).factory()).getPool(t0, t1, fee);
            uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(_twapTick(pool, IFarmPlannerView(farm_).twapWindow()));
            (amount0_, amount1_) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPrice, TickMath.getSqrtRatioAtTick(lower), TickMath.getSqrtRatioAtTick(upper), liquidity
            );
        }
        amount0_ += owed0;
        amount1_ += owed1;
    }

    /// @notice Token amounts behind the farm's shares of a Charm vault.
    function charmAmounts(address farm_, address vault_)
        public view returns (address token0_, address token1_, uint256 amount0_, uint256 amount1_)
    {
        IFarmCharmView vault = IFarmCharmView(vault_);
        (token0_, token1_) = (vault.token0(), vault.token1());
        uint256 shares = vault.balanceOf(farm_);
        uint256 supply = vault.totalSupply();
        if (shares == 0 || supply == 0) return (token0_, token1_, 0, 0);
        (uint256 total0, uint256 total1) = vault.getTotalAmounts();
        amount0_ = Math.mulDiv(total0, shares, supply);
        amount1_ = Math.mulDiv(total1, shares, supply);
    }

    function sushiValue(address farm_, uint256 tokenId_) public view returns (uint256) {
        (address t0, address t1, uint256 a0, uint256 a1) = sushiAmounts(farm_, tokenId_);
        return valueInAvkat(farm_, t0, a0) + valueInAvkat(farm_, t1, a1);
    }

    function charmValue(address farm_, address vault_) public view returns (uint256) {
        (address t0, address t1, uint256 a0, uint256 a1) = charmAmounts(farm_, vault_);
        return valueInAvkat(farm_, t0, a0) + valueInAvkat(farm_, t1, a1);
    }

    /// @notice Everything the farm holds, in avKAT: idle allowed tokens + Sushi V3 positions + Charm shares.
    function totalValueAvkat(address farm_) external view returns (uint256 total_) {
        IFarmPlannerView farm = IFarmPlannerView(farm_);
        address[] memory tokens = farm.tokens();
        for (uint256 i; i < tokens.length; ++i) {
            total_ += valueInAvkat(farm_, tokens[i], IERC20(tokens[i]).balanceOf(farm_));
        }
        uint256[] memory ids = farm.positionIds();
        for (uint256 i; i < ids.length; ++i) total_ += sushiValue(farm_, ids[i]);
        address[] memory vaults = farm.charmVaults();
        for (uint256 i; i < vaults.length; ++i) total_ += charmValue(farm_, vaults[i]);
    }

    /// @notice The farm holds at least one active (value-holding) position.
    function hasActivePositions(address farm_) external view returns (bool) {
        IFarmPlannerView farm = IFarmPlannerView(farm_);
        uint256[] memory ids = farm.positionIds();
        for (uint256 i; i < ids.length; ++i) if (sushiValue(farm_, ids[i]) != 0) return true;
        address[] memory vaults = farm.charmVaults();
        for (uint256 i; i < vaults.length; ++i) if (charmValue(farm_, vaults[i]) != 0) return true;
        return false;
    }

    /// @notice Splits `amountAvkat_` over the active positions in proportion to their current value; each leg is split
    /// between the position's two tokens in the value ratio it currently holds.
    function deployPlan(address farm_, uint256 amountAvkat_) external view returns (FarmDeployLeg[] memory legs_) {
        IFarmPlannerView farm = IFarmPlannerView(farm_);
        uint256[] memory ids = farm.positionIds();
        address[] memory vaults = farm.charmVaults();
        uint256 n = ids.length + vaults.length;
        FarmDeployLeg[] memory all = new FarmDeployLeg[](n);
        uint256[] memory values = new uint256[](n);
        uint256[2][] memory sides = new uint256[2][](n);
        uint256 totalValue;
        for (uint256 i; i < ids.length; ++i) {
            (address t0, address t1, uint256 a0, uint256 a1) = sushiAmounts(farm_, ids[i]);
            sides[i] = [valueInAvkat(farm_, t0, a0), valueInAvkat(farm_, t1, a1)];
            all[i] = FarmDeployLeg(KIND_SUSHI, ids[i], address(0), t0, t1, 0, 0);
        }
        for (uint256 j; j < vaults.length; ++j) {
            (address t0, address t1, uint256 a0, uint256 a1) = charmAmounts(farm_, vaults[j]);
            uint256 k = ids.length + j;
            sides[k] = [valueInAvkat(farm_, t0, a0), valueInAvkat(farm_, t1, a1)];
            all[k] = FarmDeployLeg(KIND_CHARM, 0, vaults[j], t0, t1, 0, 0);
        }
        uint256 active;
        for (uint256 i; i < n; ++i) {
            values[i] = sides[i][0] + sides[i][1];
            totalValue += values[i];
            if (values[i] != 0) ++active;
        }
        legs_ = new FarmDeployLeg[](active);
        if (active == 0 || amountAvkat_ == 0) return legs_;
        uint256 k2;
        for (uint256 i; i < n; ++i) {
            if (values[i] == 0) continue;
            uint256 share = Math.mulDiv(amountAvkat_, values[i], totalValue);
            all[i].avkatFor0 = Math.mulDiv(share, sides[i][0], values[i]);
            all[i].avkatFor1 = share - all[i].avkatFor0;
            legs_[k2++] = all[i];
        }
    }

    /// @dev Arithmetic-mean tick of a V3 pool over `window_` seconds (rounded toward negative infinity).
    function _twapTick(address pool_, uint32 window_) private view returns (int24) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = window_;
        (int56[] memory cumulatives,) = IFarmV3PoolView(pool_).observe(ago);
        int56 delta = cumulatives[1] - cumulatives[0];
        int56 w = int56(uint56(window_));
        int24 tick = int24(delta / w);
        if (delta < 0 && (delta % w != 0)) --tick;
        return tick;
    }
}
