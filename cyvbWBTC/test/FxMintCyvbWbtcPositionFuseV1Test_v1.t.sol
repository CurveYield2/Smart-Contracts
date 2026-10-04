// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";

import "../contracts/CyvbWbtcLtvConfig_v3.sol";
import "../contracts/FxMintCyvbWbtcPositionFuse_v1.sol";
import "../contracts/FxMintCyvbWbtcBalanceFuse_v4.sol";

contract MockTokenFxPositionV1Test {
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

contract MockFxOraclePositionV1Test {
    uint256 public anchorPrice = 1e18;

    function setPrice(uint256 price_) external {
        anchorPrice = price_;
    }

    function getPrice() external view returns (uint256, uint256, uint256) {
        return (anchorPrice, anchorPrice, anchorPrice);
    }
}

contract MockFxPoolPositionV1Test {
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

contract MockFxManagerPositionV1Test {
    error ErrorDebtRatioTooSmall();

    MockTokenFxPositionV1Test public immutable COLLATERAL;
    MockTokenFxPositionV1Test public immutable DEBT;
    MockFxPoolPositionV1Test public pool;

    constructor(address collateral_, address debt_) {
        COLLATERAL = MockTokenFxPositionV1Test(collateral_);
        DEBT = MockTokenFxPositionV1Test(debt_);
    }

    function setPool(address pool_) external {
        require(address(pool) == address(0), "pool set");
        pool = MockFxPoolPositionV1Test(pool_);
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

contract DelegateVaultFxPositionV1Test {
    address public grantedPool;

    constructor(address pool_) {
        grantedPool = pool_;
    }

    function setGrantedPool(address pool_) external {
        grantedPool = pool_;
    }

    function getMarketSubstrates(uint256 marketId_) external view returns (bytes32[] memory substrates) {
        if (marketId_ != 7001 || grantedPool == address(0)) {
            return new bytes32[](0);
        }
        substrates = new bytes32[](1);
        substrates[0] = bytes32(uint256(uint160(grantedPool)));
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

    function recordPosition(CyvbWbtcLtvConfig_v3 config_, uint256 id_) external {
        config_.recordPositionId(id_);
    }
}

contract FxMintCyvbWbtcPositionFuseV1Test_v1 is Test {
    MockTokenFxPositionV1Test internal collateral;
    MockTokenFxPositionV1Test internal debt;
    MockFxOraclePositionV1Test internal oracle;
    MockFxManagerPositionV1Test internal manager;
    MockFxPoolPositionV1Test internal pool;
    DelegateVaultFxPositionV1Test internal vault;
    CyvbWbtcLtvConfig_v3 internal config;
    FxMintCyvbWbtcPositionFuse_v1 internal fuse;
    FxMintCyvbWbtcBalanceFuse_v4 internal balanceFuse;

    function setUp() public {
        collateral = new MockTokenFxPositionV1Test();
        debt = new MockTokenFxPositionV1Test();
        oracle = new MockFxOraclePositionV1Test();
        manager = new MockFxManagerPositionV1Test(address(collateral), address(debt));
        pool = new MockFxPoolPositionV1Test(
            address(collateral),
            address(debt),
            address(manager),
            address(oracle)
        );
        manager.setPool(address(pool));

        vault = new DelegateVaultFxPositionV1Test(address(pool));

        config = new CyvbWbtcLtvConfig_v3(address(this));
        config.bindVault(address(vault));

        fuse = new FxMintCyvbWbtcPositionFuse_v1(
            address(config),
            address(manager),
            address(pool),
            address(collateral),
            address(debt)
        );

        balanceFuse = new FxMintCyvbWbtcBalanceFuse_v4(address(config), address(pool));
    }

    function testEnterOpensPositionAtomicallyAndRecordsId() public {
        collateral.mint(address(vault), 100e18);

        bytes memory result = vault.execute(
            address(fuse),
            abi.encodeCall(
                FxMintCyvbWbtcPositionFuse_v1.enter,
                (FxMintCyvbWbtcPositionFuseEnterData({
                    collateralAmount: 100e18,
                    debtAmount: 50e18
                }))
            )
        );

        (uint256 positionId, uint256 supplied, uint256 borrowed) =
            abi.decode(result, (uint256, uint256, uint256));

        assertEq(positionId, 1);
        assertEq(config.positionId(), 1);
        assertEq(supplied, 100e18);
        assertEq(borrowed, 50e18);
        assertEq(debt.balanceOf(address(vault)), 50e18);
        assertEq(collateral.allowance(address(vault), address(manager)), 0);

        (uint256 rawColls, uint256 rawDebts) = pool.getPosition(1);
        assertEq(rawColls, 100e18);
        assertEq(rawDebts, 50e18);
    }

    function testEnterCannotBypassFxAtomicOpenRule() public {
        collateral.mint(address(vault), 100e18);

        vm.expectRevert(MockFxManagerPositionV1Test.ErrorDebtRatioTooSmall.selector);
        vault.execute(
            address(fuse),
            abi.encodeCall(
                FxMintCyvbWbtcPositionFuse_v1.enter,
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
                FxMintCyvbWbtcPositionFuse_v1.exit,
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

    function testExitCapsDebtAndSupportsAllCollateralSentinel() public {
        _open();

        vault.execute(
            address(fuse),
            abi.encodeCall(
                FxMintCyvbWbtcPositionFuse_v1.exit,
                (FxMintCyvbWbtcPositionFuseExitData({
                    collateralAmount: type(uint256).max,
                    debtAmount: type(uint256).max
                }))
            )
        );

        (uint256 rawColls, uint256 rawDebts) = pool.getPosition(1);
        assertEq(rawColls, 0);
        assertEq(rawDebts, 0);
        assertEq(collateral.balanceOf(address(vault)), 100e18);
        assertEq(debt.balanceOf(address(vault)), 0);
        assertEq(config.positionId(), 1, "f(x) NFT id remains reusable");
    }

    function testFuseRequiresGovernanceGrantedPoolSubstrate() public {
        collateral.mint(address(vault), 100e18);
        vault.setGrantedPool(address(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                FxMintCyvbWbtcPositionFuse_v1.UnsupportedPool.selector,
                address(pool)
            )
        );
        vault.execute(
            address(fuse),
            abi.encodeCall(
                FxMintCyvbWbtcPositionFuse_v1.enter,
                (FxMintCyvbWbtcPositionFuseEnterData({
                    collateralAmount: 100e18,
                    debtAmount: 50e18
                }))
            )
        );
    }

    function testBalanceFuseCountsOnlyFxNetPosition() public {
        _open();

        bytes memory result = vault.execute(
            address(balanceFuse),
            abi.encodeCall(FxMintCyvbWbtcBalanceFuse_v4.balanceOf, ())
        );
        assertEq(abi.decode(result, (uint256)), 50e18);
    }

    function testBalanceFuseRevertsOnNegativeNetPosition() public {
        _open();
        pool.setPosition(100e18, 101e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                FxMintCyvbWbtcBalanceFuse_v4.NegativeBalance.selector,
                100e18,
                101e18
            )
        );
        vault.execute(
            address(balanceFuse),
            abi.encodeCall(FxMintCyvbWbtcBalanceFuse_v4.balanceOf, ())
        );
    }

    function testBalanceFuseReturnsZeroWhenPoolSubstrateRemoved() public {
        _open();
        vault.setGrantedPool(address(0));

        bytes memory result = vault.execute(
            address(balanceFuse),
            abi.encodeCall(FxMintCyvbWbtcBalanceFuse_v4.balanceOf, ())
        );
        assertEq(abi.decode(result, (uint256)), 0);
    }

    function _open() private {
        collateral.mint(address(vault), 100e18);
        vault.execute(
            address(fuse),
            abi.encodeCall(
                FxMintCyvbWbtcPositionFuse_v1.enter,
                (FxMintCyvbWbtcPositionFuseEnterData({
                    collateralAmount: 100e18,
                    debtAmount: 50e18
                }))
            )
        );
    }
}
