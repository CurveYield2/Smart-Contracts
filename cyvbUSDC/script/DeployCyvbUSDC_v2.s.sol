// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";
import "../contracts/KatRewardSwapAndSplitFuse_v3.sol";

struct FeePackageCyvbUSDCV1 {
    uint256 managementFee;
    uint256 performanceFee;
    address feeRecipient;
}

struct FusionInstanceCyvbUSDCV1 {
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

struct RecipientFeeCyvbUSDCV1 {
    address recipient;
    uint256 feeValue;
}

struct InstantWithdrawalFuseParamsCyvbUSDCV1 {
    address fuse;
    bytes32[] params;
}

struct PerformanceFeeDataCyvbUSDCV1 {
    address feeAccount;
    uint16 feeInPercentage;
}

struct ManagementFeeDataCyvbUSDCV1 {
    address feeAccount;
    uint16 feeInPercentage;
    uint32 lastUpdateTimestamp;
}

struct VestingDataCyvbUSDCV1 {
    uint32 vestingTime;
    uint32 updateBalanceTimestamp;
    uint128 transferredTokens;
    uint128 lastUpdateBalance;
}

interface IFusionFactoryCyvbUSDCV1 {
    function clone(
        string calldata assetName_,
        string calldata assetSymbol_,
        address underlyingToken_,
        uint256 redemptionDelayInSeconds_,
        address owner_,
        uint256 daoFeePackageIndex_
    ) external returns (FusionInstanceCyvbUSDCV1 memory);

    function getDaoFeePackages() external view returns (FeePackageCyvbUSDCV1[] memory);
}

interface IAccessManagerCyvbUSDCV1 {
    function grantRole(uint64 roleId_, address account_, uint32 executionDelay_) external;
    function hasRole(uint64 roleId_, address account_) external view returns (bool isMember, uint32 executionDelay);
}

interface IPlasmaVaultGovernanceCyvbUSDCV1 {
    function addFuses(address[] calldata fuses_) external;
    function addBalanceFuse(uint256 marketId_, address fuse_) external;
    function grantMarketSubstrates(uint256 marketId_, bytes32[] calldata substrates_) external;
    function configureInstantWithdrawalFuses(InstantWithdrawalFuseParamsCyvbUSDCV1[] calldata fuses_) external;
    function convertToPublicVault() external;
    function enableTransferShares() external;

    function getFuses() external view returns (address[] memory);
    function getInstantWithdrawalFuses() external view returns (address[] memory);
    function getMarketSubstrates(uint256 marketId_) external view returns (bytes32[] memory);
    function getPerformanceFeeData() external view returns (PerformanceFeeDataCyvbUSDCV1 memory);
    function getManagementFeeData() external view returns (ManagementFeeDataCyvbUSDCV1 memory);
}

interface IPriceManagerCyvbUSDCV1 {
    function setAssetsPriceSources(address[] calldata assets_, address[] calldata sources_) external;
    function getSourceOfAssetPrice(address asset_) external view returns (address);
}

interface IFeeManagerCyvbUSDCV1 {
    function updateManagementFee(RecipientFeeCyvbUSDCV1[] calldata recipientFees) external;
    function updatePerformanceFee(RecipientFeeCyvbUSDCV1[] calldata recipientFees) external;
    function getTotalManagementFee() external view returns (uint256);
    function getTotalPerformanceFee() external view returns (uint256);
}

interface IRewardsClaimManagerCyvbUSDCV1 {
    function addRewardFuses(address[] calldata fuses_) external;
    function isRewardFuseSupported(address fuse_) external view returns (bool);
    function setupVestingTime(uint256 vestingTime_) external;
    function getVestingData() external view returns (VestingDataCyvbUSDCV1 memory);
}

interface ICurveYieldSushiV3FeeRouterCyvbUSDCV1 {
    function routeFor(address tokenIn, address tokenOut) external view returns (bytes memory);
}

/// @title DeployCyvbUSDC_v2
/// @notice Deploys and configures CurveYield USDC / cyvbUSDC using the official IPOR Fusion factory on Katana.
/// @dev No strategy allocation is hard-coded. The ALPHA/keeper chooses exact amounts between the three
///      whitelisted Morpho markets when deploying fresh capital or rebalancing.
contract DeployCyvbUSDC_v1 is Script {
    // ---------------- Katana / IPOR infrastructure ----------------

    uint256 internal constant KATANA_CHAIN_ID = 747474;

    IFusionFactoryCyvbUSDCV1 internal constant FACTORY =
        IFusionFactoryCyvbUSDCV1(0xc29b8D591d6a3f109Ca7ba384F2e00162866D37B);

    address internal constant VB_USDC = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36;
    address internal constant KAT = 0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d;

    // IPOR live Katana registry addresses.
    address internal constant USD_PRICE_FEED = 0x64518f821Cd07A9471711Eba5D8fEF9c75063B01;
    address internal constant ERC20_BALANCE_FUSE = 0xb81C00eb71a3D629E6f7Ba66a26218c418D438b8;
    address internal constant MORPHO_LIQUIDITY_BALANCE_FUSE = 0x70Ed27aEE2dD509bC6BB067d8e2C61A1FE96eCa4;
    address internal constant MORPHO_LIQUIDITY_SUPPLY_FUSE = 0x1f657229ec2D261be7dCD63ca82abed334d1f28b;
    address internal constant MERKL_CLAIM_FUSE = 0xF4278e62a6B5A45E378e6692C7Aa9C7291E7ce36;

    // Existing CurveYield Katana Sushi V3 fee router used by the reference vault system.
    address internal constant CURVEYIELD_SWAP_ROUTER = 0x01F9894f92ea9224fECc8C35482E20a05De13582;

    // KAT price source copied from the working reference vault's PriceManager.
    address internal constant KAT_PRICE_SOURCE = 0xc62782910529ee50eFDa9a0273B20d8bD1C1e4b2;

    // Every non-IPOR fee stream goes here.
    address internal constant CURVEYIELD_FEE_RECEIVER = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;

    // ---------------- Markets ----------------

    uint256 internal constant ERC20_VAULT_BALANCE_MARKET = 7;
    uint256 internal constant MORPHO_LIQUIDITY_IN_MARKETS = 41;

    bytes32 internal constant AVKAT_VBUSDC_MARKET =
        0xbd48214a2f12e951da20ad0b8fd83b611c693b5bbaa280b68ba4075678f2a138;

    bytes32 internal constant SIUSD_VBUSDC_MARKET =
        0xf7fc5cc82200ddf8f23188ddbd6727eda2c8bc41863e91fb767bbc6e4f71890e;

    bytes32 internal constant WEETH_VBUSDC_MARKET =
        0x76e311d4b0e2e6ae88ad9bab18063452a6d39837d7104c430ff62457b91cb2cb;

    // ---------------- Fees ----------------

    // Live Katana factory package 1 = IPOR "Middle Way":
    // 30 bps management + 200 bps performance to IPOR.
    uint256 internal constant MIDDLE_WAY_PACKAGE_INDEX = 1;
    uint256 internal constant EXPECTED_IPOR_MANAGEMENT_BPS = 30;
    uint256 internal constant EXPECTED_IPOR_PERFORMANCE_BPS = 200;

    // Additional CurveYield fee layer requested for cyvbUSDC.
    uint256 internal constant CURVEYIELD_MANAGEMENT_BPS = 50; // 0.50%
    uint256 internal constant CURVEYIELD_PERFORMANCE_BPS = 800; // 8.00%

    uint256 internal constant EXPECTED_TOTAL_MANAGEMENT_BPS = 80; // 0.30% + 0.50%
    uint256 internal constant EXPECTED_TOTAL_PERFORMANCE_BPS = 1000; // 2% + 8%

    // ---------------- Roles ----------------

    uint64 internal constant OWNER_ROLE = 1;
    uint64 internal constant ATOMIST_ROLE = 100;
    uint64 internal constant ALPHA_ROLE = 200;
    uint64 internal constant FUSE_MANAGER_ROLE = 300;
    uint64 internal constant CLAIM_REWARDS_ROLE = 600;
    uint64 internal constant CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE = 900;
    uint64 internal constant UPDATE_MARKETS_BALANCES_ROLE = 1000;
    uint64 internal constant UPDATE_REWARDS_BALANCE_ROLE = 1100;
    uint64 internal constant PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE = 1200;

    uint256 internal constant REWARD_VESTING_TIME = 15 days;

    event CyvbUSDCDeployed(
        address indexed vault,
        address indexed accessManager,
        address indexed rewardsManager,
        address feeManager,
        address priceManager,
        address rewardSwapAndSplitFuse,
        address keeper
    );

    function run() external returns (FusionInstanceCyvbUSDCV1 memory instance, address rewardFuse) {
        require(block.chainid == KATANA_CHAIN_ID, "not Katana");

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address keeper = vm.envOr("KEEPER", deployer);
        address finalOwner = vm.envOr("FINAL_OWNER", deployer);

        require(keeper != address(0), "KEEPER=0");
        require(finalOwner != address(0), "FINAL_OWNER=0");

        _verifyExternalDependencies();

        FeePackageCyvbUSDCV1[] memory packages = FACTORY.getDaoFeePackages();
        require(packages.length > MIDDLE_WAY_PACKAGE_INDEX, "Middle Way package missing");
        FeePackageCyvbUSDCV1 memory middleWay = packages[MIDDLE_WAY_PACKAGE_INDEX];
        require(middleWay.managementFee == EXPECTED_IPOR_MANAGEMENT_BPS, "IPOR management fee changed");
        require(middleWay.performanceFee == EXPECTED_IPOR_PERFORMANCE_BPS, "IPOR performance fee changed");
        require(middleWay.feeRecipient != address(0), "IPOR fee recipient=0");

        // Abort before spending deployment gas if the existing CurveYield router has not yet
        // been configured with a KAT -> vbUSDC route.
        require(
            ICurveYieldSushiV3FeeRouterCyvbUSDCV1(CURVEYIELD_SWAP_ROUTER).routeFor(KAT, VB_USDC).length != 0,
            "KAT->vbUSDC router route missing"
        );

        vm.startBroadcast(privateKey);

        // Use deployer as initial owner so the complete atomic configuration can be executed.
        instance = FACTORY.clone(
            "CurveYield USDC",
            "cyvbUSDC",
            VB_USDC,
            0,
            deployer,
            MIDDLE_WAY_PACKAGE_INDEX
        );

        IAccessManagerCyvbUSDCV1 access = IAccessManagerCyvbUSDCV1(instance.accessManager);
        IPlasmaVaultGovernanceCyvbUSDCV1 vault = IPlasmaVaultGovernanceCyvbUSDCV1(instance.plasmaVault);
        IPriceManagerCyvbUSDCV1 priceManager = IPriceManagerCyvbUSDCV1(instance.priceManager);
        IFeeManagerCyvbUSDCV1 feeManager = IFeeManagerCyvbUSDCV1(instance.feeManager);
        IRewardsClaimManagerCyvbUSDCV1 rewardsManager =
            IRewardsClaimManagerCyvbUSDCV1(instance.rewardsManager);

        // OWNER -> deployer operational roles.
        access.grantRole(ATOMIST_ROLE, deployer, 0);

        // ATOMIST-managed roles.
        access.grantRole(FUSE_MANAGER_ROLE, deployer, 0);
        access.grantRole(CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE, deployer, 0);
        access.grantRole(PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, deployer, 0);

        // Keeper receives strategy execution and rewards claim rights only.
        access.grantRole(ALPHA_ROLE, keeper, 0);
        access.grantRole(CLAIM_REWARDS_ROLE, keeper, 0);
        access.grantRole(UPDATE_MARKETS_BALANCES_ROLE, keeper, 0);

        // Our reward fuse calls RewardsClaimManager.updateBalance() while executing by
        // delegatecall in the Plasma Vault context, so the vault itself needs role 1100.
        access.grantRole(UPDATE_REWARDS_BALANCE_ROLE, instance.plasmaVault, 0);

        if (finalOwner != deployer) {
            access.grantRole(OWNER_ROLE, finalOwner, 0);
        }

        // Static $1 vbUSDC accounting + reference-vault KAT oracle for any residual KAT.
        address[] memory priceAssets = new address[](2);
        address[] memory priceSources = new address[](2);
        priceAssets[0] = VB_USDC;
        priceSources[0] = USD_PRICE_FEED;
        priceAssets[1] = KAT;
        priceSources[1] = KAT_PRICE_SOURCE;
        priceManager.setAssetsPriceSources(priceAssets, priceSources);

        // Strategy is supply-only: no Morpho collateral or borrow fuse is installed.
        address[] memory strategyFuses = new address[](1);
        strategyFuses[0] = MORPHO_LIQUIDITY_SUPPLY_FUSE;
        vault.addFuses(strategyFuses);
        vault.addBalanceFuse(MORPHO_LIQUIDITY_IN_MARKETS, MORPHO_LIQUIDITY_BALANCE_FUSE);

        // KAT can temporarily remain in the vault if a reward swap is skipped/failed.
        // Accounting it in market 7 prevents untracked residual rewards.
        vault.addBalanceFuse(ERC20_VAULT_BALANCE_MARKET, ERC20_BALANCE_FUSE);

        bytes32[] memory morphoMarkets = new bytes32[](3);
        morphoMarkets[0] = AVKAT_VBUSDC_MARKET;
        morphoMarkets[1] = SIUSD_VBUSDC_MARKET;
        morphoMarkets[2] = WEETH_VBUSDC_MARKET;
        vault.grantMarketSubstrates(MORPHO_LIQUIDITY_IN_MARKETS, morphoMarkets);

        bytes32[] memory erc20Assets = new bytes32[](1);
        erc20Assets[0] = bytes32(uint256(uint160(KAT)));
        vault.grantMarketSubstrates(ERC20_VAULT_BALANCE_MARKET, erc20Assets);

        // Enable the official Morpho instant-withdraw path for all three allowed markets.
        // MorphoSupplyFuse.instantWithdraw:
        // params[0] = runtime withdrawal amount; params[1] = Morpho market id.
        InstantWithdrawalFuseParamsCyvbUSDCV1[] memory instant =
            new InstantWithdrawalFuseParamsCyvbUSDCV1[](3);

        instant[0].fuse = MORPHO_LIQUIDITY_SUPPLY_FUSE;
        instant[0].params = _instantWithdrawParams(AVKAT_VBUSDC_MARKET);

        instant[1].fuse = MORPHO_LIQUIDITY_SUPPLY_FUSE;
        instant[1].params = _instantWithdrawParams(SIUSD_VBUSDC_MARKET);

        instant[2].fuse = MORPHO_LIQUIDITY_SUPPLY_FUSE;
        instant[2].params = _instantWithdrawParams(WEETH_VBUSDC_MARKET);

        vault.configureInstantWithdrawalFuses(instant);

        // Add the requested non-IPOR fee layer. FeeManager adds these recipient fees
        // on top of the immutable IPOR DAO package selected during factory clone.
        RecipientFeeCyvbUSDCV1[] memory managementRecipients = new RecipientFeeCyvbUSDCV1[](1);
        managementRecipients[0] = RecipientFeeCyvbUSDCV1({
            recipient: CURVEYIELD_FEE_RECEIVER,
            feeValue: CURVEYIELD_MANAGEMENT_BPS
        });
        feeManager.updateManagementFee(managementRecipients);

        RecipientFeeCyvbUSDCV1[] memory performanceRecipients = new RecipientFeeCyvbUSDCV1[](1);
        performanceRecipients[0] = RecipientFeeCyvbUSDCV1({
            recipient: CURVEYIELD_FEE_RECEIVER,
            feeValue: CURVEYIELD_PERFORMANCE_BPS
        });
        feeManager.updatePerformanceFee(performanceRecipients);

        // Match the proven CurveYield reference rewards setup.
        rewardsManager.setupVestingTime(REWARD_VESTING_TIME);

        KatRewardSwapAndSplitFuse_v3 deployedRewardFuse =
            new KatRewardSwapAndSplitFuse_v3(
                instance.plasmaVault,
                instance.rewardsManager,
                CURVEYIELD_SWAP_ROUTER
            );
        rewardFuse = address(deployedRewardFuse);

        address[] memory rewardFuses = new address[](2);
        rewardFuses[0] = MERKL_CLAIM_FUSE;
        rewardFuses[1] = rewardFuse;
        rewardsManager.addRewardFuses(rewardFuses);

        // Public ERC-4626 vault, like the reference deployment.
        vault.convertToPublicVault();
        vault.enableTransferShares();

        vm.stopBroadcast();

        _verifyDeployment(instance, rewardFuse, keeper);

        emit CyvbUSDCDeployed(
            instance.plasmaVault,
            instance.accessManager,
            instance.rewardsManager,
            instance.feeManager,
            instance.priceManager,
            rewardFuse,
            keeper
        );
    }

    function _instantWithdrawParams(bytes32 morphoMarketId_) internal pure returns (bytes32[] memory params) {
        params = new bytes32[](2);
        params[0] = bytes32(0);
        params[1] = morphoMarketId_;
    }

    function _verifyExternalDependencies() internal view {
        require(address(FACTORY).code.length != 0, "factory missing");
        require(VB_USDC.code.length != 0, "vbUSDC missing");
        require(KAT.code.length != 0, "KAT missing");
        require(USD_PRICE_FEED.code.length != 0, "USD feed missing");
        require(KAT_PRICE_SOURCE.code.length != 0, "KAT feed missing");
        require(ERC20_BALANCE_FUSE.code.length != 0, "ERC20 balance fuse missing");
        require(MORPHO_LIQUIDITY_BALANCE_FUSE.code.length != 0, "Morpho balance fuse missing");
        require(MORPHO_LIQUIDITY_SUPPLY_FUSE.code.length != 0, "Morpho supply fuse missing");
        require(MERKL_CLAIM_FUSE.code.length != 0, "Merkl fuse missing");
        require(CURVEYIELD_SWAP_ROUTER.code.length != 0, "CurveYield router missing");
    }

    function _verifyDeployment(
        FusionInstanceCyvbUSDCV1 memory instance_,
        address rewardFuse_,
        address keeper_
    ) internal view {
        IAccessManagerCyvbUSDCV1 access = IAccessManagerCyvbUSDCV1(instance_.accessManager);
        IPlasmaVaultGovernanceCyvbUSDCV1 vault = IPlasmaVaultGovernanceCyvbUSDCV1(instance_.plasmaVault);
        IPriceManagerCyvbUSDCV1 priceManager = IPriceManagerCyvbUSDCV1(instance_.priceManager);
        IFeeManagerCyvbUSDCV1 feeManager = IFeeManagerCyvbUSDCV1(instance_.feeManager);
        IRewardsClaimManagerCyvbUSDCV1 rewardsManager =
            IRewardsClaimManagerCyvbUSDCV1(instance_.rewardsManager);

        require(instance_.underlyingToken == VB_USDC, "wrong underlying");
        require(keccak256(bytes(instance_.assetName)) == keccak256(bytes("CurveYield USDC")), "wrong name");
        require(keccak256(bytes(instance_.assetSymbol)) == keccak256(bytes("cyvbUSDC")), "wrong symbol");

        require(priceManager.getSourceOfAssetPrice(VB_USDC) == USD_PRICE_FEED, "vbUSDC source wrong");
        require(priceManager.getSourceOfAssetPrice(KAT) == KAT_PRICE_SOURCE, "KAT source wrong");

        bytes32[] memory morphoMarkets = vault.getMarketSubstrates(MORPHO_LIQUIDITY_IN_MARKETS);
        require(morphoMarkets.length == 3, "wrong Morpho market count");

        address[] memory instant = vault.getInstantWithdrawalFuses();
        require(instant.length == 3, "wrong instant withdraw count");
        require(
            instant[0] == MORPHO_LIQUIDITY_SUPPLY_FUSE &&
            instant[1] == MORPHO_LIQUIDITY_SUPPLY_FUSE &&
            instant[2] == MORPHO_LIQUIDITY_SUPPLY_FUSE,
            "wrong instant withdraw fuse"
        );

        require(feeManager.getTotalManagementFee() == EXPECTED_TOTAL_MANAGEMENT_BPS, "management total wrong");
        require(feeManager.getTotalPerformanceFee() == EXPECTED_TOTAL_PERFORMANCE_BPS, "performance total wrong");

        ManagementFeeDataCyvbUSDCV1 memory management = vault.getManagementFeeData();
        PerformanceFeeDataCyvbUSDCV1 memory performance = vault.getPerformanceFeeData();
        require(management.feeInPercentage == EXPECTED_TOTAL_MANAGEMENT_BPS, "vault management fee wrong");
        require(performance.feeInPercentage == EXPECTED_TOTAL_PERFORMANCE_BPS, "vault performance fee wrong");

        require(rewardsManager.isRewardFuseSupported(MERKL_CLAIM_FUSE), "Merkl not installed");
        require(rewardsManager.isRewardFuseSupported(rewardFuse_), "reward split fuse not installed");
        require(rewardsManager.getVestingData().vestingTime == REWARD_VESTING_TIME, "vesting wrong");

        (bool alpha,) = access.hasRole(ALPHA_ROLE, keeper_);
        (bool claimer,) = access.hasRole(CLAIM_REWARDS_ROLE, keeper_);
        (bool vaultUpdater,) = access.hasRole(UPDATE_REWARDS_BALANCE_ROLE, instance_.plasmaVault);
        require(alpha, "keeper lacks ALPHA");
        require(claimer, "keeper lacks CLAIM_REWARDS");
        require(vaultUpdater, "vault lacks reward update role");

        require(
            ICurveYieldSushiV3FeeRouterCyvbUSDCV1(CURVEYIELD_SWAP_ROUTER).routeFor(KAT, VB_USDC).length != 0,
            "router route disappeared"
        );
    }
}