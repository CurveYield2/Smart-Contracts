// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CurveYieldProfitCustody} from "../../../deployed/phase1-controller/CurveYieldProfitCustody.sol";

/// @notice Exact deployed-source custody, including its OWN configurable two-recipient windup distribution.
/// No loop-profit splitter or POL feeder appears in this contract or can capture its fee-recipient payout.
contract OriginalProfitCustodyInvariantTest is Test {
    CurveYieldProfitCustody custody;
    address feeRecipient = makeAddr("originalFeeRecipient");
    address manager = makeAddr("rewardsManager");
    address stranger = makeAddr("stranger");
    function setUp() public {
        custody = new CurveYieldProfitCustody(address(this), feeRecipient, makeAddr("router"), manager, new address[](0));
    }
    function test_untouchedDistributionAndFeeDestination() public {
        assertEq(custody.feeRecipient(), feeRecipient);
        assertEq(custody.REWARDS_CLAIM_MANAGER(), manager);
        assertEq(custody.rewardManagerDistributionBps(), 1_600);
        assertEq(custody.feeRecipientDistributionBps(), 900);
        custody.setWindupDistributionBps(2_000, 1_100);
        assertEq(custody.rewardManagerDistributionBps(), 2_000);
        assertEq(custody.feeRecipientDistributionBps(), 1_100);
        assertEq(custody.feeRecipient(), feeRecipient);
    }
    function test_unauthorizedPartyCannotDivertRecipientOrChangeInternalSplit() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        custody.setFeeRecipient(stranger);
        vm.expectRevert();
        custody.setWindupDistributionBps(2_000, 1_100);
        vm.stopPrank();
        assertEq(custody.feeRecipient(), feeRecipient);
        assertEq(custody.feeRecipientDistributionBps(), 900);
    }
}
