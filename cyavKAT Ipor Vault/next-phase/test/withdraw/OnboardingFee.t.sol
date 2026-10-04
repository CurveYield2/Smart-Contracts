// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CurveYieldWithdrawalManagerV2} from "../../src/withdraw/CurveYieldWithdrawalManagerV2.sol";
import {CurveYieldGovernanceGate} from "../../src/governance/CurveYieldGovernanceGate.sol";
import {FuseAction} from "../../src/withdraw/interfaces/CurveYieldKatanaInterfaces.sol";
import {MockAsset, MockAccessManager, MockProfitCustody, BurnHeldSharesEnterData} from "./WithdrawManagerMocks.sol";

/// @dev A vault stand-in WITH a share ledger: the WM's own share balance is what `committedShares` is checked against.
/// `deposit` models IPOR's native deposit fee: the fee shares are minted to the vault's withdraw manager.
contract LedgerVault is ERC20 {
    MockAsset public immutable ASSET;
    address public withdrawManager;
    uint256 public depositFeeBps; // FeeManager.setDepositFee, in bps of the minted shares

    constructor(MockAsset asset_) ERC20("cyavKAT", "cyavKAT") {
        ASSET = asset_;
    }

    function setWithdrawManager(address wm_) external {
        withdrawManager = wm_;
    }

    function setDepositFeeBps(uint256 bps_) external {
        depositFeeBps = bps_;
    }

    function asset() external view returns (address) {
        return address(ASSET);
    }

    function decimals() public pure override returns (uint8) {
        return 20;
    }

    function convertToAssets(uint256 shares_) external pure returns (uint256) {
        return shares_;
    }

    function convertToShares(uint256 assets_) external pure returns (uint256) {
        return assets_;
    }

    function previewRedeem(uint256 shares_) external pure returns (uint256) {
        return shares_;
    }

    /// @dev mints shares to the receiver (after the fee); the fee shares go to the withdraw manager.
    function deposit(uint256 assets_, address receiver_) external returns (uint256 minted_) {
        uint256 fee = assets_ * depositFeeBps / 10_000;
        minted_ = assets_ - fee;
        _mint(receiver_, minted_);
        if (fee != 0) _mint(withdrawManager, fee);
    }

    function mintTo(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }

    function ledgerMove(address from_, address to_, uint256 amount_) external {
        _transfer(from_, to_, amount_);
    }

    function ledgerBurn(address from_, uint256 amount_) external {
        _burn(from_, amount_);
    }

    function execute(FuseAction[] calldata actions_) external {
        for (uint256 i; i < actions_.length; ++i) {
            (bool ok, bytes memory ret) = actions_[i].fuse.call(actions_[i].data);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }
}

/// @dev Request-fee fuse that really moves shares on the ledger vault.
contract LedgerMoveFuse {
    LedgerVault public immutable VAULT;

    constructor(LedgerVault vault_) {
        VAULT = vault_;
    }

    function moveRequestFeeShares(address from_, address to_, uint256 amount_) external {
        VAULT.ledgerMove(from_, to_, amount_);
    }

    function configureManagerAssetAllowance(address) external {}
}

/// @dev Burn fuse that really burns the withdraw manager's shares; `fail` makes the burn revert.
contract LedgerBurnFuse {
    LedgerVault public immutable VAULT;
    bool public fail;

    constructor(LedgerVault vault_) {
        VAULT = vault_;
    }

    function setFail(bool fail_) external {
        fail = fail_;
    }

    function enter(BurnHeldSharesEnterData calldata data_) external {
        require(!fail, "burn failed");
        VAULT.ledgerBurn(VAULT.withdrawManager(), data_.maxShares);
    }
}

/// @notice ONBOARDING_FEE_SPEC unit tests of CurveYieldWithdrawalManagerV2: `committedShares` accounting, the pending
/// onboarding fee shares (the WM's vault-share balance above what it is accountable for), `settleOnboardingFee` (70% to
/// the profit custody, 30% to the onboarding admin, as vault shares) and `setOnboardingAdmin`.
contract OnboardingFeeTest is Test {
    uint256 constant WAD = 1e18;

    CurveYieldWithdrawalManagerV2 wm;
    MockAsset asset;
    LedgerVault vault;
    MockAccessManager am;
    LedgerMoveFuse moveFuse;
    LedgerBurnFuse burnFuse;
    CurveYieldGovernanceGate gate;

    address admin = makeAddr("admin"); // template permission (WM configurator)
    address controller = makeAddr("controller");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address custody = makeAddr("profitCustody");
    address onboardingAdmin = makeAddr("onboardingAdmin");
    address feeAuthority = makeAddr("feeAuthority");
    address dao = makeAddr("dao");

    /// @dev The test's own ledger of onboarding fee shares minted to the WM and not yet settled.
    uint256 onboardingOutstanding;

    function setUp() public {
        asset = new MockAsset();
        vault = new LedgerVault(asset);
        am = new MockAccessManager(admin);
        moveFuse = new LedgerMoveFuse(vault);
        burnFuse = new LedgerBurnFuse(vault);
        gate = new CurveYieldGovernanceGate(dao, feeAuthority);

        wm = new CurveYieldWithdrawalManagerV2(address(am), address(0xAAAA));
        vault.setWithdrawManager(address(wm));
        vm.startPrank(admin);
        wm.updatePlasmaVaultAddress(address(vault));
        wm.setDependencies(controller, address(burnFuse), address(moveFuse), address(0));
        wm.setProfitCustody(custody);
        wm.setOnboardingAdmin(onboardingAdmin);
        vm.stopPrank();

        vault.mintTo(alice, 100_000e18);
        vault.mintTo(bob, 100_000e18);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Core invariant: the WM's share balance is exactly what it is accountable for plus the unsettled onboarding
    /// shares (tracked independently by this test), and `pending` reports precisely those.
    function _inv(string memory where_) internal view {
        assertEq(
            vault.balanceOf(address(wm)),
            wm.committedShares() + onboardingOutstanding,
            string.concat("committedShares broke the share-balance identity after: ", where_)
        );
        assertEq(wm.pendingOnboardingFeeShares(), onboardingOutstanding, string.concat("pending != onboarding after: ", where_));
    }

    function _deposit(uint256 assets_, uint256 feeBps_) internal returns (uint256 fee_) {
        vault.setDepositFeeBps(feeBps_);
        fee_ = assets_ * feeBps_ / 10_000;
        vault.deposit(assets_, alice);
        onboardingOutstanding += fee_;
    }

    function _request(address who_, uint256 gross_) internal returns (uint256 fee_) {
        fee_ = (gross_ * wm.getRequestFee() + WAD - 1) / WAD;
        vm.prank(who_);
        wm.requestShares(gross_);
    }

    function _release(uint256 shares_) internal {
        vm.warp(block.timestamp + 2);
        vm.prank(controller);
        wm.releaseActiveShares(block.timestamp - 1, shares_);
    }

    // ---------------------------------------------------------------- deposit -> pending, exactly

    function test_depositFee030_mintsExactlyTheFeeSharesToThePending() public {
        uint256 aliceBefore = vault.balanceOf(alice);
        uint256 fee = _deposit(10_000e18, 30); // FeeManager.setDepositFee(0.30%)
        assertEq(fee, 30e18);
        assertEq(vault.balanceOf(alice) - aliceBefore, 9_970e18, "depositor must get shares x (1 - 0.30%)");
        assertEq(wm.pendingOnboardingFeeShares(), 30e18, "pending must be exactly the fee shares");
        assertEq(wm.committedShares(), 0, "fee shares are not request escrow");
        _inv("deposit");

        _deposit(1_234_567_891_011_121_314, 30); // odd amount: rounding is the vault's, pending follows the balance
        _inv("second deposit");
    }

    function test_noDepositFee_noPending_settleIsANoOp() public {
        vault.deposit(5_000e18, alice);
        assertEq(wm.pendingOnboardingFeeShares(), 0);
        assertEq(wm.settleOnboardingFee(), 0);
        assertEq(vault.balanceOf(custody), 0);
        assertEq(vault.balanceOf(onboardingAdmin), 0);
    }

    // ---------------------------------------------------------------- settle: 70 / 30 exactly

    function test_settleOnboardingFee_pays70custody30admin_asShares_permissionless() public {
        _deposit(10_000e18, 30); // 30 shares of fee
        vm.prank(makeAddr("anyone"));
        uint256 settled = wm.settleOnboardingFee();
        assertEq(settled, 30e18);
        assertEq(vault.balanceOf(custody), 21e18, "70% to the profit custody");
        assertEq(vault.balanceOf(onboardingAdmin), 9e18, "30% to the onboarding admin");
        onboardingOutstanding = 0;
        assertEq(vault.balanceOf(address(wm)), 0);
        assertEq(wm.pendingOnboardingFeeShares(), 0);
        _inv("settle");
        assertEq(wm.settleOnboardingFee(), 0, "nothing left to settle");
    }

    function test_settleOnboardingFee_oddAmount_noDust_custodyGets70Floor_adminTheRest() public {
        _deposit(3_333_333_333_333_333_333, 30);
        uint256 pending = wm.pendingOnboardingFeeShares();
        assertGt(pending, 0);
        wm.settleOnboardingFee();
        uint256 custodyShares = pending * 7_000 / 10_000;
        assertEq(vault.balanceOf(custody), custodyShares);
        assertEq(vault.balanceOf(onboardingAdmin), pending - custodyShares);
        assertEq(vault.balanceOf(address(wm)), 0, "dust left behind");
        onboardingOutstanding = 0;
        _inv("odd settle");
    }

    function test_settleOnboardingFee_missingReceivers_revert_andChangeNothing() public {
        CurveYieldWithdrawalManagerV2 bare = new CurveYieldWithdrawalManagerV2(address(am), address(0xAAAA));
        vault.setWithdrawManager(address(bare));
        vm.startPrank(admin);
        bare.updatePlasmaVaultAddress(address(vault));
        bare.setDependencies(controller, address(burnFuse), address(moveFuse), address(0));
        vm.stopPrank();
        vault.deposit(10_000e18, alice); // no fee configured: nothing pending
        vault.setDepositFeeBps(30);
        vault.deposit(10_000e18, alice);
        assertEq(bare.pendingOnboardingFeeShares(), 30e18);

        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.InvalidProfitCustody.selector, address(0)));
        bare.settleOnboardingFee();
        vm.prank(admin);
        bare.setProfitCustody(custody);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.InvalidOnboardingAdmin.selector, address(0)));
        bare.settleOnboardingFee();
        assertEq(bare.pendingOnboardingFeeShares(), 30e18, "a refused settle changed the balance");
    }

    // ---------------------------------------------------------------- setOnboardingAdmin

    function test_setOnboardingAdmin_noGate_templatePermission_noZeroNoSelf() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.UnauthorizedConfigurator.selector, alice, bytes4(keccak256("updateWithdrawFee(uint256)"))));
        wm.setOnboardingAdmin(alice);

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.InvalidOnboardingAdmin.selector, address(0)));
        wm.setOnboardingAdmin(address(0));
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.InvalidOnboardingAdmin.selector, address(wm)));
        wm.setOnboardingAdmin(address(wm));
        wm.setOnboardingAdmin(bob);
        vm.stopPrank();
        assertEq(wm.onboardingAdmin(), bob);
    }

    function test_setOnboardingAdmin_gateSet_feeAuthorityOnly_neverTheDaoNorTheTemplateAdmin() public {
        vm.prank(admin);
        wm.setConfigGate(address(gate));

        vm.prank(dao);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.NotFeeAuthority.selector, dao));
        wm.setOnboardingAdmin(bob);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.NotFeeAuthority.selector, admin));
        wm.setOnboardingAdmin(bob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldWithdrawalManagerV2.NotFeeAuthority.selector, alice));
        wm.setOnboardingAdmin(bob);

        vm.prank(feeAuthority);
        wm.setOnboardingAdmin(bob);
        assertEq(wm.onboardingAdmin(), bob);
    }

    // ---------------------------------------------------------------- committedShares across every flow

    function test_committedShares_request_replace_expiry_release_charge_earn_withOnboardingMixedIn() public {
        // 1. onboarding shares first
        _deposit(10_000e18, 30);
        _inv("deposit 1");

        // 2. request: the fee escrow becomes committed, the onboarding shares stay pending
        uint256 feeA = _request(alice, 1_000e18);
        assertEq(wm.committedShares(), feeA);
        _inv("alice request");
        uint256 feeB = _request(bob, 2_000e18);
        assertEq(wm.committedShares(), feeA + feeB);
        _inv("bob request");

        // 3. a deposit while requests are in flight: only the pending grows
        _deposit(5_000e18, 30);
        assertEq(wm.committedShares(), feeA + feeB, "a deposit must not touch the escrow");
        _inv("deposit during requests");

        // 4. replace: the unearned fee of the old request is refunded, a fresh one escrowed
        uint256 feeA2 = _request(alice, 3_000e18);
        assertEq(wm.committedShares(), feeA2 + feeB);
        _inv("alice replaces");

        // 5. a settle with requests in flight never touches the escrow
        uint256 aliceNet = wm.rawRequestInfo(alice).shares;
        uint256 pend = wm.pendingOnboardingFeeShares();
        assertEq(wm.settleOnboardingFee(), pend);
        onboardingOutstanding = 0;
        assertEq(wm.committedShares(), feeA2 + feeB, "settle changed committed shares");
        assertEq(vault.balanceOf(address(wm)), feeA2 + feeB, "settle paid out request escrow");
        assertEq(wm.rawRequestInfo(alice).shares, aliceNet);
        assertEq(wm.rawRequestInfo(alice).refundableFeeShares, feeA2, "settle changed a request's escrow");
        _inv("settle with requests in flight");

        // 6. partial release: the earned part is burned, committed drops by exactly it
        _deposit(2_000e18, 30);
        uint256 netB = 2_000e18 - feeB;
        uint256 committedBefore = wm.committedShares();
        uint256 supplyBefore = vault.totalSupply();
        _release(netB / 2);
        uint256 burned = supplyBefore - vault.totalSupply();
        assertGt(burned, 0, "release burned no fee");
        assertEq(wm.committedShares(), committedBefore - burned, "committed must drop by the burned earned fee");
        _inv("partial release");

        // 7. chargeRequest: shares pass through the manager and are burned: committed unchanged
        uint256 availableBob = wm.availableSharesOf(bob);
        assertGt(availableBob, 10e18);
        committedBefore = wm.committedShares();
        supplyBefore = vault.totalSupply();
        vm.prank(controller);
        wm.chargeRequest(bob, 10e18);
        assertEq(vault.totalSupply(), supplyBefore - 10e18, "charged shares must be burned");
        assertEq(wm.committedShares(), committedBefore, "a charge must not change committed shares");
        _inv("charge");

        // 8. earnRequestFees (native-exit lane): earned unearned-escrow is burned, committed drops by it
        committedBefore = wm.committedShares();
        supplyBefore = vault.totalSupply();
        vm.prank(controller);
        uint256 earned = wm.earnRequestFees(5e18, 0);
        assertGt(earned, 0);
        assertEq(supplyBefore - vault.totalSupply(), earned);
        assertEq(wm.committedShares(), committedBefore - earned);
        _inv("earn request fees");

        // 9. expiry: the unearned fee of an expired request is refunded, committed drops by the refund
        committedBefore = wm.committedShares();
        vm.warp(block.timestamp + wm.getWithdrawWindow() + 1);
        wm.pruneExpiredRequests(10);
        assertLt(wm.committedShares(), committedBefore, "expiry did not release the escrow");
        _inv("expiry refund");

        // 10. a final settle leaves the manager at exactly its commitments
        wm.settleOnboardingFee();
        onboardingOutstanding = 0;
        assertEq(vault.balanceOf(address(wm)), wm.committedShares());
        _inv("final settle");
    }

    function test_committedShares_failedBurn_isAtomic_nothingDrifts() public {
        _deposit(10_000e18, 30);
        uint256 fee = _request(alice, 1_000e18);
        uint256 net = 1_000e18 - fee;
        _inv("request");

        burnFuse.setFail(true);
        vm.warp(block.timestamp + 2);
        vm.prank(controller);
        vm.expectRevert(bytes("burn failed"));
        wm.releaseActiveShares(block.timestamp - 1, net);
        assertEq(wm.committedShares(), fee, "a reverted release changed committed shares");
        assertEq(wm.earnedFeeShares(), 0, "a reverted release left earned fee behind");
        _inv("failed release");

        burnFuse.setFail(false);
        vm.prank(controller);
        wm.releaseActiveShares(block.timestamp - 1, net);
        assertEq(wm.committedShares(), 0, "whole fee earned and burned");
        _inv("release after the burn works again");
    }

    function test_committedShares_requestWithZeroFeeRate_andManyRequesters() public {
        vm.prank(admin);
        wm.updateRequestFee(0);
        vm.prank(alice);
        wm.requestShares(100e18);
        assertEq(wm.committedShares(), 0, "no fee, nothing escrowed");
        vm.prank(admin);
        wm.updateRequestFee(0.0875e18);
        uint256 total;
        for (uint256 i; i < 5; ++i) {
            address u = makeAddr(string.concat("u", vm.toString(i)));
            vault.mintTo(u, 1_000e18);
            total += _request(u, 1_000e18 - i * 7e18);
            assertEq(wm.committedShares(), total);
            _inv("many requesters");
        }
    }

    /// @dev TODO(ONBOARDING_FEE_SPEC "Instant fee 0.90% fully burned"): the fork suite (Phase2Fork) asserts the real
    /// vault's PPS rises by exactly the 0.90% instant fee with nothing going to custody or admin; here the WM side is
    /// covered by test_canWithdrawFromUnallocated_wholeFeeBurned_custodyAndAdminGetNothing (WithdrawalManagerV2.t.sol).
}
