// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {ERC4626PriceFeed} from "contracts/price_oracle/price_feed/ERC4626PriceFeed.sol";

interface IVaultOracleL7 {
    function getPriceOracleMiddleware() external view returns (address);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function updateMarketsBalances(uint256[] calldata marketIds) external returns (uint256);
}

interface IPriceOracleL7 {
    function getSourceOfAssetPrice(address asset) external view returns (address);
    function getAssetPrice(address asset) external view returns (uint256 price, uint256 decimals);
    function setAssetsPriceSources(address[] calldata assets, address[] calldata sources) external;
}

/// Accounting hygiene: price feeds for cyavKAT and wcyavKAT in the vault's price oracle middleware, so every token in the
/// vault's Morpho markets (the wrapper market's collateral is wcyavKAT) has a USD price. IPOR's audited ERC4626PriceFeed:
///   cyavKAT  = cyavKAT.convertToAssets(1 share)  x avKAT price
///   wcyavKAT = wcyavKAT.convertToAssets(1 share) x cyavKAT price   (net of the wrapper's pending fees)
/// No accounting change: the vault holds neither token.
///
/// From C:\Users\user\Desktop\Claude:
///   forge script "$P2/script/L7_CyavkatPriceFeed.s.sol" --root $P2 --rpc-url katana --skip test --skip "*/test/**"
contract L7_CyavkatPriceFeed is Phase2Base {
    function run() external {
        require(block.chainid == 747474, "not Katana");
        IVaultOracleL7 vault = IVaultOracleL7(VAULT);
        IPriceOracleL7 oracle = IPriceOracleL7(vault.getPriceOracleMiddleware());
        address wrapper = vm.parseJsonAddress(vm.readFile(_lendingPath()), ".wcyavkat");
        bool needShare = oracle.getSourceOfAssetPrice(VAULT) == address(0); // live since 2026-09-25 (0xf9f3…c3Ea)
        require(oracle.getSourceOfAssetPrice(wrapper) == address(0), "wcyavKAT already has a price source");
        uint256 totalBefore = vault.totalAssets();

        _start();
        ERC4626PriceFeed wFeed = new ERC4626PriceFeed(wrapper);
        address[] memory assets = new address[](needShare ? 2 : 1);
        address[] memory sources = new address[](assets.length);
        (assets[0], sources[0]) = (wrapper, address(wFeed));
        if (needShare) (assets[1], sources[1]) = (VAULT, address(new ERC4626PriceFeed(VAULT)));
        oracle.setAssetsPriceSources(assets, sources);
        uint256[] memory markets = new uint256[](2);
        (markets[0], markets[1]) = (MARKET_LOOP, MARKET_ERC20);
        vault.updateMarketsBalances(markets); // accounting refresh (role 1000)
        _stop();
        (uint256 pWrap,) = oracle.getAssetPrice(wrapper);
        uint256 wrapRate = IVaultOracleL7(wrapper).convertToAssets(1e20); // cyavKAT per wcyavKAT
        console2.log("wcyavKAT feed / USD price / cyavKAT per wcyavKAT", address(wFeed), pWrap, wrapRate);

        (uint256 pShare, uint256 dShare) = oracle.getAssetPrice(VAULT);
        (uint256 pAvkat, uint256 dAvkat) = oracle.getAssetPrice(AVKAT);
        uint256 rate = vault.convertToAssets(1e20); // avKAT (18 dec) per 1 cyavKAT (20 dec)
        uint256 expected = rate * pAvkat / 10 ** dAvkat; // USD WAD
        console2.log("cyavKAT USD price / decimals", pShare, dShare);
        console2.log("avKAT USD price / share rate", pAvkat, rate);
        require(dShare == 18 && pShare * 10_000 >= expected * 9_999 && pShare * 10_000 <= expected * 10_001, "price");
        uint256 wExpected = wrapRate * pShare / 1e20;
        require(pWrap * 10_000 >= wExpected * 9_999 && pWrap * 10_000 <= wExpected * 10_001, "wrapper price");
        uint256 totalAfter = vault.totalAssets(); // refresh books accrued loop/lend interest only
        require(totalAfter * 10_000 >= totalBefore * 9_995 && totalAfter * 10_000 <= totalBefore * 10_005, "accounting step");
        console2.log("totalAssets before / after refresh", totalBefore, totalAfter);
    }
}
