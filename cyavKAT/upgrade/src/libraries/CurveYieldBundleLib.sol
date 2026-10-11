// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {FuseAction, ICyPlasmaVault} from "../interfaces/CurveYieldPhase2Interfaces.sol";
import {
    CurveYieldBundleGuardFuse,
    CurveYieldBundleGuardFuseEnterData,
    CurveYieldBundleGuardFuseExitData
} from "../generic/CurveYieldBundleGuardFuse.sol";

/// @title CurveYieldBundleLib
/// @notice Planner-side helpers that bracket a bundle with `CurveYieldBundleGuardFuse.enter` / `exit` over the vault's
/// active markets (the former `wrap` helpers of the guard fuse, IPOR_FUSE_CONFORMANCE_SPEC §4.2). A pure view: it only
/// builds the actions.
library CurveYieldBundleLib {
    /// @notice [enter] + actions + [exit]: the share price may not fall by more than `maxPpsDropBps_` (0 = never).
    function wrap(address guard_, address vault_, FuseAction[] memory actions_, uint256 maxPpsDropBps_)
        internal view returns (FuseAction[] memory)
    {
        return wrapFull(guard_, vault_, actions_, maxPpsDropBps_, int256(0), new bytes32[](0));
    }

    /// @notice As wrap, and the bundle must RAISE assets per share by at least `minGainAssets_` (zero reverts).
    function wrapWithGain(address guard_, address vault_, FuseAction[] memory actions_, uint256 minGainAssets_)
        internal view returns (FuseAction[] memory)
    {
        return wrapFull(guard_, vault_, actions_, 0, minGainAssets_ == 0 ? int256(1) : int256(minGainAssets_), new bytes32[](0));
    }

    /// @notice As wrap, but a loss of at most `maxLossAssets_` (assets per the snapshot's supply) is accepted.
    function wrapWithLoss(address guard_, address vault_, FuseAction[] memory actions_, uint256 maxLossAssets_)
        internal view returns (FuseAction[] memory)
    {
        return wrapFull(guard_, vault_, actions_, 0, -int256(maxLossAssets_), new bytes32[](0));
    }

    /// @notice As wrap, and the listed Morpho markets must end at or under their granted LTV ceiling.
    function wrapWithLtv(address guard_, address vault_, FuseAction[] memory actions_, bytes32[] memory morphoMarkets_)
        internal view returns (FuseAction[] memory)
    {
        return wrapFull(guard_, vault_, actions_, 0, int256(0), morphoMarkets_);
    }

    function wrapFull(
        address guard_, address vault_, FuseAction[] memory actions_, uint256 maxPpsDropBps_, int256 minAssetsPerShareDelta_,
        bytes32[] memory morphoMarkets_
    ) internal view returns (FuseAction[] memory out_) {
        uint256[] memory markets = ICyPlasmaVault(vault_).getActiveMarketsInBalanceFuses();
        out_ = new FuseAction[](actions_.length + 2);
        out_[0] = FuseAction(guard_, abi.encodeCall(
            CurveYieldBundleGuardFuse.enter, (CurveYieldBundleGuardFuseEnterData(markets))
        ));
        for (uint256 i; i < actions_.length; ++i) out_[i + 1] = actions_[i];
        out_[actions_.length + 1] = FuseAction(guard_, abi.encodeCall(
            CurveYieldBundleGuardFuse.exit,
            (CurveYieldBundleGuardFuseExitData(markets, maxPpsDropBps_, minAssetsPerShareDelta_, 0, morphoMarkets_))
        ));
    }

    function concat(FuseAction[] memory a_, FuseAction[] memory b_) internal pure returns (FuseAction[] memory out_) {
        out_ = new FuseAction[](a_.length + b_.length);
        for (uint256 i; i < a_.length; ++i) out_[i] = a_[i];
        for (uint256 i; i < b_.length; ++i) out_[a_.length + i] = b_[i];
    }
}
