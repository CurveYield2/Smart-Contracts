// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {FuseAction} from "../src/interfaces/CurveYieldPhase2Interfaces.sol";
import {IMorpho, MarketParams, Id, Position} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

struct InstantWithdrawalFusesParamsStruct5b {
    address fuse;
    bytes32[] params;
}

interface IVaultL5b {
    function execute(FuseAction[] calldata calls) external;
    function getMarketSubstrates(uint256 marketId) external view returns (bytes32[] memory);
    function configureInstantWithdrawalFuses(InstantWithdrawalFusesParamsStruct5b[] calldata fuses) external;
    function totalAssets() external view returns (uint256);
}

interface IErc20L5b {
    function balanceOf(address) external view returns (uint256);
}

/// Finishes L5 after it stopped part-way (the wrapper market is deployed and market 14 already has the new
/// substrate; the vault exited 0x5c60, so its lending avKAT is idle):
///   1. instant withdrawals: supply fuse -> [0, new market], then the legacy vKAT fuse
///   2. lend LEND_AVKAT (env, wei; default = the 159.0432 avKAT the vault had lent) into the new market
///   3. withdraw the deployer's leftover supply in the old market 0x5c60
/// Each step is skipped if already done, so it is safe to re-run.
///
/// From C:\Users\user\Desktop\Claude:
///   forge script "$P2/script/L5b_FinishLendMarket12.s.sol" --root $P2 --rpc-url katana --skip test --skip "*/test/**"
contract L5b_FinishLendMarket12 is Phase2Base {
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant DEFAULT_LEND = 159_043_215_838_390_996_985; // what the vault had lent in 0x5c60

    function run() external {
        require(block.chainid == 747474, "not Katana");
        IVaultL5b vault = IVaultL5b(VAULT);
        IMorpho morpho = IMorpho(MORPHO);
        string memory json = vm.readFile(_lendingPath());
        address supply = vm.parseJsonAddress(json, ".lendSupplyFuse");
        bytes32 newId = vm.parseJsonBytes32(json, ".lendMorphoMarket");
        bytes32[] memory subs = vault.getMarketSubstrates(MARKET_LOOP);
        require(subs.length == 2 && subs[0] == LOOP_MARKET && subs[1] == newId, "market 14 not on the new market");
        MarketParams memory newP = morpho.idToMarketParams(Id.wrap(newId));
        MarketParams memory oldP = morpho.idToMarketParams(Id.wrap(OLD_LEND_MARKET));
        require(newP.loanToken == AVKAT, "new market missing");

        uint256 lentNow = morpho.expectedSupplyAssets(newP, VAULT);
        uint256 amount = vm.envOr("LEND_AVKAT_WEI", DEFAULT_LEND);
        uint256 totalBefore = vault.totalAssets();
        console2.log("idle / lent in new market / to lend", IErc20L5b(AVKAT).balanceOf(VAULT), lentNow, lentNow == 0 ? amount : 0);

        _start();
        InstantWithdrawalFusesParamsStruct5b[] memory iw = new InstantWithdrawalFusesParamsStruct5b[](2);
        bytes32[] memory lendParams = new bytes32[](2);
        lendParams[1] = newId;
        iw[0] = InstantWithdrawalFusesParamsStruct5b(supply, lendParams);
        iw[1] = InstantWithdrawalFusesParamsStruct5b(LEGACY_VKAT_FUSE, new bytes32[](1));
        vault.configureInstantWithdrawalFuses(iw);
        if (lentNow == 0) {
            FuseAction[] memory a = new FuseAction[](1);
            a[0] = FuseAction(supply, abi.encodeWithSignature("enter((bytes32,uint256))", newId, amount));
            vault.execute(a);
        }
        Position memory dp = morpho.position(Id.wrap(OLD_LEND_MARKET), DEPLOYER);
        if (dp.supplyShares != 0 && dp.borrowShares == 0) morpho.withdraw(oldP, 0, dp.supplyShares, DEPLOYER, DEPLOYER);
        _stop();

        uint256 lentAfter = morpho.expectedSupplyAssets(newP, VAULT);
        uint256 totalAfter = vault.totalAssets();
        console2.log("after: lent in new market / totalAssets", lentAfter, totalAfter);
        require(lentAfter + 2 >= (lentNow == 0 ? amount : lentNow), "lend");
        require(totalAfter * 10_000 >= totalBefore * 9_995 && totalAfter * 10_000 <= totalBefore * 10_005, "share-price step");
    }
}
