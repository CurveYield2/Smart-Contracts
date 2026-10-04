// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {FuseAction} from "../src/interfaces/CurveYieldPhase2Interfaces.sol";
import {CurveYieldPlusLoopController} from "../src/plus/CurveYieldPlusLoopController.sol";
import {CurveYieldPlusDepositRouter} from "../src/plus/CurveYieldPlusDepositRouter.sol";
import {CurveYieldCallerRewardFuse} from "../src/withdraw/CurveYieldCallerRewardFuse.sol";

struct InstantWithdrawalFusesParamsP43 {
    address fuse;
    bytes32[] params;
}

struct RecipientFeeP43 {
    address recipient;
    uint256 feeValue;
}

interface IPlusVaultP43 {
    function addFuses(address[] calldata fuses) external;
    function addBalanceFuse(uint256 marketId, address fuse) external;
    function grantMarketSubstrates(uint256 marketId, bytes32[] calldata substrates) external;
    function updateDependencyBalanceGraphs(uint256[] calldata marketIds, uint256[][] calldata dependencies) external;
    function updateCallbackHandler(address handler, address sender, bytes4 sig) external;
    function configureInstantWithdrawalFuses(InstantWithdrawalFusesParamsP43[] calldata fuses) external;
    function execute(FuseAction[] calldata calls) external;
    function removeFuses(address[] calldata fuses) external;
    function getPriceOracleMiddleware() external view returns (address);
    function isFuseSupported(address fuse) external view returns (bool);
    function enableTransferShares() external;
}

interface IAmP43 {
    function grantRole(uint64 roleId, address account, uint32 executionDelay) external;
}

interface IOracleP43 {
    function setAssetsPriceSources(address[] calldata assets, address[] calldata sources) external;
    function getSourceOfAssetPrice(address asset) external view returns (address);
}

interface IWmV2P43 {
    function setDependencies(address controller, address burnFuse, address requestFeeFuse, address previousManager) external;
    function updatePlasmaVaultAddress(address vault) external;
    function updateWithdrawFee(uint256 fee) external;
    function updateRequestFee(uint256 fee) external;
    function updateWithdrawWindow(uint256 window) external;
    function setFeeSplit(address[3] calldata recipients, uint16[3] calldata bps, bool splitRequestFee) external;
}

interface IWmWindowP43 {
    function getWithdrawWindow() external view returns (uint256);
}

interface IFeeManagerP43 {
    function updatePerformanceFee(RecipientFeeP43[] calldata recipientFees) external;
}

/// Phase 4 step 3/3: wires the cyavKAT+ vault (P4_01) to its stack (P4_02). Run by the deployer (vault OWNER).
///   roles     deployer: ATOMIST 100, FUSE_MANAGER 300, 900, 901, 902, 1000, 1200 (admin work, moved to the gate later)
///             executor: ALPHA 200, 1000 · deposit router: WHITELIST 800 (the vault stays PRIVATE: only the router
///             deposits, so the 35% fee is taken from the depositor, never minted) + 1100 · booster: 1100
///   prices    avKAT (the main vault's source), cyavKAT and wcyavKAT (ERC4626PriceFeed)
///   markets   14 MORPHO: IPOR MorphoBalanceFuse, substrate = the wcyavKAT lending market; 19 MORPHO_FLASH_LOAN:
///             ZeroBalanceFuse, substrate = avKAT (cyavKAT, the vault asset, is counted as idle; no market 7 needed);
///             ERC4626_0001 [cyavKAT] / ERC4626_0002 [wcyavKAT]: ZeroBalanceFuse (the asset / Morpho collateral);
///             54 (substrate-only): transfer token cyavKAT, profit recipients, the controller as instant planner
///   fuses     IPOR flash / collateral / borrow / 2x ERC-4626 supply, generic transfer + planned instant, burn,
///             request-fee, maintenance; Morpho flash callback handler
///   withdraw  WM v2 swapped in (maintenance fuse); window = the main vault's; instant + request fee 15%; split
///             20% admin / 25% special rewards / 30% booster, 25% burned (holders); instant fuse = the loop fuse
///   fees      performance 15% to admin (IPOR FeeManager); deposit fee stays 0 at the vault (router charges it)
///   dests     controller + router: admin = fee Safe, special rewards = SPECIAL_REWARDS (default fee Safe until #22)
contract P4_03_ConfigurePlus is Phase2Base {
    address internal constant FEE_SAFE = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;
    uint256 internal constant MARKET_FLASH = 19;
    uint256 internal constant MARKET_4626_CY = 100_001;
    uint256 internal constant MARKET_4626_WRAP = 100_002;

    string internal p4;
    IPlusVaultP43 internal plus;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        p4 = vm.readFile(vm.envOr("PHASE4_DEPLOYMENTS", string("deployments/katana-phase4.json")));
        plus = IPlusVaultP43(_a(".plusVault"));
        _start();
        _roles();
        _prices();
        _markets();
        _withdrawManager();
        _feesAndDestinations();
        _stop();
        require(plus.isFuseSupported(_a(".plusCollateralFuse")) && plus.isFuseSupported(_a(".plusFlashFuse")), "fuses");
        console2.log("cyavKAT+ configured", address(plus));
    }

    function _roles() internal {
        IAmP43 am = IAmP43(_a(".plusAccessManager"));
        am.grantRole(100, DEPLOYER, 0); // OWNER administers ATOMIST
        am.grantRole(200, DEPLOYER, 0); // ALPHA for the WM swap (plus.execute); dropped at the handover (P3_05)
        uint64[6] memory mine = [uint64(300), 900, 901, 902, 1000, 1200];
        for (uint256 i; i < mine.length; ++i) am.grantRole(mine[i], DEPLOYER, 0);
        am.grantRole(200, _a(".plusExecutor"), 0);
        am.grantRole(1000, _a(".plusExecutor"), 0);
        am.grantRole(200, _a(".plusWithdrawManagerV2"), 0); // WM v2 runs the burn fuse via execute
        am.grantRole(800, _a(".plusDepositRouter"), 0);
        am.grantRole(1100, _a(".plusDepositRouter"), 0);
        am.grantRole(1100, _a(".plusYieldBooster"), 0);
    }

    function _prices() internal {
        IOracleP43 oracle = IOracleP43(plus.getPriceOracleMiddleware());
        address avkatSource = IOracleP43(IPlusVaultP43(VAULT).getPriceOracleMiddleware()).getSourceOfAssetPrice(AVKAT);
        string memory lend = vm.readFile(_lendingPath());
        address[] memory assets = new address[](3);
        address[] memory sources = new address[](3);
        (assets[0], sources[0]) = (AVKAT, avkatSource);
        (assets[1], sources[1]) = (VAULT, _a(".plusCyavkatPriceFeed"));
        (assets[2], sources[2]) = (vm.parseJsonAddress(lend, ".wcyavkat"), _a(".plusWcyavkatPriceFeed"));
        oracle.setAssetsPriceSources(assets, sources);
    }

    function _markets() internal {
        string[10] memory keys = [".plusFlashFuse", ".plusCollateralFuse", ".plusBorrowFuse", ".plusCySupplyFuse",
            ".plusWrapSupplyFuse", ".plusTransferFuse", ".plusPlannedInstantFuse", ".plusBurnRequestFeeFuse",
            ".plusRequestFeeFuse", ".plusMaintenanceFuse"];
        address[] memory add = new address[](keys.length);
        for (uint256 i; i < keys.length; ++i) add[i] = _a(keys[i]);
        plus.addFuses(add);
        plus.addBalanceFuse(MARKET_LOOP, _a(".plusMorphoBalanceFuse"));
        plus.addBalanceFuse(MARKET_FLASH, _a(".plusZeroFlashBalanceFuse"));
        plus.addBalanceFuse(MARKET_4626_CY, _a(".plusZeroCyBalanceFuse"));
        plus.addBalanceFuse(MARKET_4626_WRAP, _a(".plusZeroWrapBalanceFuse"));
        bytes32[] memory cy = new bytes32[](1);
        cy[0] = bytes32(uint256(uint160(VAULT)));
        plus.grantMarketSubstrates(MARKET_4626_CY, cy);
        bytes32[] memory wr = new bytes32[](1);
        wr[0] = bytes32(uint256(uint160(vm.parseJsonAddress(vm.readFile(_lendingPath()), ".wcyavkat"))));
        plus.grantMarketSubstrates(MARKET_4626_WRAP, wr);
        _grantTyped();
        bytes32[] memory m14 = new bytes32[](1);
        m14[0] = LEND_MARKET;
        plus.grantMarketSubstrates(MARKET_LOOP, m14);
        bytes32[] memory m19 = new bytes32[](1);
        m19[0] = bytes32(uint256(uint160(AVKAT)));
        plus.grantMarketSubstrates(MARKET_FLASH, m19);
        plus.updateCallbackHandler(_a(".plusCallbackHandler"), MORPHO, bytes4(keccak256("onMorphoFlashLoan(uint256,bytes)")));
        InstantWithdrawalFusesParamsP43[] memory iw = new InstantWithdrawalFusesParamsP43[](1);
        bytes32[] memory planned = new bytes32[](2); // [amount (filled by IPOR), planner]
        planned[1] = bytes32(uint256(uint160(_a(".plusController"))));
        iw[0] = InstantWithdrawalFusesParamsP43(_a(".plusPlannedInstantFuse"), planned);
        plus.configureInstantWithdrawalFuses(iw);
        plus.enableTransferShares(); // payouts (contributors fuse, special rewards) and forwarders move cyavKAT+ shares
    }

    function _withdrawManager() internal {
        address wm = _a(".plusWithdrawManagerV2");
        address factoryWm = _a(".plusWithdrawManager");
        CurveYieldCallerRewardFuse requestFee = CurveYieldCallerRewardFuse(_a(".plusRequestFeeFuse"));
        requestFee.setWithdrawManager(wm);
        requestFee.setController(_a(".plusExecutor"));
        FuseAction[] memory sw = new FuseAction[](1);
        sw[0] = FuseAction(_a(".plusMaintenanceFuse"), abi.encodeWithSignature("enter((address))", wm));
        plus.execute(sw); // vault withdraw manager -> WM v2
        IWmV2P43 w = IWmV2P43(wm);
        w.updatePlasmaVaultAddress(address(plus)); // as P2_01 does for cyavKAT: WM v2 must know its vault first
        w.setDependencies(_a(".plusExecutor"), _a(".plusBurnRequestFeeFuse"), address(requestFee), factoryWm);
        w.updateWithdrawWindow(IWmWindowP43(WM_OLD).getWithdrawWindow());
        w.updateWithdrawFee(0.15e18);
        w.updateRequestFee(0.15e18);
        w.setFeeSplit(
            [FEE_SAFE, vm.envOr("SPECIAL_REWARDS", FEE_SAFE), _a(".plusYieldBooster")], [uint16(2_000), 2_500, 3_000], true
        );
    }

    function _feesAndDestinations() internal {
        RecipientFeeP43[] memory perf = new RecipientFeeP43[](1);
        perf[0] = RecipientFeeP43(FEE_SAFE, 1_500);
        IFeeManagerP43(_a(".plusFeeManager")).updatePerformanceFee(perf);
        address special = vm.envOr("SPECIAL_REWARDS", FEE_SAFE);
        CurveYieldPlusLoopController c = CurveYieldPlusLoopController(_a(".plusController"));
        c.setAdminReceiver(FEE_SAFE);
        // main vault (cyavKAT) withdraw manager: bounds cyavKAT+ unwinds by its idle, reserve and instant fee
        c.setMainWithdrawManager(vm.parseJsonAddress(vm.readFile(_deploymentsPath()), ".withdrawManagerV2"));
        c.setMainFeeManager(0x11a81a7B7436CB1E8f73866AF74961cE499f5Ec6); // nets cyavKAT's pending performance fee
        c.setDestinations(special, _a(".plusYieldBooster"));
        CurveYieldPlusDepositRouter r = CurveYieldPlusDepositRouter(_a(".plusDepositRouter"));
        r.setAdminReceiver(FEE_SAFE);
        r.setDestinations(_a(".plusRewardsManager"), special, _a(".plusYieldBooster"));
        r.setWithdrawManager(_a(".plusWithdrawManagerV2")); // settle the owed fee split before each deposit
    }

    /// @dev Market 54 (substrate-only) typed entries: cyavKAT as transfer token (8), profit recipients (3), the
    /// controller as instant-withdraw planner (6). Recipients change with P4_04 (special rewards): it re-grants.
    function _grantTyped() internal {
        address special = vm.envOr("SPECIAL_REWARDS", FEE_SAFE);
        bytes32[] memory t = new bytes32[](5);
        t[0] = bytes32((uint256(8) << 160) | uint256(uint160(VAULT)));
        t[1] = bytes32((uint256(3) << 160) | uint256(uint160(FEE_SAFE)));
        t[2] = bytes32((uint256(3) << 160) | uint256(uint160(special)));
        t[3] = bytes32((uint256(3) << 160) | uint256(uint160(_a(".plusYieldBooster"))));
        t[4] = bytes32((uint256(6) << 160) | uint256(uint160(_a(".plusController"))));
        plus.grantMarketSubstrates(MARKET_SUBSTRATES, t);
    }

    function _a(string memory key_) internal view returns (address) {
        return vm.parseJsonAddress(p4, key_);
    }
}
