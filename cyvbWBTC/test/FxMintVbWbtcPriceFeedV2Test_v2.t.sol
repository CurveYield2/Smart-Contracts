// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "../contracts/FxMintVbWbtcPriceFeed_v2.sol";

contract MockFxPriceOracleCyvbWbtcPriceFeedTestV2 {
    uint256 public anchor;
    uint256 public minPrice;
    uint256 public maxPrice;

    function setPrice(uint256 anchor_, uint256 min_, uint256 max_) external {
        anchor = anchor_;
        minPrice = min_;
        maxPrice = max_;
    }

    function getPrice() external view returns (uint256, uint256, uint256) {
        return (anchor, minPrice, maxPrice);
    }
}

contract FxMintVbWbtcPriceFeedV2Test_v2 is Test {
    MockFxPriceOracleCyvbWbtcPriceFeedTestV2 internal oracle;
    FxMintVbWbtcPriceFeed_v2 internal feed;

    function setUp() public {
        oracle = new MockFxPriceOracleCyvbWbtcPriceFeedTestV2();
        feed = new FxMintVbWbtcPriceFeed_v2(address(oracle));
    }

    function testUsesAnchorPriceWith18Decimals() public {
        oracle.setPrice(84_700e18, 84_000e18, 85_000e18);
        (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound) =
            feed.latestRoundData();

        assertEq(feed.decimals(), 18);
        assertEq(roundId, 0);
        assertEq(uint256(price), 84_700e18);
        assertEq(startedAt, 0);
        assertEq(time, 0);
        assertEq(answeredInRound, 0);
    }

    function testZeroAnchorPriceReverts() public {
        oracle.setPrice(0, 1, 2);
        vm.expectRevert(FxMintVbWbtcPriceFeed_v2.InvalidPrice.selector);
        feed.latestRoundData();
    }

    function testConstructorRejectsMissingOracleCode() public {
        vm.expectRevert(FxMintVbWbtcPriceFeed_v2.ZeroAddress.selector);
        new FxMintVbWbtcPriceFeed_v2(address(0));
    }
}
