// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "../contracts/FxMintVbWbtcPriceFeed_v1.sol";

contract MockFxPriceOracleCyvbWbtcPriceFeedTestV1 {
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

contract FxMintVbWbtcPriceFeedV1Test_v1 is Test {
    MockFxPriceOracleCyvbWbtcPriceFeedTestV1 internal oracle;
    FxMintVbWbtcPriceFeed_v1 internal feed;

    function setUp() public {
        oracle = new MockFxPriceOracleCyvbWbtcPriceFeedTestV1();
        feed = new FxMintVbWbtcPriceFeed_v1(address(oracle));
    }

    function testUsesAnchorPriceWith18Decimals() public {
        oracle.setPrice(84_700e18, 84_000e18, 85_000e18);
        vm.roll(12345);
        vm.warp(999);

        (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound) =
            feed.latestRoundData();

        assertEq(feed.decimals(), 18);
        assertEq(roundId, 12345);
        assertEq(uint256(price), 84_700e18);
        assertEq(startedAt, 999);
        assertEq(time, 999);
        assertEq(answeredInRound, roundId);
    }

    function testZeroAnchorPriceReverts() public {
        oracle.setPrice(0, 1, 2);
        vm.expectRevert(FxMintVbWbtcPriceFeed_v1.InvalidPrice.selector);
        feed.latestRoundData();
    }

    function testConstructorRejectsMissingOracleCode() public {
        vm.expectRevert(FxMintVbWbtcPriceFeed_v1.InvalidOracle.selector);
        new FxMintVbWbtcPriceFeed_v1(address(0x1234));
    }
}
