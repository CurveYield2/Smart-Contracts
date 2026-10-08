// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";

import "../contracts/FxMintCyvbEthFuse_v1.sol";
import "../contracts/CyvbEthMorphoAllocatorFuse_v1.sol";
import "../contracts/CyvbEthIndicatorToken_v1.sol";
import "../contracts/VbEthUsdPriceFeed_v1.sol";

contract MockTokenCyvbEthV1 {
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address to_, uint256 amount_) external {
        balanceOf[to_] += amount_;
    }
}

contract MockPoolManagerCyvbEthV1 {
    function getTokenScalingFactor(address) external pure returns (uint256) {
        return 1e18;
    }
}

contract MockPoolCyvbEthV1 {
    address public collateralToken;
    address public fxUSD;
    address public poolManager;
    address public priceOracle;
    address public configuration;

    constructor(address collateral_, address fxUsd_, address manager_, address priceOracle_) {
        collateralToken = collateral_;
        fxUSD = fxUsd_;
        poolManager = manager_;
        priceOracle = priceOracle_;
        configuration = address(this);
    }

    function getPosition(uint256) external pure returns (uint256 rawColls, uint256 rawDebts) {
        return (0, 0);
    }

    function getPoolFeeRatio(address, address) external pure returns (uint256,uint256,uint256,uint256) {
        return (0, 0, 0, 0);
    }
}

contract MockFxOracleCyvbEthV1 {
    uint256 public price = 3_000e18;

    function getPrice() external view returns (uint256, uint256, uint256) {
        return (price, price, price);
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }
}

contract MockAggregatorCyvbEthV1 {
    uint8 public immutable decimals;
    int256 public answer;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (7, answer, block.timestamp - 1, block.timestamp, 7);
    }
}

contract MockFxBaseCyvbEthV1 {
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

    function previewRedeem(uint256 shares_) external pure returns (uint256, uint256) {
        return ((shares_ * 8) / 10, (shares_ * 2) / 10 / 1e12);
    }
}

contract MockGaugeCyvbEthV1 {
    address public stakingToken;
    mapping(address => uint256) public balanceOf;

    constructor(address staking_) {
        stakingToken = staking_;
    }

    function setStaked(address holder_, uint256 shares_) external {
        balanceOf[holder_] = shares_;
    }
}

contract MockNestedCyvbEthV1 {
    address public asset;
    mapping(address => uint256) public balanceOf;

    constructor(address asset_) {
        asset = asset_;
    }

    function setShares(address holder_, uint256 shares_) external {
        balanceOf[holder_] = shares_;
    }

    function convertToAssets(uint256 shares_) external pure returns (uint256) {
        return shares_ * 2;
    }
}

contract MockMorphoCyvbEthV1 {
    bytes32 public immutable MARKET;
    address public immutable LOAN;

    constructor(bytes32 market_, address loan_) {
        MARKET = market_;
        LOAN = loan_;
    }

    function idToMarketParams(bytes32 id)
        external
        view
        returns (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv)
    {
        require(id == MARKET, "wrong market");
        return (LOAN, address(0xCA11), address(0x0A11), address(0x1A1), 0.77e18);
    }

    function position(bytes32, address) external pure returns (uint256, uint128, uint128) {
        return (0, 0, 0);
    }

    function market(bytes32)
        external
        pure
        returns (uint128,uint128,uint128,uint128,uint128,uint128)
    {
        return (0, 0, 0, 0, 0, 0);
    }
}

contract MockOfficialMorphoFuseCyvbEthV1 {
    uint256 public immutable MARKET_ID;
    address public immutable MORPHO;
    address public immutable LOAN_TOKEN;

    constructor(uint256 marketId_, address morpho_, address loanToken_) {
        MARKET_ID = marketId_;
        MORPHO = morpho_;
        LOAN_TOKEN = loanToken_;
    }

    function enter(CyvbEthMorphoDataV1 calldata data_)
        external
        view
        returns (address asset, bytes32 market, uint256 actual)
    {
        return (LOAN_TOKEN, data_.morphoMarketId, data_.amount);
    }

    function exit(CyvbEthMorphoDataV1 calldata data_)
        external
        view
        returns (address asset, bytes32 market, uint256 actual)
    {
        return (LOAN_TOKEN, data_.morphoMarketId, data_.amount);
    }

    function instantWithdraw(bytes32[] calldata) external pure {}
}

contract MockCodeCyvbEthV1 {}

contract MockVaultHostCyvbEthV1 {
    function execute(address fuse_, bytes calldata data_) external returns (bytes memory result_) {
        (bool ok, bytes memory result) = fuse_.delegatecall(data_);
        if (!ok) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        return result;
    }
}

/// @notice Focused unit checks for the cyvbETH clone delta: policy parity, ETH topology, Morpho binding and feeds.
contract CyvbEthFuseV1Test_v1 is Test {
    bytes32 internal constant MORPHO_MARKET =
        0x2c4f26c76b4de51d3c9260c15a796cd2a35efab17786d0aa78ca2e638b0f8ba8;

    MockTokenCyvbEthV1 internal vbEth;
    MockTokenCyvbEthV1 internal weEth;
    MockTokenCyvbEthV1 internal vbUsdc;
    MockTokenCyvbEthV1 internal fxUsd;
    MockPoolManagerCyvbEthV1 internal manager;
    MockPoolCyvbEthV1 internal pool;
    MockFxOracleCyvbEthV1 internal fxOracle;
    MockAggregatorCyvbEthV1 internal ethUsd;
    MockFxBaseCyvbEthV1 internal fxBase;
    MockGaugeCyvbEthV1 internal gauge;
    MockNestedCyvbEthV1 internal nested;
    MockMorphoCyvbEthV1 internal morpho;
    address internal vault;
    address internal router;

    function setUp() public {
        vbEth = new MockTokenCyvbEthV1(18);
        weEth = new MockTokenCyvbEthV1(18);
        vbUsdc = new MockTokenCyvbEthV1(6);
        fxUsd = new MockTokenCyvbEthV1(18);
        manager = new MockPoolManagerCyvbEthV1();
        fxOracle = new MockFxOracleCyvbEthV1();
        ethUsd = new MockAggregatorCyvbEthV1(8, 3_000e8);
        vault = address(new MockCodeCyvbEthV1());
        router = address(new MockCodeCyvbEthV1());
        pool = new MockPoolCyvbEthV1(address(weEth), address(fxUsd), address(manager), address(fxOracle));
        fxBase = new MockFxBaseCyvbEthV1(address(vbUsdc), address(fxUsd));
        gauge = new MockGaugeCyvbEthV1(address(fxBase));
        nested = new MockNestedCyvbEthV1(address(vbUsdc));
        morpho = new MockMorphoCyvbEthV1(MORPHO_MARKET, address(vbEth));
    }

    function _policy(uint16 t_, uint16 ht_, uint16 hr_, uint16 lt_, uint16 lr_)
        internal
        pure
        returns (CyvbEthLtvPolicy memory)
    {
        return CyvbEthLtvPolicy({
            targetLtvBps: t_,
            highTriggerBps: ht_,
            highResetBps: hr_,
            lowTriggerBps: lt_,
            lowResetBps: lr_,
            earnBps: 0
        });
    }

    function _deploy(CyvbEthLtvPolicy memory policy_) internal returns (FxMintCyvbEthFuse_v1) {
        return new FxMintCyvbEthFuse_v1(
            7,
            MORPHO_MARKET,
            vault,
            policy_,
            CyvbEthFuseAddresses({
                poolManager: address(manager),
                fxPool: address(pool),
                fxBase: address(fxBase),
                earnGauge: address(gauge),
                fxUsd: address(fxUsd),
                vbEth: address(vbEth),
                weEth: address(weEth),
                vbEthPriceFeed: address(ethUsd),
                morpho: address(morpho),
                vbUsdc: address(vbUsdc),
                cyvbUsdc: address(nested),
                router: router,
                collateralIndicator: address(0),
                debtIndicator: address(0)
            })
        );
    }

    function testDefaultPolicyAndEthBindings() public {
        FxMintCyvbEthFuse_v1 fuse = _deploy(_policy(5_000, 6_000, 5_800, 4_500, 5_000));
        CyvbEthLtvPolicy memory p = fuse.getLtvPolicy();
        assertEq(p.targetLtvBps, 5_000);
        assertEq(p.highTriggerBps, 6_000);
        assertEq(p.highResetBps, 5_800);
        assertEq(p.lowTriggerBps, 4_500);
        assertEq(p.lowResetBps, 5_000);
        assertEq(fuse.VBETH(), address(vbEth));
        assertEq(fuse.WEETH(), address(weEth));
        assertEq(fuse.MORPHO(), address(morpho));
        assertEq(fuse.MORPHO_MARKET_ID(), MORPHO_MARKET);
        assertEq(fuse.INSTANT_WITHDRAW_MAX_LTV_BPS(), 5_500);
    }

    function testPolicyParityBounds() public {
        vm.expectRevert(FxMintCyvbEthFuse_v1.ValueOutOfRange.selector);
        _deploy(_policy(5_600, 6_000, 5_800, 4_500, 5_000));

        vm.expectRevert(FxMintCyvbEthFuse_v1.ValueOutOfRange.selector);
        _deploy(_policy(5_000, 6_700, 5_800, 4_500, 5_000));

        vm.expectRevert(FxMintCyvbEthFuse_v1.InvalidOrdering.selector);
        _deploy(_policy(5_000, 6_000, 5_800, 4_900, 4_800));
    }

    function testWrongFxCollateralRejected() public {
        MockPoolCyvbEthV1 wrong =
            new MockPoolCyvbEthV1(address(vbEth), address(fxUsd), address(manager), address(fxOracle));

        vm.expectRevert(FxMintCyvbEthFuse_v1.ProtocolTopologyMismatch.selector);
        new FxMintCyvbEthFuse_v1(
            7,
            MORPHO_MARKET,
            vault,
            _policy(5_000, 6_000, 5_800, 4_500, 5_000),
            CyvbEthFuseAddresses({
                poolManager: address(manager),
                fxPool: address(wrong),
                fxBase: address(fxBase),
                earnGauge: address(gauge),
                fxUsd: address(fxUsd),
                vbEth: address(vbEth),
                weEth: address(weEth),
                vbEthPriceFeed: address(ethUsd),
                morpho: address(morpho),
                vbUsdc: address(vbUsdc),
                cyvbUsdc: address(nested),
                router: router,
                collateralIndicator: address(0),
                debtIndicator: address(0)
            })
        );
    }

    function testWrongMorphoLoanTokenRejected() public {
        MockMorphoCyvbEthV1 wrongMorpho = new MockMorphoCyvbEthV1(MORPHO_MARKET, address(weEth));
        vm.expectRevert(FxMintCyvbEthFuse_v1.ProtocolTopologyMismatch.selector);
        new FxMintCyvbEthFuse_v1(
            7,
            MORPHO_MARKET,
            vault,
            _policy(5_000, 6_000, 5_800, 4_500, 5_000),
            CyvbEthFuseAddresses({
                poolManager: address(manager),
                fxPool: address(pool),
                fxBase: address(fxBase),
                earnGauge: address(gauge),
                fxUsd: address(fxUsd),
                vbEth: address(vbEth),
                weEth: address(weEth),
                vbEthPriceFeed: address(ethUsd),
                morpho: address(wrongMorpho),
                vbUsdc: address(vbUsdc),
                cyvbUsdc: address(nested),
                router: router,
                collateralIndicator: address(0),
                debtIndicator: address(0)
            })
        );
    }

    function testStrategyMethodsRemainVaultOnly() public {
        FxMintCyvbEthFuse_v1 fuse = _deploy(_policy(5_000, 6_000, 5_800, 4_500, 5_000));
        vm.expectRevert(FxMintCyvbEthFuse_v1.WrongVaultContext.selector);
        fuse.deployFreshCapital(0, 0, 0, block.timestamp);
        vm.expectRevert(FxMintCyvbEthFuse_v1.WrongVaultContext.selector);
        fuse.rebalanceLtv(0, 0, block.timestamp);
        bytes32[] memory params = new bytes32[](1);
        params[0] = bytes32(uint256(1));
        vm.expectRevert(FxMintCyvbEthFuse_v1.WrongVaultContext.selector);
        fuse.instantWithdraw(params);
    }

    function testMorphoAllocatorBindsOfficialFuseAndMarket() public {
        MockOfficialMorphoFuseCyvbEthV1 official =
            new MockOfficialMorphoFuseCyvbEthV1(14, address(morpho), address(vbEth));
        CyvbEthMorphoAllocatorFuse_v1 allocator = new CyvbEthMorphoAllocatorFuse_v1(
            vault, address(vbEth), address(official), 14, MORPHO_MARKET
        );
        assertEq(allocator.VBETH(), address(vbEth));
        assertEq(allocator.MORPHO(), address(morpho));
        assertEq(allocator.MORPHO_IPOR_MARKET_ID(), 14);
        assertEq(allocator.MORPHO_MARKET_ID(), MORPHO_MARKET);

        vm.expectRevert(CyvbEthMorphoAllocatorFuse_v1.WrongVaultContext.selector);
        allocator.deployToMorpho(1 ether);
    }

    function testMorphoAllocatorExecutesSelectedAndAllIdleAmountsThroughVaultContext() public {
        MockVaultHostCyvbEthV1 host = new MockVaultHostCyvbEthV1();
        MockOfficialMorphoFuseCyvbEthV1 official =
            new MockOfficialMorphoFuseCyvbEthV1(14, address(morpho), address(vbEth));
        CyvbEthMorphoAllocatorFuse_v1 allocator = new CyvbEthMorphoAllocatorFuse_v1(
            address(host), address(vbEth), address(official), 14, MORPHO_MARKET
        );

        vbEth.mint(address(host), 5 ether);

        bytes memory suppliedResult = host.execute(
            address(allocator),
            abi.encodeCall(CyvbEthMorphoAllocatorFuse_v1.deployToMorpho, (2 ether))
        );
        assertEq(abi.decode(suppliedResult, (uint256)), 2 ether);

        bytes memory allIdleResult = host.execute(
            address(allocator),
            abi.encodeCall(CyvbEthMorphoAllocatorFuse_v1.deployToMorpho, (0))
        );
        assertEq(abi.decode(allIdleResult, (uint256)), 5 ether);

        bytes memory withdrawnResult = host.execute(
            address(allocator),
            abi.encodeCall(CyvbEthMorphoAllocatorFuse_v1.withdrawFromMorpho, (1 ether))
        );
        assertEq(abi.decode(withdrawnResult, (uint256)), 1 ether);

        bytes32[] memory params = new bytes32[](1);
        params[0] = bytes32(uint256(1 ether));
        host.execute(
            address(allocator),
            abi.encodeCall(CyvbEthMorphoAllocatorFuse_v1.instantWithdraw, (params))
        );
    }

    function testMorphoAllocatorRejectsWrongOfficialMarketId() public {
        MockOfficialMorphoFuseCyvbEthV1 official =
            new MockOfficialMorphoFuseCyvbEthV1(13, address(morpho), address(vbEth));
        vm.expectRevert(CyvbEthMorphoAllocatorFuse_v1.ProtocolTopologyMismatch.selector);
        new CyvbEthMorphoAllocatorFuse_v1(vault, address(vbEth), address(official), 14, MORPHO_MARKET);
    }

    function testVbEthPriceFeedRescalesEightDecimalsToEighteen() public {
        VbEthUsdPriceFeed_v1 feed = new VbEthUsdPriceFeed_v1(address(ethUsd));
        (, int256 price,,,) = feed.latestRoundData();
        assertEq(price, 3_000e18);
        assertEq(feed.decimals(), 18);
    }

    function testIndicatorsRemainNonTransferableAndUseWeEthCollateralDecimals() public {
        CyvbEthIndicatorToken_v1 collateral = new CyvbEthIndicatorToken_v1(
            "fxMINT weETH Collateral",
            "fxMINT-weETH",
            CyvbEthIndicatorToken_v1.Kind.FX_COLLATERAL,
            vault,
            address(pool),
            address(manager),
            address(weEth),
            18
        );
        assertEq(collateral.decimals(), 18);
        vm.expectRevert(CyvbEthIndicatorToken_v1.NonTransferable.selector);
        collateral.transfer(address(1), 1);

        CyvbEthIndicatorToken_v1 nestedTvl = new CyvbEthIndicatorToken_v1(
            "CurveYield USDC TVL",
            "cyvbUSDC-TVL",
            CyvbEthIndicatorToken_v1.Kind.CYVBUSDC_TVL,
            vault,
            address(nested),
            address(0),
            address(0),
            18
        );
        nested.setShares(vault, 100e6);
        assertEq(nestedTvl.balanceOf(vault), 200e18);
    }
}
