// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Test.sol";
import {CurveYieldConfigKeys as K} from "../../src/governance/CurveYieldGateConfig.sol";
import {LbBase, Cy20} from "./LbBase.sol";
import {CurveYieldLeaderboard, CySeasonParams, CyTiers} from "../../src/leaderboard/CurveYieldLeaderboard.sol";
import {CurveYieldSeasonPoints} from "../../src/leaderboard/CurveYieldSeasonPoints.sol";

/// @notice Ramp, holding (min rule, tranches), buying, admin allocation, top-100, seasons, accounting pagination.
contract LeaderboardTest is LbBase {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    // ---------------------------------------------------------------- 1. ramp

    function test_rateAt_startCliffsMidpointsEnd() public {
        _startSeason(_params());
        uint256 s = T0;
        assertEq(lb.rateAt(1, s - 1 days), 5_000, "before the start");
        assertEq(lb.rateAt(1, s), 5_000, "start");
        assertEq(lb.rateAt(1, s + 14 days), 6_000, "midway start -> cliff 0");
        assertEq(lb.rateAt(1, s + 28 days), 7_000, "cliff 0");
        assertEq(lb.rateAt(1, s + 56 days), 8_000, "midway cliff 0 -> cliff 1");
        assertEq(lb.rateAt(1, s + 84 days), 9_000, "cliff 1");
        assertEq(lb.rateAt(1, s + 112 days), 9_500, "midway cliff 1 -> end (end = +140 days)");
        assertEq(lb.rateAt(1, s + 140 days), 10_000, "end");
        assertEq(lb.rateAt(1, s + 500 days), 10_000, "after the end");
        // quarter points, exact integer math
        assertEq(lb.rateAt(1, s + 7 days), 5_500);
        assertEq(lb.rateAt(1, s + 42 days), 7_500);
    }

    function test_rateAt_cliffAtFullRateStaysFull_andNoCliffRamp() public {
        CySeasonParams memory p = _params();
        p.cliffCount = 1;
        p.cliffAt = [uint48(T0 + 28 days), uint48(0), uint48(0)];
        p.cliffRateBps = [uint16(10_000), 0, 0];
        _startSeason(p);
        assertEq(lb.rateAt(1, T0 + 28 days), 10_000);
        assertEq(lb.rateAt(1, T0 + 60 days), 10_000, "a 100% cliff before the end must stay 100%");
        assertEq(lb.rateAt(1, T0 + 139 days), 10_000);
        assertEq(lb.rateAt(1, T0 + 14 days), 7_500);

        // no cliffs: linear from the initial rate to 100% at the end
        vm.warp(T0 + 140 days);
        t = T0 + 140 days;
        CySeasonParams memory q = _params();
        q.start = uint48(t);
        q.end = uint48(t + 10 * EPOCH);
        q.cliffCount = 0;
        q.initialRateBps = 4_000;
        lb.startSeason(q, "s2", "S2");
        assertEq(lb.rateAt(2, t + 70 days), 7_000);
        assertEq(lb.rateAt(2, t), 4_000);
    }

    function test_invalidCliffsAndRamp_revertBadParams() public {
        // decreasing cliff rate
        CySeasonParams memory p = _params();
        p.cliffRateBps = [uint16(7_000), 6_000, 0];
        vm.expectRevert(abi.encodeWithSelector(CurveYieldLeaderboard.BadParams.selector, "cliff"));
        lb.startSeason(p, "x", "X");
        // not ordered in time
        p = _params();
        p.cliffAt = [uint48(T0 + 84 days), uint48(T0 + 28 days), uint48(0)];
        vm.expectRevert(abi.encodeWithSelector(CurveYieldLeaderboard.BadParams.selector, "cliff"));
        lb.startSeason(p, "x", "X");
        // equal times
        p = _params();
        p.cliffAt = [uint48(T0 + 28 days), uint48(T0 + 28 days), uint48(0)];
        vm.expectRevert(abi.encodeWithSelector(CurveYieldLeaderboard.BadParams.selector, "cliff"));
        lb.startSeason(p, "x", "X");
        // at or before the start
        p = _params();
        p.cliffAt = [uint48(T0), uint48(T0 + 28 days), uint48(0)];
        vm.expectRevert(abi.encodeWithSelector(CurveYieldLeaderboard.BadParams.selector, "cliff"));
        lb.startSeason(p, "x", "X");
        // past the end
        p = _params();
        p.cliffAt = [uint48(T0 + 28 days), uint48(T0 + 141 days), uint48(0)];
        vm.expectRevert(abi.encodeWithSelector(CurveYieldLeaderboard.BadParams.selector, "cliff"));
        lb.startSeason(p, "x", "X");
        // a cliff rate above 100%
        p = _params();
        p.cliffRateBps = [uint16(7_000), 10_001, 0];
        vm.expectRevert(abi.encodeWithSelector(CurveYieldLeaderboard.BadParams.selector, "cliff"));
        lb.startSeason(p, "x", "X");
        // a cliff below the initial rate
        p = _params();
        p.cliffRateBps = [uint16(4_999), 9_000, 0];
        vm.expectRevert(abi.encodeWithSelector(CurveYieldLeaderboard.BadParams.selector, "cliff"));
        lb.startSeason(p, "x", "X");
        // more than 3 cliffs, initial rate above 100%
        p = _params();
        p.cliffCount = 4;
        vm.expectRevert(abi.encodeWithSelector(CurveYieldLeaderboard.BadParams.selector, "ramp"));
        lb.startSeason(p, "x", "X");
        p = _params();
        p.initialRateBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(CurveYieldLeaderboard.BadParams.selector, "ramp"));
        lb.startSeason(p, "x", "X");
        // the cliff exactly at the end is allowed
        p = _params();
        p.cliffAt = [uint48(T0 + 28 days), uint48(T0 + 140 days), uint48(0)];
        _startSeason(p);
        assertEq(lb.rateAt(1, T0 + 140 days), 10_000);
    }

    // ---------------------------------------------------------------- 2. holding

    function _oneEpochPoints(uint256 amount_, uint256 ep_, uint256 age_) internal view returns (uint256) {
        return _pts(amount_, age_, _rateMid(1, T0, ep_), 500);
    }

    function test_holding_registerHoldAccount_over1_3_5_epochs_isExact() public {
        uint256[3] memory ns = [uint256(1), 3, 5];
        for (uint256 k; k < ns.length; ++k) {
            uint256 snap = vm.snapshot();
            _startSeason(_params());
            uint256 amount = 100 * SHARE;
            _register(alice, amount);
            _warp(T0 + ns[k] * EPOCH);
            lb.accountArray(_one(alice));
            uint256 expected;
            for (uint256 ep; ep < ns[k]; ++ep) expected += _oneEpochPoints(amount, ep, ep);
            assertEq(_hold(alice), expected, "points != pointsPerShareEpoch x amount x (1 + bonus x age) x rate(mid)");
            assertEq(lb.pointsOf(1, alice), expected);
            assertEq(lb.totalPoints(1), expected);
            assertEq(lb.seasonToken(1).balanceOf(alice), expected);
            (,uint32 lastEpoch,, uint256 lastBalance) = lb.holders(alice);
            assertEq(lastEpoch, ns[k]);
            assertEq(lastBalance, amount);
            vm.revertTo(snap);
        }
    }

    /// @dev Hand-checked: 100 cyavKAT, 1 epoch at rate(mid of epoch 0) = 5,500 bps, age 0 -> 100 x 100 x 0.55 = 5,500.
    function test_holding_handComputedFirstEpoch() public {
        _startSeason(_params());
        _register(alice, 100 * SHARE);
        _warp(T0 + EPOCH);
        lb.accountArray(_one(alice));
        assertEq(_hold(alice), 5_500e18);
        // epoch 1 (mid = +21 days: rate 6,500), age 1 (+5%): 10,000 x 1.05 x 0.65 = 6,825
        _warp(T0 + 2 * EPOCH);
        lb.accountArray(_one(alice));
        assertEq(_hold(alice), 5_500e18 + 6_825e18);
    }

    function test_holding_accountingTwiceInOneEpochCreditsNothing() public {
        _startSeason(_params());
        _register(alice, 100 * SHARE);
        _warp(T0 + EPOCH + 1 days);
        lb.accountArray(_one(alice));
        uint256 p1 = _hold(alice);
        assertGt(p1, 0);
        uint256 total1 = lb.totalPoints(1);
        lb.accountArray(_one(alice));
        lb.accountAll(0, 10);
        assertEq(_hold(alice), p1, "second accounting credited again");
        assertEq(lb.totalPoints(1), total1);
        // partial epoch elapsed: still nothing until the next boundary
        _warp(T0 + EPOCH + 13 days);
        lb.accountArray(_one(alice));
        assertEq(_hold(alice), p1);
    }

    function test_holding_justInTimeDepositEarnsZeroForThatEpoch() public {
        CySeasonParams memory p = _params();
        p.minBalance = 0;
        _startSeason(p);
        _register(alice, 0); // registers with nothing
        _warp(T0 + EPOCH - 1);
        _fund(alice, 1_000 * SHARE); // a big deposit right before the epoch ends
        _warp(T0 + EPOCH);
        lb.accountArray(_one(alice));
        assertEq(_hold(alice), 0, "just-in-time deposit earned points (min rule)");
        // it earns from the next epoch on (age 0, no bonus)
        _warp(T0 + 2 * EPOCH);
        lb.accountArray(_one(alice));
        assertEq(_hold(alice), _oneEpochPoints(1_000 * SHARE, 1, 0));
    }

    function test_holding_increaseAddsAgeZeroTrancheWithoutBonus() public {
        _startSeason(_params());
        _register(alice, 100 * SHARE);
        _warp(T0 + EPOCH);
        lb.accountArray(_one(alice)); // A: age 0 -> 1
        uint256 h1 = _hold(alice);
        cy.mint(alice, 50 * SHARE); // +50: earns nothing this epoch (min rule), then becomes tranche B at age 0
        _warp(T0 + 2 * EPOCH);
        lb.accountArray(_one(alice));
        uint256 e1 = _oneEpochPoints(100 * SHARE, 1, 1); // A only, age 1
        assertEq(_hold(alice) - h1, e1, "the new deposit earned in its first epoch");
        // epoch 2: A(100, age 2) + B(50, age 0)
        _warp(T0 + 3 * EPOCH);
        uint256 h2 = _hold(alice);
        lb.accountArray(_one(alice));
        assertEq(_hold(alice) - h2, _oneEpochPoints(100 * SHARE, 2, 2) + _oneEpochPoints(50 * SHARE, 2, 0));
    }

    function test_holding_decreaseRemovesNewestTranchesFirst_oldestKeepsItsAge() public {
        _startSeason(_params());
        _register(alice, 100 * SHARE);
        _warp(T0 + EPOCH);
        lb.accountArray(_one(alice)); // A(100, age1)
        cy.mint(alice, 50 * SHARE);
        _warp(T0 + 2 * EPOCH);
        lb.accountArray(_one(alice)); // A(100, age2), B(50, age0)
        // balance 150 -> 120: 30 comes off the newest tranche B
        vm.prank(alice);
        cy.transfer(bob, 30 * SHARE);
        uint256 h = _hold(alice);
        _warp(T0 + 3 * EPOCH);
        lb.accountArray(_one(alice)); // ep 2: A(100, age 2) + B(20, age 0)
        assertEq(_hold(alice) - h, _oneEpochPoints(100 * SHARE, 2, 2) + _oneEpochPoints(20 * SHARE, 2, 0), "newest tranche not cut first");
        // 120 -> 60: B (20) goes entirely, then A is cut to 60 and KEEPS its age (3)
        vm.prank(alice);
        cy.transfer(bob, 60 * SHARE);
        h = _hold(alice);
        _warp(T0 + 4 * EPOCH);
        lb.accountArray(_one(alice)); // ep 3: A(60, age 3)
        assertEq(_hold(alice) - h, _oneEpochPoints(60 * SHARE, 3, 3), "oldest tranche lost its age or bonus");
    }

    function test_holding_trancheCap8_mergesIntoTheNewestAtAgeZero() public {
        CySeasonParams memory p = _params();
        p.end = uint48(T0 + 30 * EPOCH);
        p.cliffAt = [uint48(T0 + 28 days), uint48(T0 + 84 days), uint48(0)];
        _startSeason(p);
        _register(alice, 10 * SHARE);
        // each epoch: +10 -> a new tranche after each accounting; tranches: 1 (reg) + 7 = 8 after 7 epochs
        uint256[] memory amounts = new uint256[](20);
        uint256[] memory ages = new uint256[](20);
        uint256 n = 1;
        amounts[0] = 10 * SHARE;
        for (uint256 ep; ep < 10; ++ep) {
            cy.mint(alice, 10 * SHARE);
            uint256 h = _hold(alice);
            _warp(T0 + (ep + 1) * EPOCH);
            lb.accountArray(_one(alice));
            // reference: earn on the tranches as they were (held = min(prev balance, new balance) = prev balance)
            uint256 expected;
            for (uint256 i; i < n; ++i) {
                expected += _oneEpochPoints(amounts[i], ep, ages[i]);
                ages[i] += 1;
            }
            assertEq(_hold(alice) - h, expected, string.concat("epoch ", vm.toString(ep)));
            // then the deposit of this epoch enters: a new tranche, or (at the cap) merged into the newest at age 0
            if (n < 8) {
                amounts[n] = 10 * SHARE;
                ages[n] = 0;
                ++n;
            } else {
                amounts[n - 1] += 10 * SHARE;
                ages[n - 1] = 0;
            }
        }
        assertEq(n, 8, "reference did not reach the cap");
    }

    function test_holding_dropsToZeroAndReturns() public {
        CySeasonParams memory p = _params();
        p.minBalance = 0;
        _startSeason(p);
        _register(alice, 100 * SHARE);
        vm.prank(alice);
        cy.transfer(bob, 100 * SHARE); // everything leaves
        _warp(T0 + EPOCH);
        lb.accountArray(_one(alice));
        assertEq(_hold(alice), 0, "held nothing at the end of the epoch");
        cy.mint(alice, 40 * SHARE);
        _warp(T0 + 2 * EPOCH);
        lb.accountArray(_one(alice)); // earns 0 for that epoch (min(0, 40)), tranche 40 starts
        assertEq(_hold(alice), 0);
        _warp(T0 + 3 * EPOCH);
        lb.accountArray(_one(alice));
        assertEq(_hold(alice), _oneEpochPoints(40 * SHARE, 2, 0));
    }

    // ---------------------------------------------------------------- 5. buying points

    function _buyDestinationsBalances() internal view returns (uint256 a, uint256 s, uint256 g, uint256 b) {
        return (cy.balanceOf(adminRx), cy.balanceOf(specialRx), cy.balanceOf(growthRx), cy.balanceOf(boosterRx));
    }

    function test_buyPoints_splits30_40_20_10_dustToLast() public {
        _startSeason(_params());
        _register(alice, 10 * SHARE);
        _fund(alice, 2_000);
        vm.prank(alice);
        lb.buyPoints(1_001); // 300.3 / 400.4 / 200.2 -> 300 / 400 / 200 and the rest (101) to the booster
        (uint256 a, uint256 s, uint256 g, uint256 b) = _buyDestinationsBalances();
        assertEq(a, 300);
        assertEq(s, 400);
        assertEq(g, 200);
        assertEq(b, 101, "dust must go to the last bucket");
        assertEq(cy.balanceOf(address(lb)), 0);
        // a round amount splits exactly
        vm.prank(alice);
        lb.buyPoints(1_000);
        (a, s, g, b) = _buyDestinationsBalances();
        assertEq(a, 600);
        assertEq(s, 800);
        assertEq(g, 400);
        assertEq(b, 201, "101 from the first buy + 100 from the second");
        // a 1-unit purchase: everything is dust and lands in the last bucket
        vm.prank(alice);
        lb.buyPoints(1);
        (a, s, g, b) = _buyDestinationsBalances();
        assertEq(a + s + g, 1_800, "1-unit purchase leaked to the first buckets");
        assertEq(b, 202);
    }

    function test_buyPoints_tieredRateFollowsBuyTiersAgainstHoldAndRef() public {
        _startSeason(_params());
        _register(alice, 100 * SHARE);
        _warp(T0 + EPOCH);
        lb.accountArray(_one(alice)); // hold = 5,500e18 = own
        uint256 own = _hold(alice);
        assertEq(own, 5_500e18);
        // buyRate = 100 x PPS per 1 cyavKAT => raw = amount x 100 x 100e18 / 1e20 = amount x 1e20 x 1e2... use whole cyavKAT:
        // 1 cyavKAT (1e20) spent = 10,000e18 raw points at full rate.
        // tiers vs own = 5,500e18: full until 30% = 1,650e18; then -30% until 100% = 5,500e18; then -70% (cut1 + cut2 = 70%).
        _fund(alice, 10 * SHARE);
        // spend 0.1 cyavKAT: raw 1,000e18 -> all inside the full-rate zone (1,650e18)
        vm.prank(alice);
        uint256 p1 = lb.buyPoints(SHARE / 10);
        assertEq(p1, 1_000e18, "inside the full-rate tier");
        // spend 0.2 cyavKAT: raw 2,000e18 with 650e18 of room left at full rate, the rest at 70%
        vm.prank(alice);
        uint256 p2 = lb.buyPoints(SHARE / 5);
        uint256 rest = 2_000e18 - 650e18;
        assertEq(p2, 650e18 + rest * 7_000 / BPS, "crossing the first boundary");
        // now cum = 1,650e18 + 1,350e18 x 0.7 = 2,595e18: in the cut1 tier (room to 5,500e18 = 2,905e18 of credit)
        uint256 cum = 1_000e18 + p2;
        assertEq(cum, 2_595e18);
        // spend 1 cyavKAT: raw 10,000e18; room in the tier = 5,500e18 - 2,595e18 = 2,905e18 credited = 4,150e18 raw
        vm.prank(alice);
        uint256 p3 = lb.buyPoints(SHARE);
        uint256 rawForRoom = 2_905e18 * BPS / 7_000;
        uint256 tier1 = rawForRoom * 7_000 / BPS;
        uint256 tier2 = (10_000e18 - rawForRoom) * 3_000 / BPS;
        assertEq(p3, tier1 + tier2, "crossing the second boundary");
        assertEq(lb.pointsBreakdown(1, alice).buy, p1 + p2 + p3);
    }

    function test_buyPoints_requiresRegistrationAndAnActiveSeason() public {
        _fund(alice, SHARE);
        vm.prank(alice);
        vm.expectRevert(CurveYieldLeaderboard.NoActiveSeason.selector);
        lb.buyPoints(1);
        _startSeason(_params()); // minimum 10 cyavKAT: fund alice enough to register
        _fund(alice, 10 * SHARE);
        vm.prank(alice);
        vm.expectRevert(CurveYieldLeaderboard.NotRegistered.selector);
        lb.buyPoints(1);
        vm.prank(alice);
        lb.register();
        vm.prank(alice);
        lb.buyPoints(1);
        // after the season ends
        _warp(T0 + 10 * EPOCH);
        vm.prank(alice);
        vm.expectRevert(CurveYieldLeaderboard.NoActiveSeason.selector);
        lb.buyPoints(1);
    }

    /// @notice D-lock: the buy split (gate keys, SUM_EQ 10,000, each <= 5,000) cannot change while a season is active.
    function test_buySplit_gateKeys_lockedDuringASeason_boundsAndSum() public {
        _setSplit(2_500, 2_500, 2_500, 2_500); // before any season
        assertEq(lb.buySplitBps()[0], 2_500);
        vm.expectRevert(); // above the hard cap 5,000
        _setSplit(5_001, 2_000, 2_000, 999);
        _setSplit(5_000, 5_000, 0, 0); // each <= 50%
        vm.expectRevert(); // sum != 10,000
        _setSplit(3_000, 4_000, 2_000, 999);
        vm.prank(alice);
        vm.expectRevert(); // not DAO / fee authority
        gate.setConfigs(_k1(K.LEADERBOARD_BUY_SPLIT_1), _v1(2_500));

        _startSeason(_params());
        assertTrue(lb.seasonActive());
        vm.expectRevert(); // locked while the season runs
        _setSplit(2_500, 2_500, 2_500, 2_500);
        _warp(T0 + 10 * EPOCH);
        assertFalse(lb.seasonActive());
        _setSplit(2_500, 2_500, 2_500, 2_500); // allowed again once the season is over
    }

    // ---------------------------------------------------------------- 6. admin allocation

    function test_adminAllocate_allocatorOnly_andTheCapIsExactAtTheBoundary() public {
        _startSeason(_params()); // adminCapBps 2,000
        _register(alice, 100 * SHARE);
        _register(bob, 300 * SHARE);
        _warp(T0 + EPOCH);
        lb.accountAll(0, 10);
        uint256 total = lb.totalPoints(1);
        assertGt(total, 0);

        address[] memory us = new address[](1);
        us[0] = carol;
        uint256[] memory amts = new uint256[](1);
        amts[0] = 1;
        vm.expectRevert(CurveYieldLeaderboard.NotAllocator.selector);
        lb.adminAllocate(us, amts);
        vm.prank(bob);
        vm.expectRevert(CurveYieldLeaderboard.NotAllocator.selector);
        lb.adminAllocate(us, amts);

        // (admin + x) x 10,000 <= 2,000 x (total + x)  <=>  x <= total / 4
        uint256 x = total / 4;
        amts[0] = x + 1;
        vm.prank(allocator);
        vm.expectRevert(CurveYieldLeaderboard.AdminCapExceeded.selector);
        lb.adminAllocate(us, amts);
        amts[0] = x;
        vm.prank(allocator);
        lb.adminAllocate(us, amts);
        assertEq(lb.adminPoints(1), x);
        assertEq(lb.pointsBreakdown(1, carol).admin, x);
        assertEq(lb.totalPoints(1), total + x);
        // the cap now binds on the running totals: another unit beyond the boundary reverts
        uint256 total2 = lb.totalPoints(1);
        uint256 room = (2_000 * total2 - 10_000 * lb.adminPoints(1)) / 8_000;
        amts[0] = room + 1;
        vm.prank(allocator);
        vm.expectRevert(CurveYieldLeaderboard.AdminCapExceeded.selector);
        lb.adminAllocate(us, amts);
        amts[0] = room;
        vm.prank(allocator);
        lb.adminAllocate(us, amts);
        // batch: the cap is on the batch sum
        uint256 t3 = lb.totalPoints(1);
        uint256 r3 = (2_000 * t3 - 10_000 * lb.adminPoints(1)) / 8_000;
        address[] memory two = new address[](2);
        two[0] = carol;
        two[1] = bob;
        uint256[] memory a2 = new uint256[](2);
        a2[0] = r3 / 2 + 1;
        a2[1] = r3 - r3 / 2 + 1; // sum = r3 + 2
        vm.prank(allocator);
        vm.expectRevert(CurveYieldLeaderboard.AdminCapExceeded.selector);
        lb.adminAllocate(two, a2);
    }

    function test_adminAllocate_needsAnActiveSeason() public {
        address[] memory us = new address[](0);
        uint256[] memory amts = new uint256[](0);
        vm.prank(allocator);
        vm.expectRevert(CurveYieldLeaderboard.NoActiveSeason.selector);
        lb.adminAllocate(us, amts);
    }

    // ---------------------------------------------------------------- 7. top-100

    function _users(uint256 n_) internal returns (address[] memory us_) {
        us_ = new address[](n_);
        for (uint256 i; i < n_; ++i) us_[i] = makeAddr(string.concat("lbuser", vm.toString(i)));
    }

    function _buy(address who_, uint256 amount_) internal {
        cy.mint(who_, amount_);
        vm.prank(who_);
        lb.buyPoints(amount_);
    }

    /// @dev The board must be exactly the 100 highest point totals, descending, each entry consistent with pointsOf.
    function _assertBoard(address[] memory all_) internal view {
        (address[] memory bu, uint256[] memory bp) = lb.leaderboard();
        uint256[] memory pts = new uint256[](all_.length);
        for (uint256 i; i < all_.length; ++i) pts[i] = lb.pointsOf(1, all_[i]);
        // reference: insertion sort descending
        for (uint256 i = 1; i < pts.length; ++i) {
            uint256 v = pts[i];
            uint256 j = i;
            while (j > 0 && pts[j - 1] < v) {
                pts[j] = pts[j - 1];
                --j;
            }
            pts[j] = v;
        }
        uint256 expectedLen = all_.length < 100 ? all_.length : 100;
        // only users with points are on the board
        uint256 withPoints;
        for (uint256 i; i < pts.length; ++i) if (pts[i] != 0) ++withPoints;
        if (withPoints < expectedLen) expectedLen = withPoints;
        assertEq(bu.length, expectedLen, "board length");
        for (uint256 i; i < bu.length; ++i) {
            assertEq(bp[i], pts[i], "board points != sorted reference");
            assertEq(bp[i], lb.pointsOf(1, bu[i]), "board entry inconsistent with pointsOf");
            for (uint256 j = i + 1; j < bu.length; ++j) assertTrue(bu[i] != bu[j], "duplicate on the board");
        }
    }

    function test_board_sortedDescending_150Users() public {
        CySeasonParams memory p = _params();
        p.minBalance = 0;
        _startSeason(p);
        address[] memory us = _users(150);
        for (uint256 i; i < us.length; ++i) {
            _register(us[i], 0);
        }
        for (uint256 i; i < us.length; ++i) {
            _buy(us[i], 1_000 + (uint256(keccak256(abi.encode("amt", i))) % 1_000_000));
        }
        _assertBoard(us);
        assertEq(lb.boardCount(), 100);
    }

    function testFuzz_board_matchesSortedReference(uint256 seed_) public {
        CySeasonParams memory p = _params();
        p.minBalance = 0;
        _startSeason(p);
        address[] memory us = _users(150);
        for (uint256 i; i < us.length; ++i) {
            vm.prank(us[i]);
            lb.register();
            vm.prank(us[i]);
            cy.approve(address(lb), type(uint256).max);
        }
        // random purchases, including repeated ones for the same user (their board position moves up)
        for (uint256 k; k < 260; ++k) {
            uint256 h = uint256(keccak256(abi.encode(seed_, k)));
            address u = us[h % us.length];
            uint256 amount = 1_000 + (h >> 16) % 5_000_000;
            cy.mint(u, amount);
            vm.prank(u);
            lb.buyPoints(amount);
        }
        _assertBoard(us);
    }

    function test_board_insertionAtTheCapEvictsTheLast_andASmallerNewcomerIsIgnored() public {
        CySeasonParams memory p = _params();
        p.minBalance = 0;
        _startSeason(p);
        address[] memory us = _users(101);
        for (uint256 i; i < us.length; ++i) _register(us[i], 0);
        for (uint256 i; i < 100; ++i) _buy(us[i], 10_000 + i * 100); // strictly increasing: user 0 is last
        assertEq(lb.boardCount(), 100);
        (address[] memory bu,) = lb.leaderboard();
        assertEq(bu[99], us[0], "the smallest holder is last");
        assertEq(bu[0], us[99]);

        // a newcomer below the last: not inserted
        _buy(us[100], 1_000);
        assertEq(lb.boardCount(), 100);
        (bu,) = lb.leaderboard();
        for (uint256 i; i < bu.length; ++i) assertTrue(bu[i] != us[100]);
        // a newcomer above the last: evicts user 0
        _buy(us[100], 50_000);
        assertEq(lb.boardCount(), 100);
        (bu,) = lb.leaderboard();
        bool foundNew;
        for (uint256 i; i < bu.length; ++i) {
            assertTrue(bu[i] != us[0], "the last entry was not evicted");
            if (bu[i] == us[100]) foundNew = true;
        }
        assertTrue(foundNew, "the newcomer is missing");
        // the evicted user can come back by out-earning the new last
        _buy(us[0], 80_000);
        (bu,) = lb.leaderboard();
        bool back;
        for (uint256 i; i < bu.length; ++i) if (bu[i] == us[0]) back = true;
        assertTrue(back);
        _assertBoard(us);
    }

    function test_board_resetsOnANewSeason() public {
        CySeasonParams memory p0 = _params();
        p0.minBalance = 0;
        _startSeason(p0);
        address[] memory us = _users(5);
        for (uint256 i; i < us.length; ++i) {
            _register(us[i], 0);
            _buy(us[i], 10_000 * (i + 1));
        }
        assertEq(lb.boardCount(), 5);
        _warp(T0 + 10 * EPOCH);
        CySeasonParams memory q = _params();
        q.minBalance = 0;
        q.start = uint48(t);
        q.end = uint48(t + 10 * EPOCH);
        q.cliffAt = [uint48(t + 28 days), uint48(t + 84 days), uint48(0)];
        lb.startSeason(q, "S2", "S2");
        assertEq(lb.boardCount(), 0, "board not reset");
        (address[] memory bu, uint256[] memory bp) = lb.leaderboard();
        assertEq(bu.length, 0);
        assertEq(bp.length, 0);
        // the old users can be credited again in the new season and re-enter the board cleanly
        vm.prank(us[0]);
        lb.register();
        cy.mint(us[0], 5_000);
        vm.prank(us[0]);
        lb.buyPoints(5_000);
        (bu, bp) = lb.leaderboard();
        assertEq(bu.length, 1);
        assertEq(bu[0], us[0]);
        assertEq(bp[0], lb.pointsOf(2, us[0]));
    }

    // ---------------------------------------------------------------- 8. seasons

    function test_startSeason_revertsWhileActive_andOnlyOwner() public {
        _startSeason(_params());
        CySeasonParams memory q = _params();
        vm.expectRevert(CurveYieldLeaderboard.SeasonActive.selector);
        lb.startSeason(q, "x", "X");
        _warp(T0 + 10 * EPOCH - 1);
        vm.expectRevert(CurveYieldLeaderboard.SeasonActive.selector);
        lb.startSeason(q, "x", "X");
        _warp(T0 + 10 * EPOCH); // ended
        q.start = uint48(t);
        q.end = uint48(t + 10 * EPOCH);
        q.cliffAt = [uint48(t + 28 days), uint48(t + 84 days), uint48(0)];
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        lb.startSeason(q, "x", "X");
        lb.startSeason(q, "S2", "S2");
        assertEq(lb.currentSeason(), 2);
    }

    function test_startSeason_validatesEveryParameter() public {
        CySeasonParams memory p;
        // dates
        p = _params();
        p.start = uint48(T0 - 1);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldLeaderboard.BadParams.selector, "dates"));
        lb.startSeason(p, "x", "X");
        p = _params();
        p.end = uint48(T0 + EPOCH); // must be longer than one epoch
        vm.expectRevert(abi.encodeWithSelector(CurveYieldLeaderboard.BadParams.selector, "dates"));
        lb.startSeason(p, "x", "X");
        // referral tiers
        p = _params();
        p.tier1Bps = 4_001;
        vm.expectRevert(abi.encodeWithSelector(CurveYieldLeaderboard.BadParams.selector, "referral tiers"));
        lb.startSeason(p, "x", "X");
        p = _params();
        p.tier2Bps = 2_001;
        vm.expectRevert(abi.encodeWithSelector(CurveYieldLeaderboard.BadParams.selector, "referral tiers"));
        lb.startSeason(p, "x", "X");
        // ref tiers: full 20%-500%, cut1 20-50%, cut2 from 40%-1,000%, cut2 30-50%
        _badRef(1_999, 3_000, 30_000, 4_000);
        _badRef(50_001, 3_000, 60_000, 4_000);
        _badRef(10_000, 1_999, 30_000, 4_000);
        _badRef(10_000, 5_001, 30_000, 4_000);
        _badRef(10_000, 3_000, 3_999, 4_000);
        _badRef(10_000, 3_000, 100_001, 4_000);
        _badRef(10_000, 3_000, 9_999, 4_000); // cut2From below fullUntil
        _badRef(10_000, 3_000, 30_000, 2_999);
        _badRef(10_000, 3_000, 30_000, 5_001);
        // buy tiers: full 10-50%, cut1 20-50%, cut2 from 25%-200%, cut2 20-50%
        _badBuy(999, 3_000, 10_000, 4_000);
        _badBuy(5_001, 3_000, 10_000, 4_000);
        _badBuy(3_000, 1_999, 10_000, 4_000);
        _badBuy(3_000, 5_001, 10_000, 4_000);
        _badBuy(3_000, 3_000, 2_499, 4_000);
        _badBuy(3_000, 3_000, 20_001, 4_000);
        _badBuy(3_000, 3_000, 2_900, 4_000); // cut2From below fullUntil is fine only when >= fullUntil
        _badBuy(3_000, 3_000, 10_000, 1_999);
        _badBuy(3_000, 3_000, 10_000, 5_001);
        // admin cap 500..3,000
        p = _params();
        p.adminCapBps = 499;
        vm.expectRevert(abi.encodeWithSelector(CurveYieldLeaderboard.BadParams.selector, "admin cap"));
        lb.startSeason(p, "x", "X");
        p = _params();
        p.adminCapBps = 3_001;
        vm.expectRevert(abi.encodeWithSelector(CurveYieldLeaderboard.BadParams.selector, "admin cap"));
        lb.startSeason(p, "x", "X");
        // registration: min balance <= 1,000 cyavKAT, fee <= 100
        p = _params();
        p.minBalance = 1_000 * SHARE + 1;
        vm.expectRevert(abi.encodeWithSelector(CurveYieldLeaderboard.BadParams.selector, "registration"));
        lb.startSeason(p, "x", "X");
        p = _params();
        p.registrationFee = 100 * SHARE + 1;
        vm.expectRevert(abi.encodeWithSelector(CurveYieldLeaderboard.BadParams.selector, "registration"));
        lb.startSeason(p, "x", "X");
        // buy rate: pointsPerShareEpoch x 40 .. x 26,000
        p = _params();
        p.buyRate = PPS * 40 - 1;
        vm.expectRevert(abi.encodeWithSelector(CurveYieldLeaderboard.BadParams.selector, "buy rate"));
        lb.startSeason(p, "x", "X");
        p = _params();
        p.buyRate = PPS * 26_000 + 1;
        vm.expectRevert(abi.encodeWithSelector(CurveYieldLeaderboard.BadParams.selector, "buy rate"));
        lb.startSeason(p, "x", "X");
        // every bound is inclusive: the extremes are accepted
        p = _params();
        p.tier1Bps = 4_000;
        p.tier2Bps = 2_000;
        p.adminCapBps = 500;
        p.minBalance = 1_000 * SHARE;
        p.registrationFee = 100 * SHARE;
        p.buyRate = PPS * 40;
        p.refTiers = CyTiers({fullUntilBps: 2_000, cut1Bps: 2_000, cut2FromBps: 4_000, cut2Bps: 3_000});
        p.buyTiers = CyTiers({fullUntilBps: 1_000, cut1Bps: 2_000, cut2FromBps: 2_500, cut2Bps: 2_000});
        _startSeason(p);
        assertEq(lb.currentSeason(), 1);
    }

    function _badRef(uint32 full_, uint16 c1_, uint32 c2from_, uint16 c2_) internal {
        CySeasonParams memory p = _params();
        p.refTiers = CyTiers(full_, c1_, c2from_, c2_);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldLeaderboard.BadParams.selector, "ref"));
        lb.startSeason(p, "x", "X");
    }

    function _badBuy(uint32 full_, uint16 c1_, uint32 c2from_, uint16 c2_) internal {
        CySeasonParams memory p = _params();
        p.buyTiers = CyTiers(full_, c1_, c2from_, c2_);
        // cut2From 2,900 is valid (>= 2,500 and < fullUntil 3,000 is NOT: it must be >= fullUntil)
        vm.expectRevert(abi.encodeWithSelector(CurveYieldLeaderboard.BadParams.selector, "buy"));
        lb.startSeason(p, "x", "X");
    }

    function test_newSeasonToken_mintedForEveryCredit_nonTransferable() public {
        _startSeason(_params());
        CurveYieldSeasonPoints tok = lb.seasonToken(1);
        _register(alice, 100 * SHARE);
        _warp(T0 + EPOCH);
        lb.accountArray(_one(alice));
        _fund(alice, SHARE);
        vm.prank(alice);
        lb.buyPoints(SHARE / 10);
        assertEq(tok.balanceOf(alice), lb.pointsOf(1, alice));
        assertEq(tok.totalSupply(), lb.totalPoints(1));
        assertEq(tok.LEADERBOARD(), address(lb));
        assertEq(tok.SEASON(), 1);
        assertEq(tok.name(), "Season 1 points");
        vm.startPrank(alice);
        vm.expectRevert(CurveYieldSeasonPoints.NonTransferable.selector);
        tok.transfer(bob, 1);
        vm.expectRevert(CurveYieldSeasonPoints.NonTransferable.selector);
        tok.transferFrom(alice, bob, 1);
        vm.expectRevert(CurveYieldSeasonPoints.NonTransferable.selector);
        tok.approve(bob, 1);
        vm.expectRevert(CurveYieldSeasonPoints.NotLeaderboard.selector);
        tok.mint(alice, 1);
        vm.stopPrank();
        assertEq(tok.decimals(), 18);
        assertEq(tok.allowance(alice, bob), 0);

        // season 2 has its own token; the old one stops growing
        _warp(T0 + 10 * EPOCH);
        uint256 old = tok.totalSupply();
        CySeasonParams memory q = _params();
        q.start = uint48(t);
        q.end = uint48(t + 10 * EPOCH);
        q.cliffAt = [uint48(t + 28 days), uint48(t + 84 days), uint48(0)];
        lb.startSeason(q, "Season 2 points", "CYP2");
        CurveYieldSeasonPoints tok2 = lb.seasonToken(2);
        assertTrue(address(tok2) != address(tok));
        vm.prank(alice);
        lb.register();
        vm.prank(alice);
        lb.buyPoints(SHARE / 10);
        assertEq(tok.totalSupply(), old, "the old season token kept minting");
        assertEq(tok2.balanceOf(alice), lb.pointsOf(2, alice));
        assertEq(tok2.totalSupply(), lb.totalPoints(2));
        assertEq(lb.pointsOf(1, alice), tok.balanceOf(alice), "old season points changed");
    }

    /// @dev The contract's own header says every season is a fresh start: users register again and tranches / ages do not
    /// carry over. (The requested test list said tranches carry over; the code says they do not. This pins the code.)
    function test_newSeason_isAFreshStart_reRegistrationNeeded_tranchesDoNotCarryOver() public {
        _startSeason(_params());
        _register(alice, 100 * SHARE);
        _warp(T0 + 3 * EPOCH);
        lb.accountArray(_one(alice));
        uint256 s1 = lb.pointsOf(1, alice);
        assertGt(s1, 0);
        _warp(T0 + 10 * EPOCH);
        CySeasonParams memory q = _params();
        q.start = uint48(t);
        q.end = uint48(t + 10 * EPOCH);
        q.cliffAt = [uint48(t + 28 days), uint48(t + 84 days), uint48(0)];
        lb.startSeason(q, "S2", "S2");
        // not registered in season 2: accounting does nothing, buying is refused
        _warp(t + EPOCH);
        lb.accountArray(_one(alice));
        assertEq(lb.pointsOf(2, alice), 0);
        vm.prank(alice);
        vm.expectRevert(CurveYieldLeaderboard.NotRegistered.selector);
        lb.buyPoints(1);
        // registers again: its age starts from zero (no long-hold bonus from season 1)
        vm.prank(alice);
        lb.register();
        uint256 start2 = q.start;
        _warp(t + EPOCH);
        lb.accountArray(_one(alice));
        // registered at the start of epoch 1 of season 2, so the first epoch it earns is epoch 1 (age 0, no bonus)
        assertEq(lb.pointsOf(2, alice), _pts(100 * SHARE, 0, lb.rateAt(2, start2 + EPOCH + EPOCH / 2), 500), "age carried over from season 1");
        assertEq(lb.pointsOf(1, alice), s1, "season 1 points changed");
        // registered once per address in the list, even though it registered in two seasons
        assertEq(lb.registeredLength(), 1);
    }

    // ---------------------------------------------------------------- 9. deregistration, pagination, gas

    function test_deregistersBelowMinBalanceAtAccounting() public {
        _startSeason(_params()); // min balance 10
        _register(alice, 20 * SHARE);
        vm.prank(alice);
        cy.transfer(bob, 15 * SHARE); // 5 left: below the minimum
        _warp(T0 + EPOCH);
        vm.expectEmit(true, false, false, false);
        emit CurveYieldLeaderboard.Deregistered(alice);
        lb.accountArray(_one(alice));
        (bool registered,,,) = lb.holders(alice);
        assertFalse(registered, "still registered below the minimum");
        // it still earned for the epoch on min(20, 5) = 5
        assertEq(_hold(alice), _oneEpochPoints(5 * SHARE, 0, 0));
        // no more accounting, no buying
        _warp(T0 + 2 * EPOCH);
        uint256 h = _hold(alice);
        lb.accountArray(_one(alice));
        assertEq(_hold(alice), h);
        _fund(alice, 10);
        vm.prank(alice);
        vm.expectRevert(CurveYieldLeaderboard.NotRegistered.selector);
        lb.buyPoints(1);
        // registering again needs the minimum
        vm.prank(alice);
        vm.expectRevert(CurveYieldLeaderboard.BelowMinimum.selector);
        lb.register();
        cy.mint(alice, 10 * SHARE);
        vm.prank(alice);
        lb.register();
        assertEq(lb.registeredLength(), 1, "re-registration listed the address twice");
    }

    function test_register_feeIsTakenAndGuardsHold() public {
        CySeasonParams memory p = _params();
        p.registrationFee = 5 * SHARE;
        _startSeason(p);
        _fund(alice, 30 * SHARE);
        vm.prank(alice);
        lb.register();
        assertEq(cy.balanceOf(alice), 25 * SHARE);
        assertEq(cy.balanceOf(specialRx), 5 * SHARE, "the fee goes to the special rewards sink");
        vm.prank(alice);
        vm.expectRevert(CurveYieldLeaderboard.AlreadyRegistered.selector);
        lb.register();
        // below the minimum
        _fund(bob, 9 * SHARE);
        vm.prank(bob);
        vm.expectRevert(CurveYieldLeaderboard.BelowMinimum.selector);
        lb.register();
        // no active season before the start / after the end
        _warp(T0 + 10 * EPOCH);
        _fund(carol, 30 * SHARE);
        vm.prank(carol);
        vm.expectRevert(CurveYieldLeaderboard.NoActiveSeason.selector);
        lb.register();
    }

    function test_pagination_accountAll_accountRange_accountLeaderboard() public {
        _startSeason(_params());
        address[] memory us = _users(30);
        for (uint256 i; i < us.length; ++i) _register(us[i], (10 + i) * SHARE);
        _warp(T0 + EPOCH);
        uint256 next = lb.accountAll(0, 10);
        assertEq(next, 10);
        for (uint256 i; i < 30; ++i) {
            (, uint32 le,,) = lb.holders(us[i]);
            assertEq(le, i < 10 ? 1 : 0, "only the first page is accounted");
        }
        next = lb.accountAll(next, 10);
        assertEq(next, 20);
        next = lb.accountAll(next, 100); // past the end: clamped
        assertEq(next, 30);
        for (uint256 i; i < 30; ++i) {
            (, uint32 le,,) = lb.holders(us[i]);
            assertEq(le, 1);
            assertGt(_hold(us[i]), 0);
        }
        // accountRange only accounts holders whose points are in [min, max]
        _warp(T0 + 2 * EPOCH);
        uint256 lo = _hold(us[5]);
        uint256 hi = _hold(us[6]);
        assertGt(hi, lo);
        lb.accountRange(lo, lo, 0, 30); // only users with exactly `lo` points (user 5)
        (, uint32 l5,,) = lb.holders(us[5]);
        (, uint32 l6,,) = lb.holders(us[6]);
        assertEq(l5, 2);
        assertEq(l6, 1, "accountRange accounted a user outside the range");
        // accountLeaderboard accounts everyone on the board
        _warp(T0 + 3 * EPOCH);
        lb.accountLeaderboard();
        for (uint256 i; i < 30; ++i) {
            (, uint32 le,,) = lb.holders(us[i]);
            if (i == 5) continue;
            if (i == 6) assertLe(le, 3);
        }
        (address[] memory bu,) = lb.leaderboard();
        for (uint256 i; i < bu.length; ++i) {
            (, uint32 le,,) = lb.holders(bu[i]);
            assertEq(le, 3, "accountLeaderboard skipped a board user");
        }
    }

    function test_gas_accountAll_0_50() public {
        _startSeason(_params());
        address[] memory us = _users(50);
        for (uint256 i; i < us.length; ++i) _register(us[i], (10 + i) * SHARE);
        _warp(T0 + EPOCH);
        uint256 g = gasleft();
        lb.accountAll(0, 50);
        uint256 used = g - gasleft();
        console2.log("accountAll(0, 50) gas, 50 fresh holders, 1 epoch each:", used);
        assertLt(used, 15_000_000, "accountAll(0, 50) above ~50% of a 30M block");
        // and a second epoch on the same holders
        _warp(T0 + 2 * EPOCH);
        g = gasleft();
        lb.accountAll(0, 50);
        console2.log("accountAll(0, 50) gas, second epoch:", g - gasleft());
    }

    // ---------------------------------------------------------------- helpers

    function _one(address a_) internal pure returns (address[] memory r_) {
        r_ = new address[](1);
        r_[0] = a_;
    }
}
