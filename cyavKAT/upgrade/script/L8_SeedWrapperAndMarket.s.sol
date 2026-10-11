// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";

interface IErc20L8 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IWrapperL8 {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// Seeds the wcyavKAT wrapper and its lending market with permanently locked ("burned") positions, from the deployer:
///   1. wraps SEED_CYAVKAT (default 0.1 cyavKAT) with the wcyavKAT sent to 0x…dEaD: the wrapper can never be empty again,
///      which defuses the first-depositor inflation attack (OZ ERC-4626 without a decimals offset)
///   2. supplies SEED_AVKAT (default 0.1 avKAT) to the wrapper market on behalf of 0x…dEaD: permanent supply shares
///
/// From C:\Users\user\Desktop\Claude:
///   forge script "$P2/script/L8_SeedWrapperAndMarket.s.sol" --root $P2 --rpc-url katana --skip test --skip "*/test/**"
contract L8_SeedWrapperAndMarket is Phase2Base {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        string memory json = vm.readFile(_lendingPath());
        address wrapper = vm.parseJsonAddress(json, ".wcyavkat");
        bytes32 marketId = vm.parseJsonBytes32(json, ".lendMorphoMarket");
        IMorpho morpho = IMorpho(MORPHO);
        MarketParams memory p = morpho.idToMarketParams(Id.wrap(marketId));
        require(p.collateralToken == wrapper && p.loanToken == AVKAT, "market / wrapper mismatch");

        uint256 seedShares = vm.envOr("SEED_CYAVKAT", uint256(0.1e20)); // 0.1 cyavKAT (20 decimals)
        uint256 seedAvkat = vm.envOr("SEED_AVKAT", uint256(0.1e18));

        _start();
        IErc20L8(VAULT).approve(wrapper, seedShares);
        uint256 minted = IWrapperL8(wrapper).deposit(seedShares, DEAD);
        IErc20L8(AVKAT).approve(MORPHO, seedAvkat);
        (, uint256 supplyShares) = morpho.supply(p, seedAvkat, 0, DEAD, "");
        _stop();

        console2.log("wcyavKAT minted to dead / wrapper supply", minted, IWrapperL8(wrapper).totalSupply());
        console2.log("market supply shares to dead", supplyShares);
        require(IErc20L8(wrapper).balanceOf(DEAD) == minted && minted > 0, "wrapper seed");
        require(morpho.position(Id.wrap(marketId), DEAD).supplyShares == supplyShares && supplyShares > 0, "market seed");
    }
}
