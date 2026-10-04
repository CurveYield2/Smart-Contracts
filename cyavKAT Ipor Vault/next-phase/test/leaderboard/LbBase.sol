// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CurveYieldLeaderboard, CySeasonParams, CyTiers} from "../../src/leaderboard/CurveYieldLeaderboard.sol";
import {CurveYieldReferrals} from "../../src/leaderboard/CurveYieldReferrals.sol";
import {CurveYieldSeasonPoints} from "../../src/leaderboard/CurveYieldSeasonPoints.sol";
import {CurveYieldGovernanceGate} from "../../src/governance/CurveYieldGovernanceGate.sol";
import {CurveYieldConfigKeys as K, CurveYieldAddrKeys} from "../../src/governance/CurveYieldGateConfig.sol";

/// @dev cyavKAT stand-in with 20 decimals (the vault share has 20).
contract Cy20 is ERC20 {
    constructor() ERC20("cyavKAT", "cyavKAT") {}

    function decimals() public pure override returns (uint8) {
        return 20;
    }

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }

    function burn(address from_, uint256 amount_) external {
        _burn(from_, amount_);
    }
}

/// @notice Shared setup for the leaderboard tests. Time is kept in `t` and set with `_warp` (block.timestamp is cached
/// across vm.warp under via-ir).
abstract contract LbBase is Test {
    uint256 internal constant T0 = 1_800_000_000;
    uint256 internal constant EPOCH = 14 days;
    uint256 internal constant SHARE = 1e20;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant PPS = 100e18; // pointsPerShareEpoch: 100 points per cyavKAT-epoch at full rate

    Cy20 internal cy;
    CurveYieldGovernanceGate internal gate;
    CurveYieldReferrals internal refs;
    CurveYieldLeaderboard internal lb;
    address internal adminRx = makeAddr("adminRx");
    address internal specialRx = makeAddr("specialRx");
    address internal growthRx = makeAddr("growthRx");
    address internal boosterRx = makeAddr("boosterRx");
    address internal allocator = makeAddr("allocator");
    address internal claimFeeRx = makeAddr("claimFeeRx");
    uint256 internal t;

    function setUp() public virtual {
        t = T0;
        vm.warp(t);
        cy = new Cy20();
        // The real gate (P0_00 values for the leaderboard keys): this test contract is DAO and fee authority.
        gate = new CurveYieldGovernanceGate(address(this), address(this));
        gate.registerConfig(K.LEADERBOARD_BUY_SPLIT_0, 1, 0, 5_000, 3_000);
        gate.registerConfig(K.LEADERBOARD_BUY_SPLIT_1, 2, 0, 5_000, 4_000);
        gate.registerConfig(K.LEADERBOARD_BUY_SPLIT_2, 2, 0, 5_000, 2_000);
        gate.registerConfig(K.LEADERBOARD_BUY_SPLIT_3, 2, 0, 5_000, 1_000);
        gate.registerConfig(K.REFERRALS_CLAIM_FEE, 1, 0, 100e20, 0);
        bytes32[] memory ks = new bytes32[](4);
        (ks[0], ks[1], ks[2], ks[3]) =
            (K.LEADERBOARD_BUY_SPLIT_0, K.LEADERBOARD_BUY_SPLIT_1, K.LEADERBOARD_BUY_SPLIT_2, K.LEADERBOARD_BUY_SPLIT_3);
        gate.addRule(1, 10_000, ks, address(0), bytes4(0)); // SUM_EQ
        refs = new CurveYieldReferrals(address(this), address(cy), claimFeeRx, address(gate));
        lb = new CurveYieldLeaderboard(address(this), address(cy), address(gate));
        gate.registerAddr(CurveYieldAddrKeys.REFERRALS, address(refs));
        gate.addRule(6, 0, ks, address(lb), CurveYieldLeaderboard.seasonActive.selector); // LOCK while a season runs
        lb.setAdminReceiver(adminRx);
        lb.setBuyDestinations(specialRx, growthRx, boosterRx);
        lb.setPointsAllocator(allocator);
    }

    function _k1(bytes32 k_) internal pure returns (bytes32[] memory k) {
        k = new bytes32[](1);
        k[0] = k_;
    }

    function _v1(uint256 v_) internal pure returns (uint256[] memory v) {
        v = new uint256[](1);
        v[0] = v_;
    }

    function _setSplit(uint256 a_, uint256 b_, uint256 c_, uint256 d_) internal {
        bytes32[] memory ks = new bytes32[](4);
        (ks[0], ks[1], ks[2], ks[3]) =
            (K.LEADERBOARD_BUY_SPLIT_0, K.LEADERBOARD_BUY_SPLIT_1, K.LEADERBOARD_BUY_SPLIT_2, K.LEADERBOARD_BUY_SPLIT_3);
        uint256[] memory vs = new uint256[](4);
        (vs[0], vs[1], vs[2], vs[3]) = (a_, b_, c_, d_);
        gate.setConfigs(ks, vs);
    }

    function _warp(uint256 t_) internal {
        t = t_;
        vm.warp(t_);
    }

    /// @dev A valid season starting now and running 10 epochs, no registration fee and a 10 cyavKAT minimum.
    function _params() internal view returns (CySeasonParams memory p_) {
        p_.start = uint48(T0);
        p_.end = uint48(T0 + 10 * EPOCH);
        p_.initialRateBps = 5_000;
        p_.cliffCount = 2;
        p_.cliffAt = [uint48(T0 + 28 days), uint48(T0 + 84 days), uint48(0)];
        p_.cliffRateBps = [uint16(7_000), 9_000, 0];
        p_.pointsPerShareEpoch = PPS;
        p_.longHoldBonusBps = 500; // +5% per consecutive epoch
        p_.tier1Bps = 4_000;
        p_.tier2Bps = 2_000;
        p_.refTiers = CyTiers({fullUntilBps: 10_000, cut1Bps: 3_000, cut2FromBps: 30_000, cut2Bps: 4_000});
        p_.buyRate = PPS * 100;
        p_.buyTiers = CyTiers({fullUntilBps: 3_000, cut1Bps: 3_000, cut2FromBps: 10_000, cut2Bps: 4_000});
        p_.adminCapBps = 2_000;
        p_.minBalance = 10 * SHARE;
        p_.registrationFee = 0;
    }

    function _startSeason(CySeasonParams memory p_) internal {
        lb.startSeason(p_, "Season 1 points", "CYP1");
    }

    function _fund(address who_, uint256 amount_) internal {
        cy.mint(who_, amount_);
        vm.prank(who_);
        cy.approve(address(lb), type(uint256).max);
        vm.prank(who_);
        cy.approve(address(refs), type(uint256).max);
    }

    function _register(address who_, uint256 balance_) internal {
        _fund(who_, balance_);
        vm.prank(who_);
        lb.register();
    }

    /// @dev One accounting step of the holding formula, in the contract's own order of integer operations.
    function _pts(uint256 amount_, uint256 age_, uint256 rate_, uint256 bonus_) internal pure returns (uint256) {
        uint256 base = amount_ * PPS / SHARE;
        return base * (BPS + bonus_ * age_) / BPS * rate_ / BPS;
    }

    function _rateMid(uint256 season_, uint256 start_, uint256 ep_) internal view returns (uint256) {
        return lb.rateAt(season_, start_ + ep_ * EPOCH + EPOCH / 2);
    }

    function _hold(address who_) internal view returns (uint256) {
        return lb.pointsBreakdown(1, who_).hold;
    }
}
