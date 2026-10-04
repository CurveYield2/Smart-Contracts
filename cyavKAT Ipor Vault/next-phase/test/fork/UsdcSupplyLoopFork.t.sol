// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Test.sol";
import {IMorpho, MarketParams, Id, Market, Position} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-org/morpho-blue/src/interfaces/IOracle.sol";
import {FuseAction} from "../../src/interfaces/CurveYieldPhase2Interfaces.sol";
import {CurveYieldConfigKeys as K} from "../../src/governance/CurveYieldGateConfig.sol";
import {CurveYieldUsdcSupplyLoopFuse} from "../../src/morpho/CurveYieldUsdcSupplyLoopFuse.sol";
import {Phase2ForkBase, IErcFork} from "../helpers/Phase2ForkBase.sol";

struct UsdcLoopData {
    bytes32 morphoMarketId;
    uint256 collateralAmount;
}

struct InstantWithdrawalFusesParamsU {
    address fuse;
    bytes32[] params;
}

interface IVaultCfgU {
    function configureInstantWithdrawalFuses(InstantWithdrawalFusesParamsU[] calldata fuses) external;
    function isFuseSupported(address) external view returns (bool);
    function getMarketSubstrates(uint256) external view returns (bytes32[] memory);
}

/// @notice USDC_SUPPLY_LOOP_SPEC fork test: the CurveYieldUsdcSupplyLoopFuse (market 14, Morpho avKAT / vbUSDC market) on
/// the cyavKAT vault as installed by the real scripts (P2_01 deploys it, P2_02 adds it, grants the market substrate and
/// the vbUSDC price source). The executor (ALPHA) drives it. Scenario-isolated; the final revert lists the failures.
contract UsdcSupplyLoopForkTest is Phase2ForkBase {
    bytes32 internal constant USDC_MARKET = 0xbd48214a2f12e951da20ad0b8fd83b611c693b5bbaa280b68ba4075678f2a138;

    CurveYieldUsdcSupplyLoopFuse fuse;
    MarketParams mp;
    Id mid = Id.wrap(USDC_MARKET);

    function setUp() public {
        _setUpFork("usdcloop");
        fuse = CurveYieldUsdcSupplyLoopFuse(_p2("usdcLoopFuse"));
        mp = IMorpho(MORPHO).idToMarketParams(mid);
    }

    // ---------------------------------------------------------------- helpers

    struct Pos {
        uint256 collateral;
        uint256 debt;
        uint256 supplied;
    }

    function _pos() internal returns (Pos memory p_) {
        IMorpho(MORPHO).accrueInterest(mp);
        Position memory pos = IMorpho(MORPHO).position(mid, VAULT);
        Market memory m = IMorpho(MORPHO).market(mid);
        p_.collateral = pos.collateral;
        p_.debt = (uint256(pos.borrowShares) * (uint256(m.totalBorrowAssets) + 1) + (uint256(m.totalBorrowShares) + 1e6) - 1) / (uint256(m.totalBorrowShares) + 1e6);
        p_.supplied = pos.supplyShares * (uint256(m.totalSupplyAssets) + 1) / (uint256(m.totalSupplyShares) + 1e6);
    }

    function _ltvBps(Pos memory p_) internal view returns (uint256) {
        uint256 value = p_.collateral * IOracle(mp.oracle).price() / 1e36;
        return value == 0 ? 0 : p_.debt * 10_000 / value;
    }

    function _enter(uint256 avkat_) internal {
        FuseAction[] memory a = new FuseAction[](1);
        a[0] = FuseAction(address(fuse), abi.encodeWithSignature("enter((bytes32,uint256))", UsdcLoopData(USDC_MARKET, avkat_)));
        vm.prank(address(exec));
        cy.execute(a);
    }

    function _exit(uint256 avkat_) internal {
        FuseAction[] memory a = new FuseAction[](1);
        a[0] = FuseAction(address(fuse), abi.encodeWithSignature("exit((bytes32,uint256))", UsdcLoopData(USDC_MARKET, avkat_)));
        vm.prank(address(exec));
        cy.execute(a);
    }

    /// @dev PPS unchanged: within 1 ppm after revaluing every market (USD price conversions truncate).
    function _ppsUnchanged(uint256 before_, string memory what_) internal {
        uint256 now_ = _ppsFresh();
        uint256 d = now_ > before_ ? now_ - before_ : before_ - now_;
        require(d <= before_ / 1_000_000 + 2, string.concat("PPS changed ", what_, ": ", _u(before_), " -> ", _u(now_)));
    }

    function _fund(uint256 avkat_) internal returns (uint256 shares_) {
        shares_ = _depositAvkat(alice, avkat_);
    }

    // ---------------------------------------------------------------- scenarios

    function u0_installed() external view {
        require(IVaultCfgU(VAULT).isFuseSupported(address(fuse)), "the USDC loop fuse is not a vault fuse");
        bytes32[] memory subs = IVaultCfgU(VAULT).getMarketSubstrates(14);
        bool found;
        for (uint256 i; i < subs.length; ++i) if (subs[i] == USDC_MARKET) found = true;
        require(found, "the avKAT/vbUSDC market is not a substrate of market 14");
        require(fuse.MARKET_ID() == 14 && fuse.GATE() == address(gate), "fuse wiring");
        require(mp.collateralToken == AVKAT, "market collateral is not avKAT");
    }

    function u1_enter_ltv33_supplyEqualsDebt_ppsUnchanged() external {
        _fund(100e18);
        uint256 pps0 = _ppsFresh();
        _enter(88e18);
        Pos memory p = _pos();
        console2.log("collateral / debt / supplied", p.collateral, p.debt, p.supplied);
        console2.log("LTV bps", _ltvBps(p));
        require(p.collateral == 88e18, "collateral != 88 avKAT");
        uint256 ltv = _ltvBps(p);
        require(ltv >= 3_250 && ltv <= 3_310, string.concat("LTV not ~33%: ", _u(ltv)));
        require(p.debt != 0, "nothing borrowed");
        uint256 d = p.debt > p.supplied ? p.debt - p.supplied : p.supplied - p.debt;
        require(d <= p.debt / 1_000 + 2, "the borrowed tokens were not supplied back (supply != debt)");
        _ppsUnchanged(pps0, "by enter");
    }

    function u2_partialAndFullExit_ppsUnchanged_collateralReturned() external {
        _fund(100e18);
        _enter(88e18);
        uint256 pps0 = _ppsFresh();
        uint256 idle0 = _avkat(VAULT);
        _exit(40e18);
        Pos memory p = _pos();
        require(_avkat(VAULT) - idle0 >= 40e18 - 1, "partial exit did not return 40 avKAT");
        require(p.collateral == 48e18, "partial exit left the wrong collateral");
        uint256 ltv = _ltvBps(p);
        require(ltv >= 3_250 && ltv <= 3_320, string.concat("LTV drifted after the proportional exit: ", _u(ltv)));
        _ppsUnchanged(pps0, "by a partial exit");
        // full exit (same block: no interest gap)
        _exit(48e18);
        p = _pos();
        require(p.collateral <= 1e16 && p.debt <= 10, string.concat("position not closed: coll ", _u(p.collateral), " debt ", _u(p.debt)));
        require(_avkat(VAULT) - idle0 >= 88e18 - 1e16, "full exit did not return all the collateral");
        _ppsUnchanged(pps0, "by a full exit");
    }

    function u3_fullExit_afterInterest_returnsEverythingButTheResidualGap() external {
        _fund(100e18);
        _enter(88e18);
        _warpBy(30 days);
        uint256 idle0 = _avkat(VAULT);
        uint256 pps0 = _ppsFresh();
        _exit(88e18);
        Pos memory p = _pos();
        uint256 back = _avkat(VAULT) - idle0;
        console2.log("after 30 days: collateral returned / left / residual debt", back, p.collateral, p.debt);
        // what stays locked is exactly what the residual debt (interest above the supplied value) needs at the 35% cap
        require(back + p.collateral >= 88e18 - 1, "collateral went missing");
        require(back >= 88e18 * 90 / 100, "the full exit returned less than 90% of the collateral");
        if (p.debt != 0) {
            uint256 value = p.collateral * IOracle(mp.oracle).price() / 1e36;
            require(p.debt * 10_000 <= value * 3_500 + 1e6, "the residual position is above the 35% LTV cap");
        } else {
            require(p.collateral <= 1e12, "no debt left but collateral stayed");
        }
        _ppsUnchanged(pps0, "by a full exit after interest");
    }

    function u4_instantWithdrawThroughVaultRedeem() external {
        // the vault's instant-withdrawal list: the loop fuse first (params [amount, morphoMarketId]), then the Phase 2 sources
        InstantWithdrawalFusesParamsU[] memory iw = new InstantWithdrawalFusesParamsU[](4);
        bytes32[] memory loopParams = new bytes32[](2);
        loopParams[1] = USDC_MARKET;
        iw[0] = InstantWithdrawalFusesParamsU(address(fuse), loopParams);
        bytes32[] memory lendParams = new bytes32[](2);
        lendParams[1] = vm.parseJsonBytes32(lendj, ".lendMorphoMarket");
        iw[1] = InstantWithdrawalFusesParamsU(_p2("lendSupplyFuse"), lendParams);
        bytes32[] memory vkatParams = new bytes32[](2);
        vkatParams[1] = bytes32(uint256(uint160(_p2("vkatController"))));
        iw[2] = InstantWithdrawalFusesParamsU(_p2("plannedInstantFuse"), vkatParams);
        bytes32[] memory lpParams = new bytes32[](2);
        lpParams[1] = bytes32(uint256(uint160(_p2("lpController"))));
        iw[3] = InstantWithdrawalFusesParamsU(_p2("plannedInstantFuse"), lpParams);
        vm.prank(DEPLOYER);
        IVaultCfgU(VAULT).configureInstantWithdrawalFuses(iw);

        uint256 shares = _fund(100e18);
        _enter(_avkat(VAULT)); // all idle into the loop (the vault holds ~no other idle)
        uint256 idle = _avkat(VAULT);
        require(idle < 5e18, "setup: idle was not deployed");
        uint256 pps0 = _ppsFresh();
        uint256 gross = cy.previewRedeem(shares / 2);
        uint256 a0 = _avkat(alice);
        vm.prank(alice);
        cy.redeem(shares / 2, alice, alice);
        uint256 got = _avkat(alice) - a0;
        uint256 feeBps = _getGate(K.WM_WITHDRAW_FEE) / 1e14;
        console2.log("instant redeem through the USDC loop: gross / received / fee bps", gross, got, feeBps);
        require(got >= gross * (10_000 - feeBps) / 10_000 - gross / 1_000, "received far below gross x (1 - fee)");
        require(got <= gross, "received more than the gross value");
        // PPS: only the (burned) instant fee may move it, and only up
        uint256 now_ = _ppsFresh();
        require(now_ + pps0 / 1_000_000 + 2 >= pps0, string.concat("PPS dropped on instantWithdraw: ", _u(pps0), " -> ", _u(now_)));
        require(now_ <= pps0 + pps0 * (feeBps + 5) / 10_000, "PPS rose by more than the burned fee");
        Pos memory p = _pos();
        require(p.collateral < 100e18, "the position was not reduced");
    }

    function u5_tvlCap_revert() external {
        _fund(500e18);
        _setGate(K.USDC_LOOP_MAX_TVL_BPS, 100); // 1% of TVL ~ 140 avKAT
        uint256 cap = cy.totalAssets() * 100 / 10_000;
        FuseAction[] memory a = new FuseAction[](1);
        a[0] = FuseAction(address(fuse), abi.encodeWithSignature("enter((bytes32,uint256))", UsdcLoopData(USDC_MARKET, cap + 1e18)));
        vm.prank(address(exec));
        (bool ok, bytes memory ret) = address(cy).call(abi.encodeCall(cy.execute, (a)));
        require(!ok, "an enter above the TVL cap did not revert");
        require(_containsSel(ret, CurveYieldUsdcSupplyLoopFuse.TvlCapExceeded.selector), string.concat("wrong revert: ", vm.toString(ret)));
        // a second enter that stays under the cap works, and the cap counts the whole position (not only the new amount)
        _enter(cap / 2);
        a[0] = FuseAction(address(fuse), abi.encodeWithSignature("enter((bytes32,uint256))", UsdcLoopData(USDC_MARKET, cap / 2 + 2e18)));
        vm.prank(address(exec));
        (ok,) = address(cy).call(abi.encodeCall(cy.execute, (a)));
        require(!ok, "the cap must apply to the total collateral");
    }

    function u6_ltvCap_revert_whenThePriceFalls() external {
        _fund(200e18);
        _enter(88e18);
        // the market oracle price falls 10%: the position is now above the 35% cap, so adding collateral reverts
        uint256 px = IOracle(mp.oracle).price();
        vm.mockCall(mp.oracle, abi.encodeWithSignature("price()"), abi.encode(px * 90 / 100));
        FuseAction[] memory a = new FuseAction[](1);
        a[0] = FuseAction(address(fuse), abi.encodeWithSignature("enter((bytes32,uint256))", UsdcLoopData(USDC_MARKET, 1e18)));
        vm.prank(address(exec));
        (bool ok, bytes memory ret) = address(cy).call(abi.encodeCall(cy.execute, (a)));
        require(!ok, "an enter above the LTV cap did not revert");
        require(_containsSel(ret, CurveYieldUsdcSupplyLoopFuse.LtvAboveCap.selector), string.concat("wrong revert: ", vm.toString(ret)));
        // a substrate that is not granted is refused too
        a[0] = FuseAction(address(fuse), abi.encodeWithSignature("enter((bytes32,uint256))", UsdcLoopData(bytes32(uint256(1)), 1e18)));
        vm.prank(address(exec));
        (ok, ret) = address(cy).call(abi.encodeCall(cy.execute, (a)));
        require(!ok && _containsSel(ret, CurveYieldUsdcSupplyLoopFuse.UnsupportedMarket.selector), "ungranted market not refused");
    }

    function u7_lowLiquidity_enterAndExitStillWork_valueConserved() external {
        // another account borrows almost all of the market's free liquidity
        Market memory m = IMorpho(MORPHO).market(mid);
        uint256 free = uint256(m.totalSupplyAssets) - uint256(m.totalBorrowAssets);
        address whale = makeAddr("whale");
        deal(AVKAT, whale, 1_000_000_000e18);
        vm.startPrank(whale);
        IErcFork(AVKAT).approve(MORPHO, type(uint256).max);
        IMorpho(MORPHO).supplyCollateral(mp, 1_000_000_000e18, whale, "");
        uint256 take = free > 1_000 ? free - 1_000 : 0;
        if (take != 0) IMorpho(MORPHO).borrow(mp, take, 0, whale, whale);
        vm.stopPrank();
        m = IMorpho(MORPHO).market(mid);
        console2.log("free liquidity before / after the whale", free, uint256(m.totalSupplyAssets) - uint256(m.totalBorrowAssets));

        _fund(100e18);
        uint256 pps0 = _ppsFresh();
        _enter(88e18); // borrows in chunks of the (tiny) free liquidity, at most 8 of them: a smaller debt, never a revert
        Pos memory p = _pos();
        console2.log("low liquidity: collateral / debt / supplied", p.collateral, p.debt, p.supplied);
        require(p.collateral == 88e18, "collateral not supplied");
        require(_ltvBps(p) <= 3_310, "LTV above the target");
        _ppsUnchanged(pps0, "by enter in a low-liquidity market");
        uint256 idle0 = _avkat(VAULT);
        _exit(88e18);
        p = _pos();
        require(_avkat(VAULT) > idle0, "nothing came back from the exit");
        require(_ltvBps(p) <= 3_510, "LTV above the cap after a limited exit");
        _ppsUnchanged(pps0, "by exit in a low-liquidity market");
    }

    function _containsSel(bytes memory ret_, bytes4 sel_) internal pure returns (bool) {
        if (ret_.length < 4) return false;
        if (bytes4(ret_) == sel_) return true;
        for (uint256 i; i + 4 <= ret_.length; ++i) {
            bytes4 s;
            assembly {
                s := mload(add(add(ret_, 32), i))
            }
            if (s == sel_) return true;
        }
        return false;
    }

    function test_usdcSupplyLoop() public {
        _runS("0 installed by the scripts", this.u0_installed.selector);
        _runS("1 enter: LTV 33%, supply = debt, PPS unchanged", this.u1_enter_ltv33_supplyEqualsDebt_ppsUnchanged.selector);
        _runS("2 partial and full exit, PPS unchanged", this.u2_partialAndFullExit_ppsUnchanged_collateralReturned.selector);
        _runS("3 full exit after interest", this.u3_fullExit_afterInterest_returnsEverythingButTheResidualGap.selector);
        _runS("4 instant withdrawal through vault redeem", this.u4_instantWithdrawThroughVaultRedeem.selector);
        _runS("5 TVL cap", this.u5_tvlCap_revert.selector);
        _runS("6 LTV cap and unsupported market", this.u6_ltvCap_revert_whenThePriceFalls.selector);
        _runS("7 low liquidity", this.u7_lowLiquidity_enterAndExitStillWork_valueConserved.selector);
        _finish();
    }
}
