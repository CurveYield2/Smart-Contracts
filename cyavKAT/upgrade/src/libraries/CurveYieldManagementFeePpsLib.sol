// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice IPOR management-fee-neutral PPS denominator for CurveYield safety checks.
/// @dev IPOR realizes previously accrued management fees by minting shares, not by removing vault assets.
/// Before realization those same shares are an accrued liability. Counting them as virtual shares
/// on BOTH sides of the check prevents a fee crystallization from appearing as strategy loss.
/// Only the vault's native, read-only getUnrealizedManagementFee() and convertToShares() are used:
/// no keeper-provided exemption, loss allowance, configurable recipient, or modified IPOR source.
interface ICurveYieldManagementFeeView {
    function getUnrealizedManagementFee() external view returns (uint256);
}

library CurveYieldManagementFeePpsLib {
    function effectiveSupply(address vault_) internal view returns (uint256) {
        uint256 supply = IERC20(vault_).totalSupply();
        uint256 accruedFeeAssets = ICurveYieldManagementFeeView(vault_).getUnrealizedManagementFee();
        if (accruedFeeAssets == 0) return supply;
        return supply + IERC4626(vault_).convertToShares(accruedFeeAssets);
    }
}
