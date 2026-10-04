// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {FuseAction} from "../src/interfaces/CurveYieldPhase2Interfaces.sol";
import {MorphoSupplyFuse} from "contracts/fuses/morpho/MorphoSupplyFuse.sol";
import {MorphoOnlyLiquidityBalanceFuse} from "contracts/fuses/morpho/MorphoOnlyLiquidityBalanceFuse.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

struct InstantWithdrawalFusesParamsStruct9 {
    address fuse;
    bytes32[] params;
}

interface IVaultL9 {
    function execute(FuseAction[] calldata calls) external;
    function addFuses(address[] calldata fuses) external;
    function removeFuses(address[] calldata fuses) external;
    function addBalanceFuse(uint256 marketId, address fuse) external;
    function grantMarketSubstrates(uint256 marketId, bytes32[] calldata substrates) external;
    function getMarketSubstrates(uint256 marketId) external view returns (bytes32[] memory);
    function configureInstantWithdrawalFuses(InstantWithdrawalFusesParamsStruct9[] calldata fuses) external;
    function getInstantWithdrawalFuses() external view returns (address[] memory);
    function totalAssets() external view returns (uint256);
    function totalAssetsInMarket(uint256 marketId) external view returns (uint256);
    function isFuseSupported(address fuse) external view returns (bool);
    function isBalanceFuseSupported(uint256 marketId, address fuse) external view returns (bool);
    function getActiveMarketsInBalanceFuses() external view returns (uint256[] memory);
}

interface IFuseInfoL9 {
    function MARKET_ID() external view returns (uint256);
    function MORPHO() external view returns (address);
}

interface IErc20L9 {
    function balanceOf(address) external view returns (uint256);
}

/// Moves the vault's avKAT lending out of IPOR's MORPHO market (14) into IPOR's registered supply-only market
/// MORPHO_LIQUIDITY_IN_MARKETS (41), valued by IPOR's audited MorphoOnlyLiquidityBalanceFuse (loan-token supply only; it
/// never prices the collateral token, which is what broke the IPOR front end's Morpho card). Market 14 goes back to
/// exactly its original loop-only setup.
///   1. exit the lending market in full (market 14 supply fuse)
///   2. market 14 substrates -> [loop 0x80e6] only
///   3. market 41: MorphoOnlyLiquidityBalanceFuse(41) + MorphoSupplyFuse(41), substrate = the lending market
///   4. lend the same amount back through the market 41 supply fuse
///   5. instant withdrawals -> [market 41 supply fuse (lending market), legacy vKAT fuse]; remove the market 14 supply fuse
/// Prefer IPOR's own fuses installed from the Fusion Terminal (Morpho > Advanced > "Lend Only" / market 41):
///   LEND41_SUPPLY_FUSE, LEND41_BALANCE_FUSE (env) = their addresses; each is verified (MARKET_ID 41, Morpho) and reused.
///   Unset = deploy and install our own copies of the same IPOR contracts.
/// Rewrites deployments/katana-lending-v1.json (lendSupplyFuse, lendBalanceFuse, lendMarketId 41).
///
/// From C:\Users\user\Desktop\Claude:
///   forge script "$P2/script/L9_LendingToMarket41.s.sol" --root $P2 --rpc-url katana --skip test --skip "*/test/**"
contract L9_LendingToMarket41 is Phase2Base {
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant MARKET_MORPHO_LIQUIDITY = 41; // IporFusionMarkets.MORPHO_LIQUIDITY_IN_MARKETS
    address internal supply41; // kept in storage to stay under the stack limit
    address internal balance41;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        IVaultL9 vault = IVaultL9(VAULT);
        IMorpho morpho = IMorpho(MORPHO);
        string memory json = vm.readFile(_lendingPath());
        address oldSupply = vm.parseJsonAddress(json, ".lendSupplyFuse");
        bytes32 lendId = vm.parseJsonBytes32(json, ".lendMorphoMarket");
        require(lendId == LEND_MARKET, "lending market mismatch");
        bytes32[] memory subs = vault.getMarketSubstrates(MARKET_LOOP);
        require(subs.length == 2 && subs[0] == LOOP_MARKET && subs[1] == lendId, "unexpected market 14 substrates");
        supply41 = vm.envOr("LEND41_SUPPLY_FUSE", address(0));
        balance41 = vm.envOr("LEND41_BALANCE_FUSE", address(0));
        _checkFuse(supply41);
        _checkFuse(balance41);
        bytes32[] memory subs41 = vault.getMarketSubstrates(MARKET_MORPHO_LIQUIDITY);
        require(subs41.length == 0 || (subs41.length == 1 && subs41[0] == lendId), "market 41 has other substrates");
        MarketParams memory p = morpho.idToMarketParams(Id.wrap(lendId));
        uint256 lent = morpho.expectedSupplyAssets(p, VAULT);
        (uint256 mSupply,, uint256 mBorrow,) = morpho.expectedMarketBalances(p);
        require(mSupply - mBorrow >= lent, "not enough market liquidity to move in full");
        uint256 totalBefore = vault.totalAssets();
        console2.log("before: totalAssets / m14 / lent", totalBefore, vault.totalAssetsInMarket(MARKET_LOOP), lent);

        _start();
        // 1. exit
        uint256 idleBefore = IErc20L9(AVKAT).balanceOf(VAULT);
        FuseAction[] memory a = new FuseAction[](1);
        a[0] = FuseAction(oldSupply, abi.encodeWithSignature("exit((bytes32,uint256))", lendId, type(uint256).max));
        vault.execute(a);
        uint256 withdrawn = IErc20L9(AVKAT).balanceOf(VAULT) - idleBefore;
        // 2. market 14 back to loop only
        bytes32[] memory loopOnly = new bytes32[](1);
        loopOnly[0] = LOOP_MARKET;
        vault.grantMarketSubstrates(MARKET_LOOP, loopOnly);
        // 3. market 41
        _setupMarket41(vault, lendId, subs41.length == 0);
        address supply = supply41;
        // 4. re-lend
        a[0] = FuseAction(supply, abi.encodeWithSignature("enter((bytes32,uint256))", lendId, withdrawn));
        vault.execute(a);
        // 5. instant withdrawals + retire the market 14 supply fuse
        InstantWithdrawalFusesParamsStruct9[] memory iw = new InstantWithdrawalFusesParamsStruct9[](2);
        bytes32[] memory lendParams = new bytes32[](2);
        lendParams[1] = lendId;
        iw[0] = InstantWithdrawalFusesParamsStruct9(supply, lendParams);
        iw[1] = InstantWithdrawalFusesParamsStruct9(LEGACY_VKAT_FUSE, new bytes32[](1));
        vault.configureInstantWithdrawalFuses(iw);
        address[] memory rm = new address[](1);
        rm[0] = oldSupply;
        vault.removeFuses(rm);
        _stop();

        uint256 totalAfter = vault.totalAssets();
        uint256 m41 = vault.totalAssetsInMarket(MARKET_MORPHO_LIQUIDITY);
        console2.log("withdrawn / lent via market 41", withdrawn, morpho.expectedSupplyAssets(p, VAULT));
        console2.log("after: totalAssets / m14 / m41", totalAfter, vault.totalAssetsInMarket(MARKET_LOOP), m41);
        require(morpho.expectedSupplyAssets(p, VAULT) + 2 >= withdrawn, "re-lend");
        require(m41 > 0, "market 41 not valued");
        require(vault.getMarketSubstrates(MARKET_LOOP).length == 1, "market 14 not loop-only");
        require(totalAfter * 10_000 >= totalBefore * 9_995 && totalAfter * 10_000 <= totalBefore * 10_005, "share-price step");
        require(!vault.isFuseSupported(oldSupply) && vault.getInstantWithdrawalFuses()[0] == supply, "fuses");

        string memory o = "lend";
        vm.serializeUint(o, "lendMarketId", MARKET_MORPHO_LIQUIDITY);
        vm.serializeBytes32(o, "lendMorphoMarket", lendId);
        vm.serializeAddress(o, "lendOracle", vm.parseJsonAddress(json, ".lendOracle"));
        vm.serializeAddress(o, "wcyavkat", vm.parseJsonAddress(json, ".wcyavkat"));
        vm.serializeAddress(o, "wrapperFeeSplitter", vm.parseJsonAddress(json, ".wrapperFeeSplitter"));
        vm.serializeAddress(o, "lendBalanceFuse", balance41);
        string memory out = vm.serializeAddress(o, "lendSupplyFuse", supply);
        vm.writeJson(out, _lendingPath());
    }

    /// @dev Installs whatever market 41 still lacks; never replaces a balance fuse installed from the Terminal
    /// (addBalanceFuse overwrites).
    function _checkFuse(address f) private view {
        if (f == address(0)) return;
        require(IFuseInfoL9(f).MARKET_ID() == MARKET_MORPHO_LIQUIDITY && IFuseInfoL9(f).MORPHO() == MORPHO, "not a market 41 Morpho fuse");
    }

    function _setupMarket41(IVaultL9 vault, bytes32 lendId, bool grantSubstrate) private {
        if (supply41 == address(0)) supply41 = address(new MorphoSupplyFuse(MARKET_MORPHO_LIQUIDITY, MORPHO));
        bool has41;
        uint256[] memory active = vault.getActiveMarketsInBalanceFuses();
        for (uint256 i; i < active.length; ++i) if (active[i] == MARKET_MORPHO_LIQUIDITY) has41 = true;
        if (balance41 == address(0) && !has41) {
            balance41 = address(new MorphoOnlyLiquidityBalanceFuse(MARKET_MORPHO_LIQUIDITY, MORPHO));
        }
        if (!vault.isFuseSupported(supply41)) {
            address[] memory add = new address[](1);
            add[0] = supply41;
            vault.addFuses(add);
        }
        if (balance41 != address(0) && !vault.isBalanceFuseSupported(MARKET_MORPHO_LIQUIDITY, balance41)) {
            require(!has41, "market 41 already has a different balance fuse");
            vault.addBalanceFuse(MARKET_MORPHO_LIQUIDITY, balance41);
        }
        if (grantSubstrate) {
            bytes32[] memory lendOnly = new bytes32[](1);
            lendOnly[0] = lendId;
            vault.grantMarketSubstrates(MARKET_MORPHO_LIQUIDITY, lendOnly);
        }
    }
}
