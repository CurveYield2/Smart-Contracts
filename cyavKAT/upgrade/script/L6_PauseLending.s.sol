// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {FuseAction} from "../src/interfaces/CurveYieldPhase2Interfaces.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

struct InstantWithdrawalFusesParamsStruct6 {
    address fuse;
    bytes32[] params;
}

interface IVaultL6 {
    function execute(FuseAction[] calldata calls) external;
    function grantMarketSubstrates(uint256 marketId, bytes32[] calldata substrates) external;
    function getMarketSubstrates(uint256 marketId) external view returns (bytes32[] memory);
    function configureInstantWithdrawalFuses(InstantWithdrawalFusesParamsStruct6[] calldata fuses) external;
    function getInstantWithdrawalFuses() external view returns (address[] memory);
    function totalAssets() external view returns (uint256);
    function totalAssetsInMarket(uint256 marketId) external view returns (uint256);
}

/// Pauses avKAT lending on the live vault and restores market 14 to the loop only, because the IPOR front end drops the
/// whole Morpho (market 14) card when the lending market is a second market 14 substrate.
///   1. withdraw everything the vault lent (market 14 supply fuse, lending market from the substrate list)
///   2. market 14 substrates -> [loop 0x80e6]
///   3. instant withdrawals -> [legacy vKAT fuse] only (the supply fuse stays installed but idle)
/// The supply fuse remains in the vault's fuse list for a later re-install; nothing else changes.
///
/// From C:\Users\user\Desktop\Claude:
///   forge script "$P2/script/L6_PauseLending.s.sol" --root $P2 --rpc-url katana --skip test --skip "*/test/**"
contract L6_PauseLending is Phase2Base {
    using MorphoBalancesLib for IMorpho;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        IVaultL6 vault = IVaultL6(VAULT);
        IMorpho morpho = IMorpho(MORPHO);
        address supply = vm.parseJsonAddress(vm.readFile(_lendingPath()), ".lendSupplyFuse");
        bytes32[] memory subs = vault.getMarketSubstrates(MARKET_LOOP);
        require(subs.length == 2 && subs[0] == LOOP_MARKET, "unexpected market 14 substrates");
        bytes32 lendMarket = subs[1];
        MarketParams memory p = morpho.idToMarketParams(Id.wrap(lendMarket));
        uint256 lent = morpho.expectedSupplyAssets(p, VAULT);
        (uint256 mSupply,, uint256 mBorrow,) = morpho.expectedMarketBalances(p);
        require(mSupply - mBorrow >= lent, "not enough market liquidity to exit in full");
        uint256 totalBefore = vault.totalAssets();
        uint256 m14Before = vault.totalAssetsInMarket(MARKET_LOOP);
        console2.log("lending market:");
        console2.logBytes32(lendMarket);
        console2.log("before: totalAssets / m14 / lent", totalBefore, m14Before, lent);

        _start();
        FuseAction[] memory a = new FuseAction[](1);
        a[0] = FuseAction(supply, abi.encodeWithSignature("exit((bytes32,uint256))", lendMarket, type(uint256).max));
        vault.execute(a);
        bytes32[] memory loopOnly = new bytes32[](1);
        loopOnly[0] = LOOP_MARKET;
        vault.grantMarketSubstrates(MARKET_LOOP, loopOnly);
        InstantWithdrawalFusesParamsStruct6[] memory iw = new InstantWithdrawalFusesParamsStruct6[](1);
        iw[0] = InstantWithdrawalFusesParamsStruct6(LEGACY_VKAT_FUSE, new bytes32[](1));
        vault.configureInstantWithdrawalFuses(iw);
        _stop();

        uint256 totalAfter = vault.totalAssets();
        console2.log("after:  totalAssets / m14 / lent", totalAfter, vault.totalAssetsInMarket(MARKET_LOOP),
            morpho.expectedSupplyAssets(p, VAULT));
        require(morpho.expectedSupplyAssets(p, VAULT) == 0, "still lent");
        require(totalAfter * 10_000 >= totalBefore * 9_995 && totalAfter * 10_000 <= totalBefore * 10_005, "share-price step");
        require(vault.getMarketSubstrates(MARKET_LOOP).length == 1, "market 14 substrates");
        require(vault.getInstantWithdrawalFuses().length == 1, "instant withdrawal fuses");
    }
}
