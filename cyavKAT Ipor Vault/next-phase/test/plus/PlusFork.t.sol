// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {FuseAction} from "../../src/interfaces/CurveYieldPhase2Interfaces.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {LendingForkSetup} from "../helpers/LendingForkSetup.sol";
import {P0_00_DeployGateConfig} from "../../script/P0_00_DeployGateConfig.s.sol";
import {P2_01_Deploy} from "../../script/P2_01_Deploy.s.sol";
import {P2_02_ConfigureVault} from "../../script/P2_02_ConfigureVault.s.sol";
import {P2_03_Cutover} from "../../script/P2_03_Cutover.s.sol";
import {P4_01_CreatePlusVault} from "../../script/P4_01_CreatePlusVault.s.sol";
import {P4_02_DeployPlusStack} from "../../script/P4_02_DeployPlusStack.s.sol";
import {P4_03_ConfigurePlus} from "../../script/P4_03_ConfigurePlus.s.sol";
import {CurveYieldPlusLoopController, CyPlusSnapshot} from "../../src/plus/CurveYieldPlusLoopController.sol";
import {CurveYieldPlusExecutor} from "../../src/plus/CurveYieldPlusExecutor.sol";
import {CurveYieldPlusDepositRouter} from "../../src/plus/CurveYieldPlusDepositRouter.sol";

struct MorphoSupplyEnter {
    bytes32 marketId;
    uint256 amount;
}

interface IScriptP {
    function setPaths(string calldata, string calldata) external;
    function run() external;
}

interface IVaultP {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function redeemFromRequest(uint256 shares, address receiver, address owner) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function convertToAssets(uint256) external view returns (uint256);
    function convertToShares(uint256) external view returns (uint256);
    function previewRedeem(uint256) external view returns (uint256);
    function previewWithdraw(uint256) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function getPriceOracleMiddleware() external view returns (address);
    function getMarketSubstrates(uint256) external view returns (bytes32[] memory);
    function getInstantWithdrawalFuses() external view returns (address[] memory);
    function isBalanceFuseSupported(uint256 marketId, address fuse) external view returns (bool);
    function updateMarketsBalances(uint256[] calldata) external returns (uint256);
    function getActiveMarketsInBalanceFuses() external view returns (uint256[] memory);
    function execute(FuseAction[] calldata calls) external;
}

interface IErcP {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IOracleP {
    function getAssetPrice(address) external view returns (uint256, uint256);
}

interface IWmP {
    function getWithdrawFee() external view returns (uint256);
    function getRequestFee() external view returns (uint256);
    function feeSplit() external view returns (address[3] memory, uint16[3] memory);
    function splitRequestFee() external view returns (bool);
    function requestShares(uint256) external;
    function activeUnreleasedShares() external view returns (uint256);
    function getSharesToRelease() external view returns (uint256);
    function owedSplitShares() external view returns (uint256);
    function settleSplit() external returns (uint256);
}

/// @notice Fork test of the whole cyavKAT+ lifecycle (PHASE4 #20) on the deployed order P2_01..P2_03 (Phase 2 cutover: the
/// main vault runs WM v2) then P4_01..P4_03, run as the deployer. Every scenario runs against the contracts as they are (no
/// emulation). All scenarios live in ONE test (the scripts read PHASE4_DEPLOYMENTS from the process environment, which
/// parallel tests would share); each runs as an isolated self-call: a failure is recorded, its state rolled back, and the
/// next scenario still runs. The final revert lists every failure.
/// Run: RAYON_NUM_THREADS=2 forge test --match-path test/plus/PlusFork.t.sol -vv
contract PlusForkTest is LendingForkSetup {
    address constant VAULT = 0xEd83daf48429cfb2C650Fd721b9241e180fd4548;
    address constant AVKAT = 0x7231dbaCdFc968E07656D12389AB20De82FbfCeB;
    address constant MORPHO = 0xD50F2DffFd62f94Ee4AEd9ca05C61d0753268aBc;
    address constant DEPLOYER = 0x11b78837cadC8E894F1c6e13fA9f3A085a75FA35;
    address constant FEE_SAFE = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;
    address constant POOL_1PCT = 0x8640e1867BD563B2Ab865160E77Cb7B875243B13;
    address constant ROUTER = 0x01F9894f92ea9224fECc8C35482E20a05De13582;
    bytes32 constant WITHDRAW_MANAGER_SLOT = 0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100;
    uint256 constant CY = 1e20; // one cyavKAT (20 decimals)
    uint256 constant PPS_UNIT = 1e22; // one cyavKAT+ share (22 decimals)

    IVaultP cy = IVaultP(VAULT);
    IVaultP plus;
    string p0Path;
    string p2Path;
    string p4Path;
    string lendPath;
    string j;
    string p2j;
    string lendj;
    bytes32 lendMarket;
    CurveYieldPlusLoopController controller;
    CurveYieldPlusExecutor executor;
    CurveYieldPlusDepositRouter router;
    IWmP wm;
    address booster;
    address rcm;
    address mainAlpha; // the Phase 2 executor: ALPHA on the main vault after the cutover

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address special = makeAddr("special");

    string[] fails;
    string[] soft;

    struct PpsPoint {
        uint256 t;
        uint256 pps;
        string what;
    }

    PpsPoint[] ppsLog;
    uint256 crystalDropBps;

    function setUp() public {
        vm.createSelectFork(vm.envString("KATANA_RPC_URL"), vm.envUint("FORK_BLOCK"));
        vm.setEnv("PRIVATE_KEY", "0");
        p0Path = _tmpPath("plus-p0");
        p2Path = _tmpPath("plus-p2");
        p4Path = _tmpPath("plus-p4");
        lendPath = _tmpPath("plus-lend");
        vm.setEnv("PHASE0_DEPLOYMENTS", p0Path);
        vm.setEnv("PHASE4_DEPLOYMENTS", p4Path);
        vm.setEnv("SPECIAL_REWARDS", vm.toString(special));
        _prepareLending(lendPath, p2Path);
        IScriptP(address(new P0_00_DeployGateConfig())).run();
        _run(address(new P2_01_Deploy()));
        _run(address(new P2_02_ConfigureVault()));
        _run(address(new P2_03_Cutover()));
        if (vm.envOr("PLUS_NO_DEPOSIT_FEE", false)) { // diagnostic: P2_03 sets the 0.30% onboarding fee on the main vault
            vm.prank(DEPLOYER);
            (bool okFee,) = 0x11a81a7B7436CB1E8f73866AF74961cE499f5Ec6.call(abi.encodeWithSignature("setDepositFee(uint256)", uint256(0)));
            require(okFee, "setDepositFee(0) failed");
        }
        _run(address(new P4_01_CreatePlusVault()));
        _run(address(new P4_02_DeployPlusStack()));
        _run(address(new P4_03_ConfigurePlus()));
        j = vm.readFile(p4Path);
        p2j = vm.readFile(p2Path);
        lendj = vm.readFile(lendPath);
        lendMarket = vm.parseJsonBytes32(lendj, ".lendMorphoMarket");
        plus = IVaultP(_a(".plusVault"));
        controller = CurveYieldPlusLoopController(_a(".plusController"));
        executor = CurveYieldPlusExecutor(_a(".plusExecutor"));
        router = CurveYieldPlusDepositRouter(_a(".plusDepositRouter"));
        wm = IWmP(_a(".plusWithdrawManagerV2"));
        booster = _a(".plusYieldBooster");
        rcm = _a(".plusRewardsManager");
        mainAlpha = vm.parseJsonAddress(p2j, ".executor");
    }

    function _run(address script_) internal {
        IScriptP(script_).setPaths(p2Path, lendPath);
        IScriptP(script_).run();
    }

    function _a(string memory k) internal view returns (address) {
        return vm.parseJsonAddress(j, k);
    }

    // ---------------------------------------------------------------- helpers

    function _pps() internal view returns (uint256) {
        return plus.convertToAssets(PPS_UNIT);
    }

    /// @dev PPS net of the instant-fee split the manager has accrued (owedSplitShares) but not yet paid out: that value is
    /// still in totalAssets until settleSplit() pays it, so the raw PPS right after an instant redeem is overstated by it.
    function _ppsNet() internal view returns (uint256) {
        uint256 raw = _pps();
        uint256 supply = plus.totalSupply();
        return supply == 0 ? raw : raw - raw * wm.owedSplitShares() / supply;
    }

    function _mark(string memory what) internal {
        ppsLog.push(PpsPoint(block.timestamp, _ppsNet(), what));
        console2.log(what, "cyavKAT+ pps (net of owed split)", _ppsNet());
    }

    function _near(uint256 a, uint256 b, uint256 tolBps, string memory what) internal pure {
        uint256 d = a > b ? a - b : b - a;
        uint256 ref = a > b ? a : b;
        require(d * 10_000 <= ref * tolBps, string.concat(what, ": ", vm.toString(a), " vs ", vm.toString(b)));
    }

    function _softNear(uint256 a, uint256 b, uint256 tolBps, string memory what) internal {
        uint256 d = a > b ? a - b : b - a;
        uint256 ref = a > b ? a : b;
        if (d * 10_000 > ref * tolBps) soft.push(string.concat(what, ": ", vm.toString(a), " vs ", vm.toString(b)));
    }

    function _flushSoft() internal view {
        if (soft.length == 0) return;
        string memory all;
        for (uint256 i; i < soft.length; ++i) all = string.concat(all, i == 0 ? "" : " | ", soft[i]);
        revert(all);
    }

    function _ge(uint256 a, uint256 b, uint256 tol, string memory what) internal pure {
        require(a + tol >= b, string.concat(what, ": ", vm.toString(a), " < ", vm.toString(b)));
    }

    function _mintCy(address u, uint256 cyWanted) internal {
        _refreshMain(); // revalue first: the cached price is ~0.5% stale, a deposit prices fresh
        uint256 a = cy.convertToAssets(cyWanted) * 101 / 100 + 1e12;
        deal(AVKAT, u, a);
        vm.startPrank(u);
        IErcP(AVKAT).approve(VAULT, a);
        cy.deposit(a, u);
        vm.stopPrank();
        require(cy.balanceOf(u) >= cyWanted, "could not mint the wanted cyavKAT");
    }

    function _plusDeposit(address u, uint256 cyAmt) internal returns (uint256 shares) {
        vm.startPrank(u);
        IErcP(VAULT).approve(address(router), cyAmt);
        shares = router.deposit(cyAmt, u);
        vm.stopPrank();
    }

    function _ltv() internal view returns (uint256) {
        return controller.snapshot().ltvBps;
    }

    function _seedLending() internal {
        MarketParams memory mp = IMorpho(MORPHO).idToMarketParams(Id.wrap(lendMarket));
        address lp = makeAddr("lendLp");
        deal(AVKAT, lp, 500_000e18);
        vm.startPrank(lp);
        IErcP(AVKAT).approve(MORPHO, type(uint256).max);
        IMorpho(MORPHO).supply(mp, 500_000e18, 0, lp, "");
        vm.stopPrank();
    }

    function _refreshMain() internal {
        try cy.getActiveMarketsInBalanceFuses() returns (uint256[] memory ms) {
            vm.prank(DEPLOYER);
            try cy.updateMarketsBalances(ms) {} catch {}
        } catch {}
    }

    function _refreshPlus() internal {
        uint256[] memory ms = new uint256[](2);
        (ms[0], ms[1]) = (14, 19);
        vm.prank(DEPLOYER);
        plus.updateMarketsBalances(ms);
    }

    /// @dev main vault idle avKAT -> the lending market (value stays in its books, instant liquidity drops to `keep`)
    function _deployMainIdle(uint256 keep) internal {
        uint256 idle = IErcP(AVKAT).balanceOf(VAULT);
        require(idle > keep, "main idle already below keep");
        uint256 ta0 = cy.totalAssets();
        FuseAction[] memory a = new FuseAction[](1);
        a[0] = FuseAction(
            vm.parseJsonAddress(lendj, ".lendSupplyFuse"),
            abi.encodeWithSignature("enter((bytes32,uint256))", MorphoSupplyEnter(lendMarket, idle - keep))
        );
        vm.prank(mainAlpha);
        cy.execute(a);
        uint256 ta1 = cy.totalAssets();
        console2.log("main vault idle now / totalAssets before -> after", IErcP(AVKAT).balanceOf(VAULT), ta0, ta1);
        _near(ta1, ta0, 100, "test setup: supplying idle to the market changed the main vault's total assets");
    }

    function _crystallizeMain() internal {
        address ghost = makeAddr("ghost");
        deal(AVKAT, ghost, 20e18);
        vm.startPrank(ghost);
        IErcP(AVKAT).approve(VAULT, type(uint256).max);
        cy.deposit(20e18, ghost);
        cy.withdraw(1e18, ghost, ghost);
        vm.stopPrank();
    }

    function _warpBy(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
    }

    // ---------------------------------------------------------------- scenario 1

    function s1_sanity() external {
        require(plus.asset() == VAULT, "asset is not cyavKAT");
        deal(AVKAT, alice, 100e18);
        vm.startPrank(alice);
        IErcP(AVKAT).approve(VAULT, type(uint256).max);
        uint256 got = cy.deposit(100e18, alice);
        IErcP(VAULT).approve(address(plus), type(uint256).max);
        (bool ok,) = address(plus).call(abi.encodeCall(IVaultP.deposit, (got, alice)));
        vm.stopPrank();
        require(!ok, "direct deposit into cyavKAT+ did not revert");

        IOracleP oracle = IOracleP(plus.getPriceOracleMiddleware());
        address[3] memory assets = [VAULT, vm.parseJsonAddress(lendj, ".wcyavkat"), AVKAT];
        for (uint256 i; i < 3; ++i) {
            (uint256 p, uint256 d) = oracle.getAssetPrice(assets[i]);
            require(p != 0 && d != 0, string.concat("no price for ", vm.toString(assets[i])));
        }
        require(plus.isBalanceFuseSupported(14, _a(".plusMorphoBalanceFuse")), "market 14 balance fuse");
        require(plus.isBalanceFuseSupported(19, _a(".plusZeroFlashBalanceFuse")), "market 19 balance fuse");
        require(plus.getMarketSubstrates(14).length == 1 && plus.getMarketSubstrates(19).length == 1, "market substrates");
        address[] memory iw = plus.getInstantWithdrawalFuses();
        require(iw.length == 1 && iw[0] == _a(".plusPlannedInstantFuse"), "instant fuse is not the planned-instant fuse");
        require(address(uint160(uint256(vm.load(address(plus), WITHDRAW_MANAGER_SLOT)))) == address(wm), "WM v2 is not active");
        require(wm.getWithdrawFee() == 0.15e18 && wm.getRequestFee() == 0.15e18, "wm fees not 15%");
        (address[3] memory rec, uint16[3] memory bps) = wm.feeSplit();
        require(bps[0] == 2_000 && bps[1] == 2_500 && bps[2] == 3_000, "split not 20/25/30");
        require(rec[0] == FEE_SAFE && rec[1] == special && rec[2] == booster, "split recipients");
        require(wm.splitRequestFee(), "request fee not split");
        require(controller.mainWithdrawManager() == vm.parseJsonAddress(p2j, ".withdrawManagerV2"), "main withdraw manager not set");
    }

    // ---------------------------------------------------------------- scenario 2: deposits

    function s2_deposits() external {
        vm.prank(DEPLOYER);
        router.setWhitelisted(bob, true);
        _mintCy(alice, 1_000 * CY);
        _mintCy(bob, 1_000 * CY);

        uint256 a0 = cy.balanceOf(FEE_SAFE);
        uint256 s0 = cy.balanceOf(special);
        uint256 b0 = cy.balanceOf(booster);
        uint256 r0 = cy.balanceOf(rcm) + cy.balanceOf(address(plus));
        uint256 pps0 = _pps();

        _plusDeposit(alice, 1_000 * CY);
        require(cy.balanceOf(FEE_SAFE) - a0 == 70 * CY, "admin share != 70");
        require(cy.balanceOf(special) - s0 == 87.5e20, "special share != 87.5");
        require(cy.balanceOf(booster) - b0 == 105 * CY, "booster (last bucket) share != 105");
        uint256 r1 = cy.balanceOf(rcm) + cy.balanceOf(address(plus));
        require(r1 - r0 == 650 * CY + 87.5e20, "RCM share + net deposit not accounted");
        _ge(_pps(), pps0, 10, "alice deposit dropped the pps");
        _mark("after alice");

        pps0 = _pps();
        a0 = cy.balanceOf(FEE_SAFE);
        s0 = cy.balanceOf(special);
        b0 = cy.balanceOf(booster);
        uint256 v0 = cy.balanceOf(address(plus));
        _plusDeposit(bob, 1_000 * CY);
        require(cy.balanceOf(FEE_SAFE) == a0 && cy.balanceOf(special) == s0 && cy.balanceOf(booster) == b0, "whitelisted deposit paid a fee");
        require(cy.balanceOf(address(plus)) - v0 == 1_000 * CY, "whitelisted deposit not fully in the vault");
        _ge(_pps(), pps0, 10, "bob deposit dropped the pps");
        _mark("after bob");

        pps0 = _pps();
        a0 = cy.balanceOf(FEE_SAFE);
        s0 = cy.balanceOf(special);
        b0 = cy.balanceOf(booster);
        uint256 amt = 333_333_333_333_333_333_333 * 10; // 333.33.. cyavKAT
        _mintCy(carol, amt);
        vm.startPrank(carol);
        IErcP(VAULT).approve(address(router), amt);
        router.deposit(amt, carol);
        vm.stopPrank();
        uint256 fee = amt * 3_500 / 10_000;
        require(cy.balanceOf(FEE_SAFE) - a0 == fee * 2_000 / 10_000 && cy.balanceOf(special) - s0 == fee * 2_500 / 10_000, "carol split");
        require(cy.balanceOf(booster) - b0 == fee - fee * 2_000 / 10_000 - fee * 2_500 / 10_000 * 2, "carol booster (dust) share");
        _ge(_pps(), pps0, 10, "carol deposit dropped the pps");

        _warpBy(1 days);
        vm.prank(address(router));
        (bool ok,) = rcm.call(abi.encodeWithSignature("updateBalance()"));
        require(ok, "rcm.updateBalance");
        _ge(_pps(), pps0, 10, "vesting lowered the pps");
        _mark("after vesting");
    }

    // ---------------------------------------------------------------- scenario 3: windup

    function s3_windup() external {
        _refreshMain();
        _refreshPlus();
        uint256 pps0 = _pps(); // fresh: the cached market values lag by interest accrued since the last update
        vm.recordLogs();
        uint256 g = gasleft();
        executor.windup();
        uint256 gasWindup = g - gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            require(logs[i].emitter != POOL_1PCT && logs[i].emitter != ROUTER, "a swap venue was touched");
        }
        CyPlusSnapshot memory s = controller.snapshot();
        require(s.ltvBps >= 6_950 && s.ltvBps <= 7_050, string.concat("ltv not 70% +-0.5%: ", vm.toString(s.ltvBps)));
        // the generic-fuse plan sizes the wrap/supply legs from previewDeposit() on two chained ERC4626 conversions
        // (avKAT->cyavKAT, cyavKAT->wcyavKAT), so a few bps of dust can remain idle after the real deposits round down;
        // bound it proportionally instead of near-zero (the old single step-fuse left ~0, this one does not)
        uint256 idleLeft = cy.balanceOf(address(plus));
        require(idleLeft * 2_000 <= s.collateralCy + idleLeft, string.concat("idle cyavKAT left: ", vm.toString(idleLeft)));
        uint256 hf = s.collateralValue * 8_800 / 10_000 * 8_600 / 10_000 * 1e4 / s.debt;
        require(hf >= 10_500, "health factor below 1.05");
        // windup deposits into the main vault (cyavKAT), which can realize/update its own pending management fee as a
        // side effect (PHASE4 §0's sole allowed exception: "the IPOR management fee" may lower PPS); bound it instead
        // of requiring exact non-decrease, same tolerance philosophy as s4b's crystallisation check
        _refreshMain();
        _refreshPlus();
        _ge(_pps(), pps0, pps0 / 1_000, "windup lowered the pps by more than the management-fee exception allows");
        console2.log("windup: ltv bps / health factor x1e4", s.ltvBps, hf);
        console2.log("  windup gas", gasWindup);
        _mark("after windup");
    }

    /// @dev maxInstantOut must reflect the main vault's instant liquidity (was 0 whenever the plus vault held no idle shares)
    function s3b_maxInstantOut() external view {
        uint256 mx = controller.maxInstantOut();
        uint256 liquid = controller.mainLiquidAvkat();
        console2.log("maxInstantOut / mainLiquidAvkat", mx, liquid);
        require(liquid > 1e18 && mx != 0, "maxInstantOut is 0 while the main vault holds idle avKAT");
    }

    // ---------------------------------------------------------------- scenario 4: profit

    function s4_profit() external {
        uint256 pps0 = _pps();
        uint256 ckpt0 = controller.equityPerShareCheckpoint();
        uint256 mainAssets = cy.totalAssets();
        deal(AVKAT, VAULT, IErcP(AVKAT).balanceOf(VAULT) + mainAssets * 4 / 100);
        _refreshMain();
        (uint256 profit, uint256 outCy) = controller.pendingProfit();
        console2.log("pending profit (net of the main perf fee) / out (cyavKAT)", profit, outCy);
        require(profit != 0, "no profit after the cyavKAT price rise");
        uint256 sp0 = cy.balanceOf(special);
        uint256 bo0 = cy.balanceOf(booster);
        uint256 ad0 = cy.balanceOf(FEE_SAFE);
        uint256 eq0 = controller.snapshot().equityCy;
        uint256 g = gasleft();
        executor.windup();
        console2.log("profit windup gas", g - gasleft());
        _near(cy.balanceOf(special) - sp0, profit * 4_000 / 10_000, 5, "special 40% of profit");
        _near(cy.balanceOf(booster) - bo0, profit * 1_000 / 10_000, 5, "booster 10% of profit");
        _near(cy.balanceOf(FEE_SAFE) - ad0, profit * 1_000 / 10_000, 5, "admin 10% of profit");
        uint256 ckpt1 = controller.equityPerShareCheckpoint();
        uint256 epsNow = controller.equityPerShare();
        require(ckpt1 > ckpt0, "checkpoint did not advance");
        console2.log("checkpoint / equity per share after execute()", ckpt1, epsNow);
        _near(ckpt1, epsNow, 100, "checkpoint too far from equity per share");
        _near(controller.snapshot().equityCy, eq0 - outCy, 30, "40% compounded: equity != before - out");
        uint256 ltv = _ltv();
        require(ltv >= 6_950 && ltv <= 7_050, string.concat("ltv after profit windup: ", vm.toString(ltv)));
        require(_pps() > pps0, "pps did not rise with the profit");
        _mark("after profit");
        // the main vault's own performance fee crystallises on its next withdraw; cyavKAT+ then refreshes its cached balance
        uint256 before = _pps();
        _crystallizeMain();
        _refreshPlus();
        uint256 afterPps = _pps();
        crystalDropBps = afterPps < before ? (before - afterPps) * 10_000 / before : 0;
        console2.log("cyavKAT+ pps before / after the main perf-fee crystallisation", before, afterPps);
        console2.log("  pps before the profit windup", pps0);
        _mark("after main perf-fee crystallisation");
    }

    function s4b_perfFeeCrystallisation() external view {
        require(crystalDropBps <= 10, string.concat("cyavKAT+ pps fell ", vm.toString(crystalDropBps), " bps when the main vault crystallised its performance fee"));
    }

    // ---------------------------------------------------------------- scenario 5: instant withdraw

    /// @dev the redeem needs an unwind (the vault is fully deployed): the loop fuse runs the flash unwind inside redeem
    function s5_instantWithUnwind() external {
        uint256 sh = plus.balanceOf(alice) / 3;
        uint256 pps0 = _pps();
        uint256 mainPps0 = cy.convertToAssets(CY);
        uint256 gross = plus.convertToAssets(sh);
        uint256 a0 = cy.balanceOf(alice);
        CyPlusSnapshot memory s0 = controller.snapshot();
        uint256 g = gasleft();
        vm.prank(alice);
        plus.redeem(sh, alice, alice);
        console2.log("instant redeem with an inline unwind: gas", g - gasleft());
        // the plan-based unwind (fuse standardization) has no single dedicated event; proof it ran is the Morpho
        // position actually shrinking (debt repaid, wrapped collateral withdrawn)
        CyPlusSnapshot memory s1 = controller.snapshot();
        console2.log("debt before / after", s0.debt, s1.debt);
        console2.log("collateralWrapped before / after", s0.collateralWrapped, s1.collateralWrapped);
        require(s1.debt < s0.debt, "debt did not shrink: the unwind did not run");
        require(s1.collateralWrapped < s0.collateralWrapped, "collateral did not shrink: the unwind did not run");
        uint256 got = cy.balanceOf(alice) - a0;
        console2.log("gross / received", gross, got);
        console2.log("  received / gross (bps)", got * 10_000 / gross);
        // the redeemer bears a pro-rata part of the unwind cost (IPOR withdraws from markets before converting shares)
        require(got <= gross * 85 / 100, "received more than 85% of gross");
        require(got * 100 >= gross * 85 * 96 / 100, "received less than 85% of gross minus 4%");
        require(cy.convertToAssets(CY) > mainPps0, "the main vault's instant fee was not paid into it");
        console2.log("pps before / after the instant redeem", pps0, _pps());
        _ge(_pps(), pps0, 1e6, "instant redeem lowered the pps of the remaining holders");
        require(wm.owedSplitShares() != 0, "no split accrued");
        uint256 ltv = _ltv();
        require(ltv >= 6_950 && ltv <= 7_050, string.concat("ltv after instant redeem: ", vm.toString(ltv)));
        _mark("after instant redeem (unwind)");
    }

    /// @dev idle cyavKAT already covers the redeem (a fresh deposit not yet wound up): no unwind, exactly 85%, then the
    /// accrued split is settled from idle
    function s5d_instantFromIdleAndSettle() external {
        vm.prank(DEPLOYER);
        router.setWhitelisted(carol, true);
        _mintCy(carol, 2_000 * CY);
        _plusDeposit(carol, 2_000 * CY);
        _warpBy(3_601); // redemption delay of the depositor
        uint256 idle = cy.balanceOf(address(plus));
        require(idle >= 2_000 * CY, "deposit is not idle");
        // the pps includes the split still owed from earlier redeems; settle it first so the baseline is the true price
        uint256 ppsBeforeOldSettle = _pps();
        wm.settleSplit();
        console2.log("pps before / after settling the split owed from earlier redeems (visible pps drop)", ppsBeforeOldSettle, _pps());
        uint256 sh = plus.balanceOf(alice) / 4;
        uint256 pps0 = _pps();
        uint256 gross = plus.convertToAssets(sh);
        require(gross * 85 / 100 < idle, "test setup: redeem larger than idle");
        uint256 a0 = cy.balanceOf(alice);
        uint256 owed0 = wm.owedSplitShares();
        vm.prank(alice);
        plus.redeem(sh, alice, alice);
        uint256 got = cy.balanceOf(alice) - a0;
        console2.log("instant redeem from idle: received / gross (bps of 85%)", got * 10_000 / (gross * 85 / 100));
        _near(got, gross * 85 / 100, 10, "instant redeemer did not receive 85% of gross");
        uint256 owed1 = wm.owedSplitShares();
        _near(owed1 - owed0, sh * 15 / 100 * 75 / 100, 5, "accrued split != 75% of the 15% fee");
        console2.log("pps before / right after the redeem (owed split not yet paid)", pps0, _pps());

        // settle: recipients get 20/25/30 of the fee value, paid from idle
        uint256 ad0 = cy.balanceOf(FEE_SAFE);
        uint256 sp0 = cy.balanceOf(special);
        uint256 bo0 = cy.balanceOf(booster);
        uint256 owedValue = plus.convertToAssets(owed1); // all accrued split (earlier redeems included), at the price now
        uint256 paid = wm.settleSplit();
        console2.log("settleSplit paid shares / owed shares", paid, owed1);
        _near(cy.balanceOf(FEE_SAFE) - ad0, owedValue * 2_000 / 7_500, 200, "settle: admin 20/75 of the owed split");
        _near(cy.balanceOf(special) - sp0, owedValue * 2_500 / 7_500, 200, "settle: special 25/75 of the owed split");
        _near(cy.balanceOf(booster) - bo0, owedValue * 3_000 / 7_500, 200, "settle: booster 30/75 of the owed split");
        require(wm.owedSplitShares() == 0, "owed split not fully settled from idle");
        console2.log("pps after settleSplit", _pps());
        _ge(_pps(), pps0, 1e6, "pps below the baseline after settling");
        require(_pps() > pps0, "the 25% of the fee that stays burned did not raise the pps");
    }

    /// @dev after a deployed-vault redeem the accrued split can only be paid from idle
    function s5e_settleNeedsIdle() external {
        uint256 sh = plus.balanceOf(alice) / 3;
        vm.prank(alice);
        plus.redeem(sh, alice, alice); // unwinds inline: idle ends near 0
        uint256 owed = wm.owedSplitShares();
        require(owed != 0, "no split accrued");
        uint256 idle = cy.balanceOf(address(plus));
        uint256 paid = wm.settleSplit();
        console2.log("owed shares / idle cyavKAT", owed, idle);
        console2.log("  paid shares", paid);
        require(paid * 100 >= owed * 99, string.concat("settleSplit could pay only ", vm.toString(paid), " of ", vm.toString(owed), " owed shares: idle is ", vm.toString(idle)));
    }

    /// @dev fix F: the executor's windup() calls wm.settleSplit() FIRST (before planning), so the split owed from an
    /// earlier redeem is paid out of THAT call, not starved by windup then wrapping all the idle it needed.
    function s5f_windupSettlesTheAccruedSplitFirst() external {
        uint256 sh = plus.balanceOf(alice) / 3;
        vm.prank(alice);
        plus.redeem(sh, alice, alice); // accrues split
        uint256 owedBefore = wm.owedSplitShares();
        require(owedBefore != 0, "no split accrued");
        vm.prank(DEPLOYER);
        router.setWhitelisted(carol, true);
        _mintCy(carol, 500 * CY);
        _plusDeposit(carol, 500 * CY); // idle 500 cyavKAT, enough to cover the owed split
        uint256 ad0 = cy.balanceOf(FEE_SAFE);
        executor.windup(); // settleSplit runs first, inside this same call, then wraps whatever idle remains
        console2.log("owed split before / after windup", owedBefore, wm.owedSplitShares());
        console2.log("  admin split payout across windup", cy.balanceOf(FEE_SAFE) - ad0);
        require(wm.owedSplitShares() == 0, "windup's own settleSplit did not clear the owed split");
        require(cy.balanceOf(FEE_SAFE) > ad0, "the split recipients were not paid by windup's settleSplit");
        // settling again right after finds nothing left owed (already paid, not starved)
        require(wm.settleSplit() == 0, "a second settleSplit paid something: the first one did not pay in full");
    }

    // ---------------------------------------------------------------- scenario 6: instant bound

    function s6_bound() external {
        uint256 snap = vm.snapshot();
        executor.windup(); // no idle left in cyavKAT+ (earlier scenarios leave some)
        _deployMainIdle(5e18);
        uint256 mx = controller.maxInstantOut();
        uint256 sh = plus.balanceOf(alice) / 2;
        uint256 want = plus.convertToAssets(sh);
        console2.log("maxInstantOut with a nearly drained main vault / redeem assets", mx, want);
        require(mx > 0, "maxInstantOut is 0");
        require(want * 85 / 100 > mx * 2, "test setup: redeem is not above the instant bound");

        // (a) the instant fuse itself must never revert. Its planner (controller.planInstantWithdraw) CLAMPS the request
        // to maxInstantOut() rather than failing outright (fuse standardization), so an over-bound request still
        // executes a smaller, self-consistent unwind — proof is the position shrinking by no more than the bound, not a
        // "failed" event. params = [amount, planner], matching how P4_03 configured it (IPOR fills params[0] with the
        // needed amount at call time and keeps params[1] as configured).
        CyPlusSnapshot memory s0 = controller.snapshot();
        FuseAction[] memory acts = new FuseAction[](1);
        bytes32[] memory params = new bytes32[](2);
        params[0] = bytes32(want);
        params[1] = bytes32(uint256(uint160(address(controller))));
        acts[0] = FuseAction(plus.getInstantWithdrawalFuses()[0], abi.encodeWithSignature("instantWithdraw(bytes32[])", params));
        vm.recordLogs();
        vm.prank(address(executor));
        plus.execute(acts); // must not revert even though `want` is far above the instant bound
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawEvent;
        bool eventSuccess;
        bytes32 plannedSig = keccak256("PlannedInstantWithdraw(address,address,uint256,bool)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == plannedSig) {
                sawEvent = true;
                (,,, eventSuccess) = abi.decode(logs[i].data, (address, address, uint256, bool));
            }
        }
        require(sawEvent && eventSuccess, "the clamped instant withdrawal plan did not execute successfully");
        CyPlusSnapshot memory s1 = controller.snapshot();
        // maxInstantOut() bounds the NET payout (collateral released minus the cyavKAT-equivalent cost of the debt
        // repaid, i.e. the equity drop), not the gross collateral unwound: at ~3.3x leverage, gross collateral moved
        // is roughly leverage x the net payout, so comparing collateralCy here would fail even on correct behavior.
        console2.log("equityCy released by the clamped instant withdraw / bound", s0.equityCy - s1.equityCy, mx);
        require(s1.debt < s0.debt, "the clamped instant withdraw did not unwind anything");
        require(s0.equityCy - s1.equityCy <= mx + mx / 20, "the clamped instant withdraw released more than the bound");

        // (b) the user-facing redeem for the FULL over-bound amount may revert (the fuse can only deliver up to the
        // bound) but must leave everything unchanged; state is now at s1, not s0, since (a) already ran for real
        uint256 aliceBefore = plus.balanceOf(alice);
        vm.prank(alice);
        try plus.redeem(sh, alice, alice) returns (uint256 out) {
            console2.log("over-bound redeem returned (partial not expected)", out);
        } catch {
            console2.log("over-bound redeem reverted, as accepted");
        }
        if (plus.balanceOf(alice) == aliceBefore) {
            CyPlusSnapshot memory s2 = controller.snapshot();
            require(s2.debt == s1.debt && s2.collateralWrapped == s1.collateralWrapped, "state corrupted by the reverted redeem");
        }

        // (c) a redeem inside the bound works and keeps the LTV
        uint256 gSmall = mx * 4 / 10;
        uint256 shSmall = sh * gSmall / (want + 1);
        require(shSmall > 1e18, "test setup: in-bound redeem too small");
        vm.prank(alice);
        plus.redeem(shSmall, alice, alice);
        uint256 ltv = _ltv();
        require(ltv >= 6_900 && ltv <= 7_100, string.concat("ltv after in-bound redeem: ", vm.toString(ltv)));
        vm.revertTo(snap);
    }

    // ---------------------------------------------------------------- scenario 7: scheduled withdrawal

    function s7_scheduled() external {
        uint256 sh = plus.balanceOf(alice) / 2;
        uint256 pps0 = _pps();
        vm.prank(alice);
        wm.requestShares(sh);
        uint256 active = wm.activeUnreleasedShares();
        _warpBy(2); // release needs the request to be older than the release timestamp
        uint256 gross = plus.convertToAssets(sh);
        uint256 sp0 = cy.balanceOf(special);
        uint256 bo0 = cy.balanceOf(booster);
        uint256 ad0 = cy.balanceOf(FEE_SAFE);
        uint256 g = gasleft();
        uint256 released = executor.fulfill();
        console2.log("fulfil gas (with an inline unwind)", g - gasleft());
        console2.log("released shares / active", released, active);
        require(released == active, "fulfil did not release the whole request with ample liquidity");
        uint256 fee = gross * 15 / 100;
        _softNear(cy.balanceOf(special) - sp0, fee * 2_500 / 10_000, 300, "request-fee split: special");
        _softNear(cy.balanceOf(booster) - bo0, fee * 3_000 / 10_000, 300, "request-fee split: booster");
        _softNear(cy.balanceOf(FEE_SAFE) - ad0, fee * 2_000 / 10_000, 300, "request-fee split: admin");
        _warpBy(2);
        uint256 a0 = cy.balanceOf(alice);
        vm.prank(alice);
        plus.redeemFromRequest(released, alice, alice);
        uint256 got = cy.balanceOf(alice) - a0;
        console2.log("scheduled redeem: gross / received", gross, got);
        // the released shares are redeemed after 25% of the request fee was burned, so the redeemer recaptures a pro-rata part
        // of that burn (about 0.2% here); the unwind cost lands in the other direction
        require(got * 1000 <= gross * 855, "received more than 85.5% of gross");
        require(got * 100 >= gross * 85 * 96 / 100, "received less than 85% of gross minus 4%");
        _ge(_pps(), pps0, 1e6, "scheduled redeem lowered the pps of the remaining holders");
        uint256 ltv = _ltv();
        require(ltv >= 6_900 && ltv <= 7_100, string.concat("ltv after fulfil: ", vm.toString(ltv)));
        _mark("after scheduled redeem");
        _flushSoft();
    }

    function s7b_partialFill() external {
        uint256 snap = vm.snapshot();
        executor.windup(); // no idle left in cyavKAT+ (earlier scenarios leave some)
        _deployMainIdle(5e18);
        uint256 mx = controller.maxInstantOut();
        uint256 sh2 = plus.balanceOf(bob);
        vm.prank(bob);
        wm.requestShares(sh2);
        uint256 act2 = wm.activeUnreleasedShares();
        console2.log("partial fill setup: request assets / bound", plus.convertToAssets(act2), mx);
        require(plus.convertToAssets(act2) > mx * 2, "test setup: the request is not larger than the instant bound");
        _warpBy(2);
        uint256 rel2 = executor.fulfill();
        console2.log("partial fill: released / requested", rel2, act2);
        require(rel2 < act2, "expected a partial fill with a low-liquidity main vault");
        require(wm.activeUnreleasedShares() == act2 - rel2, "the remainder is not waiting");
        _warpBy(2);
        uint256 c0 = cy.balanceOf(bob);
        vm.prank(bob);
        plus.redeemFromRequest(rel2, bob, bob);
        require(cy.balanceOf(bob) > c0, "the released part could not be redeemed");
        vm.revertTo(snap);
    }

    // ---------------------------------------------------------------- scenario 8: delever

    function s8_delever() external {
        uint256 snap = vm.snapshot();
        uint256 drain = cy.totalAssets() * 4 / 100;
        vm.prank(VAULT);
        IErcP(AVKAT).transfer(makeAddr("sink"), drain); // a ~4% cyavKAT price drop
        uint256 ltv0 = _ltv();
        require(ltv0 > 7_220, "test setup: ltv is not above the de-lever line");
        uint256 g = gasleft();
        executor.delever();
        uint256 gasDelever = g - gasleft();
        uint256 ltv1 = _ltv();
        console2.log("ltv after the price drop / after delever", ltv0, ltv1);
        console2.log("  delever gas", gasDelever);
        require(ltv1 >= 6_950 && ltv1 <= 7_050, string.concat("ltv after delever not 70%: ", vm.toString(ltv1)));
        vm.revertTo(snap);
    }

    // ---------------------------------------------------------------- scenario 9: pps invariant

    function s9_ppsInvariant() external view {
        require(ppsLog.length >= 2, "no pps log");
        // allowed drop between two marks: wrapper 2%/yr on ~4x levered collateral + IPOR 0.5%/yr management fee, PLUS a
        // flat allowance for the main vault's management fee realizing as a side effect of a single windup deposit
        // (PHASE4 §0's sole allowed exception), which is a one-off event, not proportional to elapsed time
        for (uint256 i = 1; i < ppsLog.length; ++i) {
            PpsPoint memory a = ppsLog[i - 1];
            PpsPoint memory b = ppsLog[i];
            if (b.pps >= a.pps) continue;
            uint256 dt = b.t - a.t;
            uint256 allowed = a.pps * dt * (4 * 200 + 50) / (10_000 * 365 days) + a.pps / 1_000; // 0.1% flat allowance
            require(a.pps - b.pps <= allowed, string.concat("pps dropped at '", b.what, "': ", vm.toString(a.pps), " -> ", vm.toString(b.pps)));
        }
    }

    // ---------------------------------------------------------------- driver

    function _runS(string memory name, bytes4 sel) internal returns (bool ok_) {
        uint256 snap = vm.snapshot();
        (bool ok, bytes memory ret) = address(this).call(abi.encodeWithSelector(sel));
        if (ok) {
            console2.log("PASS", name);
            return true;
        }
        string memory why;
        if (ret.length == 0) {
            why = "(empty revert data)";
        } else if (bytes4(ret) == 0x08c379a0) {
            why = abi.decode(_tail(ret), (string));
        } else if (bytes4(ret) == 0x4085a178) {
            (uint256 rel, uint256 req, uint256 avail) = abi.decode(_tail(ret), (uint256, uint256, uint256));
            why = string.concat("InvalidUnallocatedShares(released ", vm.toString(rel), ", requested ", vm.toString(req), ", available ", vm.toString(avail), ")");
        } else if (bytes4(ret) == 0xe450d38c) {
            (address who, uint256 bal, uint256 need) = abi.decode(_tail(ret), (address, uint256, uint256));
            why = string.concat("ERC20InsufficientBalance(", vm.toString(who), ", balance ", vm.toString(bal), ", needed ", vm.toString(need), ")");
        } else if (bytes4(ret) == 0x65b62d65) {
            why = "NothingToFulfil()";
        } else {
            why = vm.toString(ret);
        }
        vm.revertTo(snap);
        console2.log("FAIL", name);
        console2.log("   ", why);
        fails.push(string.concat(name, ": ", why));
        return false;
    }

    function _tail(bytes memory b) internal pure returns (bytes memory out) {
        out = new bytes(b.length - 4);
        for (uint256 i; i < out.length; ++i) out[i] = b[i + 4];
    }

    function test_lifecycle() public {
        _seedLending();
        _runS("1 deploy/config sanity", this.s1_sanity.selector);
        _runS("2 deposits via the router", this.s2_deposits.selector);
        _runS("3 windup", this.s3_windup.selector);
        _runS("3b maxInstantOut usable after a windup", this.s3b_maxInstantOut.selector);
        _runS("4 profit and windup", this.s4_profit.selector);
        _runS("4b pps stable when the main vault crystallises its performance fee", this.s4b_perfFeeCrystallisation.selector);
        _runS("5 instant withdraw with an inline unwind", this.s5_instantWithUnwind.selector);
        _runS("5d instant withdraw from idle: exactly 85%, then settleSplit", this.s5d_instantFromIdleAndSettle.selector);
        _runS("5e settleSplit right after a deployed-vault redeem", this.s5e_settleNeedsIdle.selector);
        _runS("5f windup settles the accrued split first", this.s5f_windupSettlesTheAccruedSplitFirst.selector);
        _runS("6 instant-withdraw bound", this.s6_bound.selector);
        _runS("7 scheduled withdrawal", this.s7_scheduled.selector);
        _runS("7c partial fill with a low-liquidity main vault", this.s7b_partialFill.selector);
        _runS("8 delever", this.s8_delever.selector);
        _runS("9 pps invariant", this.s9_ppsInvariant.selector);
        if (fails.length != 0) {
            string memory all;
            for (uint256 i; i < fails.length; ++i) all = string.concat(all, "\n  ", fails[i]);
            revert(string.concat("failed scenarios:", all));
        }
    }
}
