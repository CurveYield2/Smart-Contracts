// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IFxBaseIndicatorV1 {
    function balanceOf(address account) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256 yieldOut, uint256 stableOut);
}

interface IERC4626IndicatorV1 {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

interface IFxPoolIndicatorV1 {
    function getPosition(uint256 tokenId) external view returns (uint256 rawColls, uint256 rawDebts);
    function configuration() external view returns (address);
}

interface IFxPoolManagerIndicatorV1 {
    function getTokenScalingFactor(address token) external view returns (uint256);
}

interface IFxPoolConfigurationIndicatorV1 {
    function getPoolFeeRatio(address pool, address recipient)
        external view returns (uint256 supplyFee, uint256 withdrawFee, uint256 borrowFee, uint256 repayFee);
}

/// @title CyvbEthIndicatorToken_v1 (EARN_POOL_SPEC_v1, accounting v2)
/// @notice Read-only "token" that shows one cyvbETH position on the IPOR dashboard as an ERC20 position in market 7
///         (official ERC20 balance fuse). Non-transferable; no supply is ever minted. Kinds:
///         - FX_COLLATERAL: the vbWBTC the vault holds as f(x) collateral (8 decimals, exit value after the f(x)
///           withdraw fee). Priced with the vbWBTC feed: THIS is the strategy's share value (accounting v2).
///         - EARN_POOL_TVL / CYVBUSDC_TVL / FXUSD_DEBT: live USD amounts (18 decimals, 1 unit = $1), priced at 1 wei
///           (IPOR rejects 0) - visible, but outside share value.
contract CyvbEthIndicatorToken_v1 {
    enum Kind {
        FX_COLLATERAL,
        EARN_POOL_TVL,
        CYVBUSDC_TVL,
        FXUSD_DEBT
    }

    uint8 public immutable decimals;
    uint256 private constant USDC_TO_WAD = 1e12; // vbUSDC has 6 decimals

    string public name;
    string public symbol;
    Kind public immutable KIND;
    address public immutable VAULT;
    address public immutable SOURCE; // fxBASE / cyvbUSDC / f(x) pool
    address public immutable EARN_GAUGE; // EARN_POOL_TVL: the gauge; FX_COLLATERAL: the f(x) pool manager
    address public immutable COLLATERAL; // FX_COLLATERAL: vbWBTC
    /// @notice f(x) position id (FX_COLLATERAL / FXUSD_DEBT), registered by the strategy fuse from the vault.
    uint256 public positionId;

    error NonTransferable();
    error NotVault();

    event PositionRegistered(uint256 positionId);

    constructor(
        string memory name_,
        string memory symbol_,
        Kind kind_,
        address vault_,
        address source_,
        address earnGauge_,
        address collateral_,
        uint8 decimals_
    ) {
        name = name_;
        COLLATERAL = collateral_;
        decimals = decimals_;
        symbol = symbol_;
        KIND = kind_;
        VAULT = vault_;
        SOURCE = source_;
        EARN_GAUGE = earnGauge_;
    }

    /// @notice FX_COLLATERAL / FXUSD_DEBT: the vault (its strategy fuse) registers the f(x) position it opened.
    function registerPosition(uint256 positionId_) external {
        if (msg.sender != VAULT) revert NotVault();
        positionId = positionId_;
        emit PositionRegistered(positionId_);
    }

    function totalSupply() external view returns (uint256) {
        return _value();
    }

    function balanceOf(address account_) external view returns (uint256) {
        return account_ == VAULT ? _value() : 0;
    }

    function _value() private view returns (uint256) {
        if (KIND == Kind.FX_COLLATERAL) {
            uint256 pid = positionId;
            if (pid == 0) return 0;
            (uint256 rawColls,) = IFxPoolIndicatorV1(SOURCE).getPosition(pid);
            // raw collateral is 18-decimal scaled: token amount = raw x 1e18 / scale; then net of the f(x) withdraw fee
            uint256 amount = (rawColls * 1e18) / IFxPoolManagerIndicatorV1(EARN_GAUGE).getTokenScalingFactor(COLLATERAL);
            (, uint256 withdrawFee,,) = IFxPoolConfigurationIndicatorV1(IFxPoolIndicatorV1(SOURCE).configuration())
                .getPoolFeeRatio(SOURCE, VAULT);
            return withdrawFee < 1e9 ? (amount * (1e9 - withdrawFee)) / 1e9 : 0;
        }
        if (KIND == Kind.EARN_POOL_TVL) {
            uint256 shares = IFxBaseIndicatorV1(EARN_GAUGE).balanceOf(VAULT) + IFxBaseIndicatorV1(SOURCE).balanceOf(VAULT);
            if (shares == 0) return 0;
            (uint256 yieldOut, uint256 stableOut) = IFxBaseIndicatorV1(SOURCE).previewRedeem(shares);
            return yieldOut + stableOut * USDC_TO_WAD;
        }
        if (KIND == Kind.CYVBUSDC_TVL) {
            uint256 shares = IERC4626IndicatorV1(SOURCE).balanceOf(VAULT);
            return shares == 0 ? 0 : IERC4626IndicatorV1(SOURCE).convertToAssets(shares) * USDC_TO_WAD;
        }
        uint256 id = positionId;
        if (id == 0) return 0;
        (, uint256 rawDebts) = IFxPoolIndicatorV1(SOURCE).getPosition(id);
        return rawDebts;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    function approve(address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }
}

/// @notice IPOR price-feed shaped constant: 1 wei (18 decimals) - the smallest price the oracle middleware accepts, so
///         the indicator positions show on the dashboard without moving NAV.
contract CyvbEthOneWeiPriceFeed_v1 {
    function decimals() external pure returns (uint8) {
        return 18;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, 1, block.timestamp, block.timestamp, 0);
    }
}
