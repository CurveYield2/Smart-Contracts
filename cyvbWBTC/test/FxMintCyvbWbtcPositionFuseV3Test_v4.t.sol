// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";

import "../contracts/CyvbWbtcLtvConfig_v3.sol";
import "../contracts/FxMintCyvbWbtcPositionFuse_v3.sol";
import "../contracts/FxMintCyvbWbtcErc20BalanceFuse_v6.sol";

contract MockTokenFxPositionV3Test {
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

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

contract MockFxOraclePositionV3Test {
    uint256 public anchorPrice = 1e18;

    function setPrice(uint256 price_) external {
        anchorPrice = price_;
    }

    function getPrice() external view returns (uint256, uint256, uint256) {
        return (anchorPrice, anchorPrice, anchorPrice);
    }
}

contract MockPriceMiddlewarePositionV3Test {
    mapping(address => uint256) public price;

    function setPrice(address asset_, uint256 price_) external {
        price[asset_] = price_;
    }

    function getAssetPrice(address asset_) external view returns (uint256, uint256) {
        uint256 p = price[asset_];
        require(p != 0, "unsupported");
        return (p, 18);
    }
}

contract MockFxPoolPositionV3Test {
    address public immutable collateralToken;
    address public immutable fxUSD;
    address public immutable poolManager;
    address public immutable priceOracle;

    uint256 public rawColls;
    uint256 public rawDebts;

    constructor(address collateral_, address debt_, address manager_, address oracle_) {
        collateralToken = collateral_;
        fxUSD = debt_;
        poolManager = manager_;
        priceOracle = oracle_;
    }

    function getPosition(uint256) external view returns (uint256, uint256) {
        return (rawColls, rawDebts);
    }

    function setPosition(uint256 coll_, uint256 debt_) external {
        rawColls = coll_;
        rawDebts = debt_;
    }
}

contract MockFxManagerPositionV3Test {
    error ErrorDebtRatioTooSmall();

    MockTokenFxPositionV3Test public immutable COLLATERAL;
    MockTokenFxPositionV3Test public immutable DEBT;
    MockFxPoolPositionV3Test public pool;

    constructor(address collateral_, address debt_) {
        COLLATERAL = MockTokenFxPositionV3Test(collateral_);
        DEBT = MockTokenFxPositionV3Test(debt_);
    }

    function setPool(address pool_) external {
        require(address(pool) == address(0), "pool set");
        pool = MockFxPoolPositionV3Test(pool_);
    }

    function getTokenScalingFactor(address) external pure returns (uint256) {
        return 1e18;
    }

    function operate(
        address pool_,
        uint256 positionId_,
        int256 newColl_,
        int256 newDebt_
    ) external returns (uint256 positionId) {
        require(pool_ == address(pool), "pool");
        if (positionId_ == 0 && newColl_ > 0 && newDebt_ <= 0) revert ErrorDebtRatioTooSmall();

        positionId = positionId_ == 0 ? 1 : positionId_;
        (uint256 coll, uint256 debt) = pool.getPosition(positionId);

        if (newColl_ > 0) {
            uint256 amount = uint256(newColl_);
            require(COLLATERAL.transferFrom(msg.sender, address(this), amount), "coll in");
            coll += amount;
        } else if (newColl_ < 0) {
            uint256 amount = newColl_ == type(int256).min ? coll : uint256(-newColl_);
            if (amount > coll) amount = coll;
            coll -= amount;
            require(COLLATERAL.transfer(msg.sender, amount), "coll out");
        }

        if (newDebt_ > 0) {
            uint256 amount = uint256(newDebt_);
            debt += amount;
            DEBT.mint(msg.sender, amount);
        } else if (newDebt_ < 0) {
            uint256 amount = uint256(-newDebt_);
            require(amount <= debt, "debt");
            DEBT.burn(msg.sender, amount);
            debt -= amount;
        }

        pool.setPosition(coll, debt);
    }
}

contract DelegateVaultFxPositionV3Test {
    address public immutable UNDERLYING;
    address public immutable POOL;
    address public immutable DEBT;
    address public immutable STABLE;
    address public immutable PRICE_MIDDLEWARE;

    bool public poolGranted = true;

    constructor(
        address underlying_,
        address pool_,
        address debt_,
        address stable_,
        address priceMiddleware_
    ) {
        UNDERLYING = underlying_;
        POOL = pool_;
        DEBT = debt_;
        STABLE = stable_;
        PRICE_MIDDLEWARE = priceMiddleware_;
    }

    function asset() external view returns (address) {
        return UNDERLYING;
    }

    function getPriceOracleMiddleware() external view returns (address) {
        return PRICE_MIDDLEWARE;
    }

    function setPoolGranted(bool granted_) external {
        poolGranted = granted_;
    }

    function getMarketSubstrates(uint256 marketId_) external view returns (bytes32[] memory substrates) {
        if (marketId_ != 7) return new bytes32[](0);

        uint256 size = poolGranted ? 3 : 2;
        substrates = new bytes32[](size);
        uint256 i;
        if (poolGranted) {
            substrates[i++] = bytes32(uint256(uint160(POOL)));
        }
        substrates[i++] = bytes32(uint256(uint160(DEBT)));
        substrates[i] = bytes32(uint256(uint160(STABLE)));
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
}

contract FxMintCyvbWbtcPositionFuseV3Test_v4 is Test {
    MockTokenFxPositionV3Test internal collateral;
    MockTokenFxPositionV3Test internal debt;
    MockTokenFxPositionV3Test internal stable;
    MockFxOraclePositionV3Test internal oracle;
    MockPriceMiddlewarePositionV3Test internal priceMiddleware;
    MockFxManagerPositionV3Test internal manager;
    MockFxPoolPositionV3Test internal pool;
    DelegateVaultFxPositionV3Test internal vault;
    CyvbWbtcLtvConfig_v3 internal config;
    FxMintCyvbWbtcPositionFuse_v3 internal fuse;
    FxMintCyvbWbtcErc20BalanceFuse_v6 internal balanceFuse;

    function setUp() public {
        collateral = new MockTokenFxPositionV3Test(18);
        debt = new MockTokenFxPositionV3Test(18);
        stable = new MockTokenFxPositionV3Test(6);
        oracle = new MockFxOraclePositionV3Test();
        priceMiddleware = new MockPriceMiddlewarePositionV3Test();
        manager = new MockFxManagerPositionV3Test(address(collateral), address(debt));
        pool = new MockFxPoolPositionV3Test(
            address(collateral),
            address(debt),
            address(manager),
            address(oracle)
        );
        manager.setPool(address(pool));

        priceMiddleware.setPrice(address(debt), 1e18);
        priceMiddleware.setPrice(address(stable), 1e18);

        vault = new DelegateVaultFxPositionV3Test(
            address(collateral),
            address(pool),
            address(debt),
            address(stable),
            address(priceMiddleware)
        );

        config = new CyvbWbtcLtvConfig_v3(address(this));
        config.bindVault(address(vault));

        fuse = new FxMintCyvbWbtcPositionFuse_v3(
            address(config),
            address(manager),
            address(pool),
            address(collateral),
            address(debt)
        );

        balanceFuse = new FxMintCyvbWbtcErc20BalanceFuse_v6(address(config), address(pool));
    }

    function testUsesOfficialErc20MarketId() public view {
        assertEq(fuse.MARKET_ID(), 7);
        assertEq(balanceFuse.MARKET_ID(), 7);
    }

    function testEnterOpensPositionAtomicallyAndRecordsId() public {
        _open();

        assertEq(config.positionId(), 1);
        assertEq(debt.balanceOf(address(vault)), 50e18);
        assertEq(collateral.allowance(address(vault), address(manager)), 0);

        (uint256 rawColls, uint256 rawDebts) = pool.getPosition(1);
        assertEq(rawColls, 100e18);
        assertEq(rawDebts, 50e18);
    }

    function testEnterCannotBypassFxAtomicOpenRule() public {
        collateral.mint(address(vault), 100e18);

        vm.expectRevert(MockFxManagerPositionV3Test.ErrorDebtRatioTooSmall.selector);
        vault.execute(
            address(fuse),
            abi.encodeCall(
                FxMintCyvbWbtcPositionFuse_v3.enter,
                (FxMintCyvbWbtcPositionFuseEnterData({
                    collateralAmount: 100e18,
                    debtAmount: 0
                }))
            )
        );
    }

    function testExitRepaysDebtAndWithdrawsCollateral() public {
        _open();

        vault.execute(
            address(fuse),
            abi.encodeCall(
                FxMintCyvbWbtcPositionFuse_v3.exit,
                (FxMintCyvbWbtcPositionFuseExitData({
                    collateralAmount: 10e18,
                    debtAmount: 20e18
                }))
            )
        );

        (uint256 rawColls, uint256 rawDebts) = pool.getPosition(1);
        assertEq(rawColls, 90e18);
        assertEq(rawDebts, 30e18);
        assertEq(collateral.balanceOf(address(vault)), 10e18);
        assertEq(debt.balanceOf(address(vault)), 30e18);
    }

    function testMarket7BalanceCountsFxEquityAndResidualErc20() public {
        _open();

        // f(x) equity = 100 collateral - 50 debt = 50.
        // Borrowed fxUSD still held by the vault = 50.
        // Total market-7 value = 100.
        bytes memory result = vault.execute(
            address(balanceFuse),
            abi.encodeCall(FxMintCyvbWbtcErc20BalanceFuse_v6.balanceOf, ())
        );
        assertEq(abi.decode(result, (uint256)), 100e18);

        // Add 2 vbUSDC (6 decimals) at $1.
        stable.mint(address(vault), 2e6);
        result = vault.execute(
            address(balanceFuse),
            abi.encodeCall(FxMintCyvbWbtcErc20BalanceFuse_v6.balanceOf, ())
        );
        assertEq(abi.decode(result, (uint256)), 102e18);
    }

    function testMarket7BalanceFloorsNegativeFxLegLikeIporLeveragedFuses() public {
        _open();
        debt.burn(address(vault), 50e18);
        pool.setPosition(100e18, 101e18);

        bytes memory result = vault.execute(
            address(balanceFuse),
            abi.encodeCall(FxMintCyvbWbtcErc20BalanceFuse_v6.balanceOf, ())
        );
        assertEq(abi.decode(result, (uint256)), 0);
    }

    function testRemovingPoolSubstrateRemovesOnlyFxPositionAccounting() public {
        _open();
        vault.setPoolGranted(false);

        bytes memory result = vault.execute(
            address(balanceFuse),
            abi.encodeCall(FxMintCyvbWbtcErc20BalanceFuse_v6.balanceOf, ())
        );

        // Residual borrowed fxUSD is still canonical ERC20 wallet value.
        assertEq(abi.decode(result, (uint256)), 50e18);
    }

    function testFuseRequiresGovernanceGrantedPoolSubstrate() public {
        collateral.mint(address(vault), 100e18);
        vault.setPoolGranted(false);

        vm.expectRevert(
            abi.encodeWithSelector(
                FxMintCyvbWbtcPositionFuse_v3.UnsupportedPool.selector,
                address(pool)
            )
        );
        vault.execute(
            address(fuse),
            abi.encodeCall(
                FxMintCyvbWbtcPositionFuse_v3.enter,
                (FxMintCyvbWbtcPositionFuseEnterData({
                    collateralAmount: 100e18,
                    debtAmount: 50e18
                }))
            )
        );
    }

    function _open() private {
        collateral.mint(address(vault), 100e18);
        vault.execute(
            address(fuse),
            abi.encodeCall(
                FxMintCyvbWbtcPositionFuse_v3.enter,
                (FxMintCyvbWbtcPositionFuseEnterData({
                    collateralAmount: 100e18,
                    debtAmount: 50e18
                }))
            )
        );
    }
}
