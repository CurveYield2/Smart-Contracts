// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CurveYieldWithdrawalManagerV2, CurveYieldWithdrawRequestInfo} from "../../src/withdraw/CurveYieldWithdrawalManagerV2.sol";
import {CurveYieldConfigKeys as K} from "../../src/governance/CurveYieldGateConfig.sol";
import {FakeConfigGate as MockConfigGate} from "../governance/GateConfigBase.t.sol";
import {
    MockAsset, MockAccessManager, MockPlasmaVault, MockRequestFeeFuse, MockBurnFuse, MockProfitCustody
} from "./WithdrawManagerMocks.sol";

/// @notice Unit tests of CurveYieldWithdrawalManagerV2's own-storage fee math (own defaults, the FeesInGate switch, the
/// gate-config keys, and splits) and its escrow / refund / earn accounting for request fees. No fork: the plasma vault
/// boundary (`execute`, `asset`, `convertToAssets` / `convertToShares`) is a lightweight mock (see WithdrawManagerMocks.sol)
/// since the WM's own logic — not the vault's internal ledger — is what is under test here.
contract WithdrawalManagerV2Test is Test {
    uint256 constant WAD = 1e18;

    CurveYieldWithdrawalManagerV2 wm;
    MockAsset asset;
    MockPlasmaVault vault;
    MockAccessManager am;
    MockRequestFeeFuse requestFeeFuse;
    MockBurnFuse burnFuse;
    MockProfitCustody custody;
    MockConfigGate gate;

    address admin = makeAddr("admin");
    address controller = makeAddr("controller");
    address template = address(0xAAAA);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        asset = new MockAsset();
        vault = new MockPlasmaVault(asset);
        am = new MockAccessManager(admin);
        requestFeeFuse = new MockRequestFeeFuse();
        burnFuse = new MockBurnFuse();
        custody = new MockProfitCustody();
        gate = new MockConfigGate();

        wm = new CurveYieldWithdrawalManagerV2(address(am), template);
        vm.startPrank(admin);
        wm.updatePlasmaVaultAddress(address(vault));
        wm.setDependencies(controller, address(burnFuse), address(requestFeeFuse), address(0));
        vm.stopPrank();

        asset.mint(address(vault), 1_000_000e18);
        vm.prank(address(vault));
        asset.approve(address(wm), type(uint256).max);
    }

    // ---------------------------------------------------------------- fee math: own storage, defaults

    function test_defaults_ownFees() public view {
        assertEq(wm.getWithdrawFee(), wm.DEFAULT_WITHDRAW_FEE());
        assertEq(wm.getRequestFee(), wm.DEFAULT_REQUEST_FEE());
        (address[3] memory recipients, uint16[3] memory bps) = wm.feeSplit();
        assertEq(recipients[0], address(0));
        assertEq(bps[0] + bps[1] + bps[2], 0);
    }

    function test_updateFees_onlyTemplatePermission_rejectsAboveOneWad() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.UnauthorizedConfigurator.selector, alice, wm.updateWithdrawFee.selector));
        wm.updateWithdrawFee(0.05e18);

        vm.startPrank(admin);
        wm.updateWithdrawFee(0.05e18);
        assertEq(wm.getWithdrawFee(), 0.05e18);
        wm.updateRequestFee(0.02e18);
        assertEq(wm.getRequestFee(), 0.02e18);

        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.InvalidFee.selector, uint256(1e18) + 1));
        wm.updateWithdrawFee(1e18 + 1);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.InvalidFee.selector, uint256(1e18) + 1));
        wm.updateRequestFee(1e18 + 1);
        wm.updateWithdrawFee(1e18); // exactly the cap is fine
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- fee math: gate set / unset

    function test_setConfigGate_firstSetNeedsTemplatePermission_thenOnlyTheCurrentGate() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.UnauthorizedConfigurator.selector, alice, wm.updateWithdrawFee.selector));
        wm.setConfigGate(address(gate));

        vm.prank(admin);
        wm.setConfigGate(address(gate));
        assertEq(wm.configGate(), address(gate));

        MockConfigGate gate2 = new MockConfigGate();
        vm.prank(admin); // the template permission no longer matters once a gate is set
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.UnauthorizedConfigurator.selector, admin, wm.setConfigGate.selector));
        wm.setConfigGate(address(gate2));
        vm.prank(address(gate));
        wm.setConfigGate(address(gate2));
        assertEq(wm.configGate(), address(gate2));
    }

    function test_gateSet_feesAndSplitReadFromTheGate_ownSettersRevertFeesInGate() public {
        gate.set(K.WM_WITHDRAW_FEE, 0.03e18);
        gate.set(K.WM_REQUEST_FEE, 0.04e18);
        gate.set(K.WM_SPLIT_BPS_0, 1_000);
        gate.set(K.WM_SPLIT_BPS_1, 2_000);
        gate.set(K.WM_SPLIT_BPS_2, 500);
        vm.prank(admin);
        wm.setConfigGate(address(gate));

        assertEq(wm.getWithdrawFee(), 0.03e18);
        assertEq(wm.getRequestFee(), 0.04e18);
        (, uint16[3] memory bps) = wm.feeSplit();
        assertEq(bps[0], 1_000);
        assertEq(bps[1], 2_000);
        assertEq(bps[2], 500);

        vm.startPrank(admin);
        vm.expectRevert(CurveYieldWithdrawalManagerV2.FeesInGate.selector);
        wm.updateWithdrawFee(0.01e18);
        vm.expectRevert(CurveYieldWithdrawalManagerV2.FeesInGate.selector);
        wm.updateRequestFee(0.01e18);
        vm.stopPrank();

        // the gate can be updated live and the WM follows it without any call to the WM itself
        gate.set(K.WM_WITHDRAW_FEE, 0.06e18);
        assertEq(wm.getWithdrawFee(), 0.06e18);
    }

    function test_setFeeSplit_boundsAndTemplatePermission() public {
        address[3] memory recipients = [alice, bob, address(0)];
        uint16[3] memory bps = [uint16(3_000), 3_000, 0];
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.UnauthorizedConfigurator.selector, alice, wm.updateWithdrawFee.selector));
        wm.setFeeSplit(recipients, bps, true);

        vm.startPrank(admin);
        wm.setFeeSplit(recipients, bps, true);
        (address[3] memory got,) = wm.feeSplit();
        assertEq(got[0], alice);
        assertTrue(wm.splitRequestFee());

        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.InvalidFee.selector, uint256(5_001)));
        wm.setFeeSplit(recipients, [uint16(5_001), 0, 0], true);
        // each individual bps is <= 5,000 (so no per-index revert fires) but the total exceeds the 7,500 cap
        address carol = makeAddr("carol");
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.InvalidFee.selector, uint256(7_501)));
        wm.setFeeSplit([alice, bob, carol], [uint16(2_501), 2_500, 2_500], true);
        // a non-zero bps with a zero-address recipient is rejected
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.InvalidFee.selector, uint256(100)));
        wm.setFeeSplit([address(0), bob, address(0)], [uint16(100), 0, 0], true);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- escrow: requestShares

    function test_requestShares_escrowsTheCeiledFee_intoTheManager() public {
        // 0.9% default withdraw fee is irrelevant here; default request fee is 3.9%
        uint256 gross = 1_000e18;
        uint256 wantFee = (gross * wm.DEFAULT_REQUEST_FEE() + WAD - 1) / WAD; // ceil
        vm.prank(alice);
        wm.requestShares(gross);

        assertEq(requestFeeFuse.movesLength(), 1);
        (address from, address to, uint256 amount) = requestFeeFuse.moves(0);
        assertEq(from, alice);
        assertEq(to, address(wm));
        assertEq(amount, wantFee);

        CurveYieldWithdrawRequestInfo memory info = wm.rawRequestInfo(alice);
        assertEq(info.shares, gross - wantFee);
        assertEq(info.refundableFeeShares, wantFee); // nothing earned yet
        assertEq(wm.activeRequestedShares(), gross - wantFee);
    }

    function test_requestShares_zeroShares_orFeeAtLeastGross_reverts() public {
        vm.prank(alice);
        vm.expectRevert(CurveYieldWithdrawalManagerV2.ZeroShares.selector);
        wm.requestShares(0);

        vm.prank(admin);
        wm.updateRequestFee(1e18); // 100%: fee == gross for any amount
        vm.prank(alice);
        vm.expectRevert(CurveYieldWithdrawalManagerV2.ZeroShares.selector);
        wm.requestShares(1_000e18);
    }

    /// @dev Replacing an open request before it is released refunds the UNEARNED part of the old fee (all of it here,
    /// since nothing was released yet) and re-escrows a fresh fee on the new gross amount.
    function test_requestShares_replacingAnOpenRequest_refundsTheUnearnedFee() public {
        vm.startPrank(alice);
        wm.requestShares(1_000e18);
        uint256 fee1 = requestFeeFuse.moveAmount(0);
        wm.requestShares(2_000e18);
        vm.stopPrank();

        assertEq(requestFeeFuse.movesLength(), 3, "expected escrow, refund, escrow");
        (address from1, address to1, uint256 amt1) = requestFeeFuse.moves(1);
        assertEq(from1, address(wm));
        assertEq(to1, alice);
        assertEq(amt1, fee1, "the whole unearned fee of the replaced request was not refunded");

        uint256 fee2 = (2_000e18 * wm.DEFAULT_REQUEST_FEE() + WAD - 1) / WAD;
        (,, uint256 amt2) = requestFeeFuse.moves(2);
        assertEq(amt2, fee2);
        assertEq(wm.activeRequestedShares(), 2_000e18 - fee2, "the old request's shares were not fully replaced");
    }

    // ---------------------------------------------------------------- refund: expiry

    function test_pruneExpiredRequests_refundsUnearnedFee_onExpiry() public {
        vm.prank(alice);
        wm.requestShares(1_000e18);
        uint256 fee = requestFeeFuse.moveAmount(0);

        (, bool complete) = wm.pruneExpiredRequests(10);
        assertTrue(complete, "nothing should be stale before the window elapses");
        assertEq(requestFeeFuse.movesLength(), 1);

        vm.warp(block.timestamp + wm.getWithdrawWindow() + 1);
        (uint256 processed, bool complete2) = wm.pruneExpiredRequests(10);
        assertEq(processed, 1);
        assertTrue(complete2);
        assertEq(requestFeeFuse.movesLength(), 2, "expiry did not refund the fee");
        (address from, address to, uint256 amount) = requestFeeFuse.moves(1);
        assertEq(from, address(wm));
        assertEq(to, alice);
        assertEq(amount, fee, "expiry must refund the fee in full when nothing was released");

        // note: rawRequestInfo().shares reflects raw storage (remainingShares), not zeroed by expiry; the request is
        // simply inactive from here (activeRequestedShares is the meaningful post-expiry total)
        assertEq(wm.activeRequestedShares(), 0);
    }

    function test_pruneExpiredRequests_batchSizeBounds() public {
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.InvalidPruneBatch.selector, 0));
        wm.pruneExpiredRequests(0);
        uint256 tooMany = wm.MAX_PRUNE_BATCH() + 1;
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.InvalidPruneBatch.selector, tooMany));
        wm.pruneExpiredRequests(tooMany);
    }

    // ---------------------------------------------------------------- earn: releaseActiveShares

    function test_releaseActiveShares_earnsFeeProportionally_andBurnsIt() public {
        vm.prank(alice);
        wm.requestShares(1_000e18); // net 961e18 at the 3.9% default, fee ~ 39.0...e18 (ceiled)
        uint256 fee = requestFeeFuse.moveAmount(0);
        uint256 net = 1_000e18 - fee;

        // releaseActiveShares needs a timestamp_ strictly between the request's own creation time and now (_releasable
        // requires requestTimestamp < timestamp_ < block.timestamp), so the fork moves at least 2 seconds
        vm.warp(block.timestamp + 2);
        vm.prank(controller);
        wm.releaseActiveShares(block.timestamp - 1, net); // release the whole request

        // the fee earned is proportional to consumed/initialNet = 100%: the whole fee is earned and burned
        assertEq(burnFuse.burnedLength(), 1);
        assertEq(burnFuse.burned(0), fee);
        assertEq(wm.earnedFeeShares(), 0, "burned fee must not still show as earned/escrowed");
        CurveYieldWithdrawRequestInfo memory info = wm.rawRequestInfo(alice);
        assertEq(info.refundableFeeShares, 0, "a fully released request has nothing left to refund");
    }

    function test_releaseActiveShares_partialRelease_earnsProportionalFeeOnly() public {
        vm.prank(alice);
        wm.requestShares(1_000e18);
        uint256 fee = requestFeeFuse.moveAmount(0);
        uint256 net = 1_000e18 - fee;

        vm.warp(block.timestamp + 2); // see the note in test_releaseActiveShares_earnsFeeProportionally_andBurnsIt
        vm.prank(controller);
        wm.releaseActiveShares(block.timestamp - 1, net / 2); // release half

        assertEq(burnFuse.burnedLength(), 1);
        uint256 halfFee = (fee * (net / 2) + net - 1) / net; // same ceil-mulDiv the contract uses
        assertEq(burnFuse.burned(0), halfFee);
        CurveYieldWithdrawRequestInfo memory info = wm.rawRequestInfo(alice);
        assertEq(info.refundableFeeShares, fee - halfFee);
    }

    function test_releaseActiveShares_onlyController_futureTimestamp_overAvailable_revert() public {
        vm.prank(alice);
        wm.requestShares(1_000e18);
        uint256 net = 1_000e18 - requestFeeFuse.moveAmount(0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.UnauthorizedController.selector, alice));
        wm.releaseActiveShares(block.timestamp, 1);

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.InvalidTimestamp.selector, block.timestamp));
        wm.releaseActiveShares(block.timestamp, 1); // must be strictly in the past

        vm.warp(block.timestamp + 1);
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.InvalidSharesToRelease.selector, net + 1, net));
        wm.releaseActiveShares(block.timestamp - 1, net + 1);
    }

    function test_releaseActiveShares_noBurnFuseConfigured_reverts() public {
        CurveYieldWithdrawalManagerV2 bare = new CurveYieldWithdrawalManagerV2(address(am), template);
        vm.prank(admin);
        bare.updatePlasmaVaultAddress(address(vault));
        // no setDependencies: controller is unset, so onlyController itself refuses first
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.UnauthorizedController.selector, controller));
        bare.releaseActiveShares(block.timestamp - 1, 1);
    }

    // ---------------------------------------------------------------- canWithdrawFromRequest / FromUnallocated

    function test_canWithdrawFromRequest_onlyVault_andReleaseWindow() public {
        vm.prank(alice);
        wm.requestShares(1_000e18);
        uint256 net = 1_000e18 - requestFeeFuse.moveAmount(0);

        vm.prank(alice);
        vm.expectRevert(); // onlyVault
        wm.canWithdrawFromRequest(alice, net);

        // not yet released: nothing reserved for alice
        vm.prank(address(vault));
        assertFalse(wm.canWithdrawFromRequest(alice, net));

        vm.warp(block.timestamp + 2); // see the note in test_releaseActiveShares_earnsFeeProportionally_andBurnsIt
        vm.prank(controller);
        wm.releaseActiveShares(block.timestamp - 1, net);

        vm.prank(address(vault));
        assertTrue(wm.canWithdrawFromRequest(alice, net));
        assertEq(wm.reservedSharesOf(alice), 0, "reserved shares were not consumed by the withdrawal");
    }

    /// @dev ONBOARDING_FEE_SPEC: with no split set the instant fee is burned in full, no custody is needed or paid.
    function test_canWithdrawFromUnallocated_noSplit_noCustodyNeeded_wholeFeeBurned() public {
        vm.prank(alice);
        vm.expectRevert(); // onlyVault
        wm.canWithdrawFromUnallocated(100e18);

        vm.prank(address(vault));
        uint256 fee = wm.canWithdrawFromUnallocated(100e18);
        assertEq(fee, 100e18 * wm.DEFAULT_WITHDRAW_FEE() / WAD, "the whole instant fee must be reported for burning");
    }

    function test_canWithdrawFromUnallocated_wholeFeeBurned_custodyAndAdminGetNothing() public {
        vm.prank(admin);
        wm.setProfitCustody(address(custody));
        custody.setRevenueShareBps(2_000); // the old custody cut is gone: this setting must have no effect

        uint256 shares = 100e18;
        uint256 wantFee = shares * wm.DEFAULT_WITHDRAW_FEE() / WAD;
        vm.prank(address(vault));
        uint256 feeSharesToBurn = wm.canWithdrawFromUnallocated(shares);
        assertEq(feeSharesToBurn, wantFee);
        assertEq(asset.balanceOf(address(custody)), 0, "custody must receive nothing from the instant fee");
        assertEq(wm.owedSplitShares(), 0, "no split accrues when none is configured");
    }

    function test_canWithdrawFromUnallocated_insufficientAvailableShares_reverts() public {
        vm.prank(admin);
        wm.setProfitCustody(address(custody));
        // drain the vault's asset so availableShares is tiny
        uint256 idle = asset.balanceOf(address(vault));
        vm.prank(address(vault));
        asset.transfer(alice, idle - 1);
        vm.prank(address(vault));
        vm.expectRevert(); // InvalidUnallocatedShares
        wm.canWithdrawFromUnallocated(100e18);
    }

    // ---------------------------------------------------------------- split: accrue then settleSplit

    function test_split_accruesOnUnallocatedWithdraw_thenSettleSplitPaysRecipients() public {
        address r0 = makeAddr("r0");
        address r1 = makeAddr("r1");
        vm.prank(admin);
        wm.setFeeSplit([r0, r1, address(0)], [uint16(2_000), 3_000, 0], false); // 50% of the fee split, rest burned

        uint256 shares = 500e18;
        uint256 wantFee = shares * wm.DEFAULT_WITHDRAW_FEE() / WAD;
        uint256 wantSplitShares = wantFee * 5_000 / 10_000;

        vm.prank(address(vault));
        uint256 feeSharesToBurn = wm.canWithdrawFromUnallocated(shares);
        assertEq(feeSharesToBurn, wantFee);
        assertEq(wm.owedSplitShares(), wantSplitShares);
        assertEq(asset.balanceOf(r0), 0, "split must be accrued, not paid immediately");

        uint256 paid = wm.settleSplit();
        assertEq(paid, wantSplitShares);
        assertEq(wm.owedSplitShares(), 0);
        assertEq(asset.balanceOf(r0), wantSplitShares * 2_000 / 5_000);
        assertEq(asset.balanceOf(r1), wantSplitShares * 3_000 / 5_000);
    }

    function test_settleSplit_limitedToIdleNotReservedForReleases() public {
        address r0 = makeAddr("r0");
        vm.prank(admin);
        wm.setFeeSplit([r0, address(0), address(0)], [uint16(5_000), 0, 0], false);

        vm.prank(address(vault));
        wm.canWithdrawFromUnallocated(1_000e18); // accrues a large owed split

        uint256 owed = wm.owedSplitShares();
        assertGt(owed, 0);
        // drain idle to (almost) nothing: settleSplit can pay little to nothing
        uint256 idle = asset.balanceOf(address(vault));
        vm.prank(address(vault));
        asset.transfer(alice, idle);
        uint256 paid = wm.settleSplit();
        assertEq(paid, 0, "settleSplit must not pay more than idle allows");
        assertEq(wm.owedSplitShares(), owed);
    }

    // ---------------------------------------------------------------- burn-only / emergency-exempt arm

    function test_burnOnlyFee_wholeFeeBurned_noSplitNoCustodyLeavesTheVault() public {
        address r0 = makeAddr("r0");
        vm.startPrank(admin);
        wm.setFeeSplit([r0, address(0), address(0)], [uint16(5_000), 0, 0], false);
        wm.setBurnOnlyFee(alice, true);
        vm.stopPrank();

        vm.prank(alice);
        wm.armBurnOnlyFee();
        vm.prank(address(vault));
        uint256 feeSharesToBurn = wm.canWithdrawFromUnallocated(100e18);
        assertEq(feeSharesToBurn, 100e18 * wm.DEFAULT_WITHDRAW_FEE() / WAD);
        assertEq(wm.owedSplitShares(), 0, "burn-only must skip the split entirely");
        assertEq(asset.balanceOf(r0), 0);

        // the arm is consumed: a second call from the vault is NOT burn-only (accrues the split again)
        vm.prank(address(vault));
        wm.canWithdrawFromUnallocated(100e18);
        assertGt(wm.owedSplitShares(), 0, "the burn-only arm should have been consumed by the first call");
    }

    function test_armBurnOnlyFee_notEnabled_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.NotBurnOnlyAccount.selector, alice));
        wm.armBurnOnlyFee();
    }

    function test_emergencyFeeExempt_zeroFee_oncePerArm() public {
        vm.startPrank(admin);
        wm.setProfitCustody(address(custody)); // the non-exempt fallback path needs a custody configured
        wm.setEmergencyFeeExempt(alice, true);
        vm.stopPrank();
        vm.prank(alice);
        wm.armEmergencyFeeExempt();

        vm.prank(address(vault));
        uint256 fee = wm.canWithdrawFromUnallocated(100e18);
        assertEq(fee, 0);

        // consumed: the next call pays the normal fee again
        vm.prank(address(vault));
        uint256 fee2 = wm.canWithdrawFromUnallocated(100e18);
        assertEq(fee2, 100e18 * wm.DEFAULT_WITHDRAW_FEE() / WAD);
    }

    function test_disarmEmergencyFeeExempt_clearsAnUnusedArm() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.NotEmergencyExemptAccount.selector, alice));
        wm.armEmergencyFeeExempt();
        vm.stopPrank();

        vm.startPrank(admin);
        wm.setProfitCustody(address(custody)); // the non-exempt fallback path needs a custody configured
        wm.setEmergencyFeeExempt(alice, true);
        vm.stopPrank();
        vm.startPrank(alice);
        wm.armEmergencyFeeExempt();
        wm.disarmEmergencyFeeExempt();
        vm.stopPrank();

        vm.prank(address(vault));
        uint256 fee = wm.canWithdrawFromUnallocated(100e18);
        assertEq(fee, 100e18 * wm.DEFAULT_WITHDRAW_FEE() / WAD, "disarm did not clear the exemption");
    }
}
