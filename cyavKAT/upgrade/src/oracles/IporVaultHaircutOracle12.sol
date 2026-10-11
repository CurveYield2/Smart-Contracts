// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

/// @dev Morpho Blue oracle interface (morpho-org/morpho-blue/src/interfaces/IOracle.sol).
interface IOracle {
    /// @notice Price of 1 asset of collateral token quoted in 1 asset of loan token, scaled by 1e36.
    function price() external view returns (uint256);
}

interface IERC4626Rate {
    function asset() external view returns (address);
    function decimals() external view returns (uint8);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @title IporVaultHaircutOracle12
/// @notice Morpho Blue oracle for the wcyavKAT (collateral) / avKAT (loan) market: wcyavKAT -> cyavKAT (the wrapper's
/// rate, net of its pending fees) -> avKAT (the vault share rate), minus a fixed 12% haircut. Same construction as the
/// live IporVaultHaircutOracle (0xE600…0A2C, 5%) with one more ERC-4626 hop.
///
///   price = vault.convertToAssets(wrapper.convertToAssets(10**wDec)) * 1e36 / 10**wDec * (1 - 12%)
/// For wDec = 20, loan dec = 18 and 1:1 rates: 1e18 * 1e36 / 1e20 * 0.88 = 8.8e33.
/// With LLTV 86% the maximum borrow is 0.86 * 0.88 = 75.68% of the collateral's avKAT value.
contract IporVaultHaircutOracle12 is IOracle {
    uint256 public constant ORACLE_PRICE_SCALE = 1e36;
    uint256 public constant HAIRCUT_BPS = 1_200; // 12%
    uint256 public constant BPS = 10_000;

    IERC4626Rate public immutable WRAPPER; // wcyavKAT
    IERC4626Rate public immutable VAULT; // cyavKAT
    address public immutable LOAN_TOKEN; // avKAT
    uint256 public immutable ONE_WRAPPER; // 10**wrapper.decimals()

    constructor(IERC4626Rate wrapper_, address loanToken_) {
        IERC4626Rate vault = IERC4626Rate(wrapper_.asset());
        require(vault.asset() == loanToken_, "loan token != vault asset");
        uint8 wrapperDecimals = wrapper_.decimals();
        require(wrapperDecimals <= 36, "wrapper decimals too high");
        WRAPPER = wrapper_;
        VAULT = vault;
        LOAN_TOKEN = loanToken_;
        ONE_WRAPPER = 10 ** wrapperDecimals;
    }

    /// @inheritdoc IOracle
    function price() external view returns (uint256) {
        uint256 assetsPerWrapper = VAULT.convertToAssets(WRAPPER.convertToAssets(ONE_WRAPPER));
        // single division at the end, rounding down (conservative for lenders)
        return assetsPerWrapper * ORACLE_PRICE_SCALE * (BPS - HAIRCUT_BPS) / (ONE_WRAPPER * BPS);
    }
}
