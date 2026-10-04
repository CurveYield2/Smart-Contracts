// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {MorphoSupplyFuse} from "contracts/fuses/morpho/MorphoSupplyFuse.sol";
import {MorphoOnlyLiquidityBalanceFuse} from "contracts/fuses/morpho/MorphoOnlyLiquidityBalanceFuse.sol";

struct InstantWithdrawalFusesParamsStructL {
    address fuse;
    bytes32[] params;
}

interface IVaultLend {
    function addFuses(address[] calldata fuses) external;
    function addBalanceFuse(uint256 marketId, address fuse) external;
    function grantMarketSubstrates(uint256 marketId, bytes32[] calldata substrates) external;
    function configureInstantWithdrawalFuses(InstantWithdrawalFusesParamsStructL[] calldata fuses) external;
    function getInstantWithdrawalFuses() external view returns (address[] memory);
    function isFuseSupported(address fuse) external view returns (bool);
    function getMarketSubstrates(uint256 marketId) external view returns (bytes32[] memory);
    function updateDependencyBalanceGraphs(uint256[] calldata marketIds, uint256[][] calldata dependencies) external;
}

/// Installs avKAT lending on the LIVE v1 system using only IPOR's audited fuses (no new CurveYield code):
///   - IPOR's "Lend Only" market MORPHO_LIQUIDITY_IN_MARKETS (41): MorphoSupplyFuse(41) + MorphoOnlyLiquidityBalanceFuse(41),
///     substrate = the lending market (loan avKAT, collateral wcyavKAT); dependency 41 -> [7]. Supply-only valuation
///     (loan token only), so the IPOR front end never needs a collateral price.
///   (The live vault reached this state via L1(old) -> L2 -> L4 -> L5/L5b -> L9; this is the one-step fresh version.)
///   - instant withdrawals: lending first, then the current vKAT fuse (user exits can pull from lending)
/// Writes deployments/katana-lending-v1.json; the Phase 2 deploy reuses these fuses.
/// Lending itself is done with L2_LendAvkat (amount-capped so the v1 deploy keeps working).
///
/// From C:\Users\user\Desktop\Claude:
///   forge script script/L1_InstallLendingV1.s.sol --root <phase2 path> --rpc-url katana     (add --broadcast ... to send)
contract L1_InstallLendingV1 is Phase2Base {
    function run() external {
        require(block.chainid == 747474, "not Katana");
        IVaultLend vault = IVaultLend(VAULT);
        _start();
        require(vault.getMarketSubstrates(MARKET_LEND).length == 0, "market 41 already configured");
        MorphoSupplyFuse supply = new MorphoSupplyFuse(MARKET_LEND, MORPHO);
        MorphoOnlyLiquidityBalanceFuse balance = new MorphoOnlyLiquidityBalanceFuse(MARKET_LEND, MORPHO);
        address[] memory add = new address[](1);
        add[0] = address(supply);
        vault.addFuses(add);
        vault.addBalanceFuse(MARKET_LEND, address(balance));
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = LEND_MARKET;
        vault.grantMarketSubstrates(MARKET_LEND, subs);
        uint256[] memory markets = new uint256[](1);
        markets[0] = MARKET_LEND;
        uint256[][] memory deps = new uint256[][](1);
        deps[0] = new uint256[](1);
        deps[0][0] = MARKET_ERC20;
        vault.updateDependencyBalanceGraphs(markets, deps);

        InstantWithdrawalFusesParamsStructL[] memory iw = new InstantWithdrawalFusesParamsStructL[](2);
        bytes32[] memory lendParams = new bytes32[](2);
        lendParams[1] = LEND_MARKET; // MorphoSupplyFuse.instantWithdraw: [amount, morphoMarketId]; catches its own errors
        iw[0] = InstantWithdrawalFusesParamsStructL(address(supply), lendParams);
        iw[1] = InstantWithdrawalFusesParamsStructL(LEGACY_VKAT_FUSE, new bytes32[](1));
        vault.configureInstantWithdrawalFuses(iw);
        _stop();

        require(vault.isFuseSupported(address(supply)), "supply fuse");
        require(vault.getInstantWithdrawalFuses().length == 2, "instant withdrawal fuses");
        string memory o = "lend";
        vm.serializeUint(o, "lendMarketId", MARKET_LEND);
        vm.serializeBytes32(o, "lendMorphoMarket", LEND_MARKET);
        vm.serializeAddress(o, "lendBalanceFuse", address(balance));
        string memory json = vm.serializeAddress(o, "lendSupplyFuse", address(supply));
        vm.writeJson(json, _lendingPath());
        console2.log("lending installed in market 41: supply fuse", address(supply));
    }
}
