// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IFxMintPriceOracleCyvbETHV2 {
    function getPrice() external view returns (uint256 anchorPrice, uint256 minPrice, uint256 maxPrice);
}

/// @title FxMintWeEthPriceFeed_v2
/// @notice IPOR-compatible USD price feed for the live Katana f(x) weETH collateral.
/// @dev cyvbETH accepts vbETH, but Katana f(x) has no vbETH collateral pool. The strategy therefore swaps only the
///      keeper-selected f(x) allocation vbETH -> weETH and uses this live f(x) oracle for that collateral indicator.
///      f(x) oracle prices use 18 decimals.
contract FxMintWeEthPriceFeed_v2 {
    uint8 public constant decimals = 18;

    address public immutable FX_PRICE_ORACLE;

    error InvalidOracle();
    error InvalidPrice();

    constructor(address fxPriceOracle_) {
        if (fxPriceOracle_ == address(0) || fxPriceOracle_.code.length == 0) revert InvalidOracle();
        FX_PRICE_ORACLE = fxPriceOracle_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        (uint256 anchorPrice,,) = IFxMintPriceOracleCyvbETHV2(FX_PRICE_ORACLE).getPrice();
        if (anchorPrice == 0 || anchorPrice > uint256(type(int256).max)) revert InvalidPrice();

        roundId = uint80(block.number);
        price = int256(anchorPrice);
        startedAt = block.timestamp;
        time = block.timestamp;
        answeredInRound = roundId;
    }
}
