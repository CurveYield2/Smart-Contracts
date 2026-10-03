// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface ICyvbWbtcPositionConfigV1 {
    function positionId() external view returns (uint256);
}

interface IFxLongPoolBalanceCyvbWBTCV1 {
    function getPosition(uint256 tokenId) external view returns (uint256 rawColls, uint256 rawDebts);
    function priceOracle() external view returns (address);
    function configuration() external view returns (address);
}

interface IFxOracleBalanceCyvbWBTCV1 {
    function getPrice() external view returns (uint256 anchorPrice, uint256 minPrice, uint256 maxPrice);
}

interface IFxPoolConfigurationBalanceCyvbWBTCV1 {
    function getPoolFeeRatio(
        address pool,
        address recipient
    ) external view returns (uint256 supplyFeeRatio, uint256 withdrawFeeRatio, uint256 borrowFeeRatio, uint256 repayFeeRatio);
}

interface IERC20MetaBalanceCyvbWBTCV1 {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IERC4626BalanceCyvbWBTCV1 {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function asset() external view returns (address);
}

/// @title FxMintCyvbWbtcBalanceFuse_v1
/// @notice Net USD-WAD accounting for cyvbWBTC's f(x) leveraged position and nested cyvbUSDC.
/// @dev Market value = liquidation-value f(x) collateral - fxUSD debt + nested cyvbUSDC underlying
///      + residual fxUSD/vbUSDC. Idle vbWBTC is intentionally excluded because PlasmaVault counts
///      its underlying-token balance separately.
contract FxMintCyvbWbtcBalanceFuse_v1 {
    uint256 public constant MARKET_ID = 7001;
    uint256 private constant WAD = 1e18;
    uint256 private constant FEE_PRECISION = 1e9;

    address public immutable VERSION;
    address public immutable CONFIG;
    address public immutable FX_POOL;
    address public immutable FXUSD;
    address public immutable VB_USDC;
    address public immutable CYVBUSDC;

    error InvalidAddress();
    error NestedVaultAssetMismatch();

    constructor(
        address config_,
        address fxPool_,
        address fxUsd_,
        address vbUsdc_,
        address cyvbUsdc_
    ) {
        if (
            config_ == address(0) ||
            fxPool_ == address(0) ||
            fxUsd_ == address(0) ||
            vbUsdc_ == address(0) ||
            cyvbUsdc_ == address(0)
        ) revert InvalidAddress();
        if (
            config_.code.length == 0 ||
            fxPool_.code.length == 0 ||
            fxUsd_.code.length == 0 ||
            vbUsdc_.code.length == 0 ||
            cyvbUsdc_.code.length == 0
        ) revert InvalidAddress();
        if (IERC4626BalanceCyvbWBTCV1(cyvbUsdc_).asset() != vbUsdc_) revert NestedVaultAssetMismatch();

        VERSION = address(this);
        CONFIG = config_;
        FX_POOL = fxPool_;
        FXUSD = fxUsd_;
        VB_USDC = vbUsdc_;
        CYVBUSDC = cyvbUsdc_;
    }

    function balanceOf() external view returns (uint256) {
        uint256 grossAssetsUsd;

        uint256 position = ICyvbWbtcPositionConfigV1(CONFIG).positionId();
        if (position != 0) {
            (uint256 rawColls, uint256 rawDebts) = IFxLongPoolBalanceCyvbWBTCV1(FX_POOL).getPosition(position);
            (uint256 anchorPrice,,) =
                IFxOracleBalanceCyvbWBTCV1(IFxLongPoolBalanceCyvbWBTCV1(FX_POOL).priceOracle()).getPrice();

            // Value collateral at expected liquidation proceeds after the live f(x) withdrawal fee.
            uint256 collateralUsd = (rawColls * anchorPrice) / WAD;
            (, uint256 withdrawFee,,) = IFxPoolConfigurationBalanceCyvbWBTCV1(
                IFxLongPoolBalanceCyvbWBTCV1(FX_POOL).configuration()
            ).getPoolFeeRatio(FX_POOL, address(this));
            if (withdrawFee < FEE_PRECISION) {
                collateralUsd = (collateralUsd * (FEE_PRECISION - withdrawFee)) / FEE_PRECISION;
            } else {
                collateralUsd = 0;
            }

            grossAssetsUsd = collateralUsd;
            if (rawDebts >= grossAssetsUsd) {
                grossAssetsUsd = 0;
            } else {
                grossAssetsUsd -= rawDebts; // fxUSD debt is USD-denominated, 18 decimals.
            }
        }

        uint256 nestedShares = IERC4626BalanceCyvbWBTCV1(CYVBUSDC).balanceOf(address(this));
        if (nestedShares != 0) {
            grossAssetsUsd += _toWad(
                IERC4626BalanceCyvbWBTCV1(CYVBUSDC).convertToAssets(nestedShares),
                IERC20MetaBalanceCyvbWBTCV1(VB_USDC).decimals()
            );
        }

        grossAssetsUsd += _toWad(
            IERC20MetaBalanceCyvbWBTCV1(VB_USDC).balanceOf(address(this)),
            IERC20MetaBalanceCyvbWBTCV1(VB_USDC).decimals()
        );
        grossAssetsUsd += _toWad(
            IERC20MetaBalanceCyvbWBTCV1(FXUSD).balanceOf(address(this)),
            IERC20MetaBalanceCyvbWBTCV1(FXUSD).decimals()
        );

        return grossAssetsUsd;
    }

    function _toWad(uint256 amount_, uint8 decimals_) private pure returns (uint256) {
        if (amount_ == 0 || decimals_ == 18) return amount_;
        if (decimals_ < 18) return amount_ * (10 ** (18 - decimals_));
        return amount_ / (10 ** (decimals_ - 18));
    }
}
