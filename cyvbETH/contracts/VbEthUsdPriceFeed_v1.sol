// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Chainlink-compatible source used for Katana ETH/USD.
interface IAggregatorV3CyvbEthV1 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title VbEthUsdPriceFeed_v1
/// @notice 18-decimal IPOR-compatible USD price feed for vbETH using Katana's official Chainlink ETH/USD proxy.
/// @dev vbETH is the Katana WETH/vault-bridge ETH representation, so one vbETH is priced as one ETH.
contract VbEthUsdPriceFeed_v1 {
    uint8 public constant decimals = 18;
    address public immutable SOURCE;
    uint8 public immutable SOURCE_DECIMALS;

    error InvalidSource();
    error InvalidPrice();
    error InvalidRound();

    constructor(address source_) {
        if (source_ == address(0) || source_.code.length == 0) revert InvalidSource();
        uint8 sourceDecimals = IAggregatorV3CyvbEthV1(source_).decimals();
        if (sourceDecimals > 36) revert InvalidSource();
        SOURCE = source_;
        SOURCE_DECIMALS = sourceDecimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        int256 answer;
        (roundId, answer, startedAt, time, answeredInRound) =
            IAggregatorV3CyvbEthV1(SOURCE).latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (time == 0 || answeredInRound < roundId) revert InvalidRound();

        uint256 unsigned = uint256(answer);
        uint8 sourceDecimals = SOURCE_DECIMALS;
        uint256 scaled;
        if (sourceDecimals == 18) {
            scaled = unsigned;
        } else if (sourceDecimals < 18) {
            scaled = unsigned * (10 ** (18 - sourceDecimals));
        } else {
            scaled = unsigned / (10 ** (sourceDecimals - 18));
        }
        if (scaled == 0 || scaled > uint256(type(int256).max)) revert InvalidPrice();
        price = int256(scaled);
    }
}
