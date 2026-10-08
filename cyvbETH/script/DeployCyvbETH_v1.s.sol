// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";

import "../contracts/VbEthUsdPriceFeed_v1.sol";
import "../contracts/FxMintWeEthPriceFeed_v1.sol";
import "../contracts/FxMintCyvbEthFuse_v1.sol";
import "../contracts/CyvbEthMorphoAllocatorFuse_v1.sol";
import "../contracts/CyvbEthIndicatorToken_v1.sol";
import "../../cyvbWBTC/contracts/IporBurnRequestFeeFuse_v1.sol";
import "../../cyvbWBTC/contracts/IporUpdateWithdrawManagerFuse_v1.sol";
import "../contracts/CyvbEthWithdrawManager_v1.sol";

struct FeePackageCyvbETHV1 {
    uint256 managementFee;
    uint256 performanceFee;
    address feeRecipient;
}

struct FusionInstanceCyvbETHV1 {
    uint256 index;
    uint256 version;
    string assetName;
    string assetSymbol;
    uint8 assetDecimals;
    address underlyingToken;
    string underlyingTokenSymbol;
    uint8 underlyingTokenDecimals;
    address initialOwner;
    address plasmaVault;
    address plasmaVaultBase;
    address accessManager;
    address feeManager;
    address rewardsManager;
    address withdrawManager;
    address contextManager;
    address priceManager;
}

struct RecipientFeeCyvbETHV1 {
    address recipient;
    uint256 feeValue;
}

struct InstantWithdrawalFuseParamsCyvbETHV1 {
    address fuse;
    bytes32[] params;
}

interface IFusionFactoryCyvbETHV1 {
    function clone(
        string calldata assetName_,
        string calldata assetSymbol_,
        address underlyingToken_,
        uint256 redemptionDelayInSeconds_,
        address owner_,
        uint256 daoFeePackageIndex_
    ) external returns (FusionInstanceCyvbETHV1 memory);

    function getDaoFeePackages() external view returns (FeePackageCyvbETHV1[] memory);
}

interface IAccessManagerCyvbETHV1 {
    function grantRole(uint64 roleId_, address account_, uint32 executionDelay_) external;
    function renounceRole(uint64 roleId_, address callerConfirmation_) external;
    function hasRole(uint64 roleId_, address account_) external view returns (bool isMember, uint32 executionDelay);
}

interface IVaultSubstratesCyvbETHV15 {
    function grantMarketSubstrates(uint256 marketId, bytes32[] calldata substrates) external;
}

struct FuseActionCyvbETHV14 {
    address fuse;
    bytes data;
}

interface IPlasmaVaultExecCyvbETHV14 {
    function execute(FuseActionCyvbETHV14[] calldata calls) external;
}

interface IPlasmaVaultGovernanceCyvbETHV1 {
    function addFuses(address[] calldata fuses_) external;
    function addBalanceFuse(uint256 marketId_, address fuse_) external;
    function configureInstantWithdrawalFuses(InstantWithdrawalFuseParamsCyvbETHV1[] calldata fuses_) external;
    function setPreHookImplementations(
        bytes4[] calldata selectors_,
        address[] calldata implementations_,
        bytes32[][] calldata substrates_
    ) external;
    function convertToPublicVault() external;
    function enableTransferShares() external;

    function getFuses() external view returns (address[] memory);
    function getInstantWithdrawalFuses() external view returns (address[] memory);
    function isBalanceFuseSupported(uint256 marketId_, address fuse_) external view returns (bool);
    function getManagementFeeData() external view returns (address feeAccount, uint16 feeInPercentage, uint32 lastUpdateTimestamp);
    function getPerformanceFeeData() external view returns (address feeAccount, uint16 feeInPercentage);
}

interface IPriceManagerCyvbETHV1 {
    function setAssetsPriceSources(address[] calldata assets_, address[] calldata sources_) external;
    function getSourceOfAssetPrice(address asset_) external view returns (address);
}

interface IFeeManagerCyvbETHV1 {
    function updateManagementFee(RecipientFeeCyvbETHV1[] calldata recipientFees) external;
    function updatePerformanceFee(RecipientFeeCyvbETHV1[] calldata recipientFees) external;
    function setDepositFee(uint256 depositFee_) external;
    function getDepositFee() external view returns (uint256);
    function getTotalManagementFee() external view returns (uint256);
    function getTotalPerformanceFee() external view returns (uint256);
    function getManagementFeeRecipients() external view returns (RecipientFeeCyvbETHV1[] memory);
    function getPerformanceFeeRecipients() external view returns (RecipientFeeCyvbETHV1[] memory);
}

interface IERC4626InfoCyvbETHV1 {
    function asset() external view returns (address);
    function symbol() external view returns (string memory);
}

interface IWithdrawManagerInfoCyvbETHV2 {
    function getWithdrawFee() external view returns (uint256);
    function updateWithdrawFee(uint256 fee_) external;
}

interface IFxLongPoolDeployCyvbETHV6 {
    function priceOracle() external view returns (address);
}

interface ICurveYieldRouterInfoCyvbETHV1 {
    function routeFor(address tokenIn, address tokenOut) external view returns (bytes memory);
}

struct CyvbEthComponentsV6 {
    address priceFeed;
    address collateralPriceFeed;
    address morphoAllocatorFuse;
    address burnFuse;
    address updateWmFuse;
    address withdrawManager;
    address strategyFuse;
    address oneWeiFeed;
    address collateralIndicator;
    address earnIndicator;
    address cyvbUsdcIndicator;
    address debtIndicator;
}

/// @title DeployCyvbETH_v1
/// @notice Deploy and configure CurveYield vbETH / cyvbETH through the official IPOR Fusion factory on Katana.
/// @dev Minimal ETH-side clone of the live CurveYield leveraged-vault stack:
///      - vbETH is the vault asset and the keeper may allocate it to Morpho or f(x);
///      - f(x) currently has no vbETH collateral pool, so the verified weETH pool is used with vbETH<->weETH swaps;
///      - the exact Morpho vbETH/yvvbUSDC market uses IPOR's deployed Morpho integration;
///      - fees, LTV policy, nested cyvbUSDC leg, earn policy, roles, and withdrawal semantics remain unchanged.
contract DeployCyvbETH_v1 is Script {
    uint256 internal constant KATANA_CHAIN_ID = 747474;
    uint256 internal constant STRATEGY_MARKET_ID = 7; // IporFusionMarkets.ERC20_VAULT_BALANCE
    uint256 internal constant MORPHO_IPOR_MARKET_ID = 14; // IporFusionMarkets.MORPHO
    address internal constant ERC20_BALANCE_FUSE = 0xb81C00eb71a3D629E6f7Ba66a26218c418D438b8;
    address internal constant MORPHO_BALANCE_FUSE = 0x83790D83C23461cd22429276406C4f09DB885A85;
    address internal constant MORPHO_SUPPLY_FUSE = 0xC66c3F5cC5e1550A0Ff960c06D630A2FBB80E19d;
    address internal constant MORPHO = 0xD50F2DffFd62f94Ee4AEd9ca05C61d0753268aBc;
    bytes32 internal constant MORPHO_MARKET_ID =
        0x2c4f26c76b4de51d3c9260c15a796cd2a35efab17786d0aa78ca2e638b0f8ba8;

    IFusionFactoryCyvbETHV1 internal constant FACTORY =
        IFusionFactoryCyvbETHV1(0xc29b8D591d6a3f109Ca7ba384F2e00162866D37B);

    address internal constant FEE_RECEIVER = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49; // cyavKAT fee Safe
    /// @dev Owner: the same owner as the cyavKAT vault (override with FINAL_OWNER)
    address internal constant VAULT_OWNER = 0x11b78837cadC8E894F1c6e13fA9f3A085a75FA35;
    uint256 internal constant ONBOARDING_FEE = 0.0075e18; // FeeManager deposit fee, WAD (0.75%: covers the ~0.67% full-swap deploy cost)
    uint256 internal constant REQUEST_FEE = 0.005e18; // scheduled-withdrawal request fee, WAD (0.50%)
    uint256 internal constant WITHDRAW_WINDOW = 7 days; // claim window after a scheduled request
    address internal constant EARN_GAUGE = 0x76A84525c5f61136Cf562dC1bD5aBB19FB8B53fC; // fxBASE gauge (weETH)
    uint16 internal constant EARN_BPS = 0; // earn pool OFF until the fxBASE gauge is funded (then 6_000 = 60%: new fuse version)
    uint256 internal constant INSTANT_WITHDRAW_FEE = 0.01e18; // withdraw manager instant fee, WAD (1.00%)

    address internal constant VBETH = 0xEE7D8BCFb72bC1880D0Cf19822eB0A2e6577aB62;
    address internal constant WEETH = 0x9893989433e7a383Cb313953e4c2365107dc19a7;
    address internal constant ETH_USD_CHAINLINK = 0x7BdBDB772f4a073BadD676A567C6ED82049a8eEE;
    address internal constant VBUSDC = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36;
    address internal constant FXUSD = 0x4c03ff0f44A55e7098a09016E02a01d3cdC2FDF9;

    address internal constant FX_POOL_MANAGER = 0x27b3eE81DF2Dd7356D5ac282e2416991A616f96a;
    address internal constant FX_POOL = 0x6776ce77f47aab00405fd5776c4baadc68c8ce3d;
    address internal constant FXBASE = 0xdE2E0736Ee813C425b0eE1a6e0627233B3B1EeF8;
    address internal constant FX_PRICE_ORACLE = 0x849b9e3119B7c4E4Dd0DdfaD1E0DFe587158692d;

    address internal constant CURVEYIELD_ROUTER = 0x01F9894f92ea9224fECc8C35482E20a05De13582;

    uint256 internal constant MIDDLE_WAY_PACKAGE_INDEX = 1;
    uint256 internal constant EXPECTED_IPOR_MANAGEMENT_BPS = 30;
    uint256 internal constant EXPECTED_IPOR_PERFORMANCE_BPS = 200;

    // User-directed CurveYield fee layer.
    uint256 internal constant CURVEYIELD_MANAGEMENT_BPS = 100; // 1.00%
    uint256 internal constant CURVEYIELD_PERFORMANCE_BPS = 800; // 8.00%
    uint256 internal constant EXPECTED_TOTAL_MANAGEMENT_BPS = 130; // 0.30% + 1.00%
    uint256 internal constant EXPECTED_TOTAL_PERFORMANCE_BPS = 1000; // 2.00% + 8.00%

    uint64 internal constant OWNER_ROLE = 1;
    uint64 internal constant ATOMIST_ROLE = 100;
    uint64 internal constant ALPHA_ROLE = 200;
    uint64 internal constant FUSE_MANAGER_ROLE = 300;
    uint64 internal constant WHITELIST_ROLE = 800;
    uint64 internal constant CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE = 900;
    uint64 internal constant UPDATE_MARKETS_BALANCES_ROLE = 1000;
    uint64 internal constant PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE = 1200;
    uint64 internal constant WITHDRAW_MANAGER_WITHDRAW_FEE_ROLE = 902;


    event CyvbEthDeployed(
        address indexed vault,
        address indexed strategyFuse,
        address indexed collateralIndicator,
        address priceFeed,
        address morphoAllocatorFuse,
        address keeper,
        address owner,
        address nestedCyvbUsdc
    );

    function run() external returns (FusionInstanceCyvbETHV1 memory instance) {
        require(block.chainid == KATANA_CHAIN_ID, "not Katana");

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address keeper = vm.envOr("KEEPER", deployer);
        address finalOwner = vm.envOr("FINAL_OWNER", VAULT_OWNER);
        address nestedCyvbUsdc = vm.envAddress("CURVEYIELD_USDC_VAULT");

        require(keeper != address(0) && finalOwner != address(0), "zero role address");
        _verifyExternalDependencies(nestedCyvbUsdc);
        _verifyMiddleWay();
        _verifyRoutes();

        vm.startBroadcast(privateKey);

        instance = FACTORY.clone(
            "CurveYield vbETH",
            "cyvbETH",
            VBETH,
            0,
            deployer,
            MIDDLE_WAY_PACKAGE_INDEX
        );

        CyvbEthComponentsV6 memory components =
            _deployComponents(instance.plasmaVault, nestedCyvbUsdc);

        _configureRoles(instance, deployer, keeper, finalOwner);
        _configurePrice(instance, components);
        _configureStrategy(instance, components);
        _installWithdrawManager(instance, components);
        _configureFees(instance);

        IPlasmaVaultGovernanceCyvbETHV1(instance.plasmaVault).convertToPublicVault();
        IPlasmaVaultGovernanceCyvbETHV1(instance.plasmaVault).enableTransferShares();

        _handover(instance, deployer, finalOwner);

        vm.stopBroadcast();

        _verifyDeployment(instance, nestedCyvbUsdc, keeper, finalOwner, components);

        emit CyvbEthDeployed(
            instance.plasmaVault,
            components.strategyFuse,
            components.collateralIndicator,
            components.priceFeed,
            components.morphoAllocatorFuse,
            keeper,
            finalOwner,
            nestedCyvbUsdc
        );
    }

    function _deployComponents(
        address vault_,
        address nestedCyvbUsdc_
    ) private returns (CyvbEthComponentsV6 memory components) {
        components.priceFeed = address(new VbEthUsdPriceFeed_v1(ETH_USD_CHAINLINK));
        components.collateralPriceFeed = address(new FxMintWeEthPriceFeed_v1(FX_PRICE_ORACLE));
        components.oneWeiFeed = address(new CyvbEthOneWeiPriceFeed_v1());
        components.collateralIndicator = address(new CyvbEthIndicatorToken_v1(
            "fxMINT weETH Collateral", "fxMINT-weETH", CyvbEthIndicatorToken_v1.Kind.FX_COLLATERAL,
            vault_, FX_POOL, FX_POOL_MANAGER, WEETH, 18
        ));
        components.earnIndicator = address(new CyvbEthIndicatorToken_v1(
            "fxUSD Stability Pool TVL", "fxBASE-TVL", CyvbEthIndicatorToken_v1.Kind.EARN_POOL_TVL,
            vault_, FXBASE, EARN_GAUGE, address(0), 18
        ));
        components.cyvbUsdcIndicator = address(new CyvbEthIndicatorToken_v1(
            "CurveYield USDC TVL", "cyvbUSDC-TVL", CyvbEthIndicatorToken_v1.Kind.CYVBUSDC_TVL,
            vault_, nestedCyvbUsdc_, address(0), address(0), 18
        ));
        components.debtIndicator = address(new CyvbEthIndicatorToken_v1(
            "fxUSD Debt", "fxUSD-DEBT", CyvbEthIndicatorToken_v1.Kind.FXUSD_DEBT,
            vault_, FX_POOL, address(0), address(0), 18
        ));
        // IporFusionMarkets.ZERO_BALANCE_MARKET, as the factory's own burn fuse
        components.burnFuse = address(new IporBurnRequestFeeFuse_v1(type(uint256).max));
        // default policy: target 50%, high 60% -> 58%, low 45% -> 50% (validated in the fuse constructor)
        components.strategyFuse = address(new FxMintCyvbEthFuse_v1(
            STRATEGY_MARKET_ID,
            MORPHO_MARKET_ID,
            vault_,
            CyvbEthLtvPolicy({
                targetLtvBps: 5_000, highTriggerBps: 6_000, highResetBps: 5_800, lowTriggerBps: 4_500, lowResetBps: 5_000,
                earnBps: EARN_BPS
            }),
            CyvbEthFuseAddresses({
                poolManager: FX_POOL_MANAGER, fxPool: FX_POOL, fxBase: FXBASE, earnGauge: EARN_GAUGE, fxUsd: FXUSD,
                vbEth: VBETH, weEth: WEETH, vbEthPriceFeed: components.priceFeed, morpho: MORPHO,
                vbUsdc: VBUSDC, cyvbUsdc: nestedCyvbUsdc_, router: CURVEYIELD_ROUTER,
                collateralIndicator: components.collateralIndicator, debtIndicator: components.debtIndicator
            })
        ));
        components.morphoAllocatorFuse = address(new CyvbEthMorphoAllocatorFuse_v1(
            vault_, VBETH, MORPHO_SUPPLY_FUSE, MORPHO_IPOR_MARKET_ID, MORPHO_MARKET_ID
        ));
        components.updateWmFuse = address(new IporUpdateWithdrawManagerFuse_v1(type(uint256).max));
        components.withdrawManager =
            address(new CyvbEthWithdrawManager_v1(vault_, WITHDRAW_WINDOW, INSTANT_WITHDRAW_FEE, REQUEST_FEE));
    }

    function _configureRoles(
        FusionInstanceCyvbETHV1 memory instance_,
        address deployer_,
        address keeper_,
        address finalOwner_
    ) private {
        IAccessManagerCyvbETHV1 access = IAccessManagerCyvbETHV1(instance_.accessManager);

        access.grantRole(ATOMIST_ROLE, deployer_, 0);
        access.grantRole(FUSE_MANAGER_ROLE, deployer_, 0);
        access.grantRole(CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE, deployer_, 0);
        access.grantRole(PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, deployer_, 0);
        access.grantRole(WITHDRAW_MANAGER_WITHDRAW_FEE_ROLE, deployer_, 0);

        access.grantRole(ALPHA_ROLE, keeper_, 0);
        if (keeper_ != deployer_) access.grantRole(ALPHA_ROLE, deployer_, 0);
        access.grantRole(UPDATE_MARKETS_BALANCES_ROLE, keeper_, 0);

        if (finalOwner_ != deployer_) {
            access.grantRole(OWNER_ROLE, finalOwner_, 0);
            access.grantRole(ATOMIST_ROLE, finalOwner_, 0);
        }
    }

    function _configurePrice(FusionInstanceCyvbETHV1 memory instance_, CyvbEthComponentsV6 memory c_) private {
        address[] memory assets = new address[](5);
        address[] memory sources = new address[](5);
        (assets[0], sources[0]) = (VBETH, c_.priceFeed);
        (assets[1], sources[1]) = (c_.collateralIndicator, c_.collateralPriceFeed); // weETH collateral units
        (assets[2], sources[2]) = (c_.earnIndicator, c_.oneWeiFeed);
        (assets[3], sources[3]) = (c_.cyvbUsdcIndicator, c_.oneWeiFeed);
        (assets[4], sources[4]) = (c_.debtIndicator, c_.oneWeiFeed);
        IPriceManagerCyvbETHV1(instance_.priceManager).setAssetsPriceSources(assets, sources);
    }

    function _configureStrategy(
        FusionInstanceCyvbETHV1 memory instance_,
        CyvbEthComponentsV6 memory c_
    ) private {
        address strategyFuse_ = c_.strategyFuse;
        address morphoAllocatorFuse_ = c_.morphoAllocatorFuse;
        address burnFuse_ = c_.burnFuse;
        IPlasmaVaultGovernanceCyvbETHV1 vault =
            IPlasmaVaultGovernanceCyvbETHV1(instance_.plasmaVault);

        address[] memory fuses = new address[](3);
        fuses[0] = strategyFuse_;
        fuses[1] = morphoAllocatorFuse_;
        fuses[2] = burnFuse_;
        vault.addFuses(fuses);
        vault.addBalanceFuse(STRATEGY_MARKET_ID, ERC20_BALANCE_FUSE);
        bytes32[] memory subs = new bytes32[](4);
        subs[0] = bytes32(uint256(uint160(c_.collateralIndicator)));
        subs[1] = bytes32(uint256(uint160(c_.earnIndicator)));
        subs[2] = bytes32(uint256(uint160(c_.cyvbUsdcIndicator)));
        subs[3] = bytes32(uint256(uint160(c_.debtIndicator)));
        IVaultSubstratesCyvbETHV15(instance_.plasmaVault).grantMarketSubstrates(STRATEGY_MARKET_ID, subs);

        vault.addBalanceFuse(MORPHO_IPOR_MARKET_ID, MORPHO_BALANCE_FUSE);
        bytes32[] memory morphoSubs = new bytes32[](1);
        morphoSubs[0] = MORPHO_MARKET_ID;
        IVaultSubstratesCyvbETHV15(instance_.plasmaVault).grantMarketSubstrates(MORPHO_IPOR_MARKET_ID, morphoSubs);

        InstantWithdrawalFuseParamsCyvbETHV1[] memory instant =
            new InstantWithdrawalFuseParamsCyvbETHV1[](2);
        bytes32[] memory morphoParams = new bytes32[](1);
        morphoParams[0] = bytes32(0);
        instant[0] = InstantWithdrawalFuseParamsCyvbETHV1({fuse: morphoAllocatorFuse_, params: morphoParams});
        bytes32[] memory strategyParams = new bytes32[](1);
        strategyParams[0] = bytes32(0);
        instant[1] = InstantWithdrawalFuseParamsCyvbETHV1({fuse: strategyFuse_, params: strategyParams});
        vault.configureInstantWithdrawalFuses(instant);
    }

    function _configureFees(FusionInstanceCyvbETHV1 memory instance_) private {
        IFeeManagerCyvbETHV1 fees = IFeeManagerCyvbETHV1(instance_.feeManager);

        RecipientFeeCyvbETHV1[] memory management = new RecipientFeeCyvbETHV1[](1);
        management[0] = RecipientFeeCyvbETHV1({
            recipient: FEE_RECEIVER,
            feeValue: CURVEYIELD_MANAGEMENT_BPS
        });
        fees.updateManagementFee(management);

        RecipientFeeCyvbETHV1[] memory performance = new RecipientFeeCyvbETHV1[](1);
        performance[0] = RecipientFeeCyvbETHV1({
            recipient: FEE_RECEIVER,
            feeValue: CURVEYIELD_PERFORMANCE_BPS
        });
        fees.updatePerformanceFee(performance);

        // IPOR-native user fees, both PPS-accretive: the deposit fee's shares go to the withdraw manager and are burned
        // by the keeper via the factory-installed BurnRequestFeeFuse; the instant withdraw fee shares burn on exit.
        fees.setDepositFee(ONBOARDING_FEE);
        // the instant and request fees live in CyvbEthWithdrawManager_v1 (constructor)
    }

    /// @dev Switches the vault to CyvbEthWithdrawManager_v1 (IPOR maintenance-fuse port), grants it ALPHA (it runs the
    ///      strategy / burn fuses for scheduled withdrawals) and points it at those fuses.
    function _installWithdrawManager(FusionInstanceCyvbETHV1 memory instance_, CyvbEthComponentsV6 memory c_) private {
        IPlasmaVaultGovernanceCyvbETHV1 vault = IPlasmaVaultGovernanceCyvbETHV1(instance_.plasmaVault);
        address[] memory fuses = new address[](1);
        fuses[0] = c_.updateWmFuse;
        vault.addFuses(fuses);
        FuseActionCyvbETHV14[] memory actions = new FuseActionCyvbETHV14[](1);
        actions[0] = FuseActionCyvbETHV14(
            c_.updateWmFuse, abi.encodeWithSignature("enter((address))", c_.withdrawManager)
        );
        IPlasmaVaultExecCyvbETHV14(instance_.plasmaVault).execute(actions);
        IAccessManagerCyvbETHV1(instance_.accessManager).grantRole(ALPHA_ROLE, c_.withdrawManager, 0);
        CyvbEthWithdrawManager_v1(c_.withdrawManager).setFuses(
            c_.strategyFuse, c_.morphoAllocatorFuse, c_.burnFuse
        );
    }

    /// @dev If the deployer is not the owner, it gives up every role it used for setup (owner already granted).
    function _handover(FusionInstanceCyvbETHV1 memory instance_, address deployer_, address finalOwner_) private {
        if (finalOwner_ == deployer_) return;
        IAccessManagerCyvbETHV1 access = IAccessManagerCyvbETHV1(instance_.accessManager);
        access.renounceRole(WITHDRAW_MANAGER_WITHDRAW_FEE_ROLE, deployer_);
        access.renounceRole(PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, deployer_);
        access.renounceRole(CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE, deployer_);
        access.renounceRole(FUSE_MANAGER_ROLE, deployer_);
        access.renounceRole(ATOMIST_ROLE, deployer_);
        access.renounceRole(ALPHA_ROLE, deployer_);
        access.renounceRole(OWNER_ROLE, deployer_);
    }

    function _verifyExternalDependencies(address nested_) private view {
        require(address(FACTORY).code.length != 0, "factory missing");
        require(VBETH.code.length != 0, "vbETH missing");
        require(WEETH.code.length != 0, "weETH missing");
        require(ETH_USD_CHAINLINK.code.length != 0, "ETH/USD feed missing");
        require(MORPHO.code.length != 0, "Morpho missing");
        require(MORPHO_SUPPLY_FUSE.code.length != 0, "Morpho supply fuse missing");
        require(MORPHO_BALANCE_FUSE.code.length != 0, "Morpho balance fuse missing");
        require(VBUSDC.code.length != 0, "vbUSDC missing");
        require(FXUSD.code.length != 0, "fxUSD missing");
        require(FX_POOL_MANAGER.code.length != 0, "f(x) manager missing");
        require(FX_POOL.code.length != 0, "f(x) pool missing");
        require(IFxLongPoolDeployCyvbETHV6(FX_POOL).priceOracle() == FX_PRICE_ORACLE, "f(x) oracle changed");
        require(IFxLongPoolCyvbETHV9(FX_POOL).collateralToken() == WEETH, "f(x) collateral changed");
        require(IMorphoSupplyFuseCyvbEthV1(MORPHO_SUPPLY_FUSE).MARKET_ID() == MORPHO_IPOR_MARKET_ID, "Morpho market id changed");
        require(IMorphoSupplyFuseCyvbEthV1(MORPHO_SUPPLY_FUSE).MORPHO() == MORPHO, "Morpho core changed");
        (address morphoLoan,,,,) = IMorphoCoreCyvbEthV1(MORPHO).idToMarketParams(MORPHO_MARKET_ID);
        require(morphoLoan == VBETH, "Morpho loan token changed");
        require(FXBASE.code.length != 0, "fxBASE missing");
        require(FX_PRICE_ORACLE.code.length != 0, "f(x) oracle missing");
        require(CURVEYIELD_ROUTER.code.length != 0, "CurveYield router missing");
        require(nested_.code.length != 0, "cyvbUSDC missing");
        require(IERC4626InfoCyvbETHV1(nested_).asset() == VBUSDC, "cyvbUSDC wrong asset");
        require(
            keccak256(bytes(IERC4626InfoCyvbETHV1(nested_).symbol())) == keccak256(bytes("cyvbUSDC")),
            "wrong nested vault"
        );
    }

    function _verifyMiddleWay() private view {
        FeePackageCyvbETHV1[] memory packages = FACTORY.getDaoFeePackages();
        require(packages.length > MIDDLE_WAY_PACKAGE_INDEX, "Middle Way missing");
        FeePackageCyvbETHV1 memory selected = packages[MIDDLE_WAY_PACKAGE_INDEX];
        require(selected.managementFee == EXPECTED_IPOR_MANAGEMENT_BPS, "IPOR management changed");
        require(selected.performanceFee == EXPECTED_IPOR_PERFORMANCE_BPS, "IPOR performance changed");
        require(selected.feeRecipient != address(0), "IPOR recipient zero");
    }

    function _verifyRoutes() private view {
        ICurveYieldRouterInfoCyvbETHV1 router = ICurveYieldRouterInfoCyvbETHV1(CURVEYIELD_ROUTER);
        require(router.routeFor(FXUSD, VBUSDC).length != 0, "fxUSD->vbUSDC missing");
        require(router.routeFor(VBUSDC, FXUSD).length != 0, "vbUSDC->fxUSD missing");
        require(router.routeFor(VBUSDC, VBETH).length != 0, "vbUSDC->vbETH missing");
        require(router.routeFor(VBETH, WEETH).length != 0, "vbETH->weETH missing");
        require(router.routeFor(WEETH, VBETH).length != 0, "weETH->vbETH missing");
    }

    function _verifyDeployment(
        FusionInstanceCyvbETHV1 memory instance_,
        address nested_,
        address keeper_,
        address finalOwner_,
        CyvbEthComponentsV6 memory components_
    ) private view {
        require(instance_.underlyingToken == VBETH, "underlying mismatch");
        require(keccak256(bytes(instance_.assetName)) == keccak256(bytes("CurveYield vbETH")), "name mismatch");
        require(keccak256(bytes(instance_.assetSymbol)) == keccak256(bytes("cyvbETH")), "symbol mismatch");

        IAccessManagerCyvbETHV1 access = IAccessManagerCyvbETHV1(instance_.accessManager);
        (bool alpha,) = access.hasRole(ALPHA_ROLE, keeper_);
        require(alpha, "keeper lacks ALPHA");
        (bool isOwner,) = access.hasRole(OWNER_ROLE, finalOwner_);
        require(isOwner, "final owner lacks OWNER");

        IPlasmaVaultGovernanceCyvbETHV1 vault =
            IPlasmaVaultGovernanceCyvbETHV1(instance_.plasmaVault);

        address[] memory fuses = vault.getFuses();
        require(_containsAddress(fuses, components_.strategyFuse), "strategy fuse missing");
        require(_containsAddress(fuses, components_.morphoAllocatorFuse), "Morpho allocator missing");
        require(_containsAddress(fuses, components_.burnFuse), "burn fuse missing");
        require(
            vault.isBalanceFuseSupported(STRATEGY_MARKET_ID, ERC20_BALANCE_FUSE),
            "balance fuse mismatch"
        );
        require(
            vault.isBalanceFuseSupported(MORPHO_IPOR_MARKET_ID, MORPHO_BALANCE_FUSE),
            "Morpho balance fuse mismatch"
        );

        address[] memory instant = vault.getInstantWithdrawalFuses();
        require(
            instant.length == 2 &&
            instant[0] == components_.morphoAllocatorFuse &&
            instant[1] == components_.strategyFuse,
            "instant fuse order mismatch"
        );

        require(
            IPriceManagerCyvbETHV1(instance_.priceManager).getSourceOfAssetPrice(VBETH) == components_.priceFeed,
            "price source mismatch"
        );

        IFeeManagerCyvbETHV1 fees = IFeeManagerCyvbETHV1(instance_.feeManager);
        require(fees.getTotalManagementFee() == EXPECTED_TOTAL_MANAGEMENT_BPS, "management total mismatch");
        require(fees.getTotalPerformanceFee() == EXPECTED_TOTAL_PERFORMANCE_BPS, "performance total mismatch");
        require(fees.getDepositFee() == ONBOARDING_FEE, "onboarding fee mismatch");
        _verifyWithdrawManager(instance_, components_);

        RecipientFeeCyvbETHV1[] memory management = fees.getManagementFeeRecipients();
        RecipientFeeCyvbETHV1[] memory performance = fees.getPerformanceFeeRecipients();
        require(
            management.length == 1 &&
            management[0].recipient == FEE_RECEIVER &&
            management[0].feeValue == CURVEYIELD_MANAGEMENT_BPS,
            "management receiver mismatch"
        );
        require(
            performance.length == 1 &&
            performance[0].recipient == FEE_RECEIVER &&
            performance[0].feeValue == CURVEYIELD_PERFORMANCE_BPS,
            "performance receiver mismatch"
        );

        _verifyStrategy(instance_, nested_, components_);

        _verifyRoutes();
    }
    function _verifyStrategy(
        FusionInstanceCyvbETHV1 memory instance_,
        address nested_,
        CyvbEthComponentsV6 memory components_
    ) private view {
        FxMintCyvbEthFuse_v1 fuse = FxMintCyvbEthFuse_v1(components_.strategyFuse);
        require(fuse.VAULT() == instance_.plasmaVault, "fuse vault mismatch");
        CyvbEthLtvPolicy memory policy = fuse.getLtvPolicy();
        require(policy.targetLtvBps == 5000, "target LTV mismatch");
        require(policy.highTriggerBps == 6000, "high trigger mismatch");
        require(policy.highResetBps == 5800, "high reset mismatch");
        require(policy.lowTriggerBps == 4500, "low trigger mismatch");
        require(policy.lowResetBps == 5000, "low reset mismatch");
        require(policy.earnBps == EARN_BPS, "earn split mismatch");

        require(FxMintCyvbEthFuse_v1(components_.strategyFuse).CYVBUSDC() == nested_, "nested vault fuse mismatch");
        require(FxMintCyvbEthFuse_v1(components_.strategyFuse).VBETH() == VBETH, "vbETH binding mismatch");
        require(FxMintCyvbEthFuse_v1(components_.strategyFuse).WEETH() == WEETH, "weETH binding mismatch");
        require(
            CyvbEthMorphoAllocatorFuse_v1(components_.morphoAllocatorFuse).MORPHO_MARKET_ID() == MORPHO_MARKET_ID,
            "Morpho allocator market mismatch"
        );
        require(
            IPriceManagerCyvbETHV1(instance_.priceManager).getSourceOfAssetPrice(components_.collateralIndicator)
                == components_.collateralPriceFeed,
            "collateral indicator price"
        );
        require(
            IPriceManagerCyvbETHV1(instance_.priceManager).getSourceOfAssetPrice(components_.debtIndicator)
                == components_.oneWeiFeed,
            "debt indicator price"
        );
    }

    function _verifyWithdrawManager(
        FusionInstanceCyvbETHV1 memory instance_,
        CyvbEthComponentsV6 memory components_
    ) private view {
        IAccessManagerCyvbETHV1 access = IAccessManagerCyvbETHV1(instance_.accessManager);
        CyvbEthWithdrawManager_v1 wm = CyvbEthWithdrawManager_v1(components_.withdrawManager);
        require(
            address(uint160(uint256(vm.load(instance_.plasmaVault, bytes32(0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100)))))
                == components_.withdrawManager,
            "vault withdraw manager not switched"
        );
        require(wm.getWithdrawFee() == INSTANT_WITHDRAW_FEE, "instant withdraw fee mismatch");
        require(wm.getRequestFee() == REQUEST_FEE, "request fee mismatch");
        require(wm.getWithdrawWindow() == WITHDRAW_WINDOW, "withdraw window mismatch");
        require(
            wm.strategyFuse() == components_.strategyFuse &&
            wm.morphoFuse() == components_.morphoAllocatorFuse &&
            wm.burnFuse() == components_.burnFuse,
            "wm fuses"
        );
        require(!wm.scheduledWithdrawalsEnabled(), "scheduled withdrawals must start disabled (earn pool off)");
        (bool wmAlpha,) = access.hasRole(ALPHA_ROLE, components_.withdrawManager);
        require(wmAlpha, "withdraw manager lacks ALPHA");
    }

    function _containsAddress(address[] memory values_, address target_) private pure returns (bool) {
        for (uint256 i; i < values_.length; ++i) {
            if (values_[i] == target_) return true;
        }
        return false;
    }

}