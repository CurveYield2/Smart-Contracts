// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IFxLongPoolBalanceCyvbWBTCV4 {
    function getPosition(uint256 tokenId) external view returns (uint256 rawColls, uint256 rawDebts);
    function priceOracle() external view returns (address);
    function configuration() external view returns (address);
}

interface IFxOracleBalanceCyvbWBTCV4 {
    function getPrice() external view returns (uint256 anchorPrice, uint256 minPrice, uint256 maxPrice);
}

interface IFxPoolConfigurationBalanceCyvbWBTCV4 {
    function getPoolFeeRatio(
        address pool,
        address recipient
    ) external view returns (uint256 supplyFeeRatio, uint256 withdrawFeeRatio, uint256 borrowFeeRatio, uint256 repayFeeRatio);
}

interface IERC20MetaBalanceCyvbWBTCV4 {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IERC4626BalanceCyvbWBTCV4 {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function asset() external view returns (address);
}

interface IFxBaseBalanceCyvbWBTCV5 {
    function balanceOf(address account) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256 yieldOut, uint256 stableOut);
}

/// @title FxMintCyvbWbtcBalanceFuse_v5
/// @notice Net USD-WAD value of cyvbWBTC's strategy (market 7): f(x) liquidation-value collateral - fxUSD debt
///         + nested cyvbUSDC (at its PPS) + the fxBASE earn pool (staked in its gauge or held for a pending redeem,
///         valued at previewRedeem: fxUSD + vbUSDC at $1, like the fxUSD debt) + residual vbUSDC / fxUSD. Idle vbWBTC is counted by the vault itself.
/// @dev Custom because IPOR's official FxMintBalanceFuse assumes f(x) raw collateral is in the token's own
///      decimals (true for WETH), while f(x) scales raw collateral to 18 decimals (vbWBTC: x1e10) - the official
///      fuse would overvalue an 8-decimal collateral 1e10x. (IPOR's Erc4626BalanceFuse is not deployed on Katana for
///      this market and would pull the full IPOR source into this repo, so the nested leg stays here too.)
///      The position id is read from IPOR's official FxMintStorageLib slot, written by the strategy fuse.
contract FxMintCyvbWbtcBalanceFuse_v5 {
    bytes32 private constant FX_MINT_POSITION_IDS = 0xd6497e578ce2e2ee4effa1fadef2326ebdc8f2b065aece8657da626f367fe500;
    uint256 private constant WAD = 1e18;
    uint256 private constant FEE_PRECISION = 1e9;

    struct FxMintPositionIds {
        mapping(address pool => uint256 positionId) positionIds;
    }

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable FX_POOL;
    address public immutable FXUSD;
    address public immutable VB_USDC;
    address public immutable CYVBUSDC;
    address public immutable FXBASE;
    address public immutable EARN_GAUGE;

    error InvalidAddress();
    error NestedVaultAssetMismatch();

    constructor(
        uint256 marketId_,
        address fxPool_,
        address fxUsd_,
        address vbUsdc_,
        address cyvbUsdc_,
        address fxBase_,
        address earnGauge_
    ) {
        if (fxBase_.code.length == 0 || earnGauge_.code.length == 0) revert InvalidAddress();
        FXBASE = fxBase_;
        EARN_GAUGE = earnGauge_;
        if (fxPool_.code.length == 0 || fxUsd_.code.length == 0 || vbUsdc_.code.length == 0 || cyvbUsdc_.code.length == 0) {
            revert InvalidAddress();
        }
        if (IERC4626BalanceCyvbWBTCV4(cyvbUsdc_).asset() != vbUsdc_) revert NestedVaultAssetMismatch();
        FXUSD = fxUsd_;
        VB_USDC = vbUsdc_;
        CYVBUSDC = cyvbUsdc_;
        VERSION = address(this);
        MARKET_ID = marketId_;
        FX_POOL = fxPool_;
    }

    function balanceOf() external view returns (uint256 total_) {
        total_ = _positionValue();
        uint256 nested = IERC4626BalanceCyvbWBTCV4(CYVBUSDC).balanceOf(address(this));
        if (nested != 0) total_ += _toWad(IERC4626BalanceCyvbWBTCV4(CYVBUSDC).convertToAssets(nested), VB_USDC);
        uint256 earnShares = IFxBaseBalanceCyvbWBTCV5(EARN_GAUGE).balanceOf(address(this))
            + IFxBaseBalanceCyvbWBTCV5(FXBASE).balanceOf(address(this));
        if (earnShares != 0) {
            (uint256 yieldOut, uint256 stableOut) = IFxBaseBalanceCyvbWBTCV5(FXBASE).previewRedeem(earnShares);
            total_ += _toWad(yieldOut, FXUSD) + _toWad(stableOut, VB_USDC);
        }
        total_ += _toWad(IERC20MetaBalanceCyvbWBTCV4(VB_USDC).balanceOf(address(this)), VB_USDC);
        total_ += _toWad(IERC20MetaBalanceCyvbWBTCV4(FXUSD).balanceOf(address(this)), FXUSD);
    }

    function _positionValue() private view returns (uint256) {
        uint256 position = _ids().positionIds[FX_POOL];
        if (position == 0) return 0;

        (uint256 rawColls, uint256 rawDebts) = IFxLongPoolBalanceCyvbWBTCV4(FX_POOL).getPosition(position);
        (uint256 anchorPrice,,) =
            IFxOracleBalanceCyvbWBTCV4(IFxLongPoolBalanceCyvbWBTCV4(FX_POOL).priceOracle()).getPrice();

        // collateral at expected exit proceeds after the live f(x) withdrawal fee (rawColls: 18-decimal scaled)
        uint256 collateralUsd = (rawColls * anchorPrice) / WAD;
        (, uint256 withdrawFee,,) = IFxPoolConfigurationBalanceCyvbWBTCV4(
            IFxLongPoolBalanceCyvbWBTCV4(FX_POOL).configuration()
        ).getPoolFeeRatio(FX_POOL, address(this));
        collateralUsd = withdrawFee < FEE_PRECISION ? (collateralUsd * (FEE_PRECISION - withdrawFee)) / FEE_PRECISION : 0;

        return collateralUsd > rawDebts ? collateralUsd - rawDebts : 0; // fxUSD debt: USD, 18 decimals
    }

    function _toWad(uint256 amount_, address token_) private view returns (uint256) {
        if (amount_ == 0) return 0;
        uint8 decimals = IERC20MetaBalanceCyvbWBTCV4(token_).decimals();
        if (decimals == 18) return amount_;
        return decimals < 18 ? amount_ * 10 ** (18 - decimals) : amount_ / 10 ** (decimals - 18);
    }

    function _ids() private pure returns (FxMintPositionIds storage s_) {
        bytes32 slot = FX_MINT_POSITION_IDS;
        assembly {
            s_.slot := slot
        }
    }
}
