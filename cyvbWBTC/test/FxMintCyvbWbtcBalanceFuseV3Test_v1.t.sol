// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "../contracts/FxMintCyvbWbtcBalanceFuse_v3.sol";

contract MockBalanceTokenCyvbWBTCV3TestV1 {
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address to_, uint256 amount_) external {
        balanceOf[to_] += amount_;
    }
}

contract MockNestedVaultCyvbWBTCV3TestV1 {
    address public immutable asset;
    mapping(address => uint256) public balanceOf;

    constructor(address asset_) {
        asset = asset_;
    }

    function mintShares(address to_, uint256 shares_) external {
        balanceOf[to_] += shares_;
    }

    function convertToAssets(uint256 shares_) external pure returns (uint256) {
        return shares_;
    }
}

contract MockPositionConfigCyvbWBTCV3TestV1 {
    uint256 public positionId;

    function setPositionId(uint256 id_) external {
        positionId = id_;
    }
}

contract MockFxOracleCyvbWBTCV3TestV1 {
    uint256 public anchorPrice;

    function setAnchorPrice(uint256 price_) external {
        anchorPrice = price_;
    }

    function getPrice() external view returns (uint256, uint256, uint256) {
        return (anchorPrice, anchorPrice, anchorPrice);
    }
}

contract MockFxFeeConfigCyvbWBTCV3TestV1 {
    address public expectedVault;
    uint256 public vaultWithdrawFee;
    uint256 public otherWithdrawFee;

    constructor(address vault_) {
        expectedVault = vault_;
    }

    function setFees(uint256 vaultFee_, uint256 otherFee_) external {
        vaultWithdrawFee = vaultFee_;
        otherWithdrawFee = otherFee_;
    }

    function getPoolFeeRatio(
        address,
        address recipient_
    ) external view returns (uint256, uint256, uint256, uint256) {
        uint256 fee = recipient_ == expectedVault ? vaultWithdrawFee : otherWithdrawFee;
        return (0, fee, 0, 0);
    }
}

contract MockFxPoolCyvbWBTCV3TestV1 {
    address public immutable priceOracle;
    address public immutable configuration;

    uint256 public rawColls;
    uint256 public rawDebts;

    constructor(address oracle_, address config_) {
        priceOracle = oracle_;
        configuration = config_;
    }

    function setPosition(uint256 collateral_, uint256 debt_) external {
        rawColls = collateral_;
        rawDebts = debt_;
    }

    function getPosition(uint256) external view returns (uint256, uint256) {
        return (rawColls, rawDebts);
    }
}

contract BalanceDelegateVaultCyvbWBTCV3TestV1 {
    function executeBalance(address fuse_) external returns (uint256 balance) {
        (bool ok, bytes memory data) = fuse_.delegatecall(abi.encodeWithSignature("balanceOf()"));
        if (!ok) {
            assembly {
                revert(add(data, 0x20), mload(data))
            }
        }
        balance = abi.decode(data, (uint256));
    }
}

contract FxMintCyvbWbtcBalanceFuseV3Test_v1 is Test {
    MockBalanceTokenCyvbWBTCV3TestV1 internal fxUsd;
    MockBalanceTokenCyvbWBTCV3TestV1 internal vbUsdc;
    MockNestedVaultCyvbWBTCV3TestV1 internal nested;
    MockPositionConfigCyvbWBTCV3TestV1 internal positionConfig;
    MockFxOracleCyvbWBTCV3TestV1 internal oracle;
    MockFxFeeConfigCyvbWBTCV3TestV1 internal feeConfig;
    MockFxPoolCyvbWBTCV3TestV1 internal pool;
    BalanceDelegateVaultCyvbWBTCV3TestV1 internal vault;
    FxMintCyvbWbtcBalanceFuse_v3 internal fuse;

    function setUp() public {
        fxUsd = new MockBalanceTokenCyvbWBTCV3TestV1(18);
        vbUsdc = new MockBalanceTokenCyvbWBTCV3TestV1(6);
        nested = new MockNestedVaultCyvbWBTCV3TestV1(address(vbUsdc));
        positionConfig = new MockPositionConfigCyvbWBTCV3TestV1();
        oracle = new MockFxOracleCyvbWBTCV3TestV1();
        vault = new BalanceDelegateVaultCyvbWBTCV3TestV1();
        feeConfig = new MockFxFeeConfigCyvbWBTCV3TestV1(address(vault));
        pool = new MockFxPoolCyvbWBTCV3TestV1(address(oracle), address(feeConfig));

        fuse = new FxMintCyvbWbtcBalanceFuse_v3(
            address(positionConfig),
            address(pool),
            address(fxUsd),
            address(vbUsdc),
            address(nested)
        );
    }

    function testDelegatecallValuesVaultPositionNestedAndResidualBalances() public {
        positionConfig.setPositionId(1);
        oracle.setAnchorPrice(100e18);
        pool.setPosition(1e18, 40e18);

        // 1% live f(x) withdrawal fee for the actual vault execution address.
        // A deliberately different fee for the external caller catches msg.sender accounting regressions.
        feeConfig.setFees(10_000_000, 200_000_000);

        nested.mintShares(address(vault), 10e6);
        vbUsdc.mint(address(vault), 2e6);
        fxUsd.mint(address(vault), 3e18);

        uint256 balance = vault.executeBalance(address(fuse));

        // 100 collateral - 1% exit fee - 40 debt + 10 nested + 2 vbUSDC + 3 fxUSD = 74 USD.
        assertEq(balance, 74e18);
    }

    function testDebtCannotUnderflowCollateralValue() public {
        positionConfig.setPositionId(1);
        oracle.setAnchorPrice(100e18);
        pool.setPosition(1e18, 150e18);
        feeConfig.setFees(0, 0);

        nested.mintShares(address(vault), 7e6);
        assertEq(vault.executeBalance(address(fuse)), 7e18);
    }

    function testZeroPositionStillCountsNestedAndResidualStable() public {
        positionConfig.setPositionId(0);
        nested.mintShares(address(vault), 4e6);
        vbUsdc.mint(address(vault), 5e6);
        fxUsd.mint(address(vault), 6e18);

        assertEq(vault.executeBalance(address(fuse)), 15e18);
    }

    function testConstructorRejectsNestedAssetMismatch() public {
        MockBalanceTokenCyvbWBTCV3TestV1 wrong = new MockBalanceTokenCyvbWBTCV3TestV1(6);
        MockNestedVaultCyvbWBTCV3TestV1 wrongNested = new MockNestedVaultCyvbWBTCV3TestV1(address(wrong));

        vm.expectRevert(FxMintCyvbWbtcBalanceFuse_v3.NestedVaultAssetMismatch.selector);
        new FxMintCyvbWbtcBalanceFuse_v3(
            address(positionConfig),
            address(pool),
            address(fxUsd),
            address(vbUsdc),
            address(wrongNested)
        );
    }
}
