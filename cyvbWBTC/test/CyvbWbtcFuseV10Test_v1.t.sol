// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "../contracts/FxMintCyvbWbtcFuse_v10.sol";
import "../contracts/FxMintCyvbWbtcBalanceFuse_v4.sol";

contract MockTokenCyvbV10 {
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address to_, uint256 amount_) external {
        balanceOf[to_] += amount_;
    }
}

contract MockPoolCyvbV10 {
    address public collateralToken;
    address public fxUSD;
    address public poolManager;

    constructor(address collateral_, address fxUsd_, address manager_) {
        (collateralToken, fxUSD, poolManager) = (collateral_, fxUsd_, manager_);
    }
}

contract MockFxBaseCyvbV10 {
    address public stableToken;

    constructor(address stable_) {
        stableToken = stable_;
    }
}

contract MockNestedCyvbV10 {
    address public asset;
    mapping(address => uint256) public balanceOf;

    constructor(address asset_) {
        asset = asset_;
    }

    function setShares(address holder_, uint256 shares_) external {
        balanceOf[holder_] = shares_;
    }

    function convertToAssets(uint256 shares_) external pure returns (uint256) {
        return shares_ * 2; // PPS 2.0
    }
}

contract MockCodeCyvbV10 {}

/// @notice Focused checks for the single cyvbWBTC strategy fuse (LTV policy folded in) and its balance fuse.
contract CyvbWbtcFuseV10Test_v1 is Test {
    MockTokenCyvbV10 internal vbWbtc;
    MockTokenCyvbV10 internal vbUsdc;
    MockTokenCyvbV10 internal fxUsd;
    MockPoolCyvbV10 internal pool;
    MockFxBaseCyvbV10 internal fxBase;
    MockNestedCyvbV10 internal nested;
    address internal manager;
    address internal vault;
    address internal router;

    function setUp() public {
        vbWbtc = new MockTokenCyvbV10(8);
        vbUsdc = new MockTokenCyvbV10(6);
        fxUsd = new MockTokenCyvbV10(18);
        manager = address(new MockCodeCyvbV10());
        vault = address(new MockCodeCyvbV10());
        router = address(new MockCodeCyvbV10());
        pool = new MockPoolCyvbV10(address(vbWbtc), address(fxUsd), manager);
        fxBase = new MockFxBaseCyvbV10(address(vbUsdc));
        nested = new MockNestedCyvbV10(address(vbUsdc));
    }

    function _policy(uint16 t_, uint16 ht_, uint16 hr_, uint16 lt_, uint16 lr_) internal pure returns (CyvbWbtcLtvPolicy memory) {
        return CyvbWbtcLtvPolicy({targetLtvBps: t_, highTriggerBps: ht_, highResetBps: hr_, lowTriggerBps: lt_, lowResetBps: lr_});
    }

    function _deploy(CyvbWbtcLtvPolicy memory policy_) internal returns (FxMintCyvbWbtcFuse_v10) {
        return new FxMintCyvbWbtcFuse_v10(
            7, vault, policy_, manager, address(pool), address(fxBase), address(fxUsd), address(vbWbtc),
            address(vbUsdc), address(nested), router
        );
    }

    function testDefaultPolicyIsStoredImmutably() public {
        FxMintCyvbWbtcFuse_v10 fuse = _deploy(_policy(5_000, 6_000, 5_800, 4_500, 5_000));
        CyvbWbtcLtvPolicy memory p = fuse.getLtvPolicy();
        assertEq(p.targetLtvBps, 5_000);
        assertEq(p.highTriggerBps, 6_000);
        assertEq(p.highResetBps, 5_800);
        assertEq(p.lowTriggerBps, 4_500);
        assertEq(p.lowResetBps, 5_000);
        assertEq(fuse.VAULT(), vault);
        assertEq(fuse.MARKET_ID(), 7);
        assertEq(fuse.INSTANT_WITHDRAW_MAX_LTV_BPS(), 5_500);
    }

    function testPolicyOutOfRangeReverts() public {
        vm.expectRevert(FxMintCyvbWbtcFuse_v10.ValueOutOfRange.selector);
        _deploy(_policy(5_600, 6_000, 5_800, 4_500, 5_000)); // target above 55%
        vm.expectRevert(FxMintCyvbWbtcFuse_v10.ValueOutOfRange.selector);
        _deploy(_policy(5_000, 6_700, 5_800, 4_500, 5_000)); // high trigger above 66%
    }

    function testPolicyOrderingReverts() public {
        vm.expectRevert(FxMintCyvbWbtcFuse_v10.InvalidOrdering.selector);
        _deploy(_policy(5_000, 6_000, 5_800, 4_900, 4_800)); // low trigger >= low reset
        vm.expectRevert(FxMintCyvbWbtcFuse_v10.InvalidOrdering.selector);
        _deploy(_policy(5_400, 6_000, 5_300, 4_500, 5_000)); // target > high reset
    }

    function testStrategyCallsOutsideVaultContextRevert() public {
        FxMintCyvbWbtcFuse_v10 fuse = _deploy(_policy(5_000, 6_000, 5_800, 4_500, 5_000));
        vm.expectRevert(FxMintCyvbWbtcFuse_v10.WrongVaultContext.selector);
        fuse.deployFreshCapital(0, 0, block.timestamp);
        vm.expectRevert(FxMintCyvbWbtcFuse_v10.WrongVaultContext.selector);
        fuse.rebalanceLtv(0, 0, block.timestamp);
        bytes32[] memory params = new bytes32[](1);
        params[0] = bytes32(uint256(1));
        vm.expectRevert(FxMintCyvbWbtcFuse_v10.WrongVaultContext.selector);
        fuse.instantWithdraw(params);
    }

    function testBalanceFuseValuesNestedAndResidualInUsdWad() public {
        FxMintCyvbWbtcBalanceFuse_v4 balance = new FxMintCyvbWbtcBalanceFuse_v4(
            7, address(pool), address(fxUsd), address(vbUsdc), address(nested)
        );
        // no f(x) position in this context: only nested + residual legs count
        nested.setShares(address(balance), 100e6); // 100 shares x PPS 2 = 200 vbUSDC
        vbUsdc.mint(address(balance), 5e6); // 5 vbUSDC
        fxUsd.mint(address(balance), 3e18); // 3 fxUSD
        assertEq(balance.balanceOf(), 208e18);
    }

    function testBalanceFuseRejectsWrongNestedAsset() public {
        MockNestedCyvbV10 wrong = new MockNestedCyvbV10(address(fxUsd));
        vm.expectRevert(FxMintCyvbWbtcBalanceFuse_v4.NestedVaultAssetMismatch.selector);
        new FxMintCyvbWbtcBalanceFuse_v4(7, address(pool), address(fxUsd), address(vbUsdc), address(wrong));
    }
}
