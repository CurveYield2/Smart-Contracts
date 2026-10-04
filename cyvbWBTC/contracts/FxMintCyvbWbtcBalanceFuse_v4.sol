// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface ICyvbWbtcPositionRegistryBalanceV4 {
    function positionId() external view returns (uint256);
}

interface IFxLongPoolBalanceCyvbWBTCV4 {
    function getPosition(uint256 tokenId) external view returns (uint256 rawColls, uint256 rawDebts);
    function priceOracle() external view returns (address);
}

interface IFxOracleBalanceCyvbWBTCV4 {
    function getPrice() external view returns (uint256 anchorPrice, uint256 minPrice, uint256 maxPrice);
}

interface IPlasmaVaultSubstratesBalanceV4 {
    function getMarketSubstrates(uint256 marketId_) external view returns (bytes32[] memory);
}

/// @title FxMintCyvbWbtcBalanceFuse_v4
/// @notice f(x)-only net position balance for cyvbWBTC.
/// @dev Deliberately follows IPOR's leveraged-market balance-fuse pattern:
///      - only the external protocol position belongs to this market;
///      - nested ERC4626 balances are tracked by IPOR's canonical Erc4626BalanceFuse;
///      - residual ERC20 balances are tracked by IPOR's canonical ERC20BalanceFuse;
///      - a negative collateral-minus-debt value reverts instead of silently hiding insolvency.
contract FxMintCyvbWbtcBalanceFuse_v4 {
    uint256 public constant MARKET_ID = 7001;
    uint256 private constant WAD = 1e18;

    address public immutable VERSION;
    address public immutable CONFIG;
    address public immutable FX_POOL;

    error InvalidAddress();
    error InvalidPrice();
    error NegativeBalance(uint256 collateralValue, uint256 debtValue);

    constructor(address config_, address fxPool_) {
        if (config_ == address(0) || fxPool_ == address(0)) revert InvalidAddress();
        if (config_.code.length == 0 || fxPool_.code.length == 0) revert InvalidAddress();

        VERSION = address(this);
        CONFIG = config_;
        FX_POOL = fxPool_;
    }

    /// @return Net f(x) position value in USD WAD.
    function balanceOf() external view returns (uint256) {
        if (!_isPoolGranted()) return 0;

        uint256 positionId = ICyvbWbtcPositionRegistryBalanceV4(CONFIG).positionId();
        if (positionId == 0) return 0;

        (uint256 rawColls, uint256 rawDebts) =
            IFxLongPoolBalanceCyvbWBTCV4(FX_POOL).getPosition(positionId);

        if (rawColls == 0 && rawDebts == 0) return 0;

        (uint256 anchorPrice,,) =
            IFxOracleBalanceCyvbWBTCV4(IFxLongPoolBalanceCyvbWBTCV4(FX_POOL).priceOracle()).getPrice();
        if (anchorPrice == 0) revert InvalidPrice();

        uint256 collateralValue = (rawColls * anchorPrice) / WAD;
        if (rawDebts > collateralValue) {
            revert NegativeBalance(collateralValue, rawDebts);
        }

        return collateralValue - rawDebts;
    }

    function _isPoolGranted() private view returns (bool) {
        bytes32 expected = bytes32(uint256(uint160(FX_POOL)));
        bytes32[] memory substrates =
            IPlasmaVaultSubstratesBalanceV4(address(this)).getMarketSubstrates(MARKET_ID);

        uint256 length = substrates.length;
        for (uint256 i; i < length; ++i) {
            if (substrates[i] == expected) return true;
        }
        return false;
    }
}
