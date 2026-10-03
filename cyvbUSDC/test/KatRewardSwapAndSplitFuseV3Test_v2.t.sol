// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "../contracts/KatRewardSwapAndSplitFuse_v3.sol";

contract MockTokenCyvbUSDCV1 {
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
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract MockRewardRouterCyvbUSDCV1 {
    bool public routeEnabled = true;
    bool public shouldRevert;
    uint256 public amountOut;

    function setRouteEnabled(bool value) external {
        routeEnabled = value;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function setAmountOut(uint256 value) external {
        amountOut = value;
    }

    function routeFor(address, address) external view returns (bytes memory) {
        return routeEnabled ? abi.encodePacked(bytes1(0x01)) : new bytes(0);
    }

    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minNetAmountOut,
        address recipient,
        uint256
    ) external returns (uint256 netAmountOut) {
        if (shouldRevert) revert("router revert");

        MockTokenCyvbUSDCV1(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        netAmountOut = amountOut;
        require(netAmountOut >= minNetAmountOut, "minimum");
        MockTokenCyvbUSDCV1(tokenOut).mint(recipient, netAmountOut);
    }
}

contract MockRewardsManagerCyvbUSDCV1 {
    address public immutable TOKEN;

    ICurveYieldRewardsClaimManagerV3.VestingData private _vesting;
    uint256 private _vestedBalance;

    constructor(address token_) {
        TOKEN = token_;
        _vesting.vestingTime = uint32(15 days);
    }

    function balanceOf() external view returns (uint256) {
        return _vestedBalance;
    }

    function getVestingData() external view returns (ICurveYieldRewardsClaimManagerV3.VestingData memory) {
        return _vesting;
    }

    function updateBalance() external {
        uint256 current = MockTokenCyvbUSDCV1(TOKEN).balanceOf(address(this));
        _vesting.updateBalanceTimestamp = uint32(block.timestamp);
        _vesting.transferredTokens = 0;
        _vesting.lastUpdateBalance = uint128(current);
        _vestedBalance = 0;
    }

    function executeReward(address vault_, address fuse_, bytes calldata data_) external returns (bytes memory) {
        return MockPlasmaVaultCyvbUSDCV1(vault_).executeReward(fuse_, data_);
    }
}

contract MockPlasmaVaultCyvbUSDCV1 {
    address public immutable MANAGER;

    constructor(address manager_) {
        MANAGER = manager_;
    }

    function getRewardsClaimManagerAddress() external view returns (address) {
        return MANAGER;
    }

    function executeReward(address fuse_, bytes calldata data_) external returns (bytes memory result) {
        require(msg.sender == MANAGER, "manager only");
        (bool ok, bytes memory returned) = fuse_.delegatecall(data_);
        if (!ok) {
            assembly {
                revert(add(returned, 0x20), mload(returned))
            }
        }
        return returned;
    }
}

contract KatRewardSwapAndSplitFuseV3Test_v2 is Test {
    address internal constant KAT = 0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d;
    address internal constant VB_USDC = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36;
    address internal constant ADMIN = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;

    MockTokenCyvbUSDCV1 internal kat;
    MockTokenCyvbUSDCV1 internal vbUsdc;
    MockRewardRouterCyvbUSDCV1 internal router;
    MockRewardsManagerCyvbUSDCV1 internal manager;
    MockPlasmaVaultCyvbUSDCV1 internal vault;
    KatRewardSwapAndSplitFuse_v3 internal fuse;

    function setUp() public {
        MockTokenCyvbUSDCV1 tokenTemplate = new MockTokenCyvbUSDCV1();
        vm.etch(KAT, address(tokenTemplate).code);
        vm.etch(VB_USDC, address(tokenTemplate).code);

        kat = MockTokenCyvbUSDCV1(KAT);
        vbUsdc = MockTokenCyvbUSDCV1(VB_USDC);

        router = new MockRewardRouterCyvbUSDCV1();
        manager = new MockRewardsManagerCyvbUSDCV1(VB_USDC);
        vault = new MockPlasmaVaultCyvbUSDCV1(address(manager));
        fuse = new KatRewardSwapAndSplitFuse_v3(address(vault), address(manager), address(router));
    }

    function testSwapSplitsExactly70_30AndLeavesPrincipalUntouched() public {
        uint256 principal = 1_000e6;
        uint256 katReward = 100e18;
        uint256 netOut = 200e6;

        vbUsdc.mint(address(vault), principal);
        kat.mint(address(vault), katReward);
        router.setAmountOut(netOut);

        bytes memory result = manager.executeReward(
            address(vault),
            address(fuse),
            abi.encodeCall(KatRewardSwapAndSplitFuse_v3.sweepKatRewards, (190e6, block.timestamp + 1))
        );

        (uint256 reported, uint256 managerAmount, uint256 adminAmount) =
            abi.decode(result, (uint256, uint256, uint256));

        assertEq(reported, netOut);
        assertEq(managerAmount, 140e6);
        assertEq(adminAmount, 60e6);

        assertEq(vbUsdc.balanceOf(address(vault)), principal, "principal changed");
        assertEq(vbUsdc.balanceOf(address(manager)), 140e6, "manager split wrong");
        assertEq(vbUsdc.balanceOf(ADMIN), 60e6, "admin split wrong");
        assertEq(kat.balanceOf(address(vault)), 0, "KAT not consumed");
        assertEq(kat.allowance(address(vault), address(router)), 0, "router allowance not cleared");
    }

    function testRoundingDustGoesToRewardsManager() public {
        kat.mint(address(vault), 1e18);
        router.setAmountOut(1);

        bytes memory result = manager.executeReward(
            address(vault),
            address(fuse),
            abi.encodeCall(KatRewardSwapAndSplitFuse_v3.sweepKatRewards, (1, block.timestamp + 1))
        );

        (, uint256 managerAmount, uint256 adminAmount) = abi.decode(result, (uint256, uint256, uint256));
        assertEq(managerAmount, 1);
        assertEq(adminAmount, 0);
    }

    function testMissingRouteSkipsWithoutMovingFunds() public {
        kat.mint(address(vault), 50e18);
        router.setRouteEnabled(false);
        router.setAmountOut(100e6);

        bytes memory result = manager.executeReward(
            address(vault),
            address(fuse),
            abi.encodeCall(KatRewardSwapAndSplitFuse_v3.sweepKatRewards, (0, block.timestamp + 1))
        );

        (uint256 reported, uint256 managerAmount, uint256 adminAmount) =
            abi.decode(result, (uint256, uint256, uint256));

        assertEq(reported, 0);
        assertEq(managerAmount, 0);
        assertEq(adminAmount, 0);
        assertEq(kat.balanceOf(address(vault)), 50e18);
        assertEq(vbUsdc.balanceOf(address(manager)), 0);
        assertEq(vbUsdc.balanceOf(ADMIN), 0);
    }

    function testRouterRevertSkipsAndClearsAllowance() public {
        kat.mint(address(vault), 50e18);
        router.setShouldRevert(true);

        bytes memory result = manager.executeReward(
            address(vault),
            address(fuse),
            abi.encodeCall(KatRewardSwapAndSplitFuse_v3.sweepKatRewards, (0, block.timestamp + 1))
        );

        (uint256 reported,,) = abi.decode(result, (uint256, uint256, uint256));
        assertEq(reported, 0);
        assertEq(kat.balanceOf(address(vault)), 50e18);
        assertEq(kat.allowance(address(vault), address(router)), 0);
    }

    function testDirectCallOutsideRewardContextReverts() public {
        vm.expectRevert(KatRewardSwapAndSplitFuse_v3.WrongContext.selector);
        fuse.sweepKatRewards(0, block.timestamp + 1);
    }

    function testExpiredDeadlineReverts() public {
        kat.mint(address(vault), 1e18);

        vm.warp(100);
        vm.expectRevert(KatRewardSwapAndSplitFuse_v3.DeadlineExpired.selector);
        manager.executeReward(
            address(vault),
            address(fuse),
            abi.encodeCall(KatRewardSwapAndSplitFuse_v3.sweepKatRewards, (0, 99))
        );
    }
}