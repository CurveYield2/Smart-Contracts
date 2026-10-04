// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";

import "../contracts/FxMintVbWbtcPriceFeed_v1.sol";
import "../contracts/FxMintCyvbWbtcFuse_v12.sol";
import "../contracts/FxMintCyvbWbtcBalanceFuse_v5.sol";
import "../contracts/IporBurnRequestFeeFuse_v1.sol";
import "../contracts/IporUpdateWithdrawManagerFuse_v1.sol";
import "../contracts/CyvbWbtcWithdrawManager_v1.sol";

struct FeePackageCyvbWBTCV1 {
    uint256 managementFee;
    uint256 performanceFee;
    address feeRecipient;
}

struct FusionInstanceCyvbWBTCV1 {
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

struct RecipientFeeCyvbWBTCV1 {
    address recipient;
    uint256 feeValue;
}

struct InstantWithdrawalFuseParamsCyvbWBTCV1 {
    address fuse;
    bytes32[] params;
}

interface IFusionFactoryCyvbWBTCV1 {
    function clone(
        string calldata assetName_,
        string calldata assetSymbol_,
        address underlyingToken_,
        uint256 redemptionDelayInSeconds_,
        address owner_,
        uint256 daoFeePackageIndex_
    ) external returns (FusionInstanceCyvbWBTCV1 memory);

    function getDaoFeePackages() external view returns (FeePackageCyvbWBTCV1[] memory);
}

interface IAccessManagerCyvbWBTCV1 {
    function grantRole(uint64 roleId_, address account_, uint32 executionDelay_) external;
    function renounceRole(uint64 roleId_, address callerConfirmation_) external;
    function hasRole(uint64 roleId_, address account_) external view returns (bool isMember, uint32 executionDelay);
}

struct FuseActionCyvbWBTCV14 {
    address fuse;
    bytes data;
}

interface IPlasmaVaultExecCyvbWBTCV14 {
    function execute(FuseActionCyvbWBTCV14[] calldata calls) external;
}

interface IPlasmaVaultGovernanceCyvbWBTCV1 {
    function addFuses(address[] calldata fuses_) external;
    function addBalanceFuse(uint256 marketId_, address fuse_) external;
    function configureInstantWithdrawalFuses(InstantWithdrawalFuseParamsCyvbWBTCV1[] calldata fuses_) external;
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

interface IPriceManagerCyvbWBTCV1 {
    function setAssetsPriceSources(address[] calldata assets_, address[] calldata sources_) external;
    function getSourceOfAssetPrice(address asset_) external view returns (address);
}

interface IFeeManagerCyvbWBTCV1 {
    function updateManagementFee(RecipientFeeCyvbWBTCV1[] calldata recipientFees) external;
    function updatePerformanceFee(RecipientFeeCyvbWBTCV1[] calldata recipientFees) external;
    function setDepositFee(uint256 depositFee_) external;
    function getDepositFee() external view returns (uint256);
    function getTotalManagementFee() external view returns (uint256);
    function getTotalPerformanceFee() external view returns (uint256);
    function getManagementFeeRecipients() external view returns (RecipientFeeCyvbWBTCV1[] memory);
    function getPerformanceFeeRecipients() external view returns (RecipientFeeCyvbWBTCV1[] memory);
}

interface IERC4626InfoCyvbWBTCV1 {
    function asset() external view returns (address);
    function symbol() external view returns (string memory);
}

interface IWithdrawManagerInfoCyvbWBTCV2 {
    function getWithdrawFee() external view returns (uint256);
    function updateWithdrawFee(uint256 fee_) external;
}

interface IFxLongPoolDeployCyvbWBTCV6 {
    function priceOracle() external view returns (address);
}

interface ICurveYieldRouterInfoCyvbWBTCV1 {
    function routeFor(address tokenIn, address tokenOut) external view returns (bytes memory);
}

struct CyvbWbtcComponentsV6 {
    address priceFeed;
    address burnFuse;
    address updateWmFuse;
    address withdrawManager;
    address strategyFuse;
    address balanceFuse;
}

/// @title DeployCyvbWBTC_v14
/// @notice Deploy and configure CurveYield vbWBTC / cyvbWBTC through the official IPOR Fusion factory on Katana.
/// @dev v14 (EARN_POOL_SPEC_v1): borrowed fxUSD split EARN_BPS fxBASE earn pool (staked in its gauge) / rest cyvbUSDC; EARN_BPS = 0 until the gauge is funded
///      (FxMintCyvbWbtcFuse_v12); scheduled withdrawals through CyvbWbtcWithdrawManager_v1 (installed with
///      IporUpdateWithdrawManagerFuse_v1, granted ALPHA): the request starts the fxBASE redeem itself, a permissionless
///      finish() releases after the 1 h cooldown. Fees: 0.75% onboarding, 1.00% instant, 0.50% scheduled request.
///      v13: no gateway / pre-hooks / config contract. Both user fees are IPOR-native: the 0.55% onboarding fee is
///      FeeManager's deposit fee (shares minted to the withdraw manager, burned for holders by the factory-installed
///      BurnRequestFeeFuse - keeper job; the factory-installed copy reads a stale slot, so v13 adds
///      IporBurnRequestFeeFuse_v1, a port of IPOR's corrected upstream fuse), the 0.60% instant fee is WithdrawManager's withdraw fee (burned on exit).
///      One custom fuse (FxMintCyvbWbtcFuse_v12, LTV policy folded in) + its balance fuse + the f(x) price feed.
contract DeployCyvbWBTC_v14 is Script {
    uint256 internal constant KATANA_CHAIN_ID = 747474;
    uint256 internal constant STRATEGY_MARKET_ID = 7; // IporFusionMarkets.ERC20_VAULT_BALANCE

    IFusionFactoryCyvbWBTCV1 internal constant FACTORY =
        IFusionFactoryCyvbWBTCV1(0xc29b8D591d6a3f109Ca7ba384F2e00162866D37B);

    address internal constant FEE_RECEIVER = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49; // cyavKAT fee Safe
    /// @dev Owner: the same owner as the cyavKAT vault (override with FINAL_OWNER)
    address internal constant VAULT_OWNER = 0x11b78837cadC8E894F1c6e13fA9f3A085a75FA35;
    uint256 internal constant ONBOARDING_FEE = 0.0075e18; // FeeManager deposit fee, WAD (0.75%: covers the ~0.67% full-swap deploy cost)
    uint256 internal constant REQUEST_FEE = 0.005e18; // scheduled-withdrawal request fee, WAD (0.50%)
    uint256 internal constant WITHDRAW_WINDOW = 7 days; // claim window after a scheduled request
    address internal constant EARN_GAUGE = 0x76A84525c5f61136Cf562dC1bD5aBB19FB8B53fC; // fxBASE gauge (weETH)
    uint16 internal constant EARN_BPS = 0; // earn pool OFF until the fxBASE gauge is funded (then 6_000 = 60%: new fuse version)
    uint256 internal constant INSTANT_WITHDRAW_FEE = 0.01e18; // withdraw manager instant fee, WAD (1.00%)

    address internal constant VBWBTC = 0x0913DA6Da4b42f538B445599b46Bb4622342Cf52;
    address internal constant VBUSDC = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36;
    address internal constant FXUSD = 0x4c03ff0f44A55e7098a09016E02a01d3cdC2FDF9;

    address internal constant FX_POOL_MANAGER = 0x27b3eE81DF2Dd7356D5ac282e2416991A616f96a;
    address internal constant FX_POOL = 0x49150F136C5a5Af361ECb06cB38A6205461E33CD;
    address internal constant FXBASE = 0xdE2E0736Ee813C425b0eE1a6e0627233B3B1EeF8;
    address internal constant FX_PRICE_ORACLE = 0x8244bDfb7E7fA52E05b725e6D5fbc2bcAEAfC52B;

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


    event CyvbWbtcDeployed(
        address indexed vault,
        address indexed strategyFuse,
        address indexed balanceFuse,
        address priceFeed,
        address keeper,
        address owner,
        address nestedCyvbUsdc
    );

    function run() external returns (FusionInstanceCyvbWBTCV1 memory instance) {
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
            "CurveYield vbWBTC",
            "cyvbWBTC",
            VBWBTC,
            0,
            deployer,
            MIDDLE_WAY_PACKAGE_INDEX
        );

        CyvbWbtcComponentsV6 memory components =
            _deployComponents(instance.plasmaVault, nestedCyvbUsdc);

        _configureRoles(instance, deployer, keeper, finalOwner);
        _configurePrice(instance, components.priceFeed);
        _configureStrategy(instance, components.strategyFuse, components.balanceFuse, components.burnFuse);
        _installWithdrawManager(instance, components);
        _configureFees(instance);

        IPlasmaVaultGovernanceCyvbWBTCV1(instance.plasmaVault).convertToPublicVault();
        IPlasmaVaultGovernanceCyvbWBTCV1(instance.plasmaVault).enableTransferShares();

        _handover(instance, deployer, finalOwner);

        vm.stopBroadcast();

        _verifyDeployment(instance, nestedCyvbUsdc, keeper, finalOwner, components);

        emit CyvbWbtcDeployed(
            instance.plasmaVault,
            components.strategyFuse,
            components.balanceFuse,
            components.priceFeed,
            keeper,
            finalOwner,
            nestedCyvbUsdc
        );
    }

    function _deployComponents(
        address vault_,
        address nestedCyvbUsdc_
    ) private returns (CyvbWbtcComponentsV6 memory components) {
        components.priceFeed = address(new FxMintVbWbtcPriceFeed_v1(FX_PRICE_ORACLE));
        // IporFusionMarkets.ZERO_BALANCE_MARKET, as the factory's own burn fuse
        components.burnFuse = address(new IporBurnRequestFeeFuse_v1(type(uint256).max));
        // default policy: target 50%, high 60% -> 58%, low 45% -> 50% (validated in the fuse constructor)
        components.strategyFuse = address(new FxMintCyvbWbtcFuse_v12(
            STRATEGY_MARKET_ID,
            vault_,
            CyvbWbtcLtvPolicy({
                targetLtvBps: 5_000, highTriggerBps: 6_000, highResetBps: 5_800, lowTriggerBps: 4_500, lowResetBps: 5_000,
                earnBps: EARN_BPS
            }),
            CyvbWbtcFuseAddresses({
                poolManager: FX_POOL_MANAGER, fxPool: FX_POOL, fxBase: FXBASE, earnGauge: EARN_GAUGE, fxUsd: FXUSD,
                vbWbtc: VBWBTC, vbUsdc: VBUSDC, cyvbUsdc: nestedCyvbUsdc_, router: CURVEYIELD_ROUTER
            })
        ));
        components.balanceFuse = address(new FxMintCyvbWbtcBalanceFuse_v5(
            STRATEGY_MARKET_ID,
            FX_POOL,
            FXUSD,
            VBUSDC,
            nestedCyvbUsdc_,
            FXBASE,
            EARN_GAUGE
        ));
        components.updateWmFuse = address(new IporUpdateWithdrawManagerFuse_v1(type(uint256).max));
        components.withdrawManager =
            address(new CyvbWbtcWithdrawManager_v1(vault_, WITHDRAW_WINDOW, INSTANT_WITHDRAW_FEE, REQUEST_FEE));
    }

    function _configureRoles(
        FusionInstanceCyvbWBTCV1 memory instance_,
        address deployer_,
        address keeper_,
        address finalOwner_
    ) private {
        IAccessManagerCyvbWBTCV1 access = IAccessManagerCyvbWBTCV1(instance_.accessManager);

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

    function _configurePrice(FusionInstanceCyvbWBTCV1 memory instance_, address priceFeed_) private {
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = VBWBTC;
        sources[0] = priceFeed_;
        IPriceManagerCyvbWBTCV1(instance_.priceManager).setAssetsPriceSources(assets, sources);
    }

    function _configureStrategy(
        FusionInstanceCyvbWBTCV1 memory instance_,
        address strategyFuse_,
        address balanceFuse_,
        address burnFuse_
    ) private {
        IPlasmaVaultGovernanceCyvbWBTCV1 vault =
            IPlasmaVaultGovernanceCyvbWBTCV1(instance_.plasmaVault);

        address[] memory fuses = new address[](2);
        fuses[0] = strategyFuse_;
        fuses[1] = burnFuse_;
        vault.addFuses(fuses);
        vault.addBalanceFuse(STRATEGY_MARKET_ID, balanceFuse_);

        InstantWithdrawalFuseParamsCyvbWBTCV1[] memory instant =
            new InstantWithdrawalFuseParamsCyvbWBTCV1[](1);
        bytes32[] memory params = new bytes32[](1);
        params[0] = bytes32(0); // PlasmaVault replaces params[0] with required vbWBTC amount.
        instant[0] = InstantWithdrawalFuseParamsCyvbWBTCV1({fuse: strategyFuse_, params: params});
        vault.configureInstantWithdrawalFuses(instant);
    }

    function _configureFees(FusionInstanceCyvbWBTCV1 memory instance_) private {
        IFeeManagerCyvbWBTCV1 fees = IFeeManagerCyvbWBTCV1(instance_.feeManager);

        RecipientFeeCyvbWBTCV1[] memory management = new RecipientFeeCyvbWBTCV1[](1);
        management[0] = RecipientFeeCyvbWBTCV1({
            recipient: FEE_RECEIVER,
            feeValue: CURVEYIELD_MANAGEMENT_BPS
        });
        fees.updateManagementFee(management);

        RecipientFeeCyvbWBTCV1[] memory performance = new RecipientFeeCyvbWBTCV1[](1);
        performance[0] = RecipientFeeCyvbWBTCV1({
            recipient: FEE_RECEIVER,
            feeValue: CURVEYIELD_PERFORMANCE_BPS
        });
        fees.updatePerformanceFee(performance);

        // IPOR-native user fees, both PPS-accretive: the deposit fee's shares go to the withdraw manager and are burned
        // by the keeper via the factory-installed BurnRequestFeeFuse; the instant withdraw fee shares burn on exit.
        fees.setDepositFee(ONBOARDING_FEE);
        // the instant and request fees live in CyvbWbtcWithdrawManager_v1 (constructor)
    }

    /// @dev Switches the vault to CyvbWbtcWithdrawManager_v1 (IPOR maintenance-fuse port), grants it ALPHA (it runs the
    ///      strategy / burn fuses for scheduled withdrawals) and points it at those fuses.
    function _installWithdrawManager(FusionInstanceCyvbWBTCV1 memory instance_, CyvbWbtcComponentsV6 memory c_) private {
        IPlasmaVaultGovernanceCyvbWBTCV1 vault = IPlasmaVaultGovernanceCyvbWBTCV1(instance_.plasmaVault);
        address[] memory fuses = new address[](1);
        fuses[0] = c_.updateWmFuse;
        vault.addFuses(fuses);
        FuseActionCyvbWBTCV14[] memory actions = new FuseActionCyvbWBTCV14[](1);
        actions[0] = FuseActionCyvbWBTCV14(
            c_.updateWmFuse, abi.encodeWithSignature("enter((address))", c_.withdrawManager)
        );
        IPlasmaVaultExecCyvbWBTCV14(instance_.plasmaVault).execute(actions);
        IAccessManagerCyvbWBTCV1(instance_.accessManager).grantRole(ALPHA_ROLE, c_.withdrawManager, 0);
        CyvbWbtcWithdrawManager_v1(c_.withdrawManager).setFuses(c_.strategyFuse, c_.burnFuse);
    }

    /// @dev If the deployer is not the owner, it gives up every role it used for setup (owner already granted).
    function _handover(FusionInstanceCyvbWBTCV1 memory instance_, address deployer_, address finalOwner_) private {
        if (finalOwner_ == deployer_) return;
        IAccessManagerCyvbWBTCV1 access = IAccessManagerCyvbWBTCV1(instance_.accessManager);
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
        require(VBWBTC.code.length != 0, "vbWBTC missing");
        require(VBUSDC.code.length != 0, "vbUSDC missing");
        require(FXUSD.code.length != 0, "fxUSD missing");
        require(FX_POOL_MANAGER.code.length != 0, "f(x) manager missing");
        require(FX_POOL.code.length != 0, "f(x) pool missing");
        require(IFxLongPoolDeployCyvbWBTCV6(FX_POOL).priceOracle() == FX_PRICE_ORACLE, "f(x) oracle changed");
        require(FXBASE.code.length != 0, "fxBASE missing");
        require(FX_PRICE_ORACLE.code.length != 0, "f(x) oracle missing");
        require(CURVEYIELD_ROUTER.code.length != 0, "CurveYield router missing");
        require(nested_.code.length != 0, "cyvbUSDC missing");
        require(IERC4626InfoCyvbWBTCV1(nested_).asset() == VBUSDC, "cyvbUSDC wrong asset");
        require(
            keccak256(bytes(IERC4626InfoCyvbWBTCV1(nested_).symbol())) == keccak256(bytes("cyvbUSDC")),
            "wrong nested vault"
        );
    }

    function _verifyMiddleWay() private view {
        FeePackageCyvbWBTCV1[] memory packages = FACTORY.getDaoFeePackages();
        require(packages.length > MIDDLE_WAY_PACKAGE_INDEX, "Middle Way missing");
        FeePackageCyvbWBTCV1 memory selected = packages[MIDDLE_WAY_PACKAGE_INDEX];
        require(selected.managementFee == EXPECTED_IPOR_MANAGEMENT_BPS, "IPOR management changed");
        require(selected.performanceFee == EXPECTED_IPOR_PERFORMANCE_BPS, "IPOR performance changed");
        require(selected.feeRecipient != address(0), "IPOR recipient zero");
    }

    function _verifyRoutes() private view {
        ICurveYieldRouterInfoCyvbWBTCV1 router = ICurveYieldRouterInfoCyvbWBTCV1(CURVEYIELD_ROUTER);
        require(router.routeFor(FXUSD, VBUSDC).length != 0, "fxUSD->vbUSDC missing");
        require(router.routeFor(VBUSDC, FXUSD).length != 0, "vbUSDC->fxUSD missing");
        require(router.routeFor(VBUSDC, VBWBTC).length != 0, "vbUSDC->vbWBTC missing");
    }

    function _verifyDeployment(
        FusionInstanceCyvbWBTCV1 memory instance_,
        address nested_,
        address keeper_,
        address finalOwner_,
        CyvbWbtcComponentsV6 memory components_
    ) private view {
        require(instance_.underlyingToken == VBWBTC, "underlying mismatch");
        require(keccak256(bytes(instance_.assetName)) == keccak256(bytes("CurveYield vbWBTC")), "name mismatch");
        require(keccak256(bytes(instance_.assetSymbol)) == keccak256(bytes("cyvbWBTC")), "symbol mismatch");

        IAccessManagerCyvbWBTCV1 access = IAccessManagerCyvbWBTCV1(instance_.accessManager);
        (bool alpha,) = access.hasRole(ALPHA_ROLE, keeper_);
        require(alpha, "keeper lacks ALPHA");
        (bool isOwner,) = access.hasRole(OWNER_ROLE, finalOwner_);
        require(isOwner, "final owner lacks OWNER");

        IPlasmaVaultGovernanceCyvbWBTCV1 vault =
            IPlasmaVaultGovernanceCyvbWBTCV1(instance_.plasmaVault);

        address[] memory fuses = vault.getFuses();
        require(_containsAddress(fuses, components_.strategyFuse), "strategy fuse missing");
        require(_containsAddress(fuses, components_.burnFuse), "burn fuse missing");
        require(
            vault.isBalanceFuseSupported(STRATEGY_MARKET_ID, components_.balanceFuse),
            "balance fuse mismatch"
        );

        address[] memory instant = vault.getInstantWithdrawalFuses();
        require(instant.length == 1 && instant[0] == components_.strategyFuse, "instant fuse mismatch");

        require(
            IPriceManagerCyvbWBTCV1(instance_.priceManager).getSourceOfAssetPrice(VBWBTC) == components_.priceFeed,
            "price source mismatch"
        );

        IFeeManagerCyvbWBTCV1 fees = IFeeManagerCyvbWBTCV1(instance_.feeManager);
        require(fees.getTotalManagementFee() == EXPECTED_TOTAL_MANAGEMENT_BPS, "management total mismatch");
        require(fees.getTotalPerformanceFee() == EXPECTED_TOTAL_PERFORMANCE_BPS, "performance total mismatch");
        require(fees.getDepositFee() == ONBOARDING_FEE, "onboarding fee mismatch");
        _verifyWithdrawManager(instance_, components_);

        RecipientFeeCyvbWBTCV1[] memory management = fees.getManagementFeeRecipients();
        RecipientFeeCyvbWBTCV1[] memory performance = fees.getPerformanceFeeRecipients();
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

        FxMintCyvbWbtcFuse_v12 fuse = FxMintCyvbWbtcFuse_v12(components_.strategyFuse);
        require(fuse.VAULT() == instance_.plasmaVault, "fuse vault mismatch");
        CyvbWbtcLtvPolicy memory policy = fuse.getLtvPolicy();
        require(policy.targetLtvBps == 5000, "target LTV mismatch");
        require(policy.highTriggerBps == 6000, "high trigger mismatch");
        require(policy.highResetBps == 5800, "high reset mismatch");
        require(policy.lowTriggerBps == 4500, "low trigger mismatch");
        require(policy.lowResetBps == 5000, "low reset mismatch");
        require(policy.earnBps == EARN_BPS, "earn split mismatch");

        require(FxMintCyvbWbtcFuse_v12(components_.strategyFuse).CYVBUSDC() == nested_, "nested vault fuse mismatch");
        require(FxMintCyvbWbtcBalanceFuse_v5(components_.balanceFuse).CYVBUSDC() == nested_, "nested balance mismatch");

        _verifyRoutes();
    }
    function _verifyWithdrawManager(
        FusionInstanceCyvbWBTCV1 memory instance_,
        CyvbWbtcComponentsV6 memory components_
    ) private view {
        IAccessManagerCyvbWBTCV1 access = IAccessManagerCyvbWBTCV1(instance_.accessManager);
        CyvbWbtcWithdrawManager_v1 wm = CyvbWbtcWithdrawManager_v1(components_.withdrawManager);
        require(
            address(uint160(uint256(vm.load(instance_.plasmaVault, bytes32(0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100)))))
                == components_.withdrawManager,
            "vault withdraw manager not switched"
        );
        require(wm.getWithdrawFee() == INSTANT_WITHDRAW_FEE, "instant withdraw fee mismatch");
        require(wm.getRequestFee() == REQUEST_FEE, "request fee mismatch");
        require(wm.getWithdrawWindow() == WITHDRAW_WINDOW, "withdraw window mismatch");
        require(wm.strategyFuse() == components_.strategyFuse && wm.burnFuse() == components_.burnFuse, "wm fuses");
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