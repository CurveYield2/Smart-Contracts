// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CurveYieldConfigKeys as K} from "../../src/governance/CurveYieldGateConfig.sol";
import {LbBase} from "./LbBase.sol";
import {CurveYieldLeaderboard, CySeasonParams, CyTiers} from "../../src/leaderboard/CurveYieldLeaderboard.sol";
import {CurveYieldReferrals} from "../../src/leaderboard/CurveYieldReferrals.sol";

/// @notice Referral credits in the leaderboard and the referral registry.
contract ReferralsTest is LbBase {
    address u = makeAddr("u"); // the referee
    address r1 = makeAddr("r1"); // tier 1 referrer
    address r2 = makeAddr("r2"); // tier 2 referrer
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function _link(address user_, address referrer_) internal {
        refs.adminSetReferrer(user_, referrer_);
    }

    function _one(address a_) internal pure returns (address[] memory r_) {
        r_ = new address[](1);
        r_[0] = a_;
    }

    function _accountAt(uint256 t_, address a_) internal {
        _warp(t_);
        lb.accountArray(_one(a_));
    }

    // ---------------------------------------------------------------- referral credits

    function test_tier1And2_areAFractionOfTheRefereesPoints_forRegisteredReferrersOnly() public {
        _startSeason(_params());
        // referrers hold 100x the referee, so the caps never bind here
        _register(r1, 10_000 * SHARE);
        _register(r2, 10_000 * SHARE);
        _register(u, 100 * SHARE);
        _link(u, r1);
        _link(r1, r2);
        _warp(T0 + EPOCH);
        lb.accountArray(_one(r1)); // r1's own points first: they are the cap base
        lb.accountArray(_one(r2));
        uint256 r1Own = _hold(r1);
        uint256 r2RefBefore = lb.pointsBreakdown(1, r2).ref;
        assertEq(lb.pointsBreakdown(1, r1).ref, 0);
        lb.accountArray(_one(u));
        uint256 pu = _hold(u);
        assertEq(pu, 5_500e18);
        assertEq(lb.pointsBreakdown(1, r1).ref, pu * 4_000 / BPS, "tier 1 = 40% of the referee's points");
        assertEq(lb.pointsBreakdown(1, r2).ref - r2RefBefore, pu * 2_000 / BPS, "tier 2 = 20%");
        assertGt(r1Own, pu);
        // referral points are not held points: the referee's own points are untouched
        assertEq(lb.pointsBreakdown(1, u).ref, 0);
        // the season token follows
        assertEq(lb.seasonToken(1).balanceOf(r1), lb.pointsOf(1, r1));
    }

    function test_unregisteredReferrerGetsNothing_andBlocksTier2() public {
        _startSeason(_params());
        _register(r2, 10_000 * SHARE); // registered, but its referee r1 is not
        _register(u, 100 * SHARE);
        _link(u, r1); // r1 never registers
        _link(r1, r2);
        _warp(T0 + EPOCH);
        lb.accountArray(_one(r2));
        uint256 r2Ref = lb.pointsBreakdown(1, r2).ref;
        lb.accountArray(_one(u));
        assertEq(lb.pointsBreakdown(1, r1).ref, 0, "an unregistered referrer earned");
        assertEq(lb.pointsBreakdown(1, r2).ref, r2Ref, "tier 2 paid although tier 1 is unregistered");
        // once r1 registers it earns from the next accounting
        _register(r1, 10 * SHARE);
        _warp(T0 + 2 * EPOCH);
        lb.accountArray(_one(u));
        assertGt(lb.pointsBreakdown(1, r1).ref, 0);
    }

    function test_deregisteredReferrerStopsEarning() public {
        _startSeason(_params());
        _register(r1, 20 * SHARE);
        _register(u, 100 * SHARE);
        _link(u, r1);
        vm.prank(r1);
        cy.transfer(bob, 15 * SHARE); // 5 < the 10 minimum
        _warp(T0 + EPOCH);
        lb.accountArray(_one(r1)); // deregisters r1
        (bool reg,,,) = lb.holders(r1);
        assertFalse(reg);
        lb.accountArray(_one(u));
        assertEq(lb.pointsBreakdown(1, r1).ref, 0);
    }

    function test_selfLoop_r2IsTheUser_givesNoTier2Credit() public {
        _startSeason(_params());
        _register(r1, 10_000 * SHARE);
        _register(u, 100 * SHARE);
        _link(u, r1);
        _link(r1, u); // 2-cycle: r1's referrer is u
        _warp(T0 + EPOCH);
        lb.accountArray(_one(r1)); // r1's points credit u (its referrer) tier 1
        uint256 uRefFromR1 = lb.pointsBreakdown(1, u).ref;
        lb.accountArray(_one(u));
        uint256 pu = _hold(u);
        assertEq(lb.pointsBreakdown(1, r1).ref, pu * 4_000 / BPS, "tier 1 to r1");
        assertEq(lb.pointsBreakdown(1, u).ref, uRefFromR1, "the user was credited tier 2 of its own points (self-loop)");
    }

    /// @dev Hand computed. r1's own points: 7 cyavKAT bought at the 30% no-history rate = 21,000e18; referral tiers of the
    /// season: full rate until 100% of own (21,000e18), then -30% until 300% of own (63,000e18), then -70%.
    /// u holds 5,000 cyavKAT for one epoch = 275,000e18 points; r1's tier 1 raw = 110,000e18.
    ///   21,000e18 at 100%  + 42,000e18 (60,000e18 raw at 70%)  + (110,000e18 - 21,000e18 - 60,000e18 = 29,000e18 raw at 30%)
    ///   = 21,000e18 + 42,000e18 + 8,700e18 = 71,700e18.
    /// r2 (own 0): all of 20% x 275,000e18 = 55,000e18 raw at 30% = 16,500e18.
    function test_referralCaps_crossingBothBoundariesInOneCredit_isSplitCorrectly() public {
        _startSeason(_params());
        _register(r1, 10 * SHARE);
        _register(r2, 10 * SHARE);
        _register(u, 5_000 * SHARE);
        _link(u, r1);
        _link(r1, r2);
        // r1's own points: a purchase, at the 30% rate while it has no history
        _fund(r1, 700e18);
        vm.prank(r1);
        uint256 bought = lb.buyPoints(700e18);
        assertEq(bought, 21_000e18);
        uint256 r1Ref0 = lb.pointsBreakdown(1, r1).ref;
        uint256 r2Ref0 = lb.pointsBreakdown(1, r2).ref;
        assertEq(r1Ref0, 0);
        // r2 got a tier-1 credit from r1's purchase (2,520e18); the credit from u is measured against it below
        assertEq(r2Ref0, 2_520e18);
        _warp(T0 + EPOCH);
        lb.accountArray(_one(u));
        assertEq(_hold(u), 275_000e18);
        assertEq(lb.pointsBreakdown(1, r1).ref, 71_700e18, "piecewise split of one big credit");
        assertEq(lb.pointsBreakdown(1, r2).ref - r2Ref0, 16_500e18, "tier 2 with no own points: 30% of the raw credit");
        assertEq(lb.totalPoints(1), lb.pointsOf(1, r1) + lb.pointsOf(1, r2) + lb.pointsOf(1, u));
    }

    /// @dev A credit that leaves the running total one wei short of a tier boundary must still terminate. The tier loop turns
    /// `room` credited points into `room x 10,000 / rate` raw points and back; when that rounds down, the remaining room
    /// (1 wei) converts to 1 raw point that credits 0, forever.
    function test_referralCreditNearATierBoundary_terminates() public {
        _startSeason(_params());
        _register(r1, 100 * SHARE);
        _register(u, 5_000 * SHARE);
        _link(u, r1);
        // r1's own points 5,500e18 (100 shares held for an epoch): boundaries 5,500e18 / 16,500e18, and
        // 11,000e18 x 10,000 / 7,000 is not an integer
        _warp(T0 + EPOCH);
        lb.accountArray(_one(r1));
        uint256 own = lb.pointsBreakdown(1, r1).hold + lb.pointsBreakdown(1, r1).buy;
        assertGt(own, 0);
        (bool ok,) = address(lb).call{gas: 20_000_000}(abi.encodeCall(CurveYieldLeaderboard.accountArray, (_one(u))));
        assertTrue(ok, "accounting a referee whose credit crosses a tier boundary ran out of gas (non-terminating tier loop)");
    }

    function test_buyPointsAndAdminAllocation_alsoCreditTheReferrers_andNeverCascade() public {
        _startSeason(_params());
        _register(r1, 10 * SHARE);
        _register(r2, 10 * SHARE);
        _register(u, 10 * SHARE);
        _link(u, r1);
        _link(r1, r2);
        // u buys points: r1 gets tier 1 and r2 tier 2 of the BOUGHT points
        _fund(u, 100 * SHARE);
        vm.prank(u);
        uint256 bought = lb.buyPoints(2e18);
        assertEq(bought, 2e18 * 100 * 3_000 / BPS); // raw = amount x 100 at the 30% no-history rate
        uint256 r1Ref = bought * 4_000 / BPS * 3_000 / BPS; // referrer own = 0: credited at 30%
        uint256 r2Ref = bought * 2_000 / BPS * 3_000 / BPS;
        assertEq(lb.pointsBreakdown(1, r1).ref, r1Ref, "tier 1 of bought points");
        assertEq(lb.pointsBreakdown(1, r2).ref, r2Ref, "tier 2 of bought points; r1's referral points must not cascade to r2");

        // admin allocation credits the referrers of the allocated user too (seed total points first)
        _warp(T0 + EPOCH);
        _register(alice, 1_000 * SHARE);
        _warp(T0 + 2 * EPOCH);
        lb.accountArray(_one(alice));
        address[] memory us = _one(u);
        uint256[] memory amts = new uint256[](1);
        amts[0] = 1_000e18;
        uint256 r1Before = lb.pointsBreakdown(1, r1).ref;
        uint256 r2Before = lb.pointsBreakdown(1, r2).ref;
        vm.prank(allocator);
        lb.adminAllocate(us, amts);
        assertEq(lb.pointsBreakdown(1, u).admin, 1_000e18);
        assertGt(lb.pointsBreakdown(1, r1).ref, r1Before, "admin-allocated points did not credit tier 1");
        assertGt(lb.pointsBreakdown(1, r2).ref, r2Before, "admin-allocated points did not credit tier 2");
    }

    function test_oldRegistrantIsNotAValidReferrerUntilItRegistersAgain() public {
        _startSeason(_params());
        _register(r1, 10_000 * SHARE);
        _link(u, r1);
        _warp(T0 + 10 * EPOCH);
        CySeasonParams memory q = _params();
        q.start = uint48(t);
        q.end = uint48(t + 10 * EPOCH);
        q.cliffAt = [uint48(t + 28 days), uint48(t + 84 days), uint48(0)];
        lb.startSeason(q, "S2", "S2");
        vm.prank(u);
        cy.approve(address(lb), type(uint256).max);
        _register(u, 100 * SHARE);
        // r1 registered in season 1 only: it earns nothing from u in season 2
        _warp(t + EPOCH);
        lb.accountArray(_one(u));
        assertGt(lb.pointsOf(2, u), 0);
        assertEq(lb.pointsOf(2, r1), 0, "an old registrant earned in the new season");
        // after re-registering it is valid again, and its first epoch has age-0 tranches only
        vm.prank(r1);
        lb.register();
        uint256 s2start = q.start;
        _warp(t + EPOCH);
        lb.accountArray(_one(r1));
        assertEq(lb.pointsOf(2, r1) - lb.pointsBreakdown(2, r1).ref, _pts(10_000 * SHARE, 0, lb.rateAt(2, s2start + EPOCH + EPOCH / 2), 500));
        lb.accountArray(_one(u));
        assertGt(lb.pointsBreakdown(2, r1).ref, 0);
    }

    // ---------------------------------------------------------------- registry: claims

    function test_claim_upToTenOpen_onlyZeroBalanceAddresses() public {
        address[] memory ts = _addrs(11, "target");
        address[] memory first10 = new address[](10);
        for (uint256 i; i < 10; ++i) first10[i] = ts[i];
        vm.prank(alice);
        refs.claim(first10);
        assertEq(refs.openClaimsOf(alice).length, 10);
        assertEq(refs.referrerOf(ts[3]), alice);
        assertEq(refs.claimedBy(ts[3]), alice);
        // an 11th open claim
        address[] memory one = _one(ts[10]);
        vm.prank(alice);
        vm.expectRevert(CurveYieldReferrals.TooManyOpenClaims.selector);
        refs.claim(one);
        // more than 10 in one call
        vm.prank(bob);
        vm.expectRevert(CurveYieldReferrals.TooManyOpenClaims.selector);
        refs.claim(ts);
        // an address that holds cyavKAT cannot be claimed
        cy.mint(ts[10], 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldReferrals.HasDeposited.selector, ts[10]));
        refs.claim(one);
        // claimed twice / self / zero
        address[] memory again = _one(ts[0]);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldReferrals.AlreadyClaimed.selector, ts[0]));
        refs.claim(again);
        vm.prank(bob);
        vm.expectRevert(CurveYieldReferrals.InvalidReferrer.selector);
        refs.claim(_one(bob));
        vm.prank(bob);
        vm.expectRevert(CurveYieldReferrals.InvalidReferrer.selector);
        refs.claim(_one(address(0)));
    }

    function test_claim_openClaimsArePrunedOnceTheTargetDeposits() public {
        address[] memory ts = _addrs(11, "t");
        address[] memory first10 = new address[](10);
        for (uint256 i; i < 10; ++i) first10[i] = ts[i];
        vm.prank(alice);
        refs.claim(first10);
        // one target deposits: alice's claim on it is no longer open, so an 11th claim fits
        cy.mint(ts[4], 5 * SHARE);
        vm.prank(alice);
        refs.claim(_one(ts[10]));
        address[] memory open = refs.openClaimsOf(alice);
        assertEq(open.length, 10);
        for (uint256 i; i < open.length; ++i) assertTrue(open[i] != ts[4], "the deposited target is still listed as open");
        // the referral itself stays
        assertEq(refs.referrerOf(ts[4]), alice);
        // a target that named someone else no longer counts either
        cy.mint(ts[7], 1); // must hold something to name a referrer
        vm.prank(ts[7]);
        refs.setMyReferrer(bob);
        cy.burn(ts[7], 1);
        vm.prank(alice);
        refs.claim(_addrs2(1, "fresh"));
        open = refs.openClaimsOf(alice);
        for (uint256 i; i < open.length; ++i) assertTrue(open[i] != ts[7], "an overridden claim is still open");
    }

    function test_claimFee_isChargedPerAddress_andBounded() public {
        gate.setConfigs(_k1(K.REFERRALS_CLAIM_FEE), _v1(3e20)); // FEE class: the test contract is fee authority
        _fund(alice, 10e20);
        address[] memory ts = _addrs(2, "f");
        vm.prank(alice);
        refs.claim(ts);
        assertEq(cy.balanceOf(claimFeeRx), 6e20, "fee per claimed address");
        assertEq(cy.balanceOf(alice), 4e20);
        // cannot pay: the whole call reverts
        vm.prank(alice);
        vm.expectRevert();
        refs.claim(_addrs2(2, "g"));
        assertEq(refs.referrerOf(_addrs2(1, "g")[0]), address(0), "a failed claim left state behind");
        // bounds: 0 - 100 cyavKAT (hard cap in the gate)
        gate.setConfigs(_k1(K.REFERRALS_CLAIM_FEE), _v1(100e20));
        vm.expectRevert();
        gate.setConfigs(_k1(K.REFERRALS_CLAIM_FEE), _v1(100e20 + 1));
        vm.prank(alice);
        vm.expectRevert(); // FEE class: only a fee authority
        gate.setConfigs(_k1(K.REFERRALS_CLAIM_FEE), _v1(1));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        refs.setFeeReceiver(alice);
    }

    // ---------------------------------------------------------------- registry: setMyReferrer, admin

    function test_setMyReferrer_onceFreeAndOverridesAClaim() public {
        address x = makeAddr("x");
        vm.prank(alice);
        refs.claim(_one(x));
        assertEq(refs.referrerOf(x), alice);
        // needs a balance
        vm.prank(x);
        vm.expectRevert(CurveYieldReferrals.InvalidReferrer.selector);
        refs.setMyReferrer(bob);
        cy.mint(x, SHARE);
        vm.prank(x);
        refs.setMyReferrer(bob); // free, overrides the claim
        assertEq(refs.referrerOf(x), bob);
        assertTrue(refs.selfNamed(x));
        assertEq(refs.claimedBy(x), alice, "the claim record is kept");
        // once only
        vm.prank(x);
        vm.expectRevert(CurveYieldReferrals.AlreadyNamed.selector);
        refs.setMyReferrer(alice);
        assertEq(cy.balanceOf(x), SHARE, "naming a referrer must be free");
    }

    function test_setMyReferrer_noSelf_noZero_noTwoCycles() public {
        cy.mint(alice, SHARE);
        cy.mint(bob, SHARE);
        vm.startPrank(alice);
        vm.expectRevert(CurveYieldReferrals.InvalidReferrer.selector);
        refs.setMyReferrer(alice);
        vm.expectRevert(CurveYieldReferrals.InvalidReferrer.selector);
        refs.setMyReferrer(address(0));
        refs.setMyReferrer(bob);
        vm.stopPrank();
        // bob naming alice would close a 2-cycle (alice -> bob -> alice)
        vm.prank(bob);
        vm.expectRevert(CurveYieldReferrals.InvalidReferrer.selector);
        refs.setMyReferrer(alice);
        // a longer cycle is not prevented by the registry (the leaderboard skips the self-loop at tier 2)
        address carol = makeAddr("carol");
        cy.mint(carol, SHARE);
        vm.prank(bob);
        refs.setMyReferrer(carol);
        vm.prank(carol);
        refs.setMyReferrer(alice); // alice -> bob -> carol -> alice
        assertEq(refs.referrerOf(carol), alice);
    }

    function test_adminSetReferrer_ownerOnly_canChangeAny_noSelf() public {
        refs.adminSetReferrer(alice, bob);
        assertEq(refs.referrerOf(alice), bob);
        refs.adminSetReferrer(alice, address(0)); // clearing is allowed
        assertEq(refs.referrerOf(alice), address(0));
        // it also overrides a self-named referrer
        cy.mint(alice, SHARE);
        vm.prank(alice);
        refs.setMyReferrer(bob);
        refs.adminSetReferrer(alice, r1);
        assertEq(refs.referrerOf(alice), r1);
        vm.expectRevert(CurveYieldReferrals.InvalidReferrer.selector);
        refs.adminSetReferrer(alice, alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        refs.adminSetReferrer(alice, bob);
    }

    // ---------------------------------------------------------------- helpers

    function _addrs(uint256 n_, string memory tag_) internal returns (address[] memory a_) {
        a_ = new address[](n_);
        for (uint256 i; i < n_; ++i) a_[i] = makeAddr(string.concat(tag_, vm.toString(i)));
    }

    function _addrs2(uint256 n_, string memory tag_) internal returns (address[] memory a_) {
        return _addrs(n_, tag_);
    }
}
