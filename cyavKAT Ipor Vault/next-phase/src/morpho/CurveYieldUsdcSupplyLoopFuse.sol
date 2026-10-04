// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, MarketParams, Id, Market, Position} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-org/morpho-blue/src/interfaces/IOracle.sol";
import {SharesMathLib} from "@morpho-org/morpho-blue/src/libraries/SharesMathLib.sol";
import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {ICurveYieldConfigGate, CurveYieldConfigKeys as K} from "../governance/CurveYieldGateConfig.sol";

struct CurveYieldUsdcSupplyLoopData {
    bytes32 morphoMarketId; // avKAT / vbUSDC (a granted substrate of MARKET_ID)
    uint256 collateralAmount; // avKAT
}

/// @title CurveYieldUsdcSupplyLoopFuse (USDC_SUPPLY_LOOP_SPEC)
/// @notice Idle avKAT -> collateral, borrow the loan token (vbUSDC) to a 33% LTV and supply it back to the SAME market
/// (Merkl supply incentives). Exit / instant withdrawal unwind it proportionally: withdraw supply -> repay -> withdraw
/// collateral. No swaps. Borrowed tokens are supplied straight back, so the market's free liquidity is unchanged and
/// both directions run in chunks of that free liquidity.
/// @dev Runs by delegatecall in the vault. LTV uses the market's own Morpho oracle (the price Morpho liquidates on).
/// Accounting: market 14's Morpho balance fuse (collateral + supply - debt).
contract CurveYieldUsdcSupplyLoopFuse is IFuseCommon {
    using SafeERC20 for IERC20;
    using SharesMathLib for uint256;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IMorpho public immutable MORPHO;
    /// @notice Governance gate (the strategy's TVL cap, `usdcLoop.maxTvlBps`).
    address public immutable GATE;

    uint256 public constant TARGET_LTV = 0.33e18;
    uint256 public constant MAX_LTV = 0.35e18;
    uint256 public constant MAX_CHUNKS = 8;
    uint256 private constant ORACLE_SCALE = 1e36;
    uint256 private constant BPS = 10_000;

    event UsdcSupplyLoopEnter(address version, bytes32 market, uint256 collateral, uint256 borrowedAndSupplied);
    event UsdcSupplyLoopExit(address version, bytes32 market, uint256 collateralOut, uint256 repaid);

    error UnsupportedMarket(bytes32 morphoMarketId);
    error LtvAboveCap(uint256 ltv);
    error TvlCapExceeded(uint256 collateral, uint256 cap);
    error InvalidAddress();

    constructor(uint256 marketId_, address morpho_, address gate_) {
        if (morpho_ == address(0) || gate_ == address(0)) revert InvalidAddress();
        VERSION = address(this);
        MARKET_ID = marketId_;
        MORPHO = IMorpho(morpho_);
        GATE = gate_;
    }

    /// @notice Supplies avKAT as collateral, borrows to the target LTV and supplies the loan token back.
    function enter(CurveYieldUsdcSupplyLoopData memory data_) external returns (uint256 borrowed_) {
        if (data_.collateralAmount == 0) return 0;
        MarketParams memory p = _params(data_.morphoMarketId);
        IERC20 collateral = IERC20(p.collateralToken);
        uint256 amount = Math.min(data_.collateralAmount, collateral.balanceOf(address(this)));
        if (amount != 0) {
            collateral.forceApprove(address(MORPHO), amount);
            MORPHO.supplyCollateral(p, amount, address(this), "");
        }
        MORPHO.accrueInterest(p);
        Id id = Id.wrap(data_.morphoMarketId);
        (uint256 coll, uint256 debt,) = _position(id);
        _checkTvlCap(coll);
        uint256 targetDebt = _collateralValue(p, coll) * TARGET_LTV / 1e18;
        if (targetDebt > debt) borrowed_ = _borrowAndSupply(p, id, targetDebt - debt);
        _checkLtv(p, id);
        emit UsdcSupplyLoopEnter(VERSION, data_.morphoMarketId, amount, borrowed_);
    }

    /// @notice Unwinds `collateralAmount` of avKAT (proportional supply withdrawal and repayment) back to the vault.
    function exit(CurveYieldUsdcSupplyLoopData memory data_) external returns (uint256 collateralOut_) {
        return _exit(data_.morphoMarketId, data_.collateralAmount);
    }

    /// @notice Instant-withdrawal source: params[0] = avKAT needed (the vault asset), params[1] = the Morpho market id.
    function instantWithdraw(bytes32[] calldata params_) external {
        _exit(params_[1], uint256(params_[0]));
    }

    function _exit(bytes32 marketId_, uint256 amount_) private returns (uint256 collateralOut_) {
        if (amount_ == 0) return 0;
        MarketParams memory p = _params(marketId_);
        Id id = Id.wrap(marketId_);
        MORPHO.accrueInterest(p);
        (uint256 coll, uint256 debt,) = _position(id);
        if (coll == 0) return 0;
        uint256 amount = Math.min(amount_, coll);
        uint256 repaid;
        if (debt != 0) repaid = _withdrawAndRepay(p, id, Math.mulDiv(debt, amount, coll, Math.Rounding.Ceil));
        // withdraw what the remaining debt allows at the cap (the full amount after a proportional repayment)
        (coll, debt,) = _position(id);
        uint256 locked = debt == 0
            ? 0
            : Math.mulDiv(Math.mulDiv(debt, 1e18, MAX_LTV, Math.Rounding.Ceil), ORACLE_SCALE, IOracle(p.oracle).price(), Math.Rounding.Ceil);
        uint256 free = coll > locked ? coll - locked : 0;
        collateralOut_ = Math.min(amount, free);
        if (collateralOut_ != 0) MORPHO.withdrawCollateral(p, collateralOut_, address(this), address(this));
        emit UsdcSupplyLoopExit(VERSION, marketId_, collateralOut_, repaid);
    }

    /// @dev Borrow + supply back in chunks of the market's free liquidity (unchanged by each round trip).
    function _borrowAndSupply(MarketParams memory p_, Id id_, uint256 amount_) private returns (uint256 done_) {
        IERC20 loan = IERC20(p_.loanToken);
        for (uint256 i; i < MAX_CHUNKS && done_ < amount_; ++i) {
            uint256 take = Math.min(amount_ - done_, _liquidity(id_));
            if (take == 0) break;
            MORPHO.borrow(p_, take, 0, address(this), address(this));
            loan.forceApprove(address(MORPHO), take);
            MORPHO.supply(p_, take, 0, address(this), "");
            done_ += take;
        }
    }

    /// @dev Withdraw our supply + repay in chunks of free liquidity; the last chunk repays by shares (no dust debt) and
    /// any surplus loan token goes back into the supply.
    function _withdrawAndRepay(MarketParams memory p_, Id id_, uint256 amount_) private returns (uint256 repaid_) {
        IERC20 loan = IERC20(p_.loanToken);
        for (uint256 i; i < MAX_CHUNKS && repaid_ < amount_; ++i) {
            (, uint256 debt, uint256 supplied) = _position(id_);
            if (debt == 0) break;
            uint256 take = Math.min(Math.min(amount_ - repaid_, supplied), _liquidity(id_));
            if (take == 0) break;
            MORPHO.withdraw(p_, take, 0, address(this), address(this));
            loan.forceApprove(address(MORPHO), take);
            if (take >= debt) {
                MORPHO.repay(p_, 0, MORPHO.position(id_, address(this)).borrowShares, address(this), "");
                repaid_ += debt;
                uint256 surplus = take - debt;
                if (surplus != 0) MORPHO.supply(p_, surplus, 0, address(this), "");
                break;
            }
            MORPHO.repay(p_, take, 0, address(this), "");
            repaid_ += take;
        }
        loan.forceApprove(address(MORPHO), 0);
    }

    function _position(Id id_) private view returns (uint256 coll_, uint256 debt_, uint256 supplied_) {
        Position memory pos = MORPHO.position(id_, address(this));
        Market memory m = MORPHO.market(id_);
        coll_ = pos.collateral;
        debt_ = uint256(pos.borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
        supplied_ = pos.supplyShares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);
    }

    function _liquidity(Id id_) private view returns (uint256) {
        Market memory m = MORPHO.market(id_);
        return m.totalSupplyAssets > m.totalBorrowAssets ? m.totalSupplyAssets - m.totalBorrowAssets : 0;
    }

    function _collateralValue(MarketParams memory p_, uint256 coll_) private view returns (uint256) {
        return Math.mulDiv(coll_, IOracle(p_.oracle).price(), ORACLE_SCALE);
    }

    function _checkLtv(MarketParams memory p_, Id id_) private view {
        (uint256 coll, uint256 debt,) = _position(id_);
        if (debt == 0) return;
        uint256 value = _collateralValue(p_, coll);
        uint256 ltv = value == 0 ? type(uint256).max : Math.mulDiv(debt, 1e18, value, Math.Rounding.Ceil);
        if (ltv > MAX_LTV) revert LtvAboveCap(ltv);
    }

    function _checkTvlCap(uint256 coll_) private view {
        bytes32[] memory k = new bytes32[](1);
        k[0] = K.USDC_LOOP_MAX_TVL_BPS;
        uint256 cap = IERC4626(address(this)).totalAssets() * ICurveYieldConfigGate(GATE).getMany(k)[0] / BPS;
        if (coll_ > cap) revert TvlCapExceeded(coll_, cap);
    }

    function _params(bytes32 marketId_) private view returns (MarketParams memory p_) {
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, marketId_)) revert UnsupportedMarket(marketId_);
        p_ = MORPHO.idToMarketParams(Id.wrap(marketId_));
    }
}
