// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";

import "../contracts/CyvbWbtcLtvConfig_v1.sol";
import "../contracts/CyvbWbtcGateway_v1.sol";
import "../contracts/CyvbWbtcInstantExitGatePreHook_v1.sol";
import "../contracts/FxMintVbWbtcPriceFeed_v1.sol";
import "../contracts/FxMintCyvbWbtcFuse_v1.sol";
import "../contracts/FxMintCyvbWbtcBalanceFuse_v1.sol";

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
    function hasRole(uint64 roleId_, address account_) external view returns (bool isMember, uint32 executionDelay);
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
    function enableTransferShares() external;

    function getFuses() external view returns (address[] memory);
    function getInstantWithdrawalFuses() external view returns (address[] memory);
    function getBalanceFuse(uint256 marketId_) external view returns (address);
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
    function getTotalManagementFee() external view returns (uint256);
    function getTotalPerformanceFee() external view returns (uint256);
    function getManagementFeeRecipients() external view returns (RecipientFeeCyvbWBTCV1[] memory);
    function getPerformanceFeeRecipients() external view returns (RecipientFeeCyvbWBTCV1[] memory);
}

interface IERC4626InfoCyvbWBTCV1 {
    function asset() external view returns (address);
    function symbol() external view returns (string memory);
}

interface ICurveYieldRouterInfoCyvbWBTCV1 {
    function routeFor(address tokenIn, address tokenOut) external view returns (bytes memory);
}

/// @title DeployCyvbWBTC_v1
/// @notice Deploy and configure CurveYield vbWBTC / cyvbWBTC through the official IPOR Fusion factory on Katana.
contract DeployCyvbWBTC_v1 is Script {
    uint256 internal constant KATANA_CHAIN_ID = 747474;
    uint256 internal constant STRATEGY_MARKET_ID = 7001;

    IFusionFactoryCyvbWBTCV1 internal constant FACTORY =
        IFusionFactoryCyvbWBTCV1(0xc29b8D591d6a3f109Ca7ba384F2e00162866D37B);

    address internal constant FEE_RECEIVER = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;

    address internal constant VBWBTC = 0x0913DA6Da4b42f538B445599b46Bb4622342Cf52;
    address internal constant VBUSDC = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36;
    address internal constant FXUSD = 0x1364b238C668A2dec1294174e4798E8c09979f86;

    address internal constant FX_POOL_MANAGER = 0xFae375C9eA6636c40deB92DD91B7dbbF51BD3C68;
    address internal constant FX_POOL = 0xe32b9b4c8f776687ec54b4b6b62dbd9ce5fd4b99;
    address internal constant FXBASE = 0x6cf6757725886716Bc3c6A4bB93d02F1d1E3e7Dd;
    address internal constant FX_PRICE_ORACLE = 0xeDA71e4ab642e97FBAA04beB3a7c4Bd6139a23C5;

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
    uint64 internal constant PRE_HOOKS_MANAGER_ROLE = 301;
    uint64 internal constant WHITELIST_ROLE = 800;
    uint64 internal constant CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE = 900;
    uint64 internal constant UPDATE_MARKETS_BALANCES_ROLE = 1000;
    uint64 internal constant PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE = 1200;

    bytes4 internal constant WITHDRAW_SELECTOR = bytes4(keccak256("withdraw(uint256,address,address)"));
    bytes4 internal constant REDEEM_SELECTOR = bytes4(keccak256("redeem(uint256,address,address)"));

    event CyvbWbtcDeployed(
        address indexed vault,
        address indexed gateway,
        address indexed strategyFuse,
        address balanceFuse,
        address ltvConfig,
        address priceFeed,
        address preHook,
        address keeper,
        address nestedCyvbUsdc
    );

    function run() external returns (FusionInstanceCyvbWBTCV1 memory instance) {
        require(block.chainid == KATANA_CHAIN_ID, "not Katana");

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address keeper = vm.envOr("KEEPER", deployer);
        address finalOwner = vm.envOr("FINAL_OWNER", deployer);
        address nestedCyvbUsdc = vm.envAddress("CURVEYIELD_USDC_VAULT");

        require(keeper != address(0) && finalOwner != address(0), "zero role address");
        _verifyExternalDependencies(nestedCyvbUsdc);
        _verifyMiddleWay();
        _verifyRoutes();

        vm.startBroadcast(privateKey);

        // Leave factory vault private: deposits/mints remain WHITELIST_ROLE-gated.
        // User deposits are routed through CyvbWbtcGateway_v1 so onboarding fee cannot be bypassed.
        instance = FACTORY.clone(
            "CurveYield vbWBTC",
            "cyvbWBTC",
            VBWBTC,
            0,
            deployer,
            MIDDLE_WAY_PACKAGE_INDEX
        );

        CyvbWbtcLtvConfig_v1 ltvConfig = new CyvbWbtcLtvConfig_v1(deployer);
        ltvConfig.bindVault(instance.plasmaVault);

        CyvbWbtcGateway_v1 gateway =
            new CyvbWbtcGateway_v1(instance.plasmaVault, VBWBTC, FEE_RECEIVER);

        CyvbWbtcInstantExitGatePreHook_v1 preHook =
            new CyvbWbtcInstantExitGatePreHook_v1(instance.plasmaVault, address(gateway));

        FxMintVbWbtcPriceFeed_v1 priceFeed =
            new FxMintVbWbtcPriceFeed_v1(FX_PRICE_ORACLE);

        FxMintCyvbWbtcFuse_v1 strategyFuse = new FxMintCyvbWbtcFuse_v1(
            address(ltvConfig),
            FX_POOL_MANAGER,
            FX_POOL,
            FXBASE,
            FXUSD,
            VBWBTC,
            VBUSDC,
            nestedCyvbUsdc,
            CURVEYIELD_ROUTER
        );

        FxMintCyvbWbtcBalanceFuse_v1 balanceFuse = new FxMintCyvbWbtcBalanceFuse_v1(
            address(ltvConfig),
            FX_POOL,
            FXUSD,
            VBUSDC,
            nestedCyvbUsdc
        );

        _configureRoles(instance, deployer, keeper, finalOwner, address(gateway));
        _configurePrice(instance, address(priceFeed));
        _configureStrategy(instance, address(strategyFuse), address(balanceFuse));
        _configureExitGate(instance, address(preHook));
        _configureFees(instance);

        // Shares are transferable, while deposits remain gateway-whitelisted.
        IPlasmaVaultGovernanceCyvbWBTCV1(instance.plasmaVault).enableTransferShares();

        if (finalOwner != deployer) {
            ltvConfig.transferOwnership(finalOwner);
        }

        vm.stopBroadcast();

        _verifyDeployment(
            instance,
            nestedCyvbUsdc,
            keeper,
            address(gateway),
            address(strategyFuse),
            address(balanceFuse),
            address(ltvConfig),
            address(priceFeed),
            address(preHook)
        );

        emit CyvbWbtcDeployed(
            instance.plasmaVault,
            address(gateway),
            address(strategyFuse),
            address(balanceFuse),
            address(ltvConfig),
            address(priceFeed),
            address(preHook),
            keeper,
            nestedCyvbUsdc
        );
    }

    function _configureRoles(
        FusionInstanceCyvbWBTCV1 memory instance_,
        address deployer_,
        address keeper_,
        address finalOwner_,
        address gateway_
    ) private {
        IAccessManagerCyvbWBTCV1 access = IAccessManagerCyvbWBTCV1(instance_.accessManager);

        access.grantRole(ATOMIST_ROLE, deployer_, 0);
        access.grantRole(FUSE_MANAGER_ROLE, deployer_, 0);
        access.grantRole(PRE_HOOKS_MANAGER_ROLE, deployer_, 0);
        access.grantRole(CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE, deployer_, 0);
        access.grantRole(PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, deployer_, 0);

        access.grantRole(ALPHA_ROLE, keeper_, 0);
        access.grantRole(UPDATE_MARKETS_BALANCES_ROLE, keeper_, 0);

        // Only the onboarding gateway is whitelisted for deposit/mint paths.
        access.grantRole(WHITELIST_ROLE, gateway_, 0);

        if (finalOwner_ != deployer_) {
            access.grantRole(OWNER_ROLE, finalOwner_, 0);
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
        address balanceFuse_
    ) private {
        IPlasmaVaultGovernanceCyvbWBTCV1 vault =
            IPlasmaVaultGovernanceCyvbWBTCV1(instance_.plasmaVault);

        address[] memory fuses = new address[](1);
        fuses[0] = strategyFuse_;
        vault.addFuses(fuses);
        vault.addBalanceFuse(STRATEGY_MARKET_ID, balanceFuse_);

        InstantWithdrawalFuseParamsCyvbWBTCV1[] memory instant =
            new InstantWithdrawalFuseParamsCyvbWBTCV1[](1);
        bytes32[] memory params = new bytes32[](1);
        params[0] = bytes32(0); // PlasmaVault replaces params[0] with required vbWBTC amount.
        instant[0] = InstantWithdrawalFuseParamsCyvbWBTCV1({fuse: strategyFuse_, params: params});
        vault.configureInstantWithdrawalFuses(instant);
    }

    function _configureExitGate(FusionInstanceCyvbWBTCV1 memory instance_, address preHook_) private {
        bytes4[] memory selectors = new bytes4[](2);
        address[] memory implementations = new address[](2);
        bytes32[][] memory substrates = new bytes32[][](2);

        selectors[0] = WITHDRAW_SELECTOR;
        selectors[1] = REDEEM_SELECTOR;
        implementations[0] = preHook_;
        implementations[1] = preHook_;
        substrates[0] = new bytes32[](0);
        substrates[1] = new bytes32[](0);

        IPlasmaVaultGovernanceCyvbWBTCV1(instance_.plasmaVault).setPreHookImplementations(
            selectors,
            implementations,
            substrates
        );
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
    }

    function _verifyExternalDependencies(address nested_) private view {
        require(address(FACTORY).code.length != 0, "factory missing");
        require(VBWBTC.code.length != 0, "vbWBTC missing");
        require(VBUSDC.code.length != 0, "vbUSDC missing");
        require(FXUSD.code.length != 0, "fxUSD missing");
        require(FX_POOL_MANAGER.code.length != 0, "f(x) manager missing");
        require(FX_POOL.code.length != 0, "f(x) pool missing");
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
        address gateway_,
        address strategyFuse_,
        address balanceFuse_,
        address config_,
        address priceFeed_,
        address preHook_
    ) private view {
        require(instance_.underlyingToken == VBWBTC, "underlying mismatch");
        require(keccak256(bytes(instance_.assetName)) == keccak256(bytes("CurveYield vbWBTC")), "name mismatch");
        require(keccak256(bytes(instance_.assetSymbol)) == keccak256(bytes("cyvbWBTC")), "symbol mismatch");

        IAccessManagerCyvbWBTCV1 access = IAccessManagerCyvbWBTCV1(instance_.accessManager);
        (bool alpha,) = access.hasRole(ALPHA_ROLE, keeper_);
        (bool whitelist,) = access.hasRole(WHITELIST_ROLE, gateway_);
        require(alpha, "keeper lacks ALPHA");
        require(whitelist, "gateway lacks WHITELIST");

        IPlasmaVaultGovernanceCyvbWBTCV1 vault =
            IPlasmaVaultGovernanceCyvbWBTCV1(instance_.plasmaVault);

        address[] memory fuses = vault.getFuses();
        require(fuses.length == 1 && fuses[0] == strategyFuse_, "strategy fuse mismatch");
        require(vault.getBalanceFuse(STRATEGY_MARKET_ID) == balanceFuse_, "balance fuse mismatch");

        address[] memory instant = vault.getInstantWithdrawalFuses();
        require(instant.length == 1 && instant[0] == strategyFuse_, "instant fuse mismatch");

        require(
            IPriceManagerCyvbWBTCV1(instance_.priceManager).getSourceOfAssetPrice(VBWBTC) == priceFeed_,
            "price source mismatch"
        );

        IFeeManagerCyvbWBTCV1 fees = IFeeManagerCyvbWBTCV1(instance_.feeManager);
        require(fees.getTotalManagementFee() == EXPECTED_TOTAL_MANAGEMENT_BPS, "management total mismatch");
        require(fees.getTotalPerformanceFee() == EXPECTED_TOTAL_PERFORMANCE_BPS, "performance total mismatch");

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

        require(CyvbWbtcGateway_v1(gateway_).VAULT() == instance_.plasmaVault, "gateway vault mismatch");
        require(CyvbWbtcGateway_v1(gateway_).FEE_RECEIVER() == FEE_RECEIVER, "gateway receiver mismatch");
        require(CyvbWbtcGateway_v1(gateway_).ONBOARDING_FEE_BPS() == 55, "onboarding fee mismatch");
        require(CyvbWbtcGateway_v1(gateway_).INSTANT_EXIT_FEE_BPS() == 35, "exit fee mismatch");

        require(CyvbWbtcLtvConfig_v1(config_).vault() == instance_.plasmaVault, "config vault mismatch");
        CyvbWbtcLtvConfig_v1.LtvPolicy memory policy = CyvbWbtcLtvConfig_v1(config_).getLtvPolicy();
        require(policy.targetLtvBps == 5000, "target LTV mismatch");
        require(policy.highTriggerBps == 6000, "high trigger mismatch");
        require(policy.highResetBps == 5800, "high reset mismatch");
        require(policy.lowTriggerBps == 4500, "low trigger mismatch");
        require(policy.lowResetBps == 5000, "low reset mismatch");

        require(
            CyvbWbtcInstantExitGatePreHook_v1(preHook_).GATEWAY() == gateway_,
            "prehook gateway mismatch"
        );

        require(FxMintCyvbWbtcFuse_v1(strategyFuse_).CYVBUSDC() == nested_, "nested vault fuse mismatch");
        require(FxMintCyvbWbtcBalanceFuse_v1(balanceFuse_).CYVBUSDC() == nested_, "nested balance mismatch");

        _verifyRoutes();
    }
}
