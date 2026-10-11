// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultMarketsLib} from "contracts/vaults/lib/PlasmaVaultMarketsLib.sol";
import {IRewardsClaimManager} from "contracts/interfaces/IRewardsClaimManager.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {CurveYieldSubstrateLib as Sub} from "../libraries/CurveYieldSubstrateLib.sol";
import {CurveYieldManagementFeePpsLib as FeePps} from "../libraries/CurveYieldManagementFeePpsLib.sol";

interface ICyGuardMorphoOracle {
    function price() external view returns (uint256);
}

/// @notice enter: snapshot before the bundle. `markets` = every market the bundle touches (their dependants follow).
struct CurveYieldBundleGuardFuseEnterData {
    uint256[] markets;
}

/// @notice exit: post-conditions after the bundle, against the snapshot.
struct CurveYieldBundleGuardFuseExitData {
    uint256[] markets; // same list as enter
    uint256 maxPpsDropBps; // share price may not fall more than this (0 = never drops); at most the granted ceiling
    int256 minAssetsPerShareDelta; // optional: minimum change of (fresh assets x supplyBefore / supplyAfter) - before; negative = bounded loss
    uint256 minIdleAssets; // optional: underlying left idle in the vault
    bytes32[] morphoMarkets; // optional: Morpho markets whose LTV must end at or under their granted ceiling
}

/// @title CurveYieldBundleGuardFuse (custom: IPOR has no post-bundle share-price check; exception E5)
/// @notice First and last action of a bundle. `enter` revalues the listed markets through IPOR's own
/// `PlasmaVaultMarketsLib.updateMarketsBalances` (the code path behind `UpdateMarketsBalancesFuse`, dependency graph
/// included) and snapshots gross assets and supply in transient storage; `exit` revalues the same markets and reverts
/// the whole bundle unless the management-fee-adjusted share price held (and the optional profit / bounded-loss, idle and LTV conditions).
/// The pre-hook `ExchangeRateValidatorPreHook` cannot do this: it runs before `execute` against a ratcheting stored rate
/// (F9). Ceilings are substrates granted by the governance gate (`ZERO_BALANCE_MARKET`, E6) and each is capped here by
/// an absolute value. Accrued IPOR management-fee shares are included in the pre/post denominators so
/// fee realization alone is neutral, but any additional asset loss or dilution still reverts. Stateless; the Morpho singleton is the only immutable besides VERSION / MARKET_ID.
contract CurveYieldBundleGuardFuse is IFuseCommon {
    uint256 private constant BPS = 10_000;
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;
    /// @notice Rounding allowance in raw assets (1e-15 avKAT): per-op protocol rounding, never a real loss.
    uint256 public constant ROUNDING_DUST = 1_000;
    /// @notice Absolute ceiling of the share-price drop / bounded loss, whatever the granted substrate (R5): 10%.
    uint256 public constant ABSOLUTE_MAX_PPS_DROP_BPS = 1_000;
    /// @notice Absolute ceiling of any granted LTV: 85%.
    uint256 public constant ABSOLUTE_MAX_LTV_BPS = 8_500;

    address public immutable VERSION;
    uint256 public immutable override MARKET_ID;
    address public immutable MORPHO;

    /// @dev Supply in guard events is fee-adjusted (raw supply plus unminted IPOR management-fee shares).
    event CurveYieldBundleGuardFuseEnter(address version, uint256 assets, uint256 supply);
    event CurveYieldBundleGuardFuseExit(
        address version, uint256 assetsBefore, uint256 assetsAfter, uint256 supplyBefore, uint256 supplyAfter
    );

    error CurveYieldBundleGuardFuseInvalidMarketId();
    error CurveYieldBundleGuardFuseInvalidMorpho();
    error CurveYieldBundleGuardFuseNotEntered();
    error CurveYieldBundleGuardFuseInvalidTransientInputs();
    error CurveYieldBundleGuardFuseDropAboveCeiling(uint256 requestedBps, uint256 ceilingBps);
    error CurveYieldBundleGuardFusePpsDropped(uint256 ppsBefore, uint256 ppsAfter, uint256 maxDropBps);
    error CurveYieldBundleGuardFuseProfitBelowMinimum(int256 delta, int256 minimum);
    error CurveYieldBundleGuardFuseIdleBelowMinimum(uint256 idle, uint256 minimum);
    error CurveYieldBundleGuardFuseLtvCeilingNotGranted(bytes32 morphoMarketId);
    error CurveYieldBundleGuardFuseLtvAboveCeiling(bytes32 morphoMarketId, uint256 ltvBps, uint256 ceilingBps);

    constructor(uint256 marketId_, address morpho_) {
        if (marketId_ == 0) revert CurveYieldBundleGuardFuseInvalidMarketId();
        if (morpho_ == address(0)) revert CurveYieldBundleGuardFuseInvalidMorpho();
        VERSION = address(this);
        MARKET_ID = marketId_;
        MORPHO = morpho_;
    }

    function enter(CurveYieldBundleGuardFuseEnterData memory data_) public {
        uint256 assets = _freshGrossAssets(data_.markets);
        uint256 supply = FeePps.effectiveSupply(address(this));
        // a stack of snapshots: bundles may nest (the executor brackets a bundle whose planner brackets its own part)
        bytes32 depthSlot = _depthSlot();
        uint256 depth = uint256(TransientStorageLib.tload(depthSlot));
        (bytes32 a, bytes32 s) = _slots(depth);
        TransientStorageLib.tstore(a, bytes32(assets));
        TransientStorageLib.tstore(s, bytes32(supply));
        TransientStorageLib.tstore(depthSlot, bytes32(depth + 1));
        emit CurveYieldBundleGuardFuseEnter(VERSION, assets, supply);
    }

    function exit(CurveYieldBundleGuardFuseExitData memory data_) public {
        bytes32 depthSlot = _depthSlot();
        uint256 depth = uint256(TransientStorageLib.tload(depthSlot));
        if (depth == 0) revert CurveYieldBundleGuardFuseNotEntered();
        --depth;
        TransientStorageLib.tstore(depthSlot, bytes32(depth));
        (bytes32 a, bytes32 s) = _slots(depth);
        uint256 assetsBefore = uint256(TransientStorageLib.tload(a));
        uint256 supplyBefore = uint256(TransientStorageLib.tload(s));
        TransientStorageLib.tstore(a, bytes32(0));
        TransientStorageLib.tstore(s, bytes32(0));

        uint256 ceiling = Sub.maxPpsDropBps();
        if (ceiling > ABSOLUTE_MAX_PPS_DROP_BPS) ceiling = ABSOLUTE_MAX_PPS_DROP_BPS;
        if (data_.maxPpsDropBps > ceiling) revert CurveYieldBundleGuardFuseDropAboveCeiling(data_.maxPpsDropBps, ceiling);
        if (data_.minAssetsPerShareDelta < 0) {
            uint256 loss = uint256(-data_.minAssetsPerShareDelta);
            if (loss * BPS > assetsBefore * ceiling) {
                revert CurveYieldBundleGuardFuseDropAboveCeiling(loss * BPS / (assetsBefore == 0 ? 1 : assetsBefore), ceiling);
            }
        }

        uint256 assetsAfter = _freshGrossAssets(data_.markets);
        uint256 supplyAfter = FeePps.effectiveSupply(address(this));

        // Management-fee-adjusted PPS: accrued fee shares are virtualized at enter and exit.
        // PPS: after/supplyAfter >= before/supplyBefore x (1 - drop)  <=>  after x sBefore x BPS >= before x sAfter x (BPS - drop).
        // A negative minAssetsPerShareDelta is a bounded loss the caller accepts (e.g. a scheduled-withdrawal unwind covered by
        // the request fee): the drop test then yields to the delta test.
        if (supplyBefore != 0 && supplyAfter != 0 && data_.minAssetsPerShareDelta >= 0) {
            if ((assetsAfter + ROUNDING_DUST) * supplyBefore * BPS < assetsBefore * supplyAfter * (BPS - data_.maxPpsDropBps)) {
                revert CurveYieldBundleGuardFusePpsDropped(
                    assetsBefore * 1e18 / supplyBefore, assetsAfter * 1e18 / supplyAfter, data_.maxPpsDropBps
                );
            }
        }
        if (data_.minAssetsPerShareDelta != 0 && supplyAfter != 0) {
            int256 delta = int256(Math.mulDiv(assetsAfter, supplyBefore, supplyAfter)) - int256(assetsBefore);
            if (delta + int256(ROUNDING_DUST) < data_.minAssetsPerShareDelta) {
                revert CurveYieldBundleGuardFuseProfitBelowMinimum(delta, data_.minAssetsPerShareDelta);
            }
        }
        if (data_.minIdleAssets != 0) {
            uint256 idle = IERC20(IERC4626(address(this)).asset()).balanceOf(address(this));
            if (idle < data_.minIdleAssets) revert CurveYieldBundleGuardFuseIdleBelowMinimum(idle, data_.minIdleAssets);
        }
        for (uint256 i; i < data_.morphoMarkets.length; ++i) _checkLtv(data_.morphoMarkets[i]);
        emit CurveYieldBundleGuardFuseExit(VERSION, assetsBefore, assetsAfter, supplyBefore, supplyAfter);
    }

    /// @notice R3: transient input layout: [marketCount, marketIds...].
    /// @dev Writes zero outputs; the guard is a safety gate, not an amount-producing fuse.
    function enterTransient() external {
        bytes32[] memory words = TransientStorageLib.getInputs(VERSION);
        if (words.length == 0) revert CurveYieldBundleGuardFuseInvalidTransientInputs();
        uint256 count = uint256(words[0]);
        if (count != words.length - 1) revert CurveYieldBundleGuardFuseInvalidTransientInputs();
        uint256[] memory markets = new uint256[](count);
        for (uint256 i; i < count; ++i) markets[i] = uint256(words[i + 1]);
        enter(CurveYieldBundleGuardFuseEnterData({markets: markets}));
        TransientStorageLib.setOutputs(VERSION, new bytes32[](0));
    }

    /// @notice R3: [marketCount, marketIds..., maxDropBps, signedMinAssetDelta,
    /// minIdleAssets, morphoMarketCount, morphoMarketIds...].
    function exitTransient() external {
        bytes32[] memory words = TransientStorageLib.getInputs(VERSION);
        if (words.length < 5) revert CurveYieldBundleGuardFuseInvalidTransientInputs();
        uint256 count = uint256(words[0]);
        if (count > words.length - 5) revert CurveYieldBundleGuardFuseInvalidTransientInputs();
        uint256 offset = count + 1;
        uint256[] memory markets = new uint256[](count);
        for (uint256 i; i < count; ++i) markets[i] = uint256(words[i + 1]);
        uint256 morphoCount = uint256(words[offset + 3]);
        if (morphoCount != words.length - (offset + 4)) revert CurveYieldBundleGuardFuseInvalidTransientInputs();
        bytes32[] memory morphoMarkets = new bytes32[](morphoCount);
        for (uint256 i; i < morphoCount; ++i) morphoMarkets[i] = words[offset + 4 + i];
        exit(CurveYieldBundleGuardFuseExitData({
            markets: markets, maxPpsDropBps: uint256(words[offset]),
            minAssetsPerShareDelta: int256(uint256(words[offset + 1])),
            minIdleAssets: uint256(words[offset + 2]), morphoMarkets: morphoMarkets
        }));
        TransientStorageLib.setOutputs(VERSION, new bytes32[](0));
    }

    /// @dev Gross assets (idle + all markets + rewards manager) with `markets_` revalued now through IPOR's own library.
    function _freshGrossAssets(uint256[] memory markets_) private returns (uint256 total_) {
        address asset = IERC4626(address(this)).asset();
        if (markets_.length != 0) {
            PlasmaVaultMarketsLib.updateMarketsBalances(
                markets_, asset, IERC20Metadata(address(this)).decimals(), PlasmaVaultLib.DECIMALS_OFFSET
            );
        }
        total_ = IERC20(asset).balanceOf(address(this)) + PlasmaVaultLib.getTotalAssetsInAllMarkets();
        address rcm = PlasmaVaultLib.getRewardsClaimManagerAddress();
        if (rcm != address(0)) total_ += IRewardsClaimManager(rcm).balanceOf();
    }

    function _checkLtv(bytes32 morphoMarketId_) private view {
        uint256 ceiling = Sub.maxLtvBps(morphoMarketId_);
        if (ceiling == 0) revert CurveYieldBundleGuardFuseLtvCeilingNotGranted(morphoMarketId_);
        if (ceiling > ABSOLUTE_MAX_LTV_BPS) ceiling = ABSOLUTE_MAX_LTV_BPS;
        IMorpho morpho = IMorpho(MORPHO);
        Id id = Id.wrap(morphoMarketId_);
        MarketParams memory params = morpho.idToMarketParams(id);
        uint256 debt = MorphoBalancesLib.expectedBorrowAssets(morpho, params, address(this));
        if (debt == 0) return;
        uint256 collateral = morpho.position(id, address(this)).collateral;
        uint256 collateralValue = Math.mulDiv(collateral, ICyGuardMorphoOracle(params.oracle).price(), ORACLE_PRICE_SCALE);
        uint256 ltv = collateralValue == 0 ? type(uint256).max : debt * BPS / collateralValue;
        if (ltv > ceiling) revert CurveYieldBundleGuardFuseLtvAboveCeiling(morphoMarketId_, ltv, ceiling);
    }

    function _depthSlot() private view returns (bytes32) {
        return keccak256(abi.encode(VERSION, "curveyield.guard.depth"));
    }

    function _slots(uint256 depth_) private view returns (bytes32 a_, bytes32 s_) {
        a_ = keccak256(abi.encode(VERSION, "curveyield.guard.assets", depth_));
        s_ = keccak256(abi.encode(VERSION, "curveyield.guard.supply", depth_));
    }
}
