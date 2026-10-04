// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {IPriceOracleMiddleware} from "contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {FusesLib} from "contracts/libraries/FusesLib.sol";
import {IporMath} from "contracts/libraries/math/IporMath.sol";
import {IRewardsClaimManager} from "contracts/interfaces/IRewardsClaimManager.sol";
import {FuseAction, ICyPlasmaVault} from "../interfaces/CurveYieldPhase2Interfaces.sol";

/// @notice enter: snapshot before the bundle. `markets` = every market the bundle touches (and their dependants).
struct BundleGuardEnterData {
    uint256[] markets;
}

/// @notice exit: post-conditions after the bundle, against the snapshot.
struct BundleGuardExitData {
    uint256[] markets; // same list as enter
    uint256 maxPpsDropBps; // share price may not fall more than this (0 = never drops)
    int256 minAssetsPerShareDelta; // optional: minimum change of (fresh assets x supplyBefore / supplyAfter) - before, in the underlying (negative allows a bounded loss)
    uint256 minIdleAssets; // optional: underlying left idle in the vault
}

/// @title CurveYieldBundleGuardFuse (generic, IPOR style)
/// @notice First and last action of a bundle: `enter` snapshots the vault's gross assets (with the listed markets
/// freshly revalued through their own balance fuses) and supply in transient storage; `exit` revalues the same markets
/// and reverts the whole bundle unless the share price held (and the optional profit / idle floors).
/// IPOR only refreshes market balances after `execute` returns, so the guard revalues the touched markets itself.
/// Stateless, no vault address, reusable by any Plasma Vault.
contract CurveYieldBundleGuardFuse is IFuseCommon {
    using Address for address;

    uint256 private constant BPS = 10_000;

    address public immutable VERSION;
    uint256 public immutable override MARKET_ID;

    error GuardNotEntered();
    /// @notice Rounding allowance in raw assets (1e-15 avKAT) - covers per-op protocol rounding, never a real loss.
    uint256 public constant ROUNDING_DUST = 1_000;
    error PpsDropped(uint256 ppsBefore, uint256 ppsAfter, uint256 maxDropBps);
    error ProfitBelowMinimum(int256 delta, int256 minimum);
    error IdleBelowMinimum(uint256 idle, uint256 minimum);

    event BundleGuardPassed(address version, uint256 assetsBefore, uint256 assetsAfter, uint256 supplyBefore, uint256 supplyAfter);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(BundleGuardEnterData memory data_) external {
        uint256 assets = _freshGrossAssets(data_.markets);
        uint256 supply = IERC20(address(this)).totalSupply();
        (bytes32 a, bytes32 s) = _slots();
        assembly {
            tstore(a, add(assets, 1)) // +1: a stored zero means "not entered"
            tstore(s, supply)
        }
    }

    function exit(BundleGuardExitData memory data_) external {
        (bytes32 a, bytes32 s) = _slots();
        uint256 assetsBefore;
        uint256 supplyBefore;
        assembly {
            assetsBefore := tload(a)
            supplyBefore := tload(s)
            tstore(a, 0)
            tstore(s, 0)
        }
        if (assetsBefore == 0) revert GuardNotEntered();
        assetsBefore -= 1;
        uint256 assetsAfter = _freshGrossAssets(data_.markets);
        uint256 supplyAfter = IERC20(address(this)).totalSupply();

        // PPS: after/supplyAfter >= before/supplyBefore x (1 - drop)  <=>  after x sBefore x BPS >= before x sAfter x (BPS - drop)
        if (supplyBefore != 0 && supplyAfter != 0) {
            // ROUNDING_DUST: protocol share rounding (Morpho rounds every op in its own favour) moves raw totalAssets by
            // a few wei per step; PPS at 1e18 precision is unchanged (PPS_PROTECTION_SPEC A3, rounding allowance)
            if ((assetsAfter + ROUNDING_DUST) * supplyBefore * BPS < assetsBefore * supplyAfter * (BPS - data_.maxPpsDropBps)) {
                revert PpsDropped(assetsBefore * 1e18 / supplyBefore, assetsAfter * 1e18 / supplyAfter, data_.maxPpsDropBps);
            }
        }
        if (data_.minAssetsPerShareDelta != 0 && supplyAfter != 0) {
            int256 delta = int256(assetsAfter * supplyBefore / supplyAfter) - int256(assetsBefore);
            if (delta < data_.minAssetsPerShareDelta) revert ProfitBelowMinimum(delta, data_.minAssetsPerShareDelta);
        }
        if (data_.minIdleAssets != 0) {
            uint256 idle = IERC20(IERC4626(address(this)).asset()).balanceOf(address(this));
            if (idle < data_.minIdleAssets) revert IdleBelowMinimum(idle, data_.minIdleAssets);
        }
        emit BundleGuardPassed(VERSION, assetsBefore, assetsAfter, supplyBefore, supplyAfter);
    }

    /// @dev Gross assets (idle + all markets + rewards manager) with `markets_` revalued now.
    function _freshGrossAssets(uint256[] memory markets_) private returns (uint256 total_) {
        address asset = IERC4626(address(this)).asset();
        total_ = IERC20(asset).balanceOf(address(this)) + PlasmaVaultLib.getTotalAssetsInAllMarkets();
        address rcm = PlasmaVaultLib.getRewardsClaimManagerAddress();
        if (rcm != address(0)) total_ += IRewardsClaimManager(rcm).balanceOf();
        if (markets_.length == 0) return total_;
        (uint256 price, uint256 priceDecimals) =
            IPriceOracleMiddleware(PlasmaVaultLib.getPriceOracleMiddleware()).getAssetPrice(asset);
        uint256 assetDecimals = IERC20Metadata(asset).decimals();
        for (uint256 i; i < markets_.length; ++i) {
            address balanceFuse = FusesLib.getBalanceFuse(markets_[i]);
            if (balanceFuse == address(0)) continue;
            uint256 usd = abi.decode(balanceFuse.functionDelegateCall(abi.encodeWithSignature("balanceOf()")), (uint256));
            uint256 fresh = IporMath.convertWadToAssetDecimals(
                IporMath.division(usd * IporMath.BASIS_OF_POWER ** priceDecimals, price), assetDecimals
            );
            total_ = total_ - PlasmaVaultLib.getTotalAssetsInMarket(markets_[i]) + fresh;
        }
    }

    /// @notice Helper for bundle builders (read-only, called directly, not through the vault): returns
    /// [enter(markets)] + `actions_` + [exit(markets, maxPpsDropBps_)], with markets = the vault's active balance markets.
    function wrap(address vault_, FuseAction[] calldata actions_, uint256 maxPpsDropBps_)
        external view returns (FuseAction[] memory out_)
    {
        uint256[] memory markets = ICyPlasmaVault(vault_).getActiveMarketsInBalanceFuses();
        out_ = new FuseAction[](actions_.length + 2);
        out_[0] = FuseAction(VERSION, abi.encodeCall(this.enter, (BundleGuardEnterData(markets))));
        for (uint256 i; i < actions_.length; ++i) out_[i + 1] = actions_[i];
        out_[actions_.length + 1] = FuseAction(VERSION, abi.encodeCall(
            this.exit, (BundleGuardExitData(markets, maxPpsDropBps_, int256(0), uint256(0)))
        ));
    }

    /// @notice As wrap, but the bundle must RAISE the share price by at least `minGainAssets_` (assets per the
    /// snapshot's supply): e.g. a buyback's guaranteed net gain. Zero gain reverts.
    function wrapWithGain(address vault_, FuseAction[] calldata actions_, uint256 minGainAssets_)
        external view returns (FuseAction[] memory out_)
    {
        uint256[] memory markets = ICyPlasmaVault(vault_).getActiveMarketsInBalanceFuses();
        int256 minDelta = minGainAssets_ == 0 ? int256(1) : int256(minGainAssets_);
        out_ = new FuseAction[](actions_.length + 2);
        out_[0] = FuseAction(VERSION, abi.encodeCall(this.enter, (BundleGuardEnterData(markets))));
        for (uint256 i; i < actions_.length; ++i) out_[i + 1] = actions_[i];
        out_[actions_.length + 1] = FuseAction(VERSION, abi.encodeCall(
            this.exit, (BundleGuardExitData(markets, uint256(0), minDelta, uint256(0)))
        ));
    }

    function _slots() private view returns (bytes32 a_, bytes32 s_) {
        a_ = keccak256(abi.encode(VERSION, "curveyield.guard.assets"));
        s_ = keccak256(abi.encode(VERSION, "curveyield.guard.supply"));
    }
}
