// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";

import "../contracts/CyvbWbtcLtvConfig_v3.sol";
import "../contracts/CyvbWbtcGateway_v5.sol";
import "../contracts/CyvbWbtcGatewayGatePreHook_v3.sol";

contract MockVbWbtc_v1 {
    string public constant name = "Mock vbWBTC";
    string public constant symbol = "vbWBTC";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract MockPlasmaVault_v1 {
    MockVbWbtc_v1 public immutable token;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address token_) {
        token = MockVbWbtc_v1(token_);
    }

    function asset() external view returns (address) {
        return address(token);
    }

    function totalAssets() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function approveShares(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        if (totalSupply == 0) return assets;
        uint256 assetsBefore = totalAssets();
        return assetsBefore == 0 ? assets : (assets * totalSupply) / assetsBefore;
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        if (totalSupply == 0) return assets;
        uint256 ta = totalAssets();
        return _ceilDiv(assets * totalSupply, ta);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        if (totalSupply == 0) return shares;
        return (shares * totalAssets()) / totalSupply;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return previewRedeem(shares);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = previewDeposit(assets);
        require(shares != 0, "zero shares");
        require(token.transferFrom(msg.sender, address(this), assets), "transferFrom");
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = previewWithdraw(assets);
        _spendShares(owner, shares);
        totalSupply -= shares;
        balanceOf[owner] -= shares;
        require(token.transfer(receiver, assets), "transfer");
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        assets = previewRedeem(shares);
        _spendShares(owner, shares);
        totalSupply -= shares;
        balanceOf[owner] -= shares;
        require(token.transfer(receiver, assets), "transfer");
    }

    function runGate(address hook, bytes4 selector) external {
        (bool ok, bytes memory data) = hook.delegatecall(abi.encodeWithSignature("run(bytes4)", selector));
        if (!ok) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
    }

    function _spendShares(address owner, uint256 shares) internal {
        if (msg.sender == owner) return;
        uint256 allowed = allowance[owner][msg.sender];
        require(allowed >= shares, "share allowance");
        if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : ((a - 1) / b) + 1;
    }
}

contract CyvbWbtcCoreTest_v3 is Test {
    MockVbWbtc_v1 internal token;
    MockPlasmaVault_v1 internal vault;
    CyvbWbtcGateway_v5 internal gateway;
    CyvbWbtcGatewayGatePreHook_v3 internal gate;
    CyvbWbtcLtvConfig_v3 internal config;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        token = new MockVbWbtc_v1();
        vault = new MockPlasmaVault_v1(address(token));
        gateway = new CyvbWbtcGateway_v5(address(vault), address(token));
        gate = new CyvbWbtcGatewayGatePreHook_v3(address(vault), address(gateway));
        config = new CyvbWbtcLtvConfig_v3(address(this));

        token.mint(ALICE, 100_000 ether);
        token.mint(BOB, 100_000 ether);

        vm.prank(ALICE);
        token.approve(address(gateway), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(gateway), type(uint256).max);
    }

    function test_configDefaultsAndRelativeRanges() public {
        CyvbWbtcLtvConfig_v3.LtvPolicy memory p = config.getLtvPolicy();
        assertEq(p.targetLtvBps, 5_000);
        assertEq(p.highTriggerBps, 6_000);
        assertEq(p.highResetBps, 5_800);
        assertEq(p.lowTriggerBps, 4_500);
        assertEq(p.lowResetBps, 5_000);
        assertEq(config.INSTANT_WITHDRAW_MAX_LTV_BPS(), 5_500);

        config.setLtvPolicy(5_000, 6_600, 6_380, 4_050, 4_500);
        p = config.getLtvPolicy();
        assertEq(p.highTriggerBps, 6_600);
        assertEq(p.highResetBps, 6_380);
        assertEq(p.lowTriggerBps, 4_050);
        assertEq(p.lowResetBps, 4_500);

        vm.expectRevert(CyvbWbtcLtvConfig_v3.ValueOutOfRange.selector);
        config.setLtvPolicy(4_499, 6_000, 5_800, 4_500, 5_000);

        vm.expectRevert(CyvbWbtcLtvConfig_v3.InvalidOrdering.selector);
        config.setLtvPolicy(5_000, 5_400, 5_220, 4_950, 4_500);
    }

    function test_configBindsVaultAndRecordsOnePosition() public {
        config.bindVault(address(vault));
        vm.prank(address(vault));
        config.recordPositionId(123);
        assertEq(config.positionId(), 123);

        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(CyvbWbtcLtvConfig_v3.PositionAlreadySet.selector, 123));
        config.recordPositionId(456);
    }

    function test_onboardingFeeIsRetainedInVaultAndAccretesPps() public {
        uint256 gross = 10_000 ether;
        uint256 fee = (gross * gateway.ONBOARDING_FEE_BPS()) / gateway.BPS();

        vm.prank(ALICE);
        uint256 aliceShares = gateway.deposit(gross, ALICE, 0);

        assertEq(token.balanceOf(address(vault)), gross);
        assertEq(vault.totalSupply(), gross - fee);
        assertEq(aliceShares, gross - fee);

        uint256 aliceValueBefore = vault.previewRedeem(aliceShares);

        vm.prank(BOB);
        gateway.deposit(gross, BOB, 0);

        uint256 aliceValueAfter = vault.previewRedeem(aliceShares);
        assertGt(aliceValueAfter, aliceValueBefore);
        assertEq(token.balanceOf(address(vault)), gross * 2);
        assertEq(token.balanceOf(address(gateway)), 0);
    }

    function test_instantExitFeeReturnsToVaultForRemainingHolders() public {
        uint256 grossDeposit = 20_000 ether;
        vm.prank(ALICE);
        gateway.deposit(grossDeposit, ALICE, 0);
        vm.prank(BOB);
        gateway.deposit(grossDeposit, BOB, 0);

        vm.prank(ALICE);
        vault.approveShares(address(gateway), type(uint256).max);

        uint256 grossExit = 1_000 ether;
        uint256 fee = (grossExit * gateway.INSTANT_EXIT_FEE_BPS()) / gateway.BPS();
        uint256 beforeVaultAssets = vault.totalAssets();
        uint256 beforeAliceAssets = token.balanceOf(ALICE);

        vm.prank(ALICE);
        (, uint256 netAssets) = gateway.withdraw(grossExit, ALICE, ALICE, type(uint256).max);

        assertEq(netAssets, grossExit - fee);
        assertEq(token.balanceOf(ALICE) - beforeAliceAssets, grossExit - fee);
        assertEq(vault.totalAssets(), beforeVaultAssets - grossExit + fee);
        assertEq(token.balanceOf(address(gateway)), 0);
    }

    function test_finalShareExitWaivesFeeAndLeavesNoOrphanAssets() public {
        uint256 grossDeposit = 10_000 ether;
        vm.prank(ALICE);
        gateway.deposit(grossDeposit, ALICE, 0);

        uint256 allShares = vault.balanceOf(ALICE);
        vm.prank(ALICE);
        vault.approveShares(address(gateway), type(uint256).max);

        uint256 beforeAlice = token.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 grossAssets, uint256 netAssets) = gateway.redeem(allShares, ALICE, ALICE, 0);

        assertEq(netAssets, grossAssets);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(token.balanceOf(ALICE) - beforeAlice, grossAssets);
    }

    function test_previewFinalRedeemWaivesExitFee() public {
        uint256 grossDeposit = 10_000 ether;
        vm.prank(ALICE);
        gateway.deposit(grossDeposit, ALICE, 0);

        uint256 allShares = vault.balanceOf(ALICE);
        (uint256 grossAssets, uint256 feeAssets, uint256 netAssets) =
            gateway.previewRedeem(allShares);

        assertGt(grossAssets, 0);
        assertEq(feeAssets, 0);
        assertEq(netAssets, grossAssets);
    }

    function test_gateRejectsDirectVaultUserAndAllowsGateway() public {
        bytes4 depositSelector = bytes4(keccak256("deposit(uint256,address)"));

        vm.expectRevert(
            abi.encodeWithSelector(
                CyvbWbtcGatewayGatePreHook_v3.GatewayRequired.selector,
                address(this),
                depositSelector
            )
        );
        vault.runGate(address(gate), depositSelector);

        vm.prank(address(gateway));
        vault.runGate(address(gate), depositSelector);
    }
}
