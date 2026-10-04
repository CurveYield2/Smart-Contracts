// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";

import "../contracts/CyvbWbtcLtvConfig_v3.sol";
import "../contracts/FxMintCyvbWbtcFuse_v5.sol";

contract MockTokenFxMintCyvbWBTCV5TestV4 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to_, uint256 amount_) external {
        balanceOf[to_] += amount_;
    }

    function burn(address from_, uint256 amount_) external {
        require(balanceOf[from_] >= amount_, "burn balance");
        balanceOf[from_] -= amount_;
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

    function _transfer(address from_, address to_, uint256 amount_) private {
        require(balanceOf[from_] >= amount_, "balance");
        balanceOf[from_] -= amount_;
        balanceOf[to_] += amount_;
    }
}

contract MockFxOracleFxMintCyvbWBTCV5TestV4 {
    uint256 public anchorPrice = 1_000e18;

    function setPrice(uint256 price_) external {
        anchorPrice = price_;
    }

    function getPrice() external view returns (uint256, uint256, uint256) {
        return (anchorPrice, anchorPrice, anchorPrice);
    }
}

contract MockFxFeeConfigFxMintCyvbWBTCV5TestV4 {
    uint256 public supplyFee = 3_000_000; // 0.30%, matching live Katana probe
    uint256 public withdrawFee = 1_000_000; // 0.10%, matching live Katana probe
    uint256 public borrowFee;
    uint256 public repayFee;

    function setFees(uint256 supply_, uint256 withdraw_, uint256 borrow_, uint256 repay_) external {
        supplyFee = supply_;
        withdrawFee = withdraw_;
        borrowFee = borrow_;
        repayFee = repay_;
    }

    function getPoolFeeRatio(
        address,
        address
    ) external view returns (uint256, uint256, uint256, uint256) {
        return (supplyFee, withdrawFee, borrowFee, repayFee);
    }
}

contract MockLongPoolFxMintCyvbWBTCV5TestV4 {
    address public immutable collateralToken;
    address public immutable fxUSD;
    address public immutable poolManager;
    address public immutable priceOracle;
    address public immutable configuration;

    uint256 public rawColls;
    uint256 public rawDebts;

    constructor(
        address collateral_,
        address fxUsd_,
        address manager_,
        address oracle_,
        address config_
    ) {
        collateralToken = collateral_;
        fxUSD = fxUsd_;
        poolManager = manager_;
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
        if (rawDebts == 0) return 0;
        uint256 price = MockFxOracleFxMintCyvbWBTCV5TestV4(priceOracle).anchorPrice();
        uint256 collateralValue = (rawColls * price) / 1e18;
        if (collateralValue == 0) return type(uint256).max;
        return (rawDebts * 1e18) / collateralValue;
    }
}

contract MockPoolManagerFxMintCyvbWBTCV5TestV4 {
    uint256 internal constant FEE_PRECISION = 1e9;

    error ErrorDebtRatioTooSmall();

    MockTokenFxMintCyvbWBTCV5TestV4 public immutable COLLATERAL;
    MockTokenFxMintCyvbWBTCV5TestV4 public immutable DEBT;
    MockFxFeeConfigFxMintCyvbWBTCV5TestV4 public immutable FEE_CONFIG;

    MockLongPoolFxMintCyvbWBTCV5TestV4 public pool;

    constructor(address collateral_, address debt_, address feeConfig_) {
        COLLATERAL = MockTokenFxMintCyvbWBTCV5TestV4(collateral_);
        DEBT = MockTokenFxMintCyvbWBTCV5TestV4(debt_);
        FEE_CONFIG = MockFxFeeConfigFxMintCyvbWBTCV5TestV4(feeConfig_);
    }

    function setPool(address pool_) external {
        require(address(pool) == address(0), "pool set");
        pool = MockLongPoolFxMintCyvbWBTCV5TestV4(pool_);
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
        require(pool_ == address(pool), "wrong pool");
        if (positionId_ == 0 && newColl_ > 0 && newDebt_ <= 0) revert ErrorDebtRatioTooSmall();
        positionId = positionId_ == 0 ? 1 : positionId_;

        (uint256 coll, uint256 debt) = pool.getPosition(positionId);
        (uint256 supplyFee, uint256 withdrawFee, uint256 borrowFee, uint256 repayFee) =
            FEE_CONFIG.getPoolFeeRatio(pool_, msg.sender);

        if (newColl_ > 0) {
            uint256 gross = uint256(newColl_);
            require(COLLATERAL.transferFrom(msg.sender, address(this), gross), "coll transfer");
            uint256 fee = (gross * supplyFee) / FEE_PRECISION;
            coll += gross - fee;
        } else if (newColl_ < 0) {
            uint256 gross;
            if (newColl_ == type(int256).min) {
                gross = coll;
            } else {
                gross = uint256(-newColl_);
                if (gross > coll) gross = coll;
            }
            coll -= gross;
            uint256 fee = (gross * withdrawFee) / FEE_PRECISION;
            require(COLLATERAL.transfer(msg.sender, gross - fee), "coll out");
        }

        if (newDebt_ > 0) {
            uint256 grossDebt = uint256(newDebt_);
            debt += grossDebt;
            uint256 fee = (grossDebt * borrowFee) / FEE_PRECISION;
            DEBT.mint(msg.sender, grossDebt - fee);
        } else if (newDebt_ < 0) {
            uint256 reduction = uint256(-newDebt_);
            require(reduction <= debt, "debt reduction");
            uint256 fee = (reduction * repayFee) / FEE_PRECISION;
            DEBT.burn(msg.sender, reduction + fee);
            debt -= reduction;
        }

        pool.setPosition(coll, debt);
    }
}

contract MockFxBaseFxMintCyvbWBTCV5TestV4 {
    address public immutable stableToken;

    constructor(address stable_) {
        stableToken = stable_;
    }

    function getStableTokenPriceWithScale() external pure returns (uint256) {
        return 1e18;
    }
}

contract MockNestedVaultFxMintCyvbWBTCV5TestV4 {
    MockTokenFxMintCyvbWBTCV5TestV4 public immutable TOKEN;
    address public immutable asset;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address token_) {
        TOKEN = MockTokenFxMintCyvbWBTCV5TestV4(token_);
        asset = token_;
    }

    function totalAssets() public view returns (uint256) {
        return TOKEN.balanceOf(address(this));
    }

    function convertToAssets(uint256 shares_) public view returns (uint256 assets) {
        if (totalSupply == 0) return shares_;
        return (shares_ * totalAssets()) / totalSupply;
    }

    function maxWithdraw(address owner_) external view returns (uint256) {
        return convertToAssets(balanceOf[owner_]);
    }

    function deposit(uint256 assets_, address receiver_) external returns (uint256 shares) {
        uint256 assetsBefore = totalAssets();
        uint256 supply = totalSupply;
        shares = supply == 0 || assetsBefore == 0 ? assets_ : (assets_ * supply) / assetsBefore;
        require(TOKEN.transferFrom(msg.sender, address(this), assets_), "stable in");
        totalSupply += shares;
        balanceOf[receiver_] += shares;
    }

    function withdraw(uint256 assets_, address receiver_, address owner_) external returns (uint256 shares) {
        uint256 assetsBefore = totalAssets();
        shares = _ceilDiv(assets_ * totalSupply, assetsBefore);
        require(balanceOf[owner_] >= shares, "shares");
        balanceOf[owner_] -= shares;
        totalSupply -= shares;
        require(TOKEN.transfer(receiver_, assets_), "stable out");
    }

    function redeem(uint256 shares_, address receiver_, address owner_) external returns (uint256 assets) {
        require(balanceOf[owner_] >= shares_, "shares");
        assets = convertToAssets(shares_);
        balanceOf[owner_] -= shares_;
        totalSupply -= shares_;
        require(TOKEN.transfer(receiver_, assets), "stable out");
    }

    function _ceilDiv(uint256 a_, uint256 b_) private pure returns (uint256) {
        return a_ == 0 ? 0 : ((a_ - 1) / b_) + 1;
    }
}

contract MockRouterFxMintCyvbWBTCV5TestV4 {
    MockTokenFxMintCyvbWBTCV5TestV4 public immutable FXUSD;
    MockTokenFxMintCyvbWBTCV5TestV4 public immutable VBUSDC;
    MockTokenFxMintCyvbWBTCV5TestV4 public immutable VBWBTC;
    MockFxOracleFxMintCyvbWBTCV5TestV4 public immutable ORACLE;

    mapping(bytes32 => bool) public routeEnabled;

    constructor(address fxUsd_, address vbUsdc_, address vbWbtc_, address oracle_) {
        FXUSD = MockTokenFxMintCyvbWBTCV5TestV4(fxUsd_);
        VBUSDC = MockTokenFxMintCyvbWBTCV5TestV4(vbUsdc_);
        VBWBTC = MockTokenFxMintCyvbWBTCV5TestV4(vbWbtc_);
        ORACLE = MockFxOracleFxMintCyvbWBTCV5TestV4(oracle_);
    }

    function setRoute(address tokenIn_, address tokenOut_, bool enabled_) external {
        routeEnabled[keccak256(abi.encode(tokenIn_, tokenOut_))] = enabled_;
    }

    function routeFor(address tokenIn_, address tokenOut_) external view returns (bytes memory) {
        if (!routeEnabled[keccak256(abi.encode(tokenIn_, tokenOut_))]) return new bytes(0);
        return hex"01";
    }

    function swapExactInput(
        address tokenIn_,
        address tokenOut_,
        uint256 amountIn_,
        uint256 minNetAmountOut_,
        address recipient_,
        uint256 deadline_
    ) external returns (uint256 netAmountOut) {
        require(block.timestamp <= deadline_, "expired");
        require(routeEnabled[keccak256(abi.encode(tokenIn_, tokenOut_))], "route");

        MockTokenFxMintCyvbWBTCV5TestV4 tokenIn = MockTokenFxMintCyvbWBTCV5TestV4(tokenIn_);
        require(tokenIn.transferFrom(msg.sender, address(this), amountIn_), "input");

        if (
            (tokenIn_ == address(FXUSD) && tokenOut_ == address(VBUSDC)) ||
            (tokenIn_ == address(VBUSDC) && tokenOut_ == address(FXUSD))
        ) {
            netAmountOut = amountIn_;
        } else if (tokenIn_ == address(VBUSDC) && tokenOut_ == address(VBWBTC)) {
            netAmountOut = (amountIn_ * 1e18) / ORACLE.anchorPrice();
        } else {
            revert("unsupported pair");
        }

        require(netAmountOut >= minNetAmountOut_, "minimum");
        MockTokenFxMintCyvbWBTCV5TestV4(tokenOut_).mint(recipient_, netAmountOut);
    }
}

contract StrategyDelegateVaultFxMintCyvbWBTCV5TestV4 {
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

contract FxMintCyvbWbtcFuseV5Test_v4 is Test {
    MockTokenFxMintCyvbWBTCV5TestV4 internal vbWbtc;
    MockTokenFxMintCyvbWBTCV5TestV4 internal fxUsd;
    MockTokenFxMintCyvbWBTCV5TestV4 internal vbUsdc;

    MockFxOracleFxMintCyvbWBTCV5TestV4 internal oracle;
    MockFxFeeConfigFxMintCyvbWBTCV5TestV4 internal feeConfig;
    MockPoolManagerFxMintCyvbWBTCV5TestV4 internal manager;
    MockLongPoolFxMintCyvbWBTCV5TestV4 internal pool;
    MockFxBaseFxMintCyvbWBTCV5TestV4 internal fxBase;
    MockNestedVaultFxMintCyvbWBTCV5TestV4 internal nested;
    MockRouterFxMintCyvbWBTCV5TestV4 internal router;

    StrategyDelegateVaultFxMintCyvbWBTCV5TestV4 internal vault;
    CyvbWbtcLtvConfig_v3 internal config;
    FxMintCyvbWbtcFuse_v5 internal fuse;

    function setUp() public {
        vbWbtc = new MockTokenFxMintCyvbWBTCV5TestV4("vbWBTC", "vbWBTC", 18);
        fxUsd = new MockTokenFxMintCyvbWBTCV5TestV4("fxUSD", "fxUSD", 18);
        vbUsdc = new MockTokenFxMintCyvbWBTCV5TestV4("vbUSDC", "vbUSDC", 18);

        oracle = new MockFxOracleFxMintCyvbWBTCV5TestV4();
        feeConfig = new MockFxFeeConfigFxMintCyvbWBTCV5TestV4();
        manager = new MockPoolManagerFxMintCyvbWBTCV5TestV4(
            address(vbWbtc),
            address(fxUsd),
            address(feeConfig)
        );
        pool = new MockLongPoolFxMintCyvbWBTCV5TestV4(
            address(vbWbtc),
            address(fxUsd),
            address(manager),
            address(oracle),
            address(feeConfig)
        );
        manager.setPool(address(pool));

        fxBase = new MockFxBaseFxMintCyvbWBTCV5TestV4(address(vbUsdc));
        nested = new MockNestedVaultFxMintCyvbWBTCV5TestV4(address(vbUsdc));
        router = new MockRouterFxMintCyvbWBTCV5TestV4(
            address(fxUsd),
            address(vbUsdc),
            address(vbWbtc),
            address(oracle)
        );

        router.setRoute(address(fxUsd), address(vbUsdc), true);
        router.setRoute(address(vbUsdc), address(fxUsd), true);
        router.setRoute(address(vbUsdc), address(vbWbtc), true);

        vault = new StrategyDelegateVaultFxMintCyvbWBTCV5TestV4();
        config = new CyvbWbtcLtvConfig_v3(address(this));
        config.bindVault(address(vault));

        fuse = new FxMintCyvbWbtcFuse_v5(
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

    function testDeployFreshCapitalTargets50PercentAndNestsBorrowedStable() public {
        _fundAndDeploy();

        (uint256 coll, uint256 debt) = pool.getPosition(1);
        assertEq(config.positionId(), 1);
        assertEq(coll, 0.997e18, "0.30% supply fee not reflected");
        assertEq(debt, 498.5e18);
        assertEq(pool.getPositionDebtRatio(1), 0.5e18);
        assertEq(nested.maxWithdraw(address(vault)), 498.5e18);
        assertEq(vbWbtc.balanceOf(address(vault)), 0);
    }

    function testFreshCapitalRejectsExpiredDeadlineAndMissingRoute() public {
        vbWbtc.mint(address(vault), 1e18);

        vm.warp(100);
        vm.expectRevert(FxMintCyvbWbtcFuse_v5.InvalidDeadline.selector);
        vault.execute(
            address(fuse),
            abi.encodeCall(FxMintCyvbWbtcFuse_v5.deployFreshCapital, (0, 0, 99))
        );

        router.setRoute(address(fxUsd), address(vbUsdc), false);
        vm.expectRevert(
            abi.encodeWithSelector(
                FxMintCyvbWbtcFuse_v5.MissingSwapRoute.selector,
                address(fxUsd),
                address(vbUsdc)
            )
        );
        vault.execute(
            address(fuse),
            abi.encodeCall(FxMintCyvbWbtcFuse_v5.deployFreshCapital, (0, 0, block.timestamp))
        );
    }

    function testHighLtvRebalanceResetsTo58Percent() public {
        _fundAndDeploy();
        oracle.setPrice(800e18);
        assertGe(pool.getPositionDebtRatio(1), 0.60e18);

        vault.execute(
            address(fuse),
            abi.encodeCall(FxMintCyvbWbtcFuse_v5.rebalanceLtv, (0, 0, block.timestamp))
        );

        assertApproxEqAbs(pool.getPositionDebtRatio(1), 0.58e18, 2);
    }

    function testLowLtvRebalanceResetsTo50Percent() public {
        _fundAndDeploy();
        oracle.setPrice(1_200e18);
        assertLe(pool.getPositionDebtRatio(1), 0.45e18);

        uint256 nestedBefore = nested.maxWithdraw(address(vault));
        vault.execute(
            address(fuse),
            abi.encodeCall(FxMintCyvbWbtcFuse_v5.rebalanceLtv, (0, 0, block.timestamp))
        );

        assertApproxEqAbs(pool.getPositionDebtRatio(1), 0.50e18, 2);
        assertGt(nested.maxWithdraw(address(vault)), nestedBefore);
    }

    function testRebalanceInsideBandReverts() public {
        _fundAndDeploy();
        uint256 current = pool.getPositionDebtRatio(1);

        vm.expectRevert(
            abi.encodeWithSelector(FxMintCyvbWbtcFuse_v5.NoRebalanceNeeded.selector, current)
        );
        vault.execute(
            address(fuse),
            abi.encodeCall(FxMintCyvbWbtcFuse_v5.rebalanceLtv, (0, 0, block.timestamp))
        );
    }

    function testSmallInstantWithdrawalUsesCollateralOnlyBelow55Percent() public {
        _fundAndDeploy();
        (, uint256 debtBefore) = pool.getPosition(1);

        _instantWithdraw(0.05e18);

        (, uint256 debtAfter) = pool.getPosition(1);
        assertEq(debtAfter, debtBefore);
        assertGe(vbWbtc.balanceOf(address(vault)), 0.05e18);
        assertLe(pool.getPositionDebtRatio(1), 0.55e18);
    }

    function testCrossing55PercentDeleveragesBeforeFurtherCollateralExit() public {
        _fundAndDeploy();
        (, uint256 debtBefore) = pool.getPosition(1);

        _instantWithdraw(0.15e18);

        (, uint256 debtAfter) = pool.getPosition(1);
        assertLt(debtAfter, debtBefore);
        assertGe(vbWbtc.balanceOf(address(vault)), 0.15e18);
        assertLe(pool.getPositionDebtRatio(1), 0.55e18);
    }

    function testInstantWithdrawalStartingAbove55PercentDeleverages() public {
        _fundAndDeploy();
        oracle.setPrice(850e18);
        assertGt(pool.getPositionDebtRatio(1), 0.55e18);

        _instantWithdraw(0.05e18);

        assertGe(vbWbtc.balanceOf(address(vault)), 0.05e18);
        assertLe(pool.getPositionDebtRatio(1), 0.55e18);
    }

    function testFullUnwindUsesNestedYieldAndPositionCanBeReused() public {
        _fundAndDeploy();

        // Simulate $100 of nested vault yield. This gives the full unwind enough equity
        // beyond f(x) collateral to make the requested instant withdrawal attainable.
        vbUsdc.mint(address(nested), 100e18);

        _instantWithdraw(1.05e18);

        (uint256 coll, uint256 debt) = pool.getPosition(1);
        assertEq(coll, 0);
        assertEq(debt, 0);
        assertEq(nested.balanceOf(address(vault)), 0);
        assertGe(vbWbtc.balanceOf(address(vault)), 1.05e18);

        // Simulate the PlasmaVault paying the completed withdrawal, then deploy new capital.
        vbWbtc.burn(address(vault), vbWbtc.balanceOf(address(vault)));
        vbWbtc.mint(address(vault), 1e18);

        vault.execute(
            address(fuse),
            abi.encodeCall(FxMintCyvbWbtcFuse_v5.deployFreshCapital, (0, 0, block.timestamp))
        );

        (coll, debt) = pool.getPosition(1);
        assertEq(config.positionId(), 1, "position id should be reused");
        assertGt(coll, 0);
        assertGt(debt, 0);
        assertGt(nested.balanceOf(address(vault)), 0);
    }

    function testExactValueUnwindPassesRepayStageBeforeInsufficientOutputCheck() public {
        _fundAndDeploy();

        // There is exactly enough nested stable to repay all debt, but no extra equity beyond
        // the collateral. v2 incorrectly reverted at its 1% stable buffer before repayment.
        // v3 caps the buffer to available stable, completes repayment/unwind, and only then
        // rejects an economically impossible request larger than total produced vbWBTC.
        vm.expectRevert(
            abi.encodeWithSelector(
                FxMintCyvbWbtcFuse_v5.InsufficientVbWbtcProduced.selector,
                1.01e18,
                996003000000000001
            )
        );
        _instantWithdraw(1.01e18);
    }

    function _fundAndDeploy() private {
        vbWbtc.mint(address(vault), 1e18);
        vault.execute(
            address(fuse),
            abi.encodeCall(FxMintCyvbWbtcFuse_v5.deployFreshCapital, (0, 0, block.timestamp))
        );
    }

    function _instantWithdraw(uint256 amount_) private {
        bytes32[] memory params = new bytes32[](1);
        params[0] = bytes32(amount_);
        vault.execute(
            address(fuse),
            abi.encodeCall(FxMintCyvbWbtcFuse_v5.instantWithdraw, (params))
        );
    }
}
