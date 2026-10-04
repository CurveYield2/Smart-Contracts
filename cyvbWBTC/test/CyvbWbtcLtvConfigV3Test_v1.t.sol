// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "../contracts/CyvbWbtcLtvConfig_v3.sol";

contract VaultCallerCyvbWbtcLtvV3TestV1 {
    function record(CyvbWbtcLtvConfig_v3 config_, uint256 id_) external {
        config_.recordPositionId(id_);
    }
}

contract CyvbWbtcLtvConfigV3Test_v1 is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant NEXT_OWNER = address(0xB0B);

    CyvbWbtcLtvConfig_v3 internal config;
    VaultCallerCyvbWbtcLtvV3TestV1 internal vault;

    function setUp() public {
        config = new CyvbWbtcLtvConfig_v3(OWNER);
        vault = new VaultCallerCyvbWbtcLtvV3TestV1();

        vm.prank(OWNER);
        config.bindVault(address(vault));
    }

    function testDefaultsAndFixedWithdrawalCeiling() public view {
        CyvbWbtcLtvConfig_v3.LtvPolicy memory p = config.getLtvPolicy();
        assertEq(p.targetLtvBps, 5000);
        assertEq(p.highTriggerBps, 6000);
        assertEq(p.highResetBps, 5800);
        assertEq(p.lowTriggerBps, 4500);
        assertEq(p.lowResetBps, 5000);
        assertEq(config.INSTANT_WITHDRAW_MAX_LTV_BPS(), 5500);
    }

    function testRelativeRangeConstantsAreCorrect() public view {
        assertEq(config.MIN_TARGET_LTV_BPS(), 4500);
        assertEq(config.MAX_TARGET_LTV_BPS(), 5500);
        assertEq(config.MIN_HIGH_TRIGGER_BPS(), 5400);
        assertEq(config.MAX_HIGH_TRIGGER_BPS(), 6600);
        assertEq(config.MIN_HIGH_RESET_BPS(), 5220);
        assertEq(config.MAX_HIGH_RESET_BPS(), 6380);
        assertEq(config.MIN_LOW_TRIGGER_BPS(), 4050);
        assertEq(config.MAX_LOW_TRIGGER_BPS(), 4950);
        assertEq(config.MIN_LOW_RESET_BPS(), 4500);
        assertEq(config.MAX_LOW_RESET_BPS(), 5500);
    }

    function testOwnerCanSetValidBoundaryPolicies() public {
        vm.prank(OWNER);
        config.setLtvPolicy(4500, 5400, 5220, 4050, 4500);

        CyvbWbtcLtvConfig_v3.LtvPolicy memory low = config.getLtvPolicy();
        assertEq(low.targetLtvBps, 4500);
        assertEq(low.highTriggerBps, 5400);
        assertEq(low.highResetBps, 5220);
        assertEq(low.lowTriggerBps, 4050);
        assertEq(low.lowResetBps, 4500);

        vm.prank(OWNER);
        config.setLtvPolicy(5500, 6600, 6380, 4950, 5500);

        CyvbWbtcLtvConfig_v3.LtvPolicy memory high = config.getLtvPolicy();
        assertEq(high.targetLtvBps, 5500);
        assertEq(high.highTriggerBps, 6600);
        assertEq(high.highResetBps, 6380);
        assertEq(high.lowTriggerBps, 4950);
        assertEq(high.lowResetBps, 5500);
    }

    function testOutOfRangeAndInvalidOrderingRevert() public {
        vm.startPrank(OWNER);

        vm.expectRevert(CyvbWbtcLtvConfig_v3.ValueOutOfRange.selector);
        config.setLtvPolicy(4499, 6000, 5800, 4500, 5000);

        vm.expectRevert(CyvbWbtcLtvConfig_v3.ValueOutOfRange.selector);
        config.setLtvPolicy(5000, 6601, 5800, 4500, 5000);

        vm.expectRevert(CyvbWbtcLtvConfig_v3.InvalidOrdering.selector);
        config.setLtvPolicy(5000, 6000, 5800, 4950, 4900);

        vm.expectRevert(CyvbWbtcLtvConfig_v3.InvalidOrdering.selector);
        config.setLtvPolicy(5500, 5400, 5220, 4050, 4500);

        vm.stopPrank();
    }

    function testNonOwnerCannotChangePolicy() public {
        vm.prank(NEXT_OWNER);
        vm.expectRevert(CyvbWbtcLtvConfig_v3.NotOwner.selector);
        config.setLtvPolicy(5000, 6000, 5800, 4500, 5000);
    }

    function testVaultBindingIsOneTime() public {
        vm.prank(OWNER);
        vm.expectRevert(CyvbWbtcLtvConfig_v3.VaultAlreadySet.selector);
        config.bindVault(address(new VaultCallerCyvbWbtcLtvV3TestV1()));
    }

    function testPositionIdCanOnlyBeRecordedByBoundVaultAndOnlyOnce() public {
        vm.expectRevert(CyvbWbtcLtvConfig_v3.NotVault.selector);
        config.recordPositionId(42);

        vault.record(config, 42);
        assertEq(config.positionId(), 42);

        vm.expectRevert(abi.encodeWithSelector(CyvbWbtcLtvConfig_v3.PositionAlreadySet.selector, 42));
        vault.record(config, 43);
    }

    function testOwnershipTransferIsTwoStep() public {
        vm.prank(OWNER);
        config.transferOwnership(NEXT_OWNER);

        assertEq(config.owner(), OWNER);
        assertEq(config.pendingOwner(), NEXT_OWNER);

        vm.prank(NEXT_OWNER);
        config.acceptOwnership();

        assertEq(config.owner(), NEXT_OWNER);
        assertEq(config.pendingOwner(), address(0));
    }
}
