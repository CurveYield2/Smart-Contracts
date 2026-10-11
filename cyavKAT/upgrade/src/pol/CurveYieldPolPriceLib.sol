// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CurveYieldSwapLib} from "./CurveYieldSwapLib.sol";
import {CySushiRoute, ICyPolVault} from "./CurveYieldPolInterfaces.sol";

/// @title CurveYieldPolPriceLib (POL spec section 4)
/// @notice deposit rate = avKAT per whole cyavKAT at the share rate (convertToAssets: no withdraw fee);
/// market rate = avKAT per whole cyavKAT from TWAPs: cyavKAT -> WETH on the Sushi 0.3% pool, then WETH -> avKAT
/// on the best-valued route (the cheapest-for-us route is the one that returns the most).
library CurveYieldPolPriceLib {
    function oneShare(address vault_) internal view returns (uint256) {
        return 10 ** ICyPolVault(vault_).decimals();
    }

    /// @notice avKAT per whole cyavKAT at the vault's share rate, convertToAssets: total assets / total supply, with NO
    /// withdraw fee (IPOR applies the fee only in previewRedeem / previewWithdraw) and, with no deposit fee, equal to
    /// the deposit rate. Never a market price. `feeManager_` is kept for the call sites (unused).
    function depositRate(address vault_, address feeManager_) internal view returns (uint256) {
        feeManager_;
        return ICyPolVault(vault_).convertToAssets(oneShare(vault_));
    }

    /// @return rate_ avKAT per whole cyavKAT; 0 when no market reference is configured.
    function marketRate(
        address vault_, address cyWethPool_, CySushiRoute[] memory wethToAvkat_, uint32 window_
    ) internal view returns (uint256 rate_) {
        if (cyWethPool_ == address(0) || wethToAvkat_.length == 0) return 0;
        uint256 weth = CurveYieldSwapLib.twapOut(cyWethPool_, vault_, oneShare(vault_), window_);
        for (uint256 i; i < wethToAvkat_.length; ++i) {
            uint256 out = CurveYieldSwapLib.twapOutRoute(wethToAvkat_[i], weth, window_);
            if (out > rate_) rate_ = out;
        }
    }

    /// @notice cyavKAT (raw) -> avKAT at the net rate.
    function netValue(address vault_, address feeManager_, uint256 shares_) internal view returns (uint256) {
        return shares_ * depositRate(vault_, feeManager_) / oneShare(vault_);
    }
}
