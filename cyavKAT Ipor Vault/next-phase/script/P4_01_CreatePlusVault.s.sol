// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";

struct FusionInstanceP41 {
    uint256 index;
    uint256 version;
    string assetName;
    string assetSymbol;
    uint8 assetDecimals;
    address underlyingToken;
    string underlyingTokenSymbol;
    uint8 underlyingTokenDecimals;
    address initialOwner;
    address plasmaVault;
    address plasmaVaultBase;
    address accessManager;
    address feeManager;
    address rewardsManager;
    address withdrawManager;
    address contextManager;
    address priceManager;
}

interface IFusionFactoryP41 {
    function clone(
        string memory assetName,
        string memory assetSymbol,
        address underlyingToken,
        uint256 redemptionDelayInSeconds,
        address owner,
        uint256 daoFeePackageIndex
    ) external returns (FusionInstanceP41 memory);

    function getDaoFeePackages() external view returns (DaoFeePackageP41[] memory);
}

struct DaoFeePackageP41 {
    uint256 managementFee;
    uint256 performanceFee;
    address feeRecipient;
}

interface IVaultP41 {
    function asset() external view returns (address);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// Phase 4 step 1: creates the cyavKAT+ vault ("CurveYield Looped cyavKAT", asset cyavKAT) with IPOR's FusionFactory
/// 0xc29b…D37B — the factory that created cyavKAT — so the IPOR app indexes and displays it the same way.
///   - DAO fee package 2 = (0.5% management, 0% performance) to the IPOR DAO (PHASE4 §1 "0.5% annual fee to IPOR")
///   - no votes plugin (the factory cannot add one); points / rewards use snapshots (PHASE4 P4-3, §2)
///   - owner = the deployer; configuration (fees, fuses, markets, whitelist) follows in P4_02+
/// Env: PLUS_REDEMPTION_DELAY (seconds, default 3600). Writes deployments/katana-phase4.json (PHASE4_DEPLOYMENTS).
contract P4_01_CreatePlusVault is Phase2Base {
    address internal constant FUSION_FACTORY = 0xc29b8D591d6a3f109Ca7ba384F2e00162866D37B;
    uint256 internal constant DAO_FEE_PACKAGE = 2;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        IFusionFactoryP41 factory = IFusionFactoryP41(FUSION_FACTORY);
        DaoFeePackageP41[] memory packages = factory.getDaoFeePackages();
        require(packages.length > DAO_FEE_PACKAGE, "fee package missing");
        DaoFeePackageP41 memory pkg = packages[DAO_FEE_PACKAGE];
        require(pkg.managementFee == 50 && pkg.performanceFee == 0, "fee package 2 is not 0.5% / 0%");
        uint256 delay = vm.envOr("PLUS_REDEMPTION_DELAY", uint256(3600));

        _start();
        FusionInstanceP41 memory f =
            factory.clone("CurveYield Looped cyavKAT", "cyavKAT+", VAULT, delay, DEPLOYER, DAO_FEE_PACKAGE);
        _stop();

        IVaultP41 plus = IVaultP41(f.plasmaVault);
        require(plus.asset() == VAULT, "asset is not cyavKAT");
        console2.log("cyavKAT+ vault", f.plasmaVault, plus.symbol());
        console2.log("decimals", plus.decimals());

        string memory o = "p4";
        vm.serializeAddress(o, "plusVault", f.plasmaVault);
        vm.serializeAddress(o, "plusAccessManager", f.accessManager);
        vm.serializeAddress(o, "plusFeeManager", f.feeManager);
        vm.serializeAddress(o, "plusRewardsManager", f.rewardsManager);
        vm.serializeAddress(o, "plusWithdrawManager", f.withdrawManager);
        vm.serializeAddress(o, "plusContextManager", f.contextManager);
        string memory json = vm.serializeAddress(o, "plusPriceManager", f.priceManager);
        vm.writeJson(json, vm.envOr("PHASE4_DEPLOYMENTS", string("deployments/katana-phase4.json")));
    }
}
