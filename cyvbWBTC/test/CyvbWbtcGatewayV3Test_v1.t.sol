// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";

import "../contracts/CyvbWbtcGateway_v3.sol";
import "../contracts/CyvbWbtcGatewayGatePreHook_v2.sol";

contract MockPermitTokenCyvbWBTCV3TestV1 {
    string public constant name = "Mock vbWBTC";
    string public constant symbol = "mvbWBTC";
    uint8 public constant decimals = 8;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to_, uint256 amount_) external {
        balanceOf[to_] += amount_;
    }

    function approve(address spender_, uint256 amount_) external returns (bool) {
        allowance[msg.sender][spender_] = amount_;
        return true;
    }

    function transfer(address to_, uint256 amount_) external returns (bool) {
        _transfer(msg.sender, to_, amount_);
        return true;
    }

    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool) {
        uint256 allowed = allowance[from_][msg.sender];
        require(allowed >= amount_, "allowance");
        if (allowed != type(uint256).max) allowance[from_][msg.sender] = allowed - amount_;
        _transfer(from_, to_, amount_);
        return true;
    }

    function permit(
        address owner_,
        address spender_,
        uint256 value_,
        uint256 deadline_,
        uint8,
        bytes32,
        bytes32
    ) external {
        require(block.timestamp <= deadline_, "expired");
        allowance[owner_][spender_] = value_;
    }

    function _transfer(address from_, address to_, uint256 amount_) private {
        require(balanceOf[from_] >= amount_, "balance");
        balanceOf[from_] -= amount_;
        balanceOf[to_] += amount_;
    }
}

contract MockPlasmaVaultCyvbWBTCV3TestV1 {
    MockPermitTokenCyvbWBTCV3TestV1 public immutable TOKEN;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public preHook;

    constructor(address token_) {
        TOKEN = MockPermitTokenCyvbWBTCV3TestV1(token_);
    }

    function asset() external view returns (address) {
        return address(TOKEN);
    }

    function totalAssets() public view returns (uint256) {
        return TOKEN.balanceOf(address(this));
    }

    function setPreHook(address preHook_) external {
        preHook = preHook_;
    }

    function approve(address spender_, uint256 amount_) external returns (bool) {
        allowance[msg.sender][spender_] = amount_;
        return true;
    }

    function deposit(uint256 assets_, address receiver_) external returns (uint256 shares) {
        _runHook(msg.sig);
        shares = previewDeposit(assets_);
        require(shares != 0, "zero shares");
        require(TOKEN.transferFrom(msg.sender, address(this), assets_), "asset transfer");
        totalSupply += shares;
        balanceOf[receiver_] += shares;
    }

    function mint(uint256 shares_, address receiver_) external returns (uint256 assets) {
        _runHook(msg.sig);
        assets = previewMint(shares_);
        require(TOKEN.transferFrom(msg.sender, address(this), assets), "asset transfer");
        totalSupply += shares_;
        balanceOf[receiver_] += shares_;
    }

    function withdraw(uint256 assets_, address receiver_, address owner_) external returns (uint256 shares) {
        _runHook(msg.sig);
        shares = previewWithdraw(assets_);
        _spendShareAllowance(owner_, shares);
        _burn(owner_, shares);
        require(TOKEN.transfer(receiver_, assets_), "asset transfer");
    }

    function redeem(uint256 shares_, address receiver_, address owner_) external returns (uint256 assets) {
        _runHook(msg.sig);
        assets = previewRedeem(shares_);
        _spendShareAllowance(owner_, shares_);
        _burn(owner_, shares_);
        require(TOKEN.transfer(receiver_, assets), "asset transfer");
    }

    function depositWithPermit(
        uint256 assets_,
        address receiver_,
        uint256,
        uint8,
        bytes32,
        bytes32
    ) external returns (uint256 shares) {
        _runHook(msg.sig);
        shares = previewDeposit(assets_);
        require(TOKEN.transferFrom(msg.sender, address(this), assets_), "asset transfer");
        totalSupply += shares;
        balanceOf[receiver_] += shares;
    }

    function previewDeposit(uint256 assets_) public view returns (uint256 shares) {
        uint256 supply = totalSupply;
        uint256 assetsBefore = totalAssets();
        if (supply == 0 || assetsBefore == 0) return assets_;
        return (assets_ * supply) / assetsBefore;
    }

    function previewMint(uint256 shares_) public view returns (uint256 assets) {
        uint256 supply = totalSupply;
        uint256 assetsBefore = totalAssets();
        if (supply == 0 || assetsBefore == 0) return shares_;
        return _ceilDiv(shares_ * assetsBefore, supply);
    }

    function previewWithdraw(uint256 assets_) public view returns (uint256 shares) {
        uint256 supply = totalSupply;
        uint256 assetsBefore = totalAssets();
        require(supply != 0 && assetsBefore != 0, "empty");
        return _ceilDiv(assets_ * supply, assetsBefore);
    }

    function previewRedeem(uint256 shares_) public view returns (uint256 assets) {
        uint256 supply = totalSupply;
        if (supply == 0) return 0;
        return (shares_ * totalAssets()) / supply;
    }

    function _spendShareAllowance(address owner_, uint256 shares_) private {
        if (msg.sender == owner_) return;
        uint256 allowed = allowance[owner_][msg.sender];
        require(allowed >= shares_, "share allowance");
        if (allowed != type(uint256).max) allowance[owner_][msg.sender] = allowed - shares_;
    }

    function _burn(address owner_, uint256 shares_) private {
        require(balanceOf[owner_] >= shares_, "shares");
        balanceOf[owner_] -= shares_;
        totalSupply -= shares_;
    }

    function _runHook(bytes4 selector_) private {
        address hook = preHook;
        if (hook == address(0)) return;
        (bool ok, bytes memory result) = hook.delegatecall(
            abi.encodeCall(CyvbWbtcGatewayGatePreHook_v2.run, (selector_))
        );
        if (!ok) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    function _ceilDiv(uint256 a_, uint256 b_) private pure returns (uint256) {
        if (a_ == 0) return 0;
        return ((a_ - 1) / b_) + 1;
    }
}

contract CyvbWbtcGatewayV3Test_v1 is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant ADMIN = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;

    MockPermitTokenCyvbWBTCV3TestV1 internal token;
    MockPlasmaVaultCyvbWBTCV3TestV1 internal vault;
    CyvbWbtcGateway_v3 internal gateway;
    CyvbWbtcGatewayGatePreHook_v2 internal preHook;

    function setUp() public {
        token = new MockPermitTokenCyvbWBTCV3TestV1();
        vault = new MockPlasmaVaultCyvbWBTCV3TestV1(address(token));
        gateway = new CyvbWbtcGateway_v3(address(vault), address(token));
        preHook = new CyvbWbtcGatewayGatePreHook_v2(address(vault), address(gateway));
        vault.setPreHook(address(preHook));

        token.mint(ALICE, 10e8);
        token.mint(BOB, 10e8);

        vm.prank(ALICE);
        token.approve(address(gateway), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(gateway), type(uint256).max);
    }

    function testFirstDepositBurnsOnboardingFeeAndCreatesNoOrphan() public {
        uint256 gross = 1e8;
        uint256 fee = (gross * 55) / 10_000;
        uint256 net = gross - fee;

        vm.prank(ALICE);
        uint256 shares = gateway.deposit(gross, ALICE, net);

        assertEq(shares, net);
        assertEq(vault.balanceOf(ALICE), net);
        assertEq(token.balanceOf(address(vault)), net);
        assertEq(token.balanceOf(gateway.BURN_SINK()), fee);
        assertEq(token.balanceOf(ADMIN), 0);
        assertEq(token.balanceOf(address(gateway)), 0);
    }

    function testSecondDepositFeeIsPpsAccretiveAndNotAdminRevenue() public {
        vm.prank(ALICE);
        gateway.deposit(1e8, ALICE, 0);

        uint256 aliceShares = vault.balanceOf(ALICE);
        uint256 aliceValueBefore = vault.previewRedeem(aliceShares);

        vm.prank(BOB);
        gateway.deposit(1e8, BOB, 0);

        uint256 aliceValueAfter = vault.previewRedeem(aliceShares);

        assertGt(aliceValueAfter, aliceValueBefore, "existing holder did not benefit");
        assertEq(token.balanceOf(ADMIN), 0, "operation fee reached admin");
        assertEq(token.balanceOf(address(gateway)), 0, "gateway retained assets");
    }

    function testDepositWithPermitChargesSameFee() public {
        uint256 gross = 2e8;
        uint256 fee = (gross * 55) / 10_000;

        vm.prank(ALICE);
        token.approve(address(gateway), 0);

        vm.prank(ALICE);
        gateway.depositWithPermit(
            gross,
            ALICE,
            0,
            block.timestamp + 1,
            27,
            bytes32(0),
            bytes32(0)
        );

        assertEq(token.balanceOf(gateway.BURN_SINK()), fee);
        assertEq(token.allowance(ALICE, address(gateway)), 0);
    }

    function testMintChargesOnboardingFeeAndUsesExactShares() public {
        uint256 sharesWanted = 1e8;

        (uint256 gross,, uint256 net) = gateway.previewMint(sharesWanted);

        vm.prank(ALICE);
        uint256 paid = gateway.mint(sharesWanted, ALICE, gross);

        assertEq(paid, gross);
        assertEq(vault.balanceOf(ALICE), sharesWanted);
        assertEq(token.balanceOf(address(vault)), net);
        assertEq(token.balanceOf(gateway.BURN_SINK()), gross - net);
    }

    function testDirectVaultEntryAndExitAreBlocked() public {
        vm.startPrank(ALICE);
        token.approve(address(vault), type(uint256).max);

        vm.expectRevert(CyvbWbtcGatewayGatePreHook_v2.GatewayRequired.selector);
        vault.deposit(1e8, ALICE);

        vm.expectRevert(CyvbWbtcGatewayGatePreHook_v2.GatewayRequired.selector);
        vault.mint(1e8, ALICE);

        vm.expectRevert(CyvbWbtcGatewayGatePreHook_v2.GatewayRequired.selector);
        vault.depositWithPermit(1e8, ALICE, block.timestamp + 1, 27, bytes32(0), bytes32(0));
        vm.stopPrank();

        vm.prank(ALICE);
        gateway.deposit(1e8, ALICE, 0);

        vm.startPrank(ALICE);
        vm.expectRevert(CyvbWbtcGatewayGatePreHook_v2.GatewayRequired.selector);
        vault.withdraw(1, ALICE, ALICE);

        vm.expectRevert(CyvbWbtcGatewayGatePreHook_v2.GatewayRequired.selector);
        vault.redeem(1, ALICE, ALICE);
        vm.stopPrank();
    }

    function testUnauthorizedCallerCannotConsumeOwnersGatewayAllowance() public {
        vm.prank(ALICE);
        gateway.deposit(1e8, ALICE, 0);

        vm.prank(ALICE);
        vault.approve(address(gateway), type(uint256).max);

        uint256 shares = vault.balanceOf(ALICE) / 4;

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(CyvbWbtcGateway_v3.UnauthorizedCaller.selector, BOB, ALICE)
        );
        gateway.redeem(shares, BOB, ALICE, 0);

        assertEq(vault.balanceOf(ALICE), 99_450_000);
    }

    function testApprovedOperatorCanRedeemForOwner() public {
        vm.prank(ALICE);
        gateway.deposit(1e8, ALICE, 0);

        vm.prank(ALICE);
        vault.approve(address(gateway), type(uint256).max);

        vm.prank(ALICE);
        gateway.setOperator(BOB, true);

        uint256 shares = vault.balanceOf(ALICE) / 4;
        uint256 bobBefore = token.balanceOf(BOB);

        vm.prank(BOB);
        (, uint256 netAssets) = gateway.redeem(shares, BOB, ALICE, 0);

        assertEq(token.balanceOf(BOB) - bobBefore, netAssets);
        assertLt(vault.balanceOf(ALICE), 99_450_000);
    }

    function testPartialExitFeeAccruesToRemainingHolder() public {
        vm.prank(ALICE);
        gateway.deposit(1e8, ALICE, 0);
        vm.prank(BOB);
        gateway.deposit(1e8, BOB, 0);

        vm.prank(ALICE);
        vault.approve(address(gateway), type(uint256).max);

        uint256 bobShares = vault.balanceOf(BOB);
        uint256 bobValueBefore = vault.previewRedeem(bobShares);

        vm.prank(ALICE);
        gateway.redeem(vault.balanceOf(ALICE) / 2, ALICE, ALICE, 0);

        uint256 bobValueAfter = vault.previewRedeem(bobShares);
        assertGt(bobValueAfter, bobValueBefore, "remaining holder did not receive exit fee");
        assertEq(token.balanceOf(ADMIN), 0);
    }

    function testLastHolderFullExitBurnsFeeAndLeavesVaultEmpty() public {
        vm.prank(ALICE);
        gateway.deposit(1e8, ALICE, 0);

        vm.prank(ALICE);
        vault.approve(address(gateway), type(uint256).max);

        uint256 burnBefore = token.balanceOf(gateway.BURN_SINK());
        uint256 shares = vault.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 gross, uint256 net) = gateway.redeem(shares, ALICE, ALICE, 0);

        uint256 expectedExitFee = (gross * 35) / 10_000;
        assertEq(gross - net, expectedExitFee);
        assertEq(token.balanceOf(gateway.BURN_SINK()) - burnBefore, expectedExitFee);
        assertEq(vault.totalSupply(), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(address(gateway)), 0);
    }

    function testNewDepositorAfterZeroSupplyCannotCapturePriorFee() public {
        vm.prank(ALICE);
        gateway.deposit(1e8, ALICE, 0);
        vm.prank(ALICE);
        vault.approve(address(gateway), type(uint256).max);
        vm.prank(ALICE);
        gateway.redeem(vault.balanceOf(ALICE), ALICE, ALICE, 0);

        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);

        uint256 burnBefore = token.balanceOf(gateway.BURN_SINK());

        vm.prank(BOB);
        uint256 bobShares = gateway.deposit(1e8, BOB, 0);

        assertEq(bobShares, 99_450_000);
        assertEq(vault.previewRedeem(bobShares), 99_450_000);
        assertGt(token.balanceOf(gateway.BURN_SINK()), burnBefore);
    }
}
