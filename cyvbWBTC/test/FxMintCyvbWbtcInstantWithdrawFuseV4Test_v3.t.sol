// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";

import "../contracts/CyvbWbtcLtvConfig_v3.sol";
import "../contracts/FxMintCyvbWbtcInstantWithdrawFuse_v4.sol";

contract MockTokenFxInstantV4Test {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to_, uint256 amount_) external {
        balanceOf[to_] += amount_;
    }

    function burn(address from_, uint256 amount_) external {
        require(balanceOf[from_] >= amount_, "burn");
        balanceOf[from_] -= amount_;
    }

    function approve(address spender_, uint256 amount_) external returns (bool) {
        allowance[msg.sender][spender_] = amount_;
        return true;
    }

    function transfer(address to_, uint256 amount_) external returns (bool) {
        require(balanceOf[msg.sender] >= amount_, "balance");
        balanceOf[msg.sender] -= amount_;
        balanceOf[to_] += amount_;
        return true;
    }

    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool) {
        uint256 allowed = allowance[from_][msg.sender];
        require(allowed >= amount_, "allowance");
        if (allowed != type(uint256).max) allowance[from_][msg.sender] = allowed - amount_;
        require(balanceOf[from_] >= amount_, "balance");
        balanceOf[from_] -= amount_;
        balanceOf[to_] += amount_;
        return true;
    }
}

contract MockNestedFxInstantV4Test {
    MockTokenFxInstantV4Test public immutable TOKEN;
    mapping(address => uint256) public balanceOf;

    constructor(address token_) {
        TOKEN = MockTokenFxInstantV4Test(token_);
    }

    function seed(address owner_, uint256 shares_) external {
        balanceOf[owner_] += shares_;
        TOKEN.mint(address(this), shares_);
    }

    function redeem(uint256 shares_, address receiver_, address owner_) external returns (uint256 assets) {
        require(balanceOf[owner_] >= shares_, "shares");
        balanceOf[owner_] -= shares_;
        assets = shares_;
        require(TOKEN.transfer(receiver_, assets), "transfer");
    }
}

contract MockOracleFxInstantV4Test {
    uint256 public price = 1e18;

    function getPrice() external view returns (uint256, uint256, uint256) {
        return (price, price, price);
    }
}

contract MockFeeConfigFxInstantV4Test {
    uint256 public withdrawFee;
    uint256 public repayFee;

    function setFees(uint256 withdrawFee_, uint256 repayFee_) external {
        withdrawFee = withdrawFee_;
        repayFee = repayFee_;
    }

    function getPoolFeeRatio(address, address)
        external
        view
        returns (uint256, uint256, uint256, uint256)
    {
        return (0, withdrawFee, 0, repayFee);
    }
}

contract MockPoolFxInstantV4Test {
    address public immutable priceOracle;
    address public immutable configuration;

    uint256 public rawColls;
    uint256 public rawDebts;

    constructor(address oracle_, address config_) {
        priceOracle = oracle_;
        configuration = config_;
    }

    function setPosition(uint256 coll_, uint256 debt_) external {
        rawColls = coll_;
        rawDebts = debt_;
    }

    function getPosition(uint256) external view returns (uint256, uint256) {
        return (rawColls, rawDebts);
    }

    function getPositionDebtRatio(uint256) external view returns (uint256) {
        if (rawColls == 0) return rawDebts == 0 ? 0 : type(uint256).max;
        return (rawDebts * 1e18) / rawColls;
    }
}

contract MockManagerFxInstantV4Test {
    MockTokenFxInstantV4Test public immutable COLLATERAL;
    MockTokenFxInstantV4Test public immutable DEBT;
    MockPoolFxInstantV4Test public immutable POOL;

    constructor(address collateral_, address debt_, address pool_) {
        COLLATERAL = MockTokenFxInstantV4Test(collateral_);
        DEBT = MockTokenFxInstantV4Test(debt_);
        POOL = MockPoolFxInstantV4Test(pool_);
    }

    function getTokenScalingFactor(address) external pure returns (uint256) {
        return 1e18;
    }

    function operate(address pool_, uint256 positionId_, int256 newColl_, int256 newDebt_)
        external
        returns (uint256)
    {
        require(pool_ == address(POOL), "pool");
        (uint256 coll, uint256 debt) = POOL.getPosition(positionId_);

        if (newDebt_ < 0) {
            uint256 amount = uint256(-newDebt_);
            require(amount <= debt, "debt");
            DEBT.burn(msg.sender, amount);
            debt -= amount;
        }

        if (newColl_ < 0) {
            uint256 amount = newColl_ == type(int256).min ? coll : uint256(-newColl_);
            require(amount <= coll, "coll");
            coll -= amount;
            require(COLLATERAL.transfer(msg.sender, amount), "coll out");
        }

        POOL.setPosition(coll, debt);
        return positionId_;
    }
}

contract MockFxBaseInstantV2Test {
    function getStableTokenPriceWithScale() external pure returns (uint256) {
        return 1e18;
    }
}

contract MockRouterFxInstantV4Test {
    mapping(bytes32 => bool) public enabled;

    function setRoute(address tokenIn_, address tokenOut_, bool enabled_) external {
        enabled[keccak256(abi.encode(tokenIn_, tokenOut_))] = enabled_;
    }

    function routeFor(address tokenIn_, address tokenOut_) external view returns (bytes memory) {
        if (!enabled[keccak256(abi.encode(tokenIn_, tokenOut_))]) return new bytes(0);
        bytes memory route = hex"01";
        return route;
    }

    function swapExactInput(
        address tokenIn_,
        address tokenOut_,
        uint256 amountIn_,
        uint256,
        address recipient_,
        uint256
    ) external returns (uint256 netAmountOut) {
        require(enabled[keccak256(abi.encode(tokenIn_, tokenOut_))], "route");
        require(
            MockTokenFxInstantV4Test(tokenIn_).transferFrom(msg.sender, address(this), amountIn_),
            "input"
        );
        netAmountOut = amountIn_;
        MockTokenFxInstantV4Test(tokenOut_).mint(recipient_, netAmountOut);
    }
}

contract DelegateVaultFxInstantV4Test {
    address public immutable POOL;
    address public immutable NESTED;
    address public immutable ROUTER;
    address public immutable FXUSD_TOKEN;
    address public immutable VBUSDC_TOKEN;
    address public immutable VBWBTC_TOKEN;

    bool public routerGranted = true;

    constructor(
        address pool_,
        address nested_,
        address router_,
        address fxUsd_,
        address vbUsdc_,
        address vbWbtc_
    ) {
        POOL = pool_;
        NESTED = nested_;
        ROUTER = router_;
        FXUSD_TOKEN = fxUsd_;
        VBUSDC_TOKEN = vbUsdc_;
        VBWBTC_TOKEN = vbWbtc_;
    }

    function setRouterGranted(bool granted_) external {
        routerGranted = granted_;
    }

    function getMarketSubstrates(uint256 marketId_) external view returns (bytes32[] memory out) {
        if (marketId_ == 7) {
            out = new bytes32[](1);
            out[0] = bytes32(uint256(uint160(POOL)));
            return out;
        }

        if (marketId_ == 100001) {
            out = new bytes32[](1);
            out[0] = bytes32(uint256(uint160(NESTED)));
            return out;
        }

        if (marketId_ == 1202) {
            out = new bytes32[](routerGranted ? 4 : 3);
            out[0] = _tokenSubstrate(FXUSD_TOKEN);
            out[1] = _tokenSubstrate(VBUSDC_TOKEN);
            out[2] = _tokenSubstrate(VBWBTC_TOKEN);
            if (routerGranted) out[3] = _targetSubstrate(ROUTER);
            return out;
        }

        return new bytes32[](0);
    }

    function execute(address fuse_, bytes calldata data_) external returns (bytes memory result) {
        (bool ok, bytes memory returned) = fuse_.delegatecall(data_);
        if (!ok) {
            assembly {
                revert(add(returned, 0x20), mload(returned))
            }
        }
        return returned;
    }

    function record(CyvbWbtcLtvConfig_v3 config_, uint256 id_) external {
        config_.recordPositionId(id_);
    }

    function _tokenSubstrate(address token_) private pure returns (bytes32) {
        return bytes32(uint256(1) << 248) | bytes32(uint256(uint160(token_)));
    }

    function _targetSubstrate(address target_) private pure returns (bytes32) {
        return bytes32(uint256(2) << 248) | bytes32(uint256(uint160(target_)));
    }
}

contract FxMintCyvbWbtcInstantWithdrawFuseV4Test_v3 is Test {
    MockTokenFxInstantV4Test internal vbWbtc;
    MockTokenFxInstantV4Test internal fxUsd;
    MockTokenFxInstantV4Test internal vbUsdc;
    MockNestedFxInstantV4Test internal nested;
    MockOracleFxInstantV4Test internal oracle;
    MockFeeConfigFxInstantV4Test internal fees;
    MockPoolFxInstantV4Test internal pool;
    MockManagerFxInstantV4Test internal manager;
    MockFxBaseInstantV2Test internal fxBase;
    MockRouterFxInstantV4Test internal router;
    DelegateVaultFxInstantV4Test internal vault;
    CyvbWbtcLtvConfig_v3 internal config;
    FxMintCyvbWbtcInstantWithdrawFuse_v4 internal fuse;

    function setUp() public {
        vbWbtc = new MockTokenFxInstantV4Test();
        fxUsd = new MockTokenFxInstantV4Test();
        vbUsdc = new MockTokenFxInstantV4Test();
        oracle = new MockOracleFxInstantV4Test();
        fees = new MockFeeConfigFxInstantV4Test();
        pool = new MockPoolFxInstantV4Test(address(oracle), address(fees));
        manager = new MockManagerFxInstantV4Test(address(vbWbtc), address(fxUsd), address(pool));
        fxBase = new MockFxBaseInstantV2Test();
        nested = new MockNestedFxInstantV4Test(address(vbUsdc));
        router = new MockRouterFxInstantV4Test();

        router.setRoute(address(vbUsdc), address(fxUsd), true);
        router.setRoute(address(fxUsd), address(vbUsdc), true);
        router.setRoute(address(vbUsdc), address(vbWbtc), true);

        vault = new DelegateVaultFxInstantV4Test(
            address(pool),
            address(nested),
            address(router),
            address(fxUsd),
            address(vbUsdc),
            address(vbWbtc)
        );

        config = new CyvbWbtcLtvConfig_v3(address(this));
        config.bindVault(address(vault));
        vault.record(config, 1);

        fuse = new FxMintCyvbWbtcInstantWithdrawFuse_v4(
            address(config),
            address(manager),
            address(pool),
            address(fxBase),
            address(fxUsd),
            address(vbWbtc),
            address(vbUsdc),
            address(nested),
            address(router)
        );
    }

    function testUsesOnlyOfficialIporMarketIds() public view {
        assertEq(fuse.MARKET_ID(), 100001);
    }

    function testSmallWithdrawalUsesCollateralOnlyAndStaysBelow55Percent() public {
        _seedPosition(100e18, 50e18, 0);

        bytes32[] memory params = new bytes32[](1);
        params[0] = bytes32(uint256(5e18));

        vault.execute(
            address(fuse),
            abi.encodeCall(FxMintCyvbWbtcInstantWithdrawFuse_v4.instantWithdraw, (params))
        );

        (uint256 coll, uint256 debt) = pool.getPosition(1);
        assertEq(coll, 95e18);
        assertEq(debt, 50e18);
        assertEq(vbWbtc.balanceOf(address(vault)), 5e18);
        assertLe(pool.getPositionDebtRatio(1), 0.55e18);
    }

    function testRequestCrossing55PercentFullyUnwindsAndReturnsVbWbtc() public {
        _seedPosition(100e18, 50e18, 60e18);

        bytes32[] memory params = new bytes32[](1);
        params[0] = bytes32(uint256(20e18));

        vault.execute(
            address(fuse),
            abi.encodeCall(FxMintCyvbWbtcInstantWithdrawFuse_v4.instantWithdraw, (params))
        );

        (uint256 coll, uint256 debt) = pool.getPosition(1);
        assertEq(coll, 0);
        assertEq(debt, 0);
        assertEq(nested.balanceOf(address(vault)), 0);
        assertGt(vbWbtc.balanceOf(address(vault)), 20e18);
        assertEq(fxUsd.balanceOf(address(vault)), 0);
        assertEq(vbUsdc.balanceOf(address(vault)), 0);
    }

    function testFullUnwindReusesExistingIdleFxUsdBeforeStableSwap() public {
        _seedPosition(100e18, 50e18, 40e18);
        fxUsd.mint(address(vault), 20e18);

        bytes32[] memory params = new bytes32[](1);
        params[0] = bytes32(uint256(20e18));

        vault.execute(
            address(fuse),
            abi.encodeCall(FxMintCyvbWbtcInstantWithdrawFuse_v4.instantWithdraw, (params))
        );

        (uint256 coll, uint256 debt) = pool.getPosition(1);
        assertEq(coll, 0);
        assertEq(debt, 0);
        assertGt(vbWbtc.balanceOf(address(vault)), 20e18);
    }

    function testInstantFuseRequiresGrantedRouterSubstrate() public {
        _seedPosition(100e18, 50e18, 60e18);
        vault.setRouterGranted(false);

        bytes32[] memory params = new bytes32[](1);
        params[0] = bytes32(uint256(20e18));

        vm.expectRevert(
            abi.encodeWithSelector(
                FxMintCyvbWbtcInstantWithdrawFuse_v4.UnsupportedPool.selector,
                address(router)
            )
        );
        vault.execute(
            address(fuse),
            abi.encodeCall(FxMintCyvbWbtcInstantWithdrawFuse_v4.instantWithdraw, (params))
        );
    }

    function _seedPosition(uint256 collateral_, uint256 debt_, uint256 nestedStable_) private {
        pool.setPosition(collateral_, debt_);
        vbWbtc.mint(address(manager), collateral_);
        if (nestedStable_ != 0) {
            nested.seed(address(vault), nestedStable_);
        }
    }
}
