// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {FuseAction} from "../src/interfaces/CurveYieldPhase2Interfaces.sol";
import {IporVaultHaircutOracle12, IERC4626Rate} from "../src/oracles/IporVaultHaircutOracle12.sol";
import {CurveYieldWrappedCyavKat} from "../src/wrapper/CurveYieldWrappedCyavKat.sol";
import {CurveYieldWrapperFeeSplitter} from "../src/wrapper/CurveYieldWrapperFeeSplitter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho, MarketParams, Id, Position} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-org/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

struct InstantWithdrawalFusesParamsStruct5 {
    address fuse;
    bytes32[] params;
}

interface IVaultL5 {
    function execute(FuseAction[] calldata calls) external;
    function addFuses(address[] calldata fuses) external;
    function removeFuses(address[] calldata fuses) external;
    function removeBalanceFuse(uint256 marketId, address fuse) external;
    function grantMarketSubstrates(uint256 marketId, bytes32[] calldata substrates) external;
    function getMarketSubstrates(uint256 marketId) external view returns (bytes32[] memory);
    function updateMarketsBalances(uint256[] calldata marketIds) external returns (uint256);
    function configureInstantWithdrawalFuses(InstantWithdrawalFusesParamsStruct5[] calldata fuses) external;
    function getInstantWithdrawalFuses() external view returns (address[] memory);
    function totalAssets() external view returns (uint256);
    function totalAssetsInMarket(uint256 marketId) external view returns (uint256);
    function isFuseSupported(address fuse) external view returns (bool);
}

interface IErc20L5 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// Replaces the avKAT lending market 0x5c60 (cyavKAT collateral, 5% haircut oracle) with a market whose collateral is
/// the wcyavKAT wrapper (docs/WRAPPER_SPEC.md) priced with a 12% haircut. Runs after L4 (lending already in IPOR's
/// MORPHO market 14 through the IPOR MorphoSupplyFuse(14) in the lending JSON).
///   1. deploy the fee splitter (40% admin Safe / 30% contributors / 30% burn via the withdraw manager), the wcyavKAT
///      wrapper (2%/yr + 8% over watermark; owner-settable up to 5% / 15%), IporVaultHaircutOracle12 (wrapper version); create the Morpho market
///      (loan avKAT, collateral wcyavKAT, same IRM, LLTV 86%)
///      CONTRIBUTORS_RECEIVER (env) defaults to the fee Safe until the ContributorsRewardFuse exists (owner-settable).
///   2. any deployer seed borrow/collateral left in 0x5c60 is repaid/returned (frees the liquidity the vault needs)
///   3. vault: withdraw everything from 0x5c60 with the market 14 supply fuse
///   4. market 14 substrates [loop 0x80e6, 0x5c60] -> [loop 0x80e6, new market]; instant withdrawal params point at the
///      new market; the same supply fuse lends the withdrawn amount into the new market
///   5. the deployer's leftover ~1 avKAT supply in 0x5c60 is withdrawn back to the deployer
/// Writes deployments/katana-lending-v1.json (lendSupplyFuse unchanged, lendMarketId 14, lendMorphoMarket, lendOracle).
///
/// From C:\Users\user\Desktop\Claude:
///   forge script "$P2/script/L5_LendMarket12.s.sol" --root $P2 --rpc-url katana --skip test   (add --broadcast ...)
contract L5_LendMarket12 is Phase2Base {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    address internal constant IRM = 0x4F708C0ae7deD3d74736594C2109C2E3c065B428;
    uint256 internal constant LLTV = 0.86e18;
    address internal constant FEE_SAFE = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        IVaultL5 vault = IVaultL5(VAULT);
        IMorpho morpho = IMorpho(MORPHO);
        string memory json = vm.readFile(_lendingPath());
        address supply = vm.parseJsonAddress(json, ".lendSupplyFuse");
        require(vm.parseJsonUint(json, ".lendMarketId") == MARKET_LOOP, "run L4 first");
        require(vault.isFuseSupported(supply) && vault.getInstantWithdrawalFuses()[0] == supply, "supply fuse");
        bytes32[] memory subs14 = vault.getMarketSubstrates(MARKET_LOOP);
        require(subs14.length == 2 && subs14[0] == LOOP_MARKET && subs14[1] == OLD_LEND_MARKET, "unexpected market 14 substrates");
        MarketParams memory oldP = morpho.idToMarketParams(Id.wrap(OLD_LEND_MARKET));
        require(oldP.lltv == LLTV && oldP.irm == IRM, "old market params");

        uint256 totalBefore = vault.totalAssets();
        uint256 lentBefore = morpho.expectedSupplyAssets(oldP, VAULT);
        console2.log("before: totalAssets / lent in 0x5c60", totalBefore, lentBefore);

        _start();
        // 1. oracle + market
        address contributors = vm.envOr("CONTRIBUTORS_RECEIVER", FEE_SAFE);
        CurveYieldWrapperFeeSplitter splitter =
            new CurveYieldWrapperFeeSplitter(DEPLOYER, IERC20(VAULT), FEE_SAFE, contributors, WM_OLD);
        CurveYieldWrappedCyavKat wrapper = new CurveYieldWrappedCyavKat(DEPLOYER, IERC20(VAULT), address(splitter));
        IporVaultHaircutOracle12 oracle = new IporVaultHaircutOracle12(IERC4626Rate(address(wrapper)), AVKAT);
        MarketParams memory newP = MarketParams(AVKAT, address(wrapper), address(oracle), IRM, LLTV);
        morpho.createMarket(newP);
        bytes32 newId = Id.unwrap(newP.id());

        // 2. retire the deployer's seed borrow in the old market (frees the liquidity it holds)
        morpho.accrueInterest(oldP);
        Position memory dp = morpho.position(Id.wrap(OLD_LEND_MARKET), DEPLOYER);
        if (dp.borrowShares != 0) {
            IErc20L5(AVKAT).approve(MORPHO, type(uint256).max);
            morpho.repay(oldP, 0, dp.borrowShares, DEPLOYER, "");
            IErc20L5(AVKAT).approve(MORPHO, 0);
        }
        if (dp.collateral != 0) morpho.withdrawCollateral(oldP, dp.collateral, DEPLOYER, DEPLOYER);

        // 3. vault exits the old market in full
        uint256 idleBefore = IErc20L5(AVKAT).balanceOf(VAULT);
        FuseAction[] memory a = new FuseAction[](1);
        a[0] = FuseAction(supply, abi.encodeWithSignature("exit((bytes32,uint256))", OLD_LEND_MARKET, type(uint256).max));
        vault.execute(a);
        uint256 withdrawn = IErc20L5(AVKAT).balanceOf(VAULT) - idleBefore;

        // 4. swap the market 14 substrate to the new market and re-lend with the same fuse
        bytes32[] memory both = new bytes32[](2);
        (both[0], both[1]) = (LOOP_MARKET, newId);
        vault.grantMarketSubstrates(MARKET_LOOP, both);
        InstantWithdrawalFusesParamsStruct5[] memory iw = new InstantWithdrawalFusesParamsStruct5[](2);
        bytes32[] memory lendParams = new bytes32[](2);
        lendParams[1] = newId;
        iw[0] = InstantWithdrawalFusesParamsStruct5(address(supply), lendParams);
        iw[1] = InstantWithdrawalFusesParamsStruct5(LEGACY_VKAT_FUSE, new bytes32[](1));
        vault.configureInstantWithdrawalFuses(iw);
        a[0] = FuseAction(supply, abi.encodeWithSignature("enter((bytes32,uint256))", newId, withdrawn));
        vault.execute(a);

        // 5. the deployer's own leftover supply in the old market
        Position memory dp2 = morpho.position(Id.wrap(OLD_LEND_MARKET), DEPLOYER);
        if (dp2.supplyShares != 0) morpho.withdraw(oldP, 0, dp2.supplyShares, DEPLOYER, DEPLOYER);
        _stop();

        // checks
        uint256 lentNew = morpho.expectedSupplyAssets(newP, VAULT);
        uint256 totalAfter = vault.totalAssets();
        console2.log("new market id / oracle:");
        console2.logBytes32(newId);
        console2.log("oracle", address(oracle));
        console2.log("wcyavKAT", address(wrapper));
        console2.log("fee splitter", address(splitter));
        console2.log("oracle price (1e36 scale, per 1e20 share raw)", oracle.price());
        console2.log("withdrawn / lent in new market", withdrawn, lentNew);
        console2.log("after: totalAssets / m14", totalAfter, vault.totalAssetsInMarket(MARKET_LOOP));
        require(withdrawn * 10_000 >= lentBefore * 9_999, "old market exit incomplete");
        require(lentNew + 2 >= withdrawn, "new market lend");
        require(morpho.expectedSupplyAssets(oldP, VAULT) == 0, "vault still in old market");
        require(totalAfter * 10_000 >= totalBefore * 9_995 && totalAfter * 10_000 <= totalBefore * 10_005, "share-price step");
        bytes32[] memory subsAfter = vault.getMarketSubstrates(MARKET_LOOP);
        require(subsAfter.length == 2 && subsAfter[1] == newId, "market 14 substrates after");

        string memory o = "lend";
        vm.serializeUint(o, "lendMarketId", MARKET_LOOP);
        vm.serializeBytes32(o, "lendMorphoMarket", newId);
        vm.serializeAddress(o, "lendOracle", address(oracle));
        vm.serializeAddress(o, "wcyavkat", address(wrapper));
        vm.serializeAddress(o, "wrapperFeeSplitter", address(splitter));
        vm.serializeAddress(o, "lendBalanceFuse", address(0));
        string memory out = vm.serializeAddress(o, "lendSupplyFuse", supply);
        vm.writeJson(out, _lendingPath());
    }
}
