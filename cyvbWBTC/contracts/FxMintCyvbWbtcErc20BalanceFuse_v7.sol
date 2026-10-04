// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PlasmaVaultConfigLib} from "./ipor/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "./ipor/PlasmaVaultStorageLib.sol";

/// @notice Minimal IERC20 surface used by IPOR's ERC20 balance accounting pattern.
interface IERC20FxMintErc20BalanceV7 {
    function balanceOf(address account) external view returns (uint256);
}

interface IERC20MetadataFxMintErc20BalanceV7 {
    function decimals() external view returns (uint8);
}

interface IERC4626FxMintErc20BalanceV7 {
    function asset() external view returns (address);
}

interface IPriceOracleMiddlewareFxMintErc20BalanceV7 {
    function getAssetPrice(address asset) external view returns (uint256 price, uint256 decimals);
}

interface ICyvbWbtcPositionRegistryBalanceV5 {
    function positionId() external view returns (uint256);
}

interface IFxLongPoolBalanceCyvbWBTCV5 {
    function getPosition(uint256 tokenId) external view returns (uint256 rawColls, uint256 rawDebts);
    function priceOracle() external view returns (address);
}

interface IFxOracleBalanceCyvbWBTCV5 {
    function getPrice() external view returns (uint256 anchorPrice, uint256 minPrice, uint256 maxPrice);
}

/// @title FxMintCyvbWbtcErc20BalanceFuse_v7
/// @notice IPOR ERC20_VAULT_BALANCE accounting with the smallest possible f(x) extension.
/// @dev This contract intentionally follows IPOR-Labs/ipor-fusion ERC20BalanceFuse:
///      - MARKET_ID is the official ERC20_VAULT_BALANCE id (7);
///      - iterate market substrates;
///      - skip the PlasmaVault underlying asset to avoid double counting;
///      - price normal ERC20 balances through PriceOracleMiddleware and convert to USD WAD.
///
///      The only protocol-specific modification is that the granted f(x) pool substrate is not
///      treated as an ERC20. Instead, its tracked long position is valued like IPOR's leveraged
///      balance fuses (for example Ebisu): collateral value minus debt, floored at zero.
///
///      No custom accounting market ID is introduced.
contract FxMintCyvbWbtcErc20BalanceFuse_v7 {
    uint256 public constant MARKET_ID = 7; // IporFusionMarkets.ERC20_VAULT_BALANCE
    uint256 private constant WAD = 1e18;

    address public immutable VERSION;
    address public immutable CONFIG;
    address public immutable FX_POOL;

    error InvalidAddress();
    error InvalidPrice();

    constructor(address config_, address fxPool_) {
        if (config_ == address(0) || fxPool_ == address(0)) revert InvalidAddress();
        if (config_.code.length == 0 || fxPool_.code.length == 0) revert InvalidAddress();

        VERSION = address(this);
        CONFIG = config_;
        FX_POOL = fxPool_;
    }

    /// @return balance Total market-7 balance in USD WAD: residual ERC20 balances plus net f(x) position.
    function balanceOf() external view returns (uint256 balance) {
        bytes32[] memory substrates =
            PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = substrates.length;
        if (len == 0) return 0;

        address underlyingAsset = IERC4626FxMintErc20BalanceV7(address(this)).asset();
        address priceOracleMiddleware =
            PlasmaVaultStorageLib.getPriceOracleMiddleware().value;

        for (uint256 i; i < len; ++i) {
            address substrate = address(uint160(uint256(substrates[i])));

            if (substrate == FX_POOL) {
                balance += _fxNetPositionValue();
                continue;
            }

            if (substrate == underlyingAsset) {
                continue;
            }

            (uint256 price, uint256 priceDecimals) =
                IPriceOracleMiddlewareFxMintErc20BalanceV7(priceOracleMiddleware)
                    .getAssetPrice(substrate);

            uint256 tokenBalance =
                IERC20FxMintErc20BalanceV7(substrate).balanceOf(address(this));

            balance += _convertToWad(
                tokenBalance * price,
                uint256(IERC20MetadataFxMintErc20BalanceV7(substrate).decimals()) + priceDecimals
            );
        }
    }

    function _fxNetPositionValue() private view returns (uint256) {
        uint256 positionId = ICyvbWbtcPositionRegistryBalanceV5(CONFIG).positionId();
        if (positionId == 0) return 0;

        (uint256 rawColls, uint256 rawDebts) =
            IFxLongPoolBalanceCyvbWBTCV5(FX_POOL).getPosition(positionId);

        if (rawColls == 0 && rawDebts == 0) return 0;

        (uint256 anchorPrice,,) =
            IFxOracleBalanceCyvbWBTCV5(IFxLongPoolBalanceCyvbWBTCV5(FX_POOL).priceOracle())
                .getPrice();
        if (anchorPrice == 0) revert InvalidPrice();

        uint256 collateralValue = (rawColls * anchorPrice) / WAD;

        // Match IPOR leveraged-market accounting style: max(collateral - debt, 0).
        return rawDebts >= collateralValue ? 0 : collateralValue - rawDebts;
    }

    /// @dev Equivalent conversion rule to IPOR's IporMath.convertToWad.
    function _convertToWad(uint256 value_, uint256 decimals_) private pure returns (uint256) {
        if (value_ == 0 || decimals_ == 18) return value_;
        if (decimals_ > 18) return value_ / (10 ** (decimals_ - 18));
        return value_ * (10 ** (18 - decimals_));
    }
}
