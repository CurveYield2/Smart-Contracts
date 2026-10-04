// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {LbBase} from "./LbBase.sol";
import {CurveYieldLeaderboard, CySeasonParams, CyTiers} from "../../src/leaderboard/CurveYieldLeaderboard.sol";

/// @notice Fuzz of the tiered crediting (`_tiered`) through buyPoints and referral credits: it terminates cheaply, never
/// credits more than the raw amount, and the credit never decreases as the raw amount grows.
contract TieredFuzzTest is LbBase {
    address user = makeAddr("user");
    address ref1 = makeAddr("ref1");
    address referee = makeAddr("referee");

    function _rng(uint256 h_, uint256 lo_, uint256 hi_) internal pure returns (uint256) {
        return lo_ + h_ % (hi_ - lo_ + 1);
    }

    function _tiers(uint256 seed_, bool buy_) internal pure returns (CyTiers memory t_) {
        uint256 h = uint256(keccak256(abi.encode(seed_, buy_)));
        uint256 fullLo = buy_ ? 1_000 : 2_000;
        uint256 fullHi = buy_ ? 5_000 : 50_000;
        uint256 fromLo = buy_ ? 2_500 : 4_000;
        uint256 fromHi = buy_ ? 20_000 : 100_000;
        uint256 full = _rng(h, fullLo, fullHi);
        uint256 from = _rng(h >> 32, fromLo > full ? fromLo : full, fromHi);
        t_.fullUntilBps = uint32(full);
        t_.cut1Bps = uint16(_rng(h >> 64, 2_000, 5_000));
        t_.cut2FromBps = uint32(from);
        t_.cut2Bps = uint16(buy_ ? _rng(h >> 96, 2_000, 5_000) : _rng(h >> 96, 3_000, 5_000));
    }

    function _seasonWithTiers(uint256 seed_) internal {
        CySeasonParams memory p = _params();
        p.refTiers = _tiers(seed_, false);
        p.buyTiers = _tiers(seed_, true);
        _startSeason(p);
    }

    /// @dev A holder with `own` holding points: a random balance held for 1..5 epochs.
    function _giveHoldingPoints(address who_, uint256 h_) internal {
        uint256 shares = _rng(h_, 10, 20_000);
        _register(who_, shares * SHARE);
        _warp(T0 + _rng(h_ >> 32, 1, 5) * EPOCH);
        address[] memory one = new address[](1);
        one[0] = who_;
        lb.accountArray(one);
    }

    function testFuzz_buyPoints_terminates_boundedByRaw_andMonotonic(uint256 seed_) public {
        _seasonWithTiers(seed_);
        _giveHoldingPoints(user, seed_);
        // some purchases first so `already` (the buy points so far) is arbitrary
        for (uint256 k; k < 3; ++k) {
            uint256 h = uint256(keccak256(abi.encode(seed_, "pre", k)));
            uint256 a = _rng(h, 1, 3e21);
            cy.mint(user, a);
            vm.prank(user);
            uint256 g = gasleft();
            uint256 pts = lb.buyPoints(a);
            assertLt(g - gasleft(), 1_000_000, "buyPoints used more than 1M gas");
            assertLe(pts, a * (PPS * 100) / SHARE, "credited more than the raw points");
        }
        // monotonicity from one state: a larger purchase never credits less
        uint256 h2 = uint256(keccak256(abi.encode(seed_, "mono")));
        uint256 a1 = _rng(h2, 1, 5e21);
        uint256 a2 = a1 + _rng(h2 >> 64, 0, 5e21);
        cy.mint(user, a2);
        uint256 snap = vm.snapshot();
        vm.prank(user);
        uint256 g1 = gasleft();
        uint256 p1 = lb.buyPoints(a1);
        assertLt(g1 - gasleft(), 1_000_000, "gas (a1)");
        vm.revertTo(snap);
        vm.prank(user);
        uint256 g2 = gasleft();
        uint256 p2 = lb.buyPoints(a2);
        assertLt(g2 - gasleft(), 1_000_000, "gas (a2)");
        assertLe(p1, a1 * (PPS * 100) / SHARE);
        assertLe(p2, a2 * (PPS * 100) / SHARE);
        assertGe(p2, p1, "the credit decreased as the raw amount grew");
    }

    function testFuzz_referralCredit_terminates_boundedByRaw_andMonotonic(uint256 seed_) public {
        _seasonWithTiers(seed_);
        // the referrer's own points (the cap base) come from holding; sometimes also from a purchase
        _giveHoldingPoints(ref1, seed_);
        if (seed_ % 2 == 0) {
            uint256 a = _rng(seed_ >> 8, 1, 2e21);
            cy.mint(ref1, a);
            vm.prank(ref1);
            lb.buyPoints(a);
        }
        refs.adminSetReferrer(referee, ref1);
        uint256 h = uint256(keccak256(abi.encode(seed_, "referee")));
        uint256 s1 = _rng(h, 10, 30_000);
        uint256 s2 = s1 + _rng(h >> 64, 0, 30_000);
        uint256 when = t + _rng(h >> 128, 1, 3) * EPOCH;
        // two referees with different balances from the same state: same registration time, different amounts
        address referee2 = makeAddr("referee2");
        refs.adminSetReferrer(referee2, ref1);
        _register(referee, s1 * SHARE);
        _register(referee2, s2 * SHARE);
        _warp(when);
        uint256 before = lb.pointsBreakdown(1, ref1).ref;
        uint256 snap = vm.snapshot();

        address[] memory one = new address[](1);
        one[0] = referee;
        uint256 g1 = gasleft();
        lb.accountArray(one);
        assertLt(g1 - gasleft(), 1_000_000, "accounting a referee used more than 1M gas");
        uint256 credit1 = lb.pointsBreakdown(1, ref1).ref - before;
        uint256 pts1 = lb.pointsBreakdown(1, referee).hold;
        assertLe(credit1, pts1 * 4_000 / BPS, "referral credit above the raw tier-1 amount");
        vm.revertTo(snap);

        one[0] = referee2;
        uint256 g2 = gasleft();
        lb.accountArray(one);
        assertLt(g2 - gasleft(), 1_000_000, "accounting a larger referee used more than 1M gas");
        uint256 credit2 = lb.pointsBreakdown(1, ref1).ref - before;
        uint256 pts2 = lb.pointsBreakdown(1, referee2).hold;
        assertLe(credit2, pts2 * 4_000 / BPS);
        // more raw points (a larger balance held over the same epochs) never credit less
        assertGe(pts2, pts1);
        assertGe(credit2, credit1, "the referral credit decreased as the referee's points grew");
    }
}
