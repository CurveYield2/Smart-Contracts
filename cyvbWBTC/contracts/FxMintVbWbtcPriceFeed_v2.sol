// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Minimal IPOR-compatible custom price-feed interface.
interface IFxMintPriceOracleCyvbWBTCV2 {
    function getPrice() external view returns (uint256 anchorPrice, uint256 minPrice, uint256 maxPrice);
}

/// @title FxMintVbWbtcPriceFeed_v2
/// @notice IPOR IPriceFeed-style adapter for the live f(x) vbWBTC pool oracle.
/// @dev Mirrors IPOR custom price feeds: 18-decimal price and zero-valued round metadata.
///      The f(x) anchor price is used because it is the protocol's own debt-ratio reference price.
contract FxMintVbWbtcPriceFeed_v2 {
    address public immutable FX_PRICE_ORACLE;

    error ZeroAddress();
    error InvalidPrice();

    constructor(address fxPriceOracle_) {
        if (fxPriceOracle_ == address(0)) revert ZeroAddress();
        FX_PRICE_ORACLE = fxPriceOracle_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        (uint256 anchorPrice,,) = IFxMintPriceOracleCyvbWBTCV2(FX_PRICE_ORACLE).getPrice();
        if (anchorPrice == 0 || anchorPrice > uint256(type(int256).max)) revert InvalidPrice();

        return (0, int256(anchorPrice), 0, 0, 0);
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}
