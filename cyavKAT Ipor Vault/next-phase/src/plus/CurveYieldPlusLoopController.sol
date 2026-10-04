// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {FuseAction} from "../interfaces/CurveYieldPhase2Interfaces.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {CurveYieldNetPps} from "./CurveYieldNetPpsPriceFeed.sol";
import {MorphoFlashLoanFuseEnterData} from "contracts/fuses/morpho/MorphoFlashLoanFuse.sol";

interface ICyErc4626Plus {
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function getPerformanceFeeData() external view returns (CyFeeData memory);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

struct CyFeeData {
    address feeAccount;
    uint16 feeInPercentage; // bps
}

interface ICyMainWm {
    function getSharesToRelease() external view returns (uint256);
    function getWithdrawFee() external view returns (uint256); // WAD
}

interface ICyErc20Bal {
    function balanceOf(address) external view returns (uint256);
}

/// @notice Fixed addresses of the cyavKAT+ loop.
struct CyPlusEnv {
    address plusVault; // cyavKAT+ (PlasmaVault, asset cyavKAT)
    address morpho;
    bytes32 marketId; // lending market: loan avKAT, collateral wcyavKAT
    address avkat;
    address cyavkat; // the main vault (ERC-4626 over avKAT)
    address wrapper; // wcyavKAT (ERC-4626 over cyavKAT)
    address flashLoanFuse; // IPOR MorphoFlashLoanFuse in cyavKAT+
    address stepFuse; // CurveYieldPlusStepFuse (runs inside the flash callback)
}

/// @notice LTVs are debt / collateral MARKET value (both in avKAT); Morpho's own limit is 86% of 88% = 75.68%.
struct CyPlusParams {
    uint16 targetLtvBps; // 7,000
    uint16 deleverLtvBps; // 7,220: above this, de-lever back to target
    uint16 windupBandBps; // wind up when LTV < target - band
    uint16 specialRewardsBps; // profit split (sum 10,000): 4,000
    uint16 compoundBps; // 4,000 (stays in the position)
    uint16 boosterBps; // 1,000
    uint16 adminBps; // 1,000 (protected by the governance gate)
}

/// @notice The standard fuses the cyavKAT+ loop is planned onto (fuse standardization). IPOR's own fuses except the
/// transfer; the two ERC-4626 markets (cyavKAT, wcyavKAT) carry IPOR's ZeroBalanceFuse (cyavKAT is the vault's asset;
/// wcyavKAT is only ever held as Morpho collateral, valued in market 14).
struct CyPlusFuses {
    address flashLoan; // IPOR MorphoFlashLoanFuse (market 19)
    address collateral; // IPOR MorphoCollateralFuse (market 14)
    address borrow; // IPOR MorphoBorrowFuse (market 14)
    address cySupply; // IPOR Erc4626SupplyFuse, ERC4626 market holding cyavKAT (avKAT <-> cyavKAT)
    address wrapSupply; // IPOR Erc4626SupplyFuse, ERC4626 market holding wcyavKAT (cyavKAT <-> wcyavKAT)
    address transfer; // CurveYieldErc20TransferFuse (profit share out)
}

interface ICyPlusWmReserve {
    function getSharesToRelease() external view returns (uint256);
    function owedSplitShares() external view returns (uint256);
}

interface ICyPlus4626Preview {
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

struct CyPlusSnapshot {
    uint256 collateralWrapped; // wcyavKAT in Morpho
    uint256 collateralCy; // cyavKAT it represents
    uint256 collateralValue; // avKAT value (market, no haircut)
    uint256 debt; // avKAT
    uint256 idleCy; // cyavKAT idle in cyavKAT+
    uint256 ltvBps;
    uint256 equityCy; // collateral + idle - debt, in cyavKAT
}

/// @title CurveYieldPlusLoopController (#20)
/// @notice Planning brain of the cyavKAT+ loop (no swaps: avKAT <-> cyavKAT through the main vault's deposit / withdraw,
/// cyavKAT <-> wcyavKAT through the wrapper). The fuses execute; this contract sizes:
///   - windup: flash F avKAT so that (D + F) = t * (C + F - P), P = the profit sent out  => F = (t(C - P) - D) / (1 - t)
///   - unwind for X cyavKAT paid out: slice f = X / (Ccy - q * D), q = cyavKAT shares burned per avKAT withdrawn
///     (fee included); repays f*D, withdraws f*C, capped by the main vault's instant liquidity (maxWithdraw)
///   - de-lever above deleverLtv back to target: repay d = (D - t*Cv) / (1 - t*q*p), p = avKAT per cyavKAT
/// Profit = growth of cyavKAT equity per cyavKAT+ share since the last checkpoint; 60% is sent out at windup
/// (special rewards 40, booster 10, admin 10), 40% compounds.
contract CurveYieldPlusLoopController is Ownable2Step {
    using MorphoBalancesLib for IMorpho;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_LTV_BPS = 7_500; // hard ceiling for any configured LTV (Morpho limit 75.68%)
    uint256 private constant WAD = 1e18;
    uint256 private constant ONE_CY = 1e20; // one whole cyavKAT (20 decimals)

    CyPlusEnv private _env;
    CyPlusParams private _params;
    address public specialRewards;
    address public booster;
    address public adminReceiver;
    uint256 public equityPerShareCheckpoint; // cyavKAT per cyavKAT+ share, WAD
    address public executor;
    address public mainWithdrawManager; // cyavKAT's withdraw manager (WM v2): its reserve and instant fee bound unwinds
    address public mainFeeManager;
    address public emergencyArmFuse; // PPS spec B5 (D3): arms a zero main-vault instant fee for emergency de-leverage only // cyavKAT's IPOR FeeManager: its high-water mark nets the pending performance fee
    CyPlusFuses public fuses;

    event ParamsSet(CyPlusParams params);
    event CheckpointRecorded(uint256 equityPerShare);

    error BadParams();
    error OnlyVault();
    error InvalidAddress();

    constructor(address owner_, CyPlusEnv memory env_, CyPlusParams memory params_) Ownable(owner_) {
        if (env_.plusVault == address(0) || env_.wrapper == address(0) || env_.cyavkat == address(0)) revert InvalidAddress();
        _env = env_;
        _setParams(params_);
    }

    // ---------------------------------------------------------------- admin

    /// @notice LTVs and windup band (DAO). The profit split in `params_` is ignored: it has its own protected setter.
    function setParams(CyPlusParams calldata params_) external onlyOwner {
        CyPlusParams memory p = params_;
        (p.specialRewardsBps, p.compoundBps, p.boosterBps, p.adminBps) =
            (_params.specialRewardsBps, _params.compoundBps, _params.boosterBps, _params.adminBps);
        _setParams(p);
    }

    /// @notice Profit split incl. the admin share: protected by the governance gate (fee authority only).
    function setProfitSplit(uint16 special_, uint16 compound_, uint16 booster_, uint16 admin_) external onlyOwner {
        CyPlusParams memory p = _params;
        (p.specialRewardsBps, p.compoundBps, p.boosterBps, p.adminBps) = (special_, compound_, booster_, admin_);
        _setParams(p);
    }

    /// @notice Admin share of the profit split and its receiver: protected by the governance gate (fee authority).
    function setAdminReceiver(address admin_) external onlyOwner {
        adminReceiver = admin_;
    }

    function setDestinations(address specialRewards_, address booster_) external onlyOwner {
        (specialRewards, booster) = (specialRewards_, booster_);
    }

    function setMainWithdrawManager(address wm_) external onlyOwner {
        mainWithdrawManager = wm_;
    }

    function setMainFeeManager(address feeManager_) external onlyOwner {
        mainFeeManager = feeManager_;
    }

    /// @notice avKAT per 1 cyavKAT (WAD), net of cyavKAT's pending performance fee (gross if no fee manager is set).
    function cyPrice() public view returns (uint256) {
        uint256 perShare = mainFeeManager == address(0)
            ? ICyErc4626Plus(_env.cyavkat).convertToAssets(ONE_CY)
            : CurveYieldNetPps.netRate(_env.cyavkat, mainFeeManager);
        return perShare; // avKAT (18 dec) per whole cyavKAT (1e20)
    }

    function setExecutor(address executor_) external onlyOwner {
        executor = executor_;
    }

    function setFuses(CyPlusFuses calldata f_) external onlyOwner {
        if (f_.flashLoan == address(0) || f_.collateral == address(0) || f_.borrow == address(0) ||
            f_.cySupply == address(0) || f_.wrapSupply == address(0) || f_.transfer == address(0)) revert InvalidAddress();
        fuses = f_;
    }

    /// @notice Called by the executor after a windup / distribution (the vault is still accepted).
    function recordCheckpoint() external {
        if (msg.sender != _env.plusVault && msg.sender != executor) revert OnlyVault();
        uint256 eps = equityPerShare();
        equityPerShareCheckpoint = eps;
        emit CheckpointRecorded(eps);
    }

    // ---------------------------------------------------------------- views

    function env() external view returns (CyPlusEnv memory) {
        return _env;
    }

    function params() external view returns (CyPlusParams memory) {
        return _params;
    }

    function snapshot() public view returns (CyPlusSnapshot memory s_) {
        CyPlusEnv memory e = _env;
        IMorpho morpho = IMorpho(e.morpho);
        MarketParams memory mp = morpho.idToMarketParams(Id.wrap(e.marketId));
        s_.collateralWrapped = morpho.position(Id.wrap(e.marketId), e.plusVault).collateral;
        s_.collateralCy = ICyErc4626Plus(e.wrapper).convertToAssets(s_.collateralWrapped);
        uint256 price = cyPrice();
        s_.collateralValue = s_.collateralCy * price / ONE_CY;
        s_.debt = morpho.expectedBorrowAssets(mp, e.plusVault);
        s_.idleCy = ICyErc4626Plus(e.cyavkat).balanceOf(e.plusVault);
        s_.ltvBps = s_.collateralValue == 0 ? 0 : s_.debt * BPS / s_.collateralValue;
        uint256 debtCy = s_.debt * ONE_CY / price;
        uint256 gross = s_.collateralCy + s_.idleCy;
        s_.equityCy = gross > debtCy ? gross - debtCy : 0;
    }

    function equityPerShare() public view returns (uint256) {
        uint256 supply = ICyErc4626Plus(_env.plusVault).totalSupply();
        return supply == 0 ? 0 : snapshot().equityCy * WAD / supply;
    }

    /// @notice Profit since the last checkpoint, in cyavKAT, and the part to send out (special + booster + admin).
    function pendingProfit() public view returns (uint256 profitCy_, uint256 outCy_) {
        uint256 eps = equityPerShare();
        uint256 last = equityPerShareCheckpoint;
        if (last == 0 || eps <= last) return (0, 0);
        profitCy_ = (eps - last) * ICyErc4626Plus(_env.plusVault).totalSupply() / WAD;
        // (equity is valued at cyavKAT's NET price, so the main vault's pending fee is already excluded)
        CyPlusParams memory p = _params;
        outCy_ = profitCy_ * (uint256(p.specialRewardsBps) + p.boosterBps + p.adminBps) / BPS;
    }

    /// @notice Flash amount for a windup to target (including idle cyavKAT, which is supplied first), and the profit out.
    function planWindup() external view returns (uint256 flashAvkat_, uint256 profitOutCy_) {
        CyPlusSnapshot memory s = snapshot();
        CyPlusParams memory p = _params;
        (, profitOutCy_) = pendingProfit();
        uint256 price = cyPrice(); // avKAT per whole cyavKAT (net)
        uint256 idleValue = s.idleCy * price / ONE_CY;
        uint256 outValue = profitOutCy_ * price / ONE_CY;
        uint256 cv = s.collateralValue + idleValue;
        cv = cv > outValue ? cv - outValue : 0;
        uint256 ltvNow = cv == 0 ? 0 : s.debt * BPS / cv;
        if (ltvNow + p.windupBandBps >= p.targetLtvBps && idleValue == 0) return (0, profitOutCy_);
        uint256 targetDebt = cv * p.targetLtvBps / BPS;
        if (targetDebt <= s.debt) return (0, profitOutCy_);
        flashAvkat_ = (targetDebt - s.debt) * BPS / (BPS - p.targetLtvBps);
    }

    /// @notice Unwind slice paying out `cyOut_` cyavKAT: debt to repay (avKAT) and wrapped collateral to withdraw.
    /// Reverts if the main vault cannot supply the avKAT instantly (the caller then uses a scheduled request).
    function planUnwind(uint256 cyOut_) public view returns (uint256 repayAvkat_, uint256 withdrawWrapped_) {
        CyPlusSnapshot memory s = snapshot();
        if (cyOut_ == 0 || s.collateralCy == 0) return (0, 0);
        uint256 q = _sharesPerAvkat(); // cyavKAT burned per avKAT withdrawn (WAD), fee included
        uint256 debtCost = s.debt * q / WAD; // cyavKAT needed to clear all debt
        if (s.collateralCy <= debtCost) return (0, 0); // underwater: nothing withdrawable
        uint256 fWad = Math.mulDiv(cyOut_, WAD, s.collateralCy - debtCost, Math.Rounding.Ceil);
        if (fWad > WAD) fWad = WAD;
        repayAvkat_ = Math.mulDiv(s.debt, fWad, WAD, Math.Rounding.Ceil);
        uint256 cyNeeded = Math.mulDiv(s.collateralCy, fWad, WAD, Math.Rounding.Ceil);
        withdrawWrapped_ = _wrappedFor(cyNeeded, s);
    }

    /// @notice The largest cyavKAT payout an unwind can make now (the main vault's instant liquidity bounds it).
    function maxInstantOut() external view returns (uint256) {
        CyPlusSnapshot memory s = snapshot();
        if (s.debt == 0) return s.collateralCy;
        uint256 liquid = mainLiquidAvkat();
        uint256 q = _sharesPerAvkat();
        uint256 debtCost = s.debt * q / WAD;
        if (s.collateralCy <= debtCost) return 0;
        // payout per unit of repaid debt = (Ccy - q*D) / D
        return liquid >= s.debt ? s.collateralCy - debtCost : liquid * (s.collateralCy - debtCost) / s.debt;
    }

    /// @notice avKAT cyavKAT can pay out instantly now without touching its markets: idle minus what released requests
    /// reserve, net of its instant withdraw fee (its withdraw manager checks idle shares >= shares + fee).
    function mainLiquidAvkat() public view returns (uint256) {
        CyPlusEnv memory e = _env;
        ICyMainWm wm = ICyMainWm(mainWithdrawManager);
        if (address(wm) == address(0)) return 0;
        uint256 idle = ICyErc20Bal(e.avkat).balanceOf(e.cyavkat);
        uint256 reserved = ICyErc4626Plus(e.cyavkat).convertToAssets(wm.getSharesToRelease());
        if (idle <= reserved) return 0;
        return (idle - reserved) * WAD / (WAD + wm.getWithdrawFee());
    }

    /// @notice De-lever above deleverLtv: repay d = (D - t*Cv) / (1 - t*q*p) and withdraw q*d cyavKAT of collateral.
    function planDelever() external view returns (uint256 repayAvkat_, uint256 withdrawWrapped_) {
        CyPlusSnapshot memory s = snapshot();
        CyPlusParams memory p = _params;
        if (s.ltvBps <= p.deleverLtvBps) return (0, 0);
        uint256 q = _sharesPerAvkat();
        uint256 price = cyPrice();
        uint256 targetDebt = s.collateralValue * p.targetLtvBps / BPS;
        uint256 qp = q * price / ONE_CY; // avKAT of collateral burned per avKAT repaid (> 1 by the fee)
        uint256 denom = BPS * WAD - uint256(p.targetLtvBps) * qp;
        repayAvkat_ = Math.mulDiv(s.debt - targetDebt, BPS * WAD, denom, Math.Rounding.Ceil);
        if (repayAvkat_ > s.debt) repayAvkat_ = s.debt;
        withdrawWrapped_ = _wrappedFor(Math.mulDiv(repayAvkat_, q, WAD, Math.Rounding.Ceil), s);
    }

    // ---------------------------------------------------------------- bundles for the standard fuses

    /// @notice Wind-up to target LTV (same sizing as planWindup): flash avKAT -> deposit into cyavKAT -> send the profit
    /// share out -> wrap every free cyavKAT (keeping what released requests and the owed fee split need) -> supply as
    /// collateral -> borrow the flash back. Without a flash: profit out, then wrap + supply the free cyavKAT.
    function planWindupActions(address withdrawManager_) external view returns (FuseAction[] memory actions_) {
        (uint256 flash, uint256 outCy) = this.planWindup();
        CyPlusEnv memory e = _env;
        CyPlusFuses memory f = fuses;
        uint256 shares = flash == 0 ? 0 : ICyPlus4626Preview(e.cyavkat).previewDeposit(flash);
        uint256 cyAfter = ICyErc4626Plus(e.cyavkat).balanceOf(e.plusVault) + shares;
        uint256 reserved = withdrawManager_ == address(0) ? 0 : ICyErc4626Plus(e.plusVault).convertToAssets(
            ICyPlusWmReserve(withdrawManager_).getSharesToRelease() + ICyPlusWmReserve(withdrawManager_).owedSplitShares()
        );
        uint256 out = outCy > cyAfter ? cyAfter : outCy;
        uint256 free = cyAfter - out;
        free = free > reserved ? free - reserved : 0;
        uint256 wrapped = free == 0 ? 0 : ICyPlus4626Preview(e.wrapper).previewDeposit(free);
        FuseAction[] memory legs = _profitLegs(out);
        FuseAction[] memory inner = new FuseAction[](
            (flash != 0 ? 2 : 0) + legs.length + (wrapped != 0 ? 2 : 0)
        );
        uint256 k;
        if (flash != 0) inner[k++] = _supply4626(f.cySupply, e.cyavkat, flash, true);
        for (uint256 i; i < legs.length; ++i) inner[k++] = legs[i];
        if (wrapped != 0) {
            inner[k++] = _supply4626(f.wrapSupply, e.wrapper, free, true);
            inner[k++] = FuseAction(f.collateral, abi.encodeWithSignature("enter((bytes32,uint256))", e.marketId, wrapped));
        }
        if (flash != 0) inner[k] = FuseAction(f.borrow, abi.encodeWithSignature("enter((bytes32,uint256,uint256))", e.marketId, flash, uint256(0)));
        if (inner.length == 0) return inner;
        actions_ = flash == 0 ? inner : _flash(e, f, flash, inner);
    }

    /// @notice Unwind paying out cyOut_ cyavKAT (planUnwind sizing).
    function planUnwindActions(uint256 cyOut_) public view returns (FuseAction[] memory) {
        (uint256 repay, uint256 withdrawWrapped) = planUnwind(cyOut_);
        return _unwindActions(repay, withdrawWrapped);
    }

    /// @notice De-lever back to target (planDelever sizing).
    /// @dev PPS spec B5 (D3): with an emergency arm fuse set, the de-lever bundle is wrapped in arm / disarm so its own
    /// redemption from cyavKAT pays no instant fee (the arm fuse re-checks LTV > deleverLtv in the same call).
    function planDeleverActions() external view returns (FuseAction[] memory actions_) {
        (uint256 repay, uint256 withdrawWrapped) = this.planDelever();
        FuseAction[] memory unwind = _unwindActions(repay, withdrawWrapped);
        address arm = emergencyArmFuse;
        if (arm == address(0) || unwind.length == 0) return unwind;
        actions_ = new FuseAction[](unwind.length + 2);
        actions_[0] = FuseAction(arm, abi.encodeWithSignature("enter(bool)", true));
        for (uint256 i; i < unwind.length; ++i) actions_[i + 1] = unwind[i];
        actions_[unwind.length + 1] = FuseAction(arm, abi.encodeWithSignature("enter(bool)", false));
    }

    /// @notice PPS spec B5 (D3): the CurveYieldEmergencyFeeArmFuse used by the de-lever bundle (0 = none).
    function setEmergencyArmFuse(address fuse_) external onlyOwner {
        emergencyArmFuse = fuse_;
    }

    /// @notice Instant withdrawals (CurveYieldPlannedInstantWithdrawFuse; it sets the execution flag the flash callback
    /// needs): unwind the cyavKAT the redemption lacks, bounded by the main vault's instant liquidity.
    function planInstantWithdraw(uint256 cyOut_) external view returns (FuseAction[] memory actions_) {
        uint256 maxOut = this.maxInstantOut();
        return planUnwindActions(cyOut_ < maxOut ? cyOut_ : maxOut);
    }

    /// @dev flash avKAT -> repay debt -> withdraw collateral -> unwrap -> withdraw exactly the flashed avKAT from cyavKAT
    /// (its instant fee applies). Without debt: withdraw + unwrap only.
    function _unwindActions(uint256 repay_, uint256 withdrawWrapped_) private view returns (FuseAction[] memory actions_) {
        if (repay_ == 0 && withdrawWrapped_ == 0) return actions_;
        CyPlusEnv memory e = _env;
        CyPlusFuses memory f = fuses;
        uint256 cyFromWrap = withdrawWrapped_ == 0 ? 0 : ICyPlus4626Preview(e.wrapper).previewRedeem(withdrawWrapped_);
        FuseAction[] memory inner = new FuseAction[](
            (repay_ != 0 ? 2 : 0) + (withdrawWrapped_ != 0 ? 2 : 0)
        );
        uint256 k;
        if (repay_ != 0) inner[k++] = FuseAction(f.borrow, abi.encodeWithSignature("exit((bytes32,uint256,uint256))", e.marketId, repay_, uint256(0)));
        if (withdrawWrapped_ != 0) {
            inner[k++] = FuseAction(f.collateral, abi.encodeWithSignature("exit((bytes32,uint256))", e.marketId, withdrawWrapped_));
            inner[k++] = _supply4626(f.wrapSupply, e.wrapper, cyFromWrap, false);
        }
        if (repay_ != 0) inner[k] = _supply4626(f.cySupply, e.cyavkat, repay_, false);
        actions_ = repay_ == 0 ? inner : _flash(e, f, repay_, inner);
    }

    function _flash(CyPlusEnv memory e_, CyPlusFuses memory f_, uint256 amount_, FuseAction[] memory callback_)
        private pure returns (FuseAction[] memory actions_)
    {
        actions_ = new FuseAction[](1);
        // ONE tuple (token, amount, callback actions): the IPOR MorphoFlashLoanFuse ABI. Encoded as the struct: loose
        // fields would be three top-level params, which the fuse cannot decode (the tuple holds a dynamic `bytes`).
        actions_[0] = FuseAction(f_.flashLoan, abi.encodeWithSignature(
            "enter((address,uint256,bytes))", MorphoFlashLoanFuseEnterData(e_.avkat, amount_, abi.encode(callback_))
        ));
    }

    /// @dev IPOR Erc4626SupplyFuse: enter deposits assets_ of the 4626's asset; exit withdraws assets_ of it.
    function _supply4626(address fuse_, address vault_, uint256 assets_, bool enter_) private pure returns (FuseAction memory) {
        return FuseAction(fuse_, enter_
            ? abi.encodeWithSignature("enter((address,uint256,uint256))", vault_, assets_, uint256(0))
            : abi.encodeWithSignature("exit((address,uint256,uint256))", vault_, assets_, uint256(0)));
    }

    /// @dev The profit share out, split like the Phase 4 step fuse (special rewards / booster / admin).
    function _profitLegs(uint256 outCy_) private view returns (FuseAction[] memory legs_) {
        CyPlusParams memory p = _params;
        uint256 outBps = uint256(p.specialRewardsBps) + p.boosterBps + p.adminBps;
        if (outCy_ == 0 || outBps == 0) return legs_;
        uint256 toAdmin = outCy_ * p.adminBps / outBps;
        uint256 toBooster = outCy_ * p.boosterBps / outBps;
        uint256 toSpecial = outCy_ - toAdmin - toBooster;
        address[3] memory to = [specialRewards, booster, adminReceiver];
        uint256[3] memory amounts = [toSpecial, toBooster, toAdmin];
        uint256 n;
        for (uint256 i; i < 3; ++i) if (amounts[i] != 0) ++n;
        legs_ = new FuseAction[](n);
        uint256 k;
        for (uint256 i; i < 3; ++i) {
            if (amounts[i] == 0) continue;
            legs_[k++] = FuseAction(fuses.transfer, abi.encodeWithSignature(
                "enter((address,address,uint256))", _env.cyavkat, to[i], amounts[i]
            ));
        }
    }

    // ---------------------------------------------------------------- internals

    function _sharesPerAvkat() private view returns (uint256) {
        return ICyErc4626Plus(_env.cyavkat).previewWithdraw(WAD); // includes the main vault's instant fee
    }

    function _wrappedFor(uint256 cy_, CyPlusSnapshot memory s_) private view returns (uint256 w_) {
        w_ = ICyErc4626Plus(_env.wrapper).convertToShares(cy_) + 1;
        if (w_ > s_.collateralWrapped) w_ = s_.collateralWrapped;
    }

    function _setParams(CyPlusParams memory p_) private {
        if (
            p_.targetLtvBps == 0 || p_.targetLtvBps > MAX_LTV_BPS || p_.deleverLtvBps <= p_.targetLtvBps
                || p_.deleverLtvBps > MAX_LTV_BPS || p_.windupBandBps > 1_000
                || uint256(p_.specialRewardsBps) + p_.compoundBps + p_.boosterBps + p_.adminBps != BPS
        ) revert BadParams();
        _params = p_;
        emit ParamsSet(p_);
    }
}
