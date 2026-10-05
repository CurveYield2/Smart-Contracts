// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "../contracts/FxMintCyvbWbtcFuse_v13.sol";
import "../contracts/CyvbWbtcIndicatorToken_v1.sol";

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
    address public yieldToken;
    mapping(address => uint256) public balanceOf;

    constructor(address stable_, address yield_) {
        stableToken = stable_;
        yieldToken = yield_;
    }

    function setShares(address holder_, uint256 shares_) external {
        balanceOf[holder_] = shares_;
    }

    // 1 share = 0.8 fxUSD + 0.2 vbUSDC (6 dec)
    function previewRedeem(uint256 shares_) external pure returns (uint256, uint256) {
        return ((shares_ * 8) / 10, (shares_ * 2) / 10 / 1e12);
    }
}

contract MockGaugeCyvbV12 {
    address public stakingToken;
    mapping(address => uint256) public balanceOf;

    constructor(address staking_) {
        stakingToken = staking_;
    }

    function setStaked(address holder_, uint256 shares_) external {
        balanceOf[holder_] = shares_;
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
contract CyvbWbtcFuseV13Test_v1 is Test {
    MockTokenCyvbV10 internal vbWbtc;
    MockTokenCyvbV10 internal vbUsdc;
    MockTokenCyvbV10 internal fxUsd;
    MockPoolCyvbV10 internal pool;
    MockFxBaseCyvbV10 internal fxBase;
    MockNestedCyvbV10 internal nested;
    MockGaugeCyvbV12 internal gauge;
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
        fxBase = new MockFxBaseCyvbV10(address(vbUsdc), address(fxUsd));
        gauge = new MockGaugeCyvbV12(address(fxBase));
        nested = new MockNestedCyvbV10(address(vbUsdc));
    }

    function _policy(uint16 t_, uint16 ht_, uint16 hr_, uint16 lt_, uint16 lr_) internal pure returns (CyvbWbtcLtvPolicy memory) {
        return CyvbWbtcLtvPolicy({
            targetLtvBps: t_, highTriggerBps: ht_, highResetBps: hr_, lowTriggerBps: lt_, lowResetBps: lr_, earnBps: 6_000
        });
    }

    function _deploy(CyvbWbtcLtvPolicy memory policy_) internal returns (FxMintCyvbWbtcFuse_v13) {
        return new FxMintCyvbWbtcFuse_v13(
            7, vault, policy_,
            CyvbWbtcFuseAddresses({
                poolManager: manager, fxPool: address(pool), fxBase: address(fxBase), earnGauge: address(gauge),
                fxUsd: address(fxUsd), vbWbtc: address(vbWbtc), vbUsdc: address(vbUsdc), cyvbUsdc: address(nested),
                router: router, collateralIndicator: address(0), debtIndicator: address(0)
            })
        );
    }

    function testDefaultPolicyIsStoredImmutably() public {
        FxMintCyvbWbtcFuse_v13 fuse = _deploy(_policy(5_000, 6_000, 5_800, 4_500, 5_000));
        CyvbWbtcLtvPolicy memory p = fuse.getLtvPolicy();
        assertEq(p.targetLtvBps, 5_000);
        assertEq(p.highTriggerBps, 6_000);
        assertEq(p.highResetBps, 5_800);
        assertEq(p.lowTriggerBps, 4_500);
        assertEq(p.lowResetBps, 5_000);
        assertEq(p.earnBps, 6_000);
        assertEq(fuse.EARN_GAUGE(), address(gauge));
        assertEq(fuse.VAULT(), vault);
        assertEq(fuse.MARKET_ID(), 7);
        assertEq(fuse.INSTANT_WITHDRAW_MAX_LTV_BPS(), 5_500);
    }

    function testPolicyOutOfRangeReverts() public {
        vm.expectRevert(FxMintCyvbWbtcFuse_v13.ValueOutOfRange.selector);
        _deploy(_policy(5_600, 6_000, 5_800, 4_500, 5_000)); // target above 55%
        vm.expectRevert(FxMintCyvbWbtcFuse_v13.ValueOutOfRange.selector);
        _deploy(_policy(5_000, 6_700, 5_800, 4_500, 5_000)); // high trigger above 66%
    }

    function testEarnSplitAbove100PercentReverts() public {
        CyvbWbtcLtvPolicy memory p = _policy(5_000, 6_000, 5_800, 4_500, 5_000);
        p.earnBps = 10_001;
        vm.expectRevert(FxMintCyvbWbtcFuse_v13.ValueOutOfRange.selector);
        _deploy(p);
    }

    function testPolicyOrderingReverts() public {
        vm.expectRevert(FxMintCyvbWbtcFuse_v13.InvalidOrdering.selector);
        _deploy(_policy(5_000, 6_000, 5_800, 4_900, 4_800)); // low trigger >= low reset
        vm.expectRevert(FxMintCyvbWbtcFuse_v13.InvalidOrdering.selector);
        _deploy(_policy(5_400, 6_000, 5_300, 4_500, 5_000)); // target > high reset
    }

    function testStrategyCallsOutsideVaultContextRevert() public {
        FxMintCyvbWbtcFuse_v13 fuse = _deploy(_policy(5_000, 6_000, 5_800, 4_500, 5_000));
        vm.expectRevert(FxMintCyvbWbtcFuse_v13.WrongVaultContext.selector);
        fuse.deployFreshCapital(0, 0, 0, block.timestamp);
        vm.expectRevert(FxMintCyvbWbtcFuse_v13.WrongVaultContext.selector);
        fuse.rebalanceLtv(0, 0, block.timestamp);
        bytes32[] memory params = new bytes32[](1);
        params[0] = bytes32(uint256(1));
        vm.expectRevert(FxMintCyvbWbtcFuse_v13.WrongVaultContext.selector);
        fuse.instantWithdraw(params);
        vm.expectRevert(FxMintCyvbWbtcFuse_v13.WrongVaultContext.selector);
        fuse.requestEarnRedeem(1);
        vm.expectRevert(FxMintCyvbWbtcFuse_v13.WrongVaultContext.selector);
        fuse.completeScheduledWithdrawal(1, block.timestamp);
    }

    function testIndicatorsShowUsdUnitsAndAreNotTransferable() public {
        CyvbWbtcIndicatorToken_v1 nestedTvl = new CyvbWbtcIndicatorToken_v1(
            "CurveYield USDC TVL", "cyvbUSDC-TVL", CyvbWbtcIndicatorToken_v1.Kind.CYVBUSDC_TVL,
            vault, address(nested), address(0), address(0), 18
        );
        nested.setShares(vault, 100e6); // 100 shares x PPS 2 = 200 vbUSDC
        assertEq(nestedTvl.balanceOf(vault), 200e18);
        assertEq(nestedTvl.balanceOf(address(this)), 0);
        assertEq(nestedTvl.decimals(), 18);

        CyvbWbtcIndicatorToken_v1 earnTvl = new CyvbWbtcIndicatorToken_v1(
            "fxUSD Stability Pool TVL", "fxBASE-TVL", CyvbWbtcIndicatorToken_v1.Kind.EARN_POOL_TVL,
            vault, address(fxBase), address(gauge), address(0), 18
        );
        gauge.setStaked(vault, 50e18);
        fxBase.setShares(vault, 50e18); // 100 shares x (0.8 fxUSD + 0.2 vbUSDC) = 100 USD
        assertEq(earnTvl.balanceOf(vault), 100e18);

        vm.expectRevert(CyvbWbtcIndicatorToken_v1.NonTransferable.selector);
        earnTvl.transfer(address(1), 1);
    }

    function testOnlyTheVaultRegistersThePosition() public {
        CyvbWbtcIndicatorToken_v1 debt = new CyvbWbtcIndicatorToken_v1(
            "fxUSD Debt", "fxUSD-DEBT", CyvbWbtcIndicatorToken_v1.Kind.FXUSD_DEBT,
            vault, address(pool), address(0), address(0), 18
        );
        vm.expectRevert(CyvbWbtcIndicatorToken_v1.NotVault.selector);
        debt.registerPosition(7);
        vm.prank(vault);
        debt.registerPosition(7);
        assertEq(debt.positionId(), 7);
    }

    function testOneWeiFeed() public {
        CyvbWbtcOneWeiPriceFeed_v1 feed = new CyvbWbtcOneWeiPriceFeed_v1();
        (, int256 price,,,) = feed.latestRoundData();
        assertEq(price, 1);
        assertEq(feed.decimals(), 18);
    }

}
