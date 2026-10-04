// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPriceFeed} from "contracts/price_oracle/price_feed/IPriceFeed.sol";
import {IPriceOracleMiddleware} from "contracts/price_oracle/IPriceOracleMiddleware.sol";
import {IporMath} from "contracts/libraries/math/IporMath.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface ICyNetPpsVault {
    function decimals() external view returns (uint8);
    function asset() external view returns (address);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function getPerformanceFeeData() external view returns (CyPerfFeeData memory);
}

struct CyPerfFeeData {
    address feeAccount;
    uint16 feeInPercentage; // bps
}

struct CyHwm {
    uint128 highWaterMark;
    uint32 lastUpdate;
    uint32 updateInterval;
}

interface ICyNetPpsFeeManager {
    function getPlasmaVaultHighWaterMarkPerformanceFee() external view returns (CyHwm memory);
}

/// @title CurveYieldNetPps (library + price feed, #20)
/// @notice An IPOR vault's share price NET of its pending (not yet crystallised) performance fee. IPOR mints
/// feeShares = supply * (rate - hwm) / rate * perf at the next crystallisation, so the post-fee rate is
///   net = rate^2 / (rate + (rate - hwm) * perf / 10_000)
/// Pricing cyavKAT this way inside cyavKAT+ means the main vault's fee crystallisation never moves cyavKAT+'s PPS.
library CurveYieldNetPps {
    function netRate(address vault_, address feeManager_) internal view returns (uint256 rate_) {
        ICyNetPpsVault v = ICyNetPpsVault(vault_);
        rate_ = v.convertToAssets(10 ** v.decimals());
        uint256 hwm = ICyNetPpsFeeManager(feeManager_).getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark;
        uint256 perf = v.getPerformanceFeeData().feeInPercentage;
        if (hwm == 0 || perf == 0 || rate_ <= hwm) return rate_;
        rate_ = rate_ * rate_ * 10_000 / (rate_ * 10_000 + (rate_ - hwm) * perf);
    }
}

/// @notice IPOR price feed: USD price of one vault share, net of the vault's pending performance fee.
contract CurveYieldNetPpsPriceFeed is IPriceFeed {
    address public immutable VAULT;
    address public immutable FEE_MANAGER;

    constructor(address vault_, address feeManager_) {
        VAULT = vault_;
        FEE_MANAGER = feeManager_;
    }

    function decimals() external pure override returns (uint8) {
        return 18;
    }

    function latestRoundData()
        external view override returns (uint80, int256 price, uint256, uint256, uint80)
    {
        address asset = ICyNetPpsVault(VAULT).asset();
        (uint256 assetPrice, uint256 priceDecimals) = IPriceOracleMiddleware(msg.sender).getAssetPrice(asset);
        uint256 rate = CurveYieldNetPps.netRate(VAULT, FEE_MANAGER); // asset units per 1 share
        price = int256(IporMath.convertToWad(rate * assetPrice, IERC20Metadata(asset).decimals() + priceDecimals));
    }
}
