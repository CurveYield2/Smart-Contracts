// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CurveYieldBundleGuardFuse} from "../../src/generic/CurveYieldBundleGuardFuse.sol";
import {CurveYieldErc20TransferFuse, CurveYieldErc20TransferFuseEnterData} from "../../src/generic/CurveYieldErc20TransferFuse.sol";
import {CurveYieldBurnHeldSharesFuse} from "../../src/generic/CurveYieldBurnHeldSharesFuse.sol";
import {CurveYieldRequestFeeSharesFuse} from "../../src/withdraw/CurveYieldRequestFeeSharesFuse.sol";
import {CurveYieldRateAwareBalancerBalanceFuse} from "../../src/generic/CurveYieldRateAwareBalancerBalanceFuse.sol";
import {CurveYieldErc1271ConfigFuse} from "../../src/generic/CurveYieldErc1271ConfigFuse.sol";
import {CurveYieldErc1271InstallFuse} from "../../src/generic/CurveYieldErc1271InstallFuse.sol";

/// @notice R1 / R3 / R8 and forbidden administrative selectors for all generic custom fuse families.
/// @dev Does not assert live-vault permission effects (those require the fork conformance suite).
contract FuseConformanceV6Test is Test {
    CurveYieldBundleGuardFuse guard;
    CurveYieldErc20TransferFuse transferFuse;
    CurveYieldBurnHeldSharesFuse burnFuse;
    CurveYieldRequestFeeSharesFuse requestFuse;
    CurveYieldRateAwareBalancerBalanceFuse balancerFuse;
    CurveYieldErc1271ConfigFuse signingConfig;
    CurveYieldErc1271InstallFuse signingInstall;

    function setUp() public {
        guard = new CurveYieldBundleGuardFuse(1, makeAddr("morpho"));
        transferFuse = new CurveYieldErc20TransferFuse(7);
        burnFuse = new CurveYieldBurnHeldSharesFuse(type(uint256).max);
        requestFuse = new CurveYieldRequestFeeSharesFuse(type(uint256).max);
        balancerFuse = new CurveYieldRateAwareBalancerBalanceFuse(36);
        signingConfig = new CurveYieldErc1271ConfigFuse(type(uint256).max);
        signingInstall = new CurveYieldErc1271InstallFuse(type(uint256).max);
    }

    function test_versionAndMarketIdentity() public {
        assertEq(guard.VERSION(), address(guard));
        assertEq(transferFuse.VERSION(), address(transferFuse));
        assertEq(burnFuse.VERSION(), address(burnFuse));
        assertEq(requestFuse.VERSION(), address(requestFuse));
        assertEq(balancerFuse.VERSION(), address(balancerFuse));
        assertEq(signingConfig.VERSION(), address(signingConfig));
        assertEq(signingInstall.VERSION(), address(signingInstall));
        assertEq(transferFuse.MARKET_ID(), 7);
        assertEq(balancerFuse.MARKET_ID(), 36);
    }

    function test_zeroMarketIdAlwaysReverts() public {
        vm.expectRevert(CurveYieldBundleGuardFuse.CurveYieldBundleGuardFuseInvalidMarketId.selector);
        new CurveYieldBundleGuardFuse(0, makeAddr("morpho"));
        vm.expectRevert(CurveYieldErc20TransferFuse.CurveYieldErc20TransferFuseInvalidMarketId.selector);
        new CurveYieldErc20TransferFuse(0);
        vm.expectRevert(CurveYieldBurnHeldSharesFuse.CurveYieldBurnHeldSharesFuseInvalidMarketId.selector);
        new CurveYieldBurnHeldSharesFuse(0);
        vm.expectRevert(CurveYieldRequestFeeSharesFuse.CurveYieldRequestFeeSharesFuseInvalidMarketId.selector);
        new CurveYieldRequestFeeSharesFuse(0);
        vm.expectRevert(CurveYieldRateAwareBalancerBalanceFuse.CurveYieldRateAwareBalancerBalanceFuseInvalidMarketId.selector);
        new CurveYieldRateAwareBalancerBalanceFuse(0);
        vm.expectRevert(CurveYieldErc1271ConfigFuse.CurveYieldErc1271ConfigFuseInvalidMarketId.selector);
        new CurveYieldErc1271ConfigFuse(0);
        vm.expectRevert(CurveYieldErc1271InstallFuse.CurveYieldErc1271InstallFuseInvalidMarketId.selector);
        new CurveYieldErc1271InstallFuse(0);
    }

    function test_noOwnerOrExecuteInternalSelector() public {
        address[7] memory fuses = [address(guard),address(transferFuse),address(burnFuse),address(requestFuse),
                                   address(balancerFuse),address(signingConfig),address(signingInstall)];
        for (uint256 i; i < fuses.length; ++i) {
            (bool isOwner,) = fuses[i].staticcall(abi.encodeWithSignature("owner()"));
            assertFalse(isOwner, "fuse has owner() selector");
            (bool internalExecution,) = fuses[i].call(abi.encodeWithSignature("executeInternal(bytes)"));
            assertFalse(internalExecution, "fuse has executeInternal selector");
        }
    }

    function test_zeroTransferIsNoopAndUngrantedTransferFails() public {
        assertEq(transferFuse.enter(CurveYieldErc20TransferFuseEnterData({
            token: makeAddr("token"), to: makeAddr("recipient"), amount: 0
        })), 0);
        vm.expectRevert();
        transferFuse.enter(CurveYieldErc20TransferFuseEnterData({
            token: makeAddr("token"), to: makeAddr("recipient"), amount: 1
        }));
    }

    function test_invalidTransientLayoutsRevertRatherThanApplyChanges() public {
        vm.expectRevert(CurveYieldBundleGuardFuse.CurveYieldBundleGuardFuseInvalidTransientInputs.selector);
        guard.enterTransient();
        vm.expectRevert(CurveYieldBundleGuardFuse.CurveYieldBundleGuardFuseInvalidTransientInputs.selector);
        guard.exitTransient();
        vm.expectRevert(CurveYieldRequestFeeSharesFuse.CurveYieldRequestFeeSharesFuseInvalidTransientInputs.selector);
        requestFuse.enterTransient();
        vm.expectRevert(CurveYieldErc1271ConfigFuse.CurveYieldErc1271ConfigFuseInvalidTransientInputs.selector);
        signingConfig.enterTransient();
        vm.expectRevert(CurveYieldErc1271InstallFuse.CurveYieldErc1271InstallFuseInvalidTransientInputs.selector);
        signingInstall.enterTransient();
    }
}
