// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";

import "../contracts/CyvbWbtcGateway_v3.sol";
import "../contracts/CyvbWbtcGatewayGatePreHook_v3.sol";
import "../contracts/CyvbWbtcLtvConfig_v3.sol";
import "../contracts/FxMintVbWbtcPriceFeed_v2.sol";
import "../contracts/FxMintCyvbWbtcPositionFuse_v1.sol";
import "../contracts/FxMintCyvbWbtcBalanceFuse_v4.sol";
import "../contracts/FxMintCyvbWbtcInstantWithdrawFuse_v2.sol";

struct FeePackageCyvbWBTCV11 {
    uint256 managementFee;
    uint256 performanceFee;
    address feeRecipient;
}

struct FusionInstanceCyvbWBTCV11 {
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

struct RecipientFeeCyvbWBTCV11 {
    address recipient;
    uint256 feeValue;
}

struct InstantWithdrawalFuseParamsCyvbWBTCV11 {
    address fuse;
    bytes32[] params;
}

interface IFusionFactoryCyvbWBTCV11 {
    function clone(
        string calldata assetName_,
        string calldata assetSymbol_,
        address underlyingToken_,
        uint256 redemptionDelayInSeconds_,
        address owner_,
        uint256 daoFeePackageIndex_
    ) external returns (FusionInstanceCyvbWBTCV11 memory);

    function getDaoFeePackages() external view returns (FeePackageCyvbWBTCV11[] memory);
}

interface IAccessManagerCyvbWBTCV11 {
    function grantRole(uint64 roleId_, address account_, uint32 executionDelay_) external;
    function hasRole(uint64 roleId_, address account_) external view returns (bool isMember, uint32 executionDelay);
}

interface IPlasmaVaultGovernanceCyvbWBTCV11 {
    function addFuses(address[] calldata fuses_) external;
    function addBalanceFuse(uint256 marketId_, address fuse_) external;
    function grantMarketSubstrates(uint256 marketId_, bytes32[] calldata substrates_) external;
    function updateDependencyBalanceGraphs(
        uint256[] memory marketIds_,
        uint256[][] memory dependencies_
    ) external;
    function configureInstantWithdrawalFuses(
        InstantWithdrawalFuseParamsCyvbWBTCV11[] calldata fuses_
    ) external;
    function setPreHookImplementations(
        bytes4[] calldata selectors_,
        address[] calldata implementations_,
        bytes32[][] calldata substrates_
    ) external;
    function convertToPublicVault() external;
    function enableTransferShares() external;

    function getFuses() external view returns (address[] memory);
    function getInstantWithdrawalFuses() external view returns (address[] memory);
    function getBalanceFuse(uint256 marketId_) external view returns (address);
    function getMarketSubstrates(uint256 marketId_) external view returns (bytes32[] memory);
    function getDependencyBalanceGraph(uint256 marketId_) external view returns (uint256[] memory);
}

interface IPriceManagerCyvbWBTCV11 {
    function setAssetsPriceSources(address[] calldata assets_, address[] calldata sources_) external;
    function getSourceOfAssetPrice(address asset_) external view returns (address);
}

interface IFeeManagerCyvbWBTCV11 {
    function updateManagementFee(RecipientFeeCyvbWBTCV11[] calldata recipientFees) external;
    function updatePerformanceFee(RecipientFeeCyvbWBTCV11[] calldata recipientFees) external;
    function setDepositFee(uint256 depositFee_) external;
    function getDepositFee() external view returns (uint256);
    function getTotalManagementFee() external view returns (uint256);
    function getTotalPerformanceFee() external view returns (uint256);
}

interface IWithdrawManagerCyvbWBTCV11 {
    function getWithdrawFee() external view returns (uint256);
}

interface IERC4626InfoCyvbWBTCV11 {
    function asset() external view returns (address);
    function symbol() external view returns (string memory);
}

interface IFuseMarketCyvbWBTCV11 {
    function MARKET_ID() external view returns (uint256);
}

interface ICurveYieldRouterInfoCyvbWBTCV11 {
    function routeFor(address tokenIn, address tokenOut) external view returns (bytes memory);
    function routeTwapGuard(address tokenIn, address tokenOut)
        external
        view
        returns (uint32 window, uint16 maxDeviationBps, bool configured);
}

interface IFxLongPoolDeployCyvbWBTCV11 {
    function collateralToken() external view returns (address);
    function fxUSD() external view returns (address);
    function poolManager() external view returns (address);
    function priceOracle() external view returns (address);
    function configuration() external view returns (address);
}

interface IFxPoolConfigurationDeployCyvbWBTCV11 {
    function isStableRepayAllowed() external view returns (bool);
}

/// @title DeployCyvbWBTC_v11
/// @notice IPOR-native cyvbWBTC deployment using canonical IPOR Katana fuses wherever available.
/// @dev Custom contracts are restricted to behavior for which IPOR has no canonical Katana fuse:
///      f(x) position adjustment/balance, cross-asset instant unwind, vbWBTC f(x)-oracle adapter,
///      the CurveYield fee gateway, and its minimal gateway-only pre-hook.
contract DeployCyvbWBTC_v11 is Script {
    uint256 internal constant KATANA_CHAIN_ID = 747474;

    uint256 internal constant FX_MARKET_ID = 7001;
    uint256 internal constant ERC20_BALANCE_MARKET_ID = 7;
    uint256 internal constant UNIVERSAL_SWAPPER_V2_MARKET_ID = 1202;
    uint256 internal constant ERC4626_MARKET_ID = 100001;

    IFusionFactoryCyvbWBTCV11 internal constant FACTORY =
        IFusionFactoryCyvbWBTCV11(0xc29b8D591d6a3f109Ca7ba384F2e00162866D37B);

    // Canonical IPOR Katana deployments from IPOR-Labs/ipor-abi.
    address internal constant IPOR_USD_PRICE_FEED =
        0x64518f821Cd07A9471711Eba5D8fEF9c75063B01;
    address internal constant IPOR_ERC20_BALANCE_FUSE =
        0xb81C00eb71a3D629E6f7Ba66a26218c418D438b8;
    address internal constant IPOR_ERC4626_SUPPLY_FUSE =
        0xb05770874500c7dC981AF26AFb95C7656e2545c5;
    address internal constant IPOR_ERC4626_BALANCE_FUSE =
        0x5F8696C110Ccb3686c8B209Fc61dcf40daf88167;
    address internal constant IPOR_UNIVERSAL_SWAPPER_V2 =
        0x2513bA6f5603217636973F130128fc0372084C1E;
    address internal constant IPOR_UNIVERSAL_SWAPPER_BALANCE_V2 =
        0x87dF04464459Bfb377aFB130aD3Fd98A0957C0b1;

    address internal constant FEE_RECEIVER =
        0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;

    address internal constant VBWBTC =
        0x0913DA6Da4b42f538B445599b46Bb4622342Cf52;
    address internal constant VBUSDC =
        0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36;
    address internal constant FXUSD =
        0x1364b238C668A2dec1294174e4798E8c09979f86;

    address internal constant FX_POOL_MANAGER =
        0xFae375C9eA6636c40deB92DD91B7dbbF51BD3C68;
    address internal constant FX_POOL =
        0xE32B9b4C8f776687Ec54B4b6B62DbD9ce5fd4b99;
    address internal constant FX_POOL_CONFIGURATION =
        0xB582Eb17059171D09B4F78f0BB63E47C7ceEfF62;
    address internal constant FXBASE =
        0x6cf6757725886716Bc3c6A4bB93d02F1d1E3e7Dd;
    address internal constant FX_PRICE_ORACLE =
        0xeDA71e4ab642e97FBAA04beB3a7c4Bd6139a23C5;

    address internal constant CURVEYIELD_ROUTER =
        0x01F9894f92ea9224fECc8C35482E20a05De13582;

    bytes internal constant FXUSD_TO_VBUSDC =
        hex"1364b238c668a2dec1294174e4798e8c09979f86000064203a662b0bd271a6ed5a60edfbd04bfce608fd36";
    bytes internal constant VBUSDC_TO_FXUSD =
        hex"203a662b0bd271a6ed5a60edfbd04bfce608fd360000641364b238c668a2dec1294174e4798e8c09979f86";
    bytes internal constant VBUSDC_TO_VBWBTC =
        hex"203a662b0bd271a6ed5a60edfbd04bfce608fd360001f40913da6da4b42f538b445599b46bb4622342cf52";

    uint32 internal constant REQUIRED_TWAP_WINDOW = 15 minutes;
    uint16 internal constant REQUIRED_TWAP_DEVIATION_BPS = 200;
    uint256 internal constant UNIVERSAL_SWAP_SLIPPAGE_WAD = 1e16; // canonical 1%

    uint256 internal constant MIDDLE_WAY_PACKAGE_INDEX = 1;
    uint256 internal constant EXPECTED_IPOR_MANAGEMENT_BPS = 30;
    uint256 internal constant EXPECTED_IPOR_PERFORMANCE_BPS = 200;
    uint256 internal constant CURVEYIELD_MANAGEMENT_BPS = 100;
    uint256 internal constant CURVEYIELD_PERFORMANCE_BPS = 800;
    uint256 internal constant EXPECTED_TOTAL_MANAGEMENT_BPS = 130;
    uint256 internal constant EXPECTED_TOTAL_PERFORMANCE_BPS = 1000;

    uint64 internal constant OWNER_ROLE = 1;
    uint64 internal constant ATOMIST_ROLE = 100;
    uint64 internal constant ALPHA_ROLE = 200;
    uint64 internal constant FUSE_MANAGER_ROLE = 300;
    uint64 internal constant PRE_HOOKS_MANAGER_ROLE = 301;
    uint64 internal constant CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE = 900;
    uint64 internal constant UPDATE_MARKETS_BALANCES_ROLE = 1000;
    uint64 internal constant PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE = 1200;

    bytes4 internal constant DEPOSIT_SELECTOR = bytes4(keccak256("deposit(uint256,address)"));
    bytes4 internal constant MINT_SELECTOR = bytes4(keccak256("mint(uint256,address)"));
    bytes4 internal constant DEPOSIT_WITH_PERMIT_SELECTOR =
        bytes4(keccak256("depositWithPermit(uint256,address,uint256,uint8,bytes32,bytes32)"));
    bytes4 internal constant WITHDRAW_SELECTOR = bytes4(keccak256("withdraw(uint256,address,address)"));
    bytes4 internal constant REDEEM_SELECTOR = bytes4(keccak256("redeem(uint256,address,address)"));

    struct DeployedComponents {
        address config;
        address gateway;
        address preHook;
        address priceFeed;
        address positionFuse;
        address fxBalanceFuse;
        address instantFuse;
    }

    event CyvbWbtcDeployedV11(
        address indexed vault,
        address indexed gateway,
        address indexed positionFuse,
        address instantFuse,
        address fxBalanceFuse,
        address config,
        address priceFeed,
        address nestedCyvbUsdc,
        address keeper
    );

    function run() external returns (FusionInstanceCyvbWBTCV11 memory instance) {
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
        _verifyCanonicalIporFuses();

        vm.startBroadcast(privateKey);

        instance = FACTORY.clone(
            "CurveYield vbWBTC",
            "cyvbWBTC",
            VBWBTC,
            0,
            deployer,
            MIDDLE_WAY_PACKAGE_INDEX
        );

        DeployedComponents memory components =
            _deployCustomComponents(instance.plasmaVault, nestedCyvbUsdc, deployer);

        _configureRoles(instance, deployer, keeper, finalOwner);
        _configurePrices(instance, components.priceFeed);
        _configureMarkets(instance, nestedCyvbUsdc, components);
        _configureGatewayGate(instance, components.preHook);
        _configureFees(instance);

        IPlasmaVaultGovernanceCyvbWBTCV11(instance.plasmaVault).convertToPublicVault();
        IPlasmaVaultGovernanceCyvbWBTCV11(instance.plasmaVault).enableTransferShares();

        if (finalOwner != deployer) {
            CyvbWbtcLtvConfig_v3(components.config).transferOwnership(finalOwner);
        }

        vm.stopBroadcast();

        _verifyDeployment(instance, nestedCyvbUsdc, keeper, finalOwner, components);

        emit CyvbWbtcDeployedV11(
            instance.plasmaVault,
            components.gateway,
            components.positionFuse,
            components.instantFuse,
            components.fxBalanceFuse,
            components.config,
            components.priceFeed,
            nestedCyvbUsdc,
            keeper
        );
    }

    function _deployCustomComponents(
        address vault_,
        address nested_,
        address deployer_
    ) private returns (DeployedComponents memory components) {
        CyvbWbtcLtvConfig_v3 config = new CyvbWbtcLtvConfig_v3(deployer_);
        config.bindVault(vault_);
        components.config = address(config);

        components.gateway = address(new CyvbWbtcGateway_v3(vault_, VBWBTC));
        components.preHook = address(new CyvbWbtcGatewayGatePreHook_v3(components.gateway));
        components.priceFeed = address(new FxMintVbWbtcPriceFeed_v2(FX_PRICE_ORACLE));

        components.positionFuse = address(
            new FxMintCyvbWbtcPositionFuse_v1(
                components.config,
                FX_POOL_MANAGER,
                FX_POOL,
                VBWBTC,
                FXUSD
            )
        );

        components.fxBalanceFuse =
            address(new FxMintCyvbWbtcBalanceFuse_v4(components.config, FX_POOL));

        components.instantFuse = address(
            new FxMintCyvbWbtcInstantWithdrawFuse_v2(
                components.config,
                FX_POOL_MANAGER,
                FX_POOL,
                FXBASE,
                FXUSD,
                VBWBTC,
                VBUSDC,
                nested_,
                CURVEYIELD_ROUTER
            )
        );
    }

    function _configureRoles(
        FusionInstanceCyvbWBTCV11 memory instance_,
        address deployer_,
        address keeper_,
        address finalOwner_
    ) private {
        IAccessManagerCyvbWBTCV11 access = IAccessManagerCyvbWBTCV11(instance_.accessManager);

        access.grantRole(ATOMIST_ROLE, deployer_, 0);
        access.grantRole(FUSE_MANAGER_ROLE, deployer_, 0);
        access.grantRole(PRE_HOOKS_MANAGER_ROLE, deployer_, 0);
        access.grantRole(CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE, deployer_, 0);
        access.grantRole(PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, deployer_, 0);

        access.grantRole(ALPHA_ROLE, keeper_, 0);
        access.grantRole(UPDATE_MARKETS_BALANCES_ROLE, keeper_, 0);

        if (finalOwner_ != deployer_) {
            access.grantRole(OWNER_ROLE, finalOwner_, 0);
        }
    }

    function _configurePrices(
        FusionInstanceCyvbWBTCV11 memory instance_,
        address vbWbtcPriceFeed_
    ) private {
        address[] memory assets = new address[](3);
        address[] memory sources = new address[](3);

        assets[0] = VBWBTC;
        sources[0] = vbWbtcPriceFeed_;

        assets[1] = VBUSDC;
        sources[1] = IPOR_USD_PRICE_FEED;

        assets[2] = FXUSD;
        sources[2] = IPOR_USD_PRICE_FEED;

        IPriceManagerCyvbWBTCV11(instance_.priceManager).setAssetsPriceSources(assets, sources);
    }

    function _configureMarkets(
        FusionInstanceCyvbWBTCV11 memory instance_,
        address nested_,
        DeployedComponents memory components_
    ) private {
        IPlasmaVaultGovernanceCyvbWBTCV11 vault =
            IPlasmaVaultGovernanceCyvbWBTCV11(instance_.plasmaVault);

        address[] memory fuses = new address[](4);
        fuses[0] = components_.positionFuse;
        fuses[1] = components_.instantFuse;
        fuses[2] = IPOR_ERC4626_SUPPLY_FUSE;
        fuses[3] = IPOR_UNIVERSAL_SWAPPER_V2;
        vault.addFuses(fuses);

        vault.addBalanceFuse(FX_MARKET_ID, components_.fxBalanceFuse);
        vault.addBalanceFuse(ERC4626_MARKET_ID, IPOR_ERC4626_BALANCE_FUSE);
        vault.addBalanceFuse(ERC20_BALANCE_MARKET_ID, IPOR_ERC20_BALANCE_FUSE);
        vault.addBalanceFuse(
            UNIVERSAL_SWAPPER_V2_MARKET_ID,
            IPOR_UNIVERSAL_SWAPPER_BALANCE_V2
        );

        bytes32[] memory fxSubstrates = new bytes32[](3);
        fxSubstrates[0] = _addressToBytes32(FX_POOL);
        fxSubstrates[1] = _addressToBytes32(nested_);
        fxSubstrates[2] = _addressToBytes32(CURVEYIELD_ROUTER);
        vault.grantMarketSubstrates(FX_MARKET_ID, fxSubstrates);

        bytes32[] memory erc4626Substrates = new bytes32[](1);
        erc4626Substrates[0] = _addressToBytes32(nested_);
        vault.grantMarketSubstrates(ERC4626_MARKET_ID, erc4626Substrates);

        bytes32[] memory residualSubstrates = new bytes32[](2);
        residualSubstrates[0] = _addressToBytes32(FXUSD);
        residualSubstrates[1] = _addressToBytes32(VBUSDC);
        vault.grantMarketSubstrates(ERC20_BALANCE_MARKET_ID, residualSubstrates);

        bytes32[] memory swapSubstrates = new bytes32[](8);
        swapSubstrates[0] = _tokenSubstrate(FXUSD);
        swapSubstrates[1] = _tokenSubstrate(VBUSDC);
        swapSubstrates[2] = _tokenSubstrate(VBWBTC);
        swapSubstrates[3] = _targetSubstrate(FXUSD);
        swapSubstrates[4] = _targetSubstrate(VBUSDC);
        swapSubstrates[5] = _targetSubstrate(VBWBTC);
        swapSubstrates[6] = _targetSubstrate(CURVEYIELD_ROUTER);
        swapSubstrates[7] = _slippageSubstrate(UNIVERSAL_SWAP_SLIPPAGE_WAD);
        vault.grantMarketSubstrates(UNIVERSAL_SWAPPER_V2_MARKET_ID, swapSubstrates);

        uint256[] memory marketIds = new uint256[](3);
        uint256[][] memory dependencies = new uint256[][](3);

        marketIds[0] = FX_MARKET_ID;
        dependencies[0] = new uint256[](2);
        dependencies[0][0] = ERC4626_MARKET_ID;
        dependencies[0][1] = ERC20_BALANCE_MARKET_ID;

        marketIds[1] = ERC4626_MARKET_ID;
        dependencies[1] = new uint256[](1);
        dependencies[1][0] = ERC20_BALANCE_MARKET_ID;

        marketIds[2] = UNIVERSAL_SWAPPER_V2_MARKET_ID;
        dependencies[2] = new uint256[](1);
        dependencies[2][0] = ERC20_BALANCE_MARKET_ID;

        vault.updateDependencyBalanceGraphs(marketIds, dependencies);

        InstantWithdrawalFuseParamsCyvbWBTCV11[] memory instant =
            new InstantWithdrawalFuseParamsCyvbWBTCV11[](1);
        bytes32[] memory instantParams = new bytes32[](1);
        instantParams[0] = bytes32(0);
        instant[0] = InstantWithdrawalFuseParamsCyvbWBTCV11({
            fuse: components_.instantFuse,
            params: instantParams
        });
        vault.configureInstantWithdrawalFuses(instant);
    }

    function _configureGatewayGate(
        FusionInstanceCyvbWBTCV11 memory instance_,
        address preHook_
    ) private {
        bytes4[] memory selectors = new bytes4[](5);
        address[] memory implementations = new address[](5);
        bytes32[][] memory substrates = new bytes32[][](5);

        selectors[0] = DEPOSIT_SELECTOR;
        selectors[1] = MINT_SELECTOR;
        selectors[2] = DEPOSIT_WITH_PERMIT_SELECTOR;
        selectors[3] = WITHDRAW_SELECTOR;
        selectors[4] = REDEEM_SELECTOR;

        for (uint256 i; i < 5; ++i) {
            implementations[i] = preHook_;
            substrates[i] = new bytes32[](0);
        }

        IPlasmaVaultGovernanceCyvbWBTCV11(instance_.plasmaVault).setPreHookImplementations(
            selectors,
            implementations,
            substrates
        );
    }

    function _configureFees(FusionInstanceCyvbWBTCV11 memory instance_) private {
        IFeeManagerCyvbWBTCV11 fees = IFeeManagerCyvbWBTCV11(instance_.feeManager);

        RecipientFeeCyvbWBTCV11[] memory management = new RecipientFeeCyvbWBTCV11[](1);
        management[0] = RecipientFeeCyvbWBTCV11({
            recipient: FEE_RECEIVER,
            feeValue: CURVEYIELD_MANAGEMENT_BPS
        });
        fees.updateManagementFee(management);

        RecipientFeeCyvbWBTCV11[] memory performance = new RecipientFeeCyvbWBTCV11[](1);
        performance[0] = RecipientFeeCyvbWBTCV11({
            recipient: FEE_RECEIVER,
            feeValue: CURVEYIELD_PERFORMANCE_BPS
        });
        fees.updatePerformanceFee(performance);

        fees.setDepositFee(0);
    }

    function _verifyExternalDependencies(address nested_) private view {
        require(address(FACTORY).code.length != 0, "factory missing");
        require(VBWBTC.code.length != 0, "vbWBTC missing");
        require(VBUSDC.code.length != 0, "vbUSDC missing");
        require(FXUSD.code.length != 0, "fxUSD missing");
        require(FX_POOL_MANAGER.code.length != 0, "f(x) manager missing");
        require(FX_POOL.code.length != 0, "f(x) pool missing");
        require(FX_POOL_CONFIGURATION.code.length != 0, "f(x) config missing");
        require(FXBASE.code.length != 0, "fxBASE missing");
        require(FX_PRICE_ORACLE.code.length != 0, "f(x) oracle missing");
        require(CURVEYIELD_ROUTER.code.length != 0, "router missing");
        require(nested_.code.length != 0, "cyvbUSDC missing");
        require(IPOR_USD_PRICE_FEED.code.length != 0, "IPOR USD feed missing");

        IFxLongPoolDeployCyvbWBTCV11 pool = IFxLongPoolDeployCyvbWBTCV11(FX_POOL);
        require(pool.collateralToken() == VBWBTC, "f(x) collateral changed");
        require(pool.fxUSD() == FXUSD, "f(x) debt asset changed");
        require(pool.poolManager() == FX_POOL_MANAGER, "f(x) manager changed");
        require(pool.priceOracle() == FX_PRICE_ORACLE, "f(x) oracle changed");
        require(pool.configuration() == FX_POOL_CONFIGURATION, "f(x) config changed");

        // Live Katana currently has stable repay disabled; instant unwind therefore uses router swap.
        require(
            !IFxPoolConfigurationDeployCyvbWBTCV11(FX_POOL_CONFIGURATION).isStableRepayAllowed(),
            "f(x) stable repay behavior changed"
        );

        require(IERC4626InfoCyvbWBTCV11(nested_).asset() == VBUSDC, "nested asset wrong");
        require(
            keccak256(bytes(IERC4626InfoCyvbWBTCV11(nested_).symbol())) ==
                keccak256(bytes("cyvbUSDC")),
            "nested vault wrong"
        );
    }

    function _verifyCanonicalIporFuses() private view {
        _requireMarket(IPOR_ERC20_BALANCE_FUSE, ERC20_BALANCE_MARKET_ID);
        _requireMarket(IPOR_ERC4626_SUPPLY_FUSE, ERC4626_MARKET_ID);
        _requireMarket(IPOR_ERC4626_BALANCE_FUSE, ERC4626_MARKET_ID);
        _requireMarket(IPOR_UNIVERSAL_SWAPPER_V2, UNIVERSAL_SWAPPER_V2_MARKET_ID);
        _requireMarket(
            IPOR_UNIVERSAL_SWAPPER_BALANCE_V2,
            UNIVERSAL_SWAPPER_V2_MARKET_ID
        );
    }

    function _requireMarket(address fuse_, uint256 expectedMarket_) private view {
        require(fuse_.code.length != 0, "canonical IPOR fuse missing");
        require(
            IFuseMarketCyvbWBTCV11(fuse_).MARKET_ID() == expectedMarket_,
            "canonical IPOR market changed"
        );
    }

    function _verifyMiddleWay() private view {
        FeePackageCyvbWBTCV11[] memory packages = FACTORY.getDaoFeePackages();
        require(packages.length > MIDDLE_WAY_PACKAGE_INDEX, "Middle Way missing");
        FeePackageCyvbWBTCV11 memory selected = packages[MIDDLE_WAY_PACKAGE_INDEX];
        require(selected.managementFee == EXPECTED_IPOR_MANAGEMENT_BPS, "IPOR management changed");
        require(selected.performanceFee == EXPECTED_IPOR_PERFORMANCE_BPS, "IPOR performance changed");
        require(selected.feeRecipient != address(0), "IPOR recipient zero");
    }

    function _verifyRoute(address tokenIn_, address tokenOut_, bytes memory expected_) private view {
        ICurveYieldRouterInfoCyvbWBTCV11 router =
            ICurveYieldRouterInfoCyvbWBTCV11(CURVEYIELD_ROUTER);

        require(
            keccak256(router.routeFor(tokenIn_, tokenOut_)) == keccak256(expected_),
            "route mismatch"
        );

        (uint32 window, uint16 deviation, bool configured) =
            router.routeTwapGuard(tokenIn_, tokenOut_);

        require(configured, "TWAP guard missing");
        require(window == REQUIRED_TWAP_WINDOW, "TWAP window changed");
        require(deviation == REQUIRED_TWAP_DEVIATION_BPS, "TWAP deviation changed");
    }

    function _verifyRoutes() private view {
        _verifyRoute(FXUSD, VBUSDC, FXUSD_TO_VBUSDC);
        _verifyRoute(VBUSDC, FXUSD, VBUSDC_TO_FXUSD);
        _verifyRoute(VBUSDC, VBWBTC, VBUSDC_TO_VBWBTC);
    }

    function _verifyDeployment(
        FusionInstanceCyvbWBTCV11 memory instance_,
        address nested_,
        address keeper_,
        address finalOwner_,
        DeployedComponents memory components_
    ) private view {
        require(instance_.underlyingToken == VBWBTC, "underlying mismatch");
        require(
            keccak256(bytes(instance_.assetName)) == keccak256(bytes("CurveYield vbWBTC")),
            "name mismatch"
        );
        require(
            keccak256(bytes(instance_.assetSymbol)) == keccak256(bytes("cyvbWBTC")),
            "symbol mismatch"
        );

        IAccessManagerCyvbWBTCV11 access = IAccessManagerCyvbWBTCV11(instance_.accessManager);
        (bool alpha,) = access.hasRole(ALPHA_ROLE, keeper_);
        require(alpha, "keeper lacks ALPHA");

        if (finalOwner_ != instance_.initialOwner) {
            (bool ownerRole,) = access.hasRole(OWNER_ROLE, finalOwner_);
            require(ownerRole, "final owner role missing");
        }

        IPriceManagerCyvbWBTCV11 prices = IPriceManagerCyvbWBTCV11(instance_.priceManager);
        require(prices.getSourceOfAssetPrice(VBWBTC) == components_.priceFeed, "vbWBTC source wrong");
        require(prices.getSourceOfAssetPrice(VBUSDC) == IPOR_USD_PRICE_FEED, "vbUSDC source wrong");
        require(prices.getSourceOfAssetPrice(FXUSD) == IPOR_USD_PRICE_FEED, "fxUSD source wrong");

        IPlasmaVaultGovernanceCyvbWBTCV11 vault =
            IPlasmaVaultGovernanceCyvbWBTCV11(instance_.plasmaVault);

        require(vault.getBalanceFuse(FX_MARKET_ID) == components_.fxBalanceFuse, "f(x) balance wrong");
        require(
            vault.getBalanceFuse(ERC4626_MARKET_ID) == IPOR_ERC4626_BALANCE_FUSE,
            "ERC4626 balance wrong"
        );
        require(
            vault.getBalanceFuse(ERC20_BALANCE_MARKET_ID) == IPOR_ERC20_BALANCE_FUSE,
            "ERC20 balance wrong"
        );
        require(
            vault.getBalanceFuse(UNIVERSAL_SWAPPER_V2_MARKET_ID) ==
                IPOR_UNIVERSAL_SWAPPER_BALANCE_V2,
            "swapper balance wrong"
        );

        bytes32[] memory fxSubs = vault.getMarketSubstrates(FX_MARKET_ID);
        require(fxSubs.length == 3, "f(x) substrate count");
        require(fxSubs[0] == _addressToBytes32(FX_POOL), "f(x) pool substrate");
        require(fxSubs[1] == _addressToBytes32(nested_), "nested substrate");
        require(fxSubs[2] == _addressToBytes32(CURVEYIELD_ROUTER), "router substrate");

        bytes32[] memory nestedSubs = vault.getMarketSubstrates(ERC4626_MARKET_ID);
        require(
            nestedSubs.length == 1 && nestedSubs[0] == _addressToBytes32(nested_),
            "ERC4626 substrate wrong"
        );

        uint256[] memory fxDeps = vault.getDependencyBalanceGraph(FX_MARKET_ID);
        require(
            fxDeps.length == 2 &&
                fxDeps[0] == ERC4626_MARKET_ID &&
                fxDeps[1] == ERC20_BALANCE_MARKET_ID,
            "f(x) dependencies wrong"
        );

        address[] memory instant = vault.getInstantWithdrawalFuses();
        require(
            instant.length == 1 && instant[0] == components_.instantFuse,
            "instant fuse wrong"
        );

        IFeeManagerCyvbWBTCV11 fees = IFeeManagerCyvbWBTCV11(instance_.feeManager);
        require(fees.getTotalManagementFee() == EXPECTED_TOTAL_MANAGEMENT_BPS, "management total");
        require(fees.getTotalPerformanceFee() == EXPECTED_TOTAL_PERFORMANCE_BPS, "performance total");
        require(fees.getDepositFee() == 0, "native deposit fee");
        require(
            IWithdrawManagerCyvbWBTCV11(instance_.withdrawManager).getWithdrawFee() == 0,
            "native withdraw fee"
        );

        require(CyvbWbtcGateway_v3(components_.gateway).VAULT() == instance_.plasmaVault, "gateway vault");
        require(CyvbWbtcGateway_v3(components_.gateway).ASSET() == VBWBTC, "gateway asset");
        require(CyvbWbtcGatewayGatePreHook_v3(components_.preHook).GATEWAY() == components_.gateway, "prehook gateway");

        CyvbWbtcLtvConfig_v3 config = CyvbWbtcLtvConfig_v3(components_.config);
        require(config.vault() == instance_.plasmaVault, "config vault");
        require(config.INSTANT_WITHDRAW_MAX_LTV_BPS() == 5500, "instant max LTV");

        CyvbWbtcLtvConfig_v3.LtvPolicy memory policy = config.getLtvPolicy();
        require(policy.targetLtvBps == 5000, "target LTV");
        require(policy.highTriggerBps == 6000, "high trigger");
        require(policy.highResetBps == 5800, "high reset");
        require(policy.lowTriggerBps == 4500, "low trigger");
        require(policy.lowResetBps == 5000, "low reset");

        if (finalOwner_ != instance_.initialOwner) {
            require(config.pendingOwner() == finalOwner_, "config handoff missing");
        }

        require(
            FxMintCyvbWbtcPositionFuse_v1(components_.positionFuse).FX_POOL() == FX_POOL,
            "position fuse pool"
        );
        require(
            FxMintCyvbWbtcBalanceFuse_v4(components_.fxBalanceFuse).FX_POOL() == FX_POOL,
            "balance fuse pool"
        );
        require(
            FxMintCyvbWbtcInstantWithdrawFuse_v2(components_.instantFuse).CYVBUSDC() == nested_,
            "instant nested"
        );

        _verifyCanonicalIporFuses();
        _verifyRoutes();
    }

    function _addressToBytes32(address address_) private pure returns (bytes32) {
        return bytes32(uint256(uint160(address_)));
    }

    function _tokenSubstrate(address token_) private pure returns (bytes32) {
        return bytes32(uint256(1) << 248) | bytes32(uint256(uint160(token_)));
    }

    function _targetSubstrate(address target_) private pure returns (bytes32) {
        return bytes32(uint256(2) << 248) | bytes32(uint256(uint160(target_)));
    }

    function _slippageSubstrate(uint256 slippageWad_) private pure returns (bytes32) {
        return bytes32(uint256(3) << 248) | bytes32(slippageWad_);
    }
}
