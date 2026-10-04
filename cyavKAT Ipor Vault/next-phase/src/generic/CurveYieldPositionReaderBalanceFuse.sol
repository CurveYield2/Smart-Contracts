// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IMarketBalanceFuse} from "contracts/fuses/IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {IporMath} from "contracts/libraries/math/IporMath.sol";

/// @notice A position held OUTSIDE the vault on its behalf (a holder contract, an exit queue ...), reported as one
/// NET amount of one asset. Debt or fees are netted inside the reader and the result is never negative.
interface ICurveYieldPositionReader {
    function positionValue(address vault) external view returns (address asset, uint256 amount);
}

/// @title CurveYieldPositionReaderBalanceFuse (generic, IPOR style; ERC20_VAULT_BALANCE market)
/// @notice IPOR Erc20BalanceFuse plus position readers:
///   MARKET_ID substrates: plain ERC-20 addresses the vault holds (IPOR's convention, unchanged; underlying skipped)
///   SUBSTRATE_MARKET_ID entries bytes32(1 << 160 | reader): position readers, valued at the oracle price of their asset
/// The type tag keeps a reader from ever being read as a token balance (and a token from being called as a reader).
contract CurveYieldPositionReaderBalanceFuse is IMarketBalanceFuse {
    uint256 public constant TYPE_READER = 1;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    uint256 public immutable SUBSTRATE_MARKET_ID; // where the typed reader entries live

    constructor(uint256 marketId_, uint256 substrateMarketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        SUBSTRATE_MARKET_ID = substrateMarketId_;
    }

    function readerSubstrate(address reader_) external pure returns (bytes32) {
        return bytes32((TYPE_READER << 160) | uint256(uint160(reader_)));
    }

    function balanceOf() external view override returns (uint256 balance_) {
        IPriceOracleMiddleware oracle = IPriceOracleMiddleware(PlasmaVaultLib.getPriceOracleMiddleware());
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        address underlying = IERC4626(address(this)).asset();
        for (uint256 i; i < substrates.length; ++i) {
            if (uint256(substrates[i]) >> 160 != 0) continue; // IPOR convention: plain token addresses only
            address token = PlasmaVaultConfigLib.bytes32ToAddress(substrates[i]);
            if (token == underlying) continue; // idle underlying is counted by the vault itself
            balance_ += _usd(oracle, token, IERC20(token).balanceOf(address(this)));
        }
        bytes32[] memory readers = PlasmaVaultConfigLib.getMarketSubstrates(SUBSTRATE_MARKET_ID);
        for (uint256 i; i < readers.length; ++i) {
            if (uint256(readers[i]) >> 160 != TYPE_READER) continue;
            (address asset, uint256 amount) =
                ICurveYieldPositionReader(PlasmaVaultConfigLib.bytes32ToAddress(readers[i])).positionValue(address(this));
            balance_ += _usd(oracle, asset, amount);
        }
    }

    function _usd(IPriceOracleMiddleware oracle_, address asset_, uint256 amount_) private view returns (uint256) {
        if (amount_ == 0) return 0;
        (uint256 price, uint256 priceDecimals) = oracle_.getAssetPrice(asset_);
        return IporMath.convertToWad(amount_ * price, IERC20Metadata(asset_).decimals() + priceDecimals);
    }
}
