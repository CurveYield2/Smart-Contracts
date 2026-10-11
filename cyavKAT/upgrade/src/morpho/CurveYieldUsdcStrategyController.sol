// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, MarketParams, Market, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {
    MorphoCollateralFuse, MorphoCollateralFuseEnterData, MorphoCollateralFuseExitData
} from "contracts/fuses/morpho/MorphoCollateralFuse.sol";
import {
    MorphoBorrowFuse, MorphoBorrowFuseEnterData, MorphoBorrowFuseExitData
} from "contracts/fuses/morpho/MorphoBorrowFuse.sol";
import {
    Erc4626SupplyFuse, Erc4626SupplyFuseEnterData, Erc4626SupplyFuseExitData
} from "contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {FuseAction, ICyStrategySet, ICyWithdrawManager, ICyMorphoOracle} from "../interfaces/CurveYieldPhase2Interfaces.sol";
import {CurveYieldGateConfig, CurveYieldConfigKeys as K} from "../governance/CurveYieldGateConfig.sol";
import {CurveYieldBundleLib} from "../libraries/CurveYieldBundleLib.sol";
import {CurveYieldQuoteLib} from "../libraries/CurveYieldQuoteLib.sol";
import {CurveYieldUtsLib} from "../libraries/CurveYieldUtsLib.sol";

/// @notice Addresses of the USDC strategy: avKAT collateral on the Morpho avKAT / vbUSDC market, the borrowed vbUSDC
/// deposited into the CurveYield USDC IPOR vault (cyvbUSDC).
struct CyUsdcEnv {
    address vault;
    address morpho;
    bytes32 marketId; // Morpho avKAT / vbUSDC market (0xbd48…, LLTV 62.5%)
    address avkat;
    address usdc; // vbUSDC (loan token, 6 decimals)
    address supplyVault; // cyvbUSDC 0xDf9C…, an ERC-4626 whose asset is vbUSDC
    address collateralFuse; // IPOR MorphoCollateralFuse (market 14)
    address borrowFuse; // IPOR MorphoBorrowFuse (market 14)
    address supplyFuse; // IPOR Erc4626SupplyFuse (market 100_001)
    address swapFuse; // IPOR UniversalTokenSwapperFuse (market 12)
    address router; // CurveYieldSwapRouterV2
    address guardFuse; // CurveYieldBundleGuardFuse
    address withdrawManager;
}

/// @title CurveYieldUsdcStrategyController (a PLANNER; IPOR_FUSE_CONFORMANCE_SPEC §4.3)
/// @notice The USDC strategy from IPOR's official fuses only: supply avKAT as collateral on Morpho, borrow vbUSDC, deposit
/// it into cyvbUSDC (`Erc4626SupplyFuse`), all in one guarded bundle that also caps the LTV through the guard's granted
/// ceiling. Exit reverses it (withdraw from cyvbUSDC, repay, withdraw collateral). The Merkl incentives on the Morpho
/// markets cyvbUSDC supplies are claimed by cyvbUSDC itself (F15) and reach the vault through cyvbUSDC's share price: the
/// vault claims nothing. NOT an instant source (B3): it is served through withdrawal requests.
contract CurveYieldUsdcStrategyController is ICyStrategySet, Ownable2Step, CurveYieldGateConfig {
    uint256 private constant BPS = 10_000;
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;
    /// @dev Smallest avKAT collateral a deploy adds, so the strategy never creates dust positions.
    uint256 public constant MIN_DEPLOY_AVKAT = 1e18;
    /// @dev Tolerance on the deposit's minimum shares (cyvbUSDC share price moves between planning and execution): 0.5%.
    uint256 public constant DEPOSIT_TOLERANCE_BPS = 50;
    /// @dev LTV drift above target that triggers a rebalance (2%).
    uint256 public constant REBALANCE_TOLERANCE_BPS = 200;

    CyUsdcEnv private _env;
    address public executor;

    error InvalidAddress();

    event ExecutorUpdated(address indexed executor);

    constructor(address owner_, CyUsdcEnv memory env_, address configGate_)
        Ownable(owner_)
        CurveYieldGateConfig(configGate_)
    {
        if (
            env_.vault == address(0) || env_.morpho == address(0) || env_.avkat == address(0) || env_.usdc == address(0) ||
            env_.supplyVault == address(0) || env_.collateralFuse == address(0) || env_.borrowFuse == address(0) ||
            env_.supplyFuse == address(0) || env_.swapFuse == address(0) || env_.router == address(0) ||
            env_.guardFuse == address(0) || env_.withdrawManager == address(0) || env_.marketId == bytes32(0)
        ) revert InvalidAddress();
        _env = env_;
    }

    function setExecutor(address executor_) external onlyOwner {
        if (executor_ == address(0)) revert InvalidAddress();
        executor = executor_;
        emit ExecutorUpdated(executor_);
    }

    function env() external view returns (CyUsdcEnv memory) {
        return _env;
    }

    /// @notice maxTvlBps (collateral cap, bps of managed avKAT), targetLtvBps, from the governance gate.
    function params() public view returns (uint256 maxTvlBps_, uint256 targetLtvBps_) {
        bytes32[] memory k = new bytes32[](2);
        (k[0], k[1]) = (K.USDC_LOOP_MAX_TVL_BPS, K.USDC_LOOP_TARGET_LTV_BPS);
        uint256[] memory v = _config(k);
        return (v[0], v[1]);
    }

    /// @notice Unwind loss a scheduled fulfilment may take, bps of the avKAT released (as the loop's).
    function allowedLossBps() public view returns (uint256) {
        uint256 feeBps = ICyWithdrawManager(_env.withdrawManager).getRequestFee() * BPS / 1e18;
        uint256 keep = _config1(K.LOOP_MIN_UNWIND_PROFIT_BPS);
        return feeBps > keep ? feeBps - keep : 0;
    }

    // ---------------------------------------------------------------- views

    struct Position {
        uint256 collateralAvkat;
        uint256 debtUsdc;
        uint256 suppliedUsdc; // cyvbUSDC position, in vbUSDC
        uint256 price; // Morpho oracle: vbUSDC (loan) per avKAT (collateral), 1e36 scale
        uint256 ltvBps;
    }

    function position() public view returns (Position memory p_) {
        CyUsdcEnv memory e = _env;
        IMorpho morpho = IMorpho(e.morpho);
        Id id = Id.wrap(e.marketId);
        MarketParams memory mp = morpho.idToMarketParams(id);
        p_.collateralAvkat = morpho.position(id, e.vault).collateral;
        p_.debtUsdc = MorphoBalancesLib.expectedBorrowAssets(morpho, mp, e.vault);
        p_.suppliedUsdc = IERC4626(e.supplyVault).convertToAssets(IERC20(e.supplyVault).balanceOf(e.vault));
        p_.price = ICyMorphoOracle(mp.oracle).price();
        uint256 collateralValue = Math.mulDiv(p_.collateralAvkat, p_.price, ORACLE_PRICE_SCALE);
        p_.ltvBps = collateralValue == 0 ? 0 : p_.debtUsdc * BPS / collateralValue;
    }

    /// @notice avKAT-equivalent equity: collateral + (cyvbUSDC position - debt), the vbUSDC converted at the market oracle.
    function managedAvkat() public view override returns (uint256) {
        Position memory p = position();
        if (p.price == 0) return p.collateralAvkat;
        if (p.suppliedUsdc >= p.debtUsdc) {
            return p.collateralAvkat + Math.mulDiv(p.suppliedUsdc - p.debtUsdc, ORACLE_PRICE_SCALE, p.price);
        }
        uint256 shortfall = Math.mulDiv(p.debtUsdc - p.suppliedUsdc, ORACLE_PRICE_SCALE, p.price, Math.Rounding.Ceil);
        return p.collateralAvkat > shortfall ? p.collateralAvkat - shortfall : 0;
    }

    function allocationBps() external view override returns (uint256) {
        (uint256 maxTvl,) = params();
        return maxTvl;
    }

    // ---------------------------------------------------------------- plans

    /// @inheritdoc ICyStrategySet
    /// @dev Enter: collateral, borrow vbUSDC up to the target LTV, deposit it into cyvbUSDC, then the guard requires the
    /// share price to hold and the LTV to end at or under the granted ceiling.
    function planDeploy(uint256 budgetAvkat_, uint256 managedTotal_)
        external view override returns (FuseAction[] memory actions_, uint256 consumedAvkat_)
    {
        CyUsdcEnv memory e = _env;
        (uint256 maxTvl, uint256 targetLtv) = params();
        Position memory p = position();
        uint256 cap = managedTotal_ * maxTvl / BPS;
        if (budgetAvkat_ < MIN_DEPLOY_AVKAT || p.collateralAvkat >= cap || p.price == 0) return (actions_, 0);
        uint256 add = cap - p.collateralAvkat;
        if (add > budgetAvkat_) add = budgetAvkat_;
        if (add < MIN_DEPLOY_AVKAT) return (actions_, 0);

        uint256 newCollateralValue = Math.mulDiv(p.collateralAvkat + add, p.price, ORACLE_PRICE_SCALE);
        uint256 targetDebt = newCollateralValue * targetLtv / BPS;
        uint256 borrow = targetDebt > p.debtUsdc ? targetDebt - p.debtUsdc : 0;
        uint256 liquidity = _marketLiquidity(e);
        if (borrow > liquidity) borrow = liquidity;
        uint256 minShares = borrow == 0 ? 0 : IERC4626(e.supplyVault).previewDeposit(borrow) * (BPS - DEPOSIT_TOLERANCE_BPS) / BPS;
        uint256 n = 1 + (borrow != 0 ? 2 : 0);
        FuseAction[] memory bundle = new FuseAction[](n);
        bundle[0] = FuseAction(e.collateralFuse, abi.encodeCall(
            MorphoCollateralFuse.enter, (MorphoCollateralFuseEnterData(e.marketId, add))
        ));
        if (borrow != 0) {
            bundle[1] = FuseAction(e.borrowFuse, abi.encodeCall(
                MorphoBorrowFuse.enter, (MorphoBorrowFuseEnterData(e.marketId, borrow, 0))
            ));
            bundle[2] = FuseAction(e.supplyFuse, abi.encodeCall(
                Erc4626SupplyFuse.enter, (Erc4626SupplyFuseEnterData({vault: e.supplyVault, vaultAssetAmount: borrow, minSharesOut: minShares}))
            ));
        }
        bytes32[] memory morphoMarkets = new bytes32[](1);
        morphoMarkets[0] = e.marketId;
        actions_ = CurveYieldBundleLib.wrapWithLtv(e.guardFuse, e.vault, bundle, morphoMarkets);
        consumedAvkat_ = add;
    }

    /// @inheritdoc ICyStrategySet
    /// @dev Never reduced on its own (an exit costs fees): it shrinks through scheduled withdrawals.
    function planReduce(uint256) external pure override returns (FuseAction[] memory actions_, uint256 releasedAvkat_) {
        return (actions_, 0);
    }

    /// @inheritdoc ICyStrategySet
    /// @dev Exit of a proportional share of the position that frees `neededAvkat_` of equity: withdraw that share of the
    /// cyvbUSDC position, repay its share of the debt (a shortfall of cyvbUSDC against the debt is bought with idle avKAT
    /// through UTS when the router can quote it; otherwise the share is reduced until cyvbUSDC covers the debt), withdraw
    /// its share of the collateral. Bounded loss through the guard; not instant (B3).
    function planWithdraw(uint256 neededAvkat_, bool scheduled_)
        external view override returns (FuseAction[] memory actions_, uint256 providedAvkat_)
    {
        if (!scheduled_ || neededAvkat_ == 0) return (actions_, 0);
        CyUsdcEnv memory e = _env;
        Position memory p = position();
        uint256 equity = managedAvkat();
        if (equity == 0 || p.collateralAvkat == 0) return (actions_, 0);
        providedAvkat_ = neededAvkat_ > equity ? equity : neededAvkat_;
        // share of the position to unwind (1e18), rounded up so the freed collateral covers the request
        uint256 share = Math.mulDiv(providedAvkat_, 1e18, equity, Math.Rounding.Ceil);
        if (share > 1e18) share = 1e18;
        uint256 maxOut = IERC4626(e.supplyVault).maxWithdraw(e.vault);
        uint256 collateralOut;
        uint256 repay;
        uint256 redeem;
        uint256 sold;
        uint256 minShortfall;
        for (uint256 attempt; attempt < 2; ++attempt) {
            collateralOut = Math.mulDiv(p.collateralAvkat, share, 1e18);
            repay = Math.mulDiv(p.debtUsdc, share, 1e18, Math.Rounding.Ceil);
            redeem = Math.mulDiv(p.suppliedUsdc, share, 1e18);
            if (redeem > maxOut) redeem = maxOut;
            if (repay <= redeem) break;
            minShortfall = repay - redeem;
            try this.shortfallInput(minShortfall, IERC20(e.avkat).balanceOf(e.vault)) returns (uint256 input) {
                sold = input;
                break;
            } catch {
                // the router cannot quote the shortfall (no route / no oracle history): unwind only what cyvbUSDC covers
                share = redeem == 0 ? 0 : Math.mulDiv(share, redeem, repay);
                minShortfall = 0;
                if (share == 0) return (new FuseAction[](0), 0);
            }
        }
        FuseAction[] memory bundle = new FuseAction[](4);
        uint256 k;
        if (redeem != 0) {
            bundle[k++] = FuseAction(e.supplyFuse, abi.encodeCall(
                Erc4626SupplyFuse.exit, (Erc4626SupplyFuseExitData({vault: e.supplyVault, vaultAssetAmount: redeem, maxSharesBurned: 0}))
            ));
        }
        if (sold != 0) bundle[k++] = CurveYieldUtsLib.swapAction(e.swapFuse, e.router, e.avkat, e.usdc, sold, minShortfall);
        if (repay != 0) {
            if (repay > redeem + minShortfall) repay = redeem + minShortfall; // never repay more than the vault will hold
            bundle[k++] = FuseAction(e.borrowFuse, abi.encodeCall(
                MorphoBorrowFuse.exit, (MorphoBorrowFuseExitData(e.marketId, repay, 0))
            ));
        }
        bundle[k++] = FuseAction(e.collateralFuse, abi.encodeCall(
            MorphoCollateralFuse.exit, (MorphoCollateralFuseExitData(e.marketId, collateralOut))
        ));
        assembly { mstore(bundle, k) }
        providedAvkat_ = collateralOut > sold ? collateralOut - sold : 0;
        if (providedAvkat_ == 0) return (new FuseAction[](0), 0);
        actions_ = CurveYieldBundleLib.wrapWithLoss(e.guardFuse, e.vault, bundle, providedAvkat_ * allowedLossBps() / BPS);
    }

    /// @notice The avKAT to sell for `shortfallUsdc_` through the router's protected minimum (reverts when it cannot quote).
    /// External only so `planWithdraw` can try it.
    function shortfallInput(uint256 shortfallUsdc_, uint256 maxAvkat_) external view returns (uint256) {
        return CurveYieldQuoteLib.requiredInput(_env.router, _env.avkat, _env.usdc, shortfallUsdc_, maxAvkat_);
    }

    /// @notice LTV rebalance: above target + tolerance, withdraw vbUSDC from cyvbUSDC and repay the excess debt. One
    /// guarded bundle (no price impact: no swap). Empty when LTV is in range or cyvbUSDC cannot pay it.
    function planRebalance() external view returns (FuseAction[] memory actions_) {
        CyUsdcEnv memory e = _env;
        (, uint256 targetLtv) = params();
        Position memory p = position();
        if (p.collateralAvkat == 0 || p.ltvBps <= targetLtv + REBALANCE_TOLERANCE_BPS) return actions_;
        uint256 collateralValue = Math.mulDiv(p.collateralAvkat, p.price, ORACLE_PRICE_SCALE);
        uint256 targetDebt = collateralValue * targetLtv / BPS;
        uint256 repay = p.debtUsdc - targetDebt;
        uint256 idle = IERC20(e.usdc).balanceOf(e.vault);
        uint256 redeem = repay > idle ? repay - idle : 0;
        uint256 maxOut = IERC4626(e.supplyVault).maxWithdraw(e.vault);
        if (redeem > maxOut) {
            redeem = maxOut;
            repay = idle + redeem;
        }
        if (repay == 0) return actions_;
        FuseAction[] memory bundle = new FuseAction[](redeem != 0 ? 2 : 1);
        uint256 k;
        if (redeem != 0) {
            bundle[k++] = FuseAction(e.supplyFuse, abi.encodeCall(
                Erc4626SupplyFuse.exit, (Erc4626SupplyFuseExitData({vault: e.supplyVault, vaultAssetAmount: redeem, maxSharesBurned: 0}))
            ));
        }
        bundle[k] = FuseAction(e.borrowFuse, abi.encodeCall(
            MorphoBorrowFuse.exit, (MorphoBorrowFuseExitData(e.marketId, repay, 0))
        ));
        actions_ = CurveYieldBundleLib.wrap(e.guardFuse, e.vault, bundle, 0);
    }

    function _marketLiquidity(CyUsdcEnv memory e_) private view returns (uint256) {
        Market memory m = IMorpho(e_.morpho).market(Id.wrap(e_.marketId));
        return m.totalSupplyAssets > m.totalBorrowAssets ? m.totalSupplyAssets - m.totalBorrowAssets : 0;
    }
}
