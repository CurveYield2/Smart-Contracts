// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "contracts/fuses/IMarketBalanceFuse.sol";
import {BalancerSubstrateLib, BalancerSubstrateType, BalancerSubstrate} from "contracts/fuses/balancer/BalancerSubstrateLib.sol";
import {IPool} from "contracts/fuses/balancer/ext/IPool.sol";
import {ILiquidityGauge} from "contracts/fuses/balancer/ext/ILiquidityGauge.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {IPriceOracleMiddleware} from "contracts/price_oracle/IPriceOracleMiddleware.sol";
import {IporMath} from "contracts/libraries/math/IporMath.sol";

/// @title CurveYieldRateAwareBalancerBalanceFuse (generic, IPOR style)
/// @notice IPOR BalancerBalanceFuse with one change: the vault's share of each pool is taken from the RAW balances (in
/// each token's own decimals) and every token is priced by the vault's oracle middleware. IPOR's version uses the
/// live, rate-scaled balances, which counts a WITH_RATE token's rate twice when the oracle also prices that token at
/// its rate. The vault's share of each token is COUNTED from the raw balances; a leg that is the vault's OWN share is
/// converted at the share rate (convertToAssets: no withdraw fee; the deposit rate while there is no deposit fee) and
/// valued as the underlying: never a market or oracle price. Same substrates as IPOR's Balancer
/// market (BalancerSubstrateLib POOL / GAUGE).
contract CurveYieldRateAwareBalancerBalanceFuse is IMarketBalanceFuse {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    error PriceOracleNotConfigured();

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function balanceOf() external view override returns (uint256 balance_) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        if (substrates.length == 0) return 0;
        address oracle = PlasmaVaultLib.getPriceOracleMiddleware();
        if (oracle == address(0)) revert PriceOracleNotConfigured();
        for (uint256 i; i < substrates.length; ++i) {
            BalancerSubstrate memory s = BalancerSubstrateLib.bytes32ToSubstrate(substrates[i]);
            address pool;
            uint256 lp;
            if (s.substrateType == BalancerSubstrateType.POOL) {
                pool = s.substrateAddress;
                lp = IERC20(pool).balanceOf(address(this));
            } else if (s.substrateType == BalancerSubstrateType.GAUGE) {
                pool = ILiquidityGauge(s.substrateAddress).lp_token();
                lp = IERC20(s.substrateAddress).balanceOf(address(this));
            } else {
                continue;
            }
            if (lp == 0) continue;
            (IERC20[] memory tokens,, uint256[] memory balancesRaw,) = IPool(pool).getTokenInfo();
            uint256 supply = IERC20(pool).totalSupply();
            for (uint256 j; j < tokens.length; ++j) {
                uint256 amount = balancesRaw[j] * lp / supply; // rounds down: never overstates
                if (amount == 0) continue;
                address token = address(tokens[j]);
                if (token == address(this)) {
                    // the vault's OWN shares: the counted amount at the share rate (convertToAssets: no withdraw
                    // fee; equals the deposit rate while there is no deposit fee), valued as the underlying
                    amount = IERC4626(address(this)).convertToAssets(amount);
                    token = IERC4626(address(this)).asset();
                }
                (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(oracle).getAssetPrice(token);
                balance_ += IporMath.convertToWad(amount * price, IERC20Metadata(token).decimals() + priceDecimals);
            }
        }
    }
}
