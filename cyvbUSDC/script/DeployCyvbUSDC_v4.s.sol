// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";
import "../contracts/KatRewardSwapAndSplitFuse_v3.sol";

struct FeePackageCyvbUSDCV3 {
    uint256 managementFee;
    uint256 performanceFee;
    address feeRecipient;
}

struct FusionInstanceCyvbUSDCV3 {
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

struct RecipientFeeCyvbUSDCV3 {
    address recipient;
    uint256 feeValue;
}

struct InstantWithdrawalFuseParamsCyvbUSDCV3 {
    address fuse;
    bytes32[] params;
}

struct PerformanceFeeDataCyvbUSDCV3 {
    address feeAccount;
    uint16 feeInPercentage;
}

struct ManagementFeeDataCyvbUSDCV3 {
    address feeAccount;
    uint16 feeInPercentage;
    uint32 lastUpdateTimestamp;
}

struct VestingDataCyvbUSDCV3 {
    uint32 vestingTime;
    uint32 updateBalanceTimestamp;
    uint128 transferredTokens;
    uint128 lastUpdateBalance;
}

interface IFusionFactoryCyvbUSDCV3 {
    function clone(
        string calldata assetName_,
        string calldata assetSymbol_,
        address underlyingToken_,
        uint256 redemptionDelayInSeconds_,
        address owner_,
        uint256 daoFeePackageIndex_
    ) external returns (FusionInstanceCyvbUSDCV3 memory);

    function getDaoFeePackages() external view returns (FeePackageCyvbUSDCV3[] memory);
}

interface IAccessManagerCyvbUSDCV3 {
    function grantRole(uint64 roleId_, address account_, uint32 executionDelay_) external;
    function renounceRole(uint64 roleId_, address callerConfirmation_) external;
    function hasRole(uint64 roleId_, address account_) external view returns (bool isMember, uint32 executionDelay);
}

interface IPlasmaVaultGovernanceCyvbUSDCV3 {
    function addFuses(address[] calldata fuses_) external;
    function addBalanceFuse(uint256 marketId_, address fuse_) external;
    function grantMarketSubstrates(uint256 marketId_, bytes32[] calldata substrates_) external;
    function configureInstantWithdrawalFuses(InstantWithdrawalFuseParamsCyvbUSDCV3[] calldata fuses_) external;
    function convertToPublicVault() external;
    function enableTransferShares() external;

    function getInstantWithdrawalFuses() external view returns (address[] memory);
    function getMarketSubstrates(uint256 marketId_) external view returns (bytes32[] memory);
    function getPerformanceFeeData() external view returns (PerformanceFeeDataCyvbUSDCV3 memory);
    function getManagementFeeData() external view returns (ManagementFeeDataCyvbUSDCV3 memory);
}

interface IPriceManagerCyvbUSDCV3 {
    function setAssetsPriceSources(address[] calldata assets_, address[] calldata sources_) external;
    function getSourceOfAssetPrice(address asset_) external view returns (address);
}

interface IFeeManagerCyvbUSDCV3 {
    function updateManagementFee(RecipientFeeCyvbUSDCV3[] calldata recipientFees) external;
    function updatePerformanceFee(RecipientFeeCyvbUSDCV3[] calldata recipientFees) external;
    function getTotalManagementFee() external view returns (uint256);
    function getTotalPerformanceFee() external view returns (uint256);
}

interface IRewardsClaimManagerCyvbUSDCV3 {
    function addRewardFuses(address[] calldata fuses_) external;
    function isRewardFuseSupported(address fuse_) external view returns (bool);
    function setupVestingTime(uint256 vestingTime_) external;
    function getVestingData() external view returns (VestingDataCyvbUSDCV3 memory);
}

interface ICurveYieldSushiV3FeeRouterCyvbUSDCV3 {
    function routeFor(address tokenIn, address tokenOut) external view returns (bytes memory);
}

/// @title DeployCyvbUSDC_v4
/// @notice Official-IPOR-factory deployment and complete configuration for CurveYield USDC / cyvbUSDC on Katana.
/// @dev The keeper chooses allocation amounts dynamically across the three whitelisted Morpho markets.
///      This script intentionally grants no Morpho borrow/collateral capability.
contract DeployCyvbUSDC_v4 is Script {
    uint256 internal constant KATANA_CHAIN_ID = 747474;

    IFusionFactoryCyvbUSDCV3 internal constant FACTORY =
        IFusionFactoryCyvbUSDCV3(0xc29b8D591d6a3f109Ca7ba384F2e00162866D37B);

    address internal constant VB_USDC = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36;
    address internal constant KAT = 0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d;

    address internal constant USD_PRICE_FEED = 0x64518f821Cd07A9471711Eba5D8fEF9c75063B01;
    address internal constant KAT_PRICE_SOURCE = 0xc62782910529ee50eFDa9a0273B20d8bD1C1e4b2;
    address internal constant ERC20_BALANCE_FUSE = 0xb81C00eb71a3D629E6f7Ba66a26218c418D438b8;
    address internal constant MORPHO_LIQUIDITY_BALANCE_FUSE = 0x70Ed27aEE2dD509bC6BB067d8e2C61A1FE96eCa4;
    address internal constant MORPHO_LIQUIDITY_SUPPLY_FUSE = 0x1f657229ec2D261be7dCD63ca82abed334d1f28b;
    address internal constant MERKL_CLAIM_FUSE = 0xF4278e62a6B5A45E378e6692C7Aa9C7291E7ce36;
    address internal constant CURVEYIELD_SWAP_ROUTER = 0x01F9894f92ea9224fECc8C35482E20a05De13582;
    address internal constant CURVEYIELD_FEE_RECEIVER = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49; // cyavKAT fee Safe
    /// @dev Owner: the same owner as the cyavKAT vault (override with FINAL_OWNER)
    address internal constant VAULT_OWNER = 0x11b78837cadC8E894F1c6e13fA9f3A085a75FA35;

    uint256 internal constant ERC20_VAULT_BALANCE_MARKET = 7;
    uint256 internal constant MORPHO_LIQUIDITY_IN_MARKETS = 41;

    bytes32 internal constant AVKAT_VBUSDC_MARKET =
        0xbd48214a2f12e951da20ad0b8fd83b611c693b5bbaa280b68ba4075678f2a138;
    bytes32 internal constant SIUSD_VBUSDC_MARKET =
        0xf7fc5cc82200ddf8f23188ddbd6727eda2c8bc41863e91fb767bbc6e4f71890e;
    bytes32 internal constant WEETH_VBUSDC_MARKET =
        0x76e311d4b0e2e6ae88ad9bab18063452a6d39837d7104c430ff62457b91cb2cb;

    uint256 internal constant MIDDLE_WAY_PACKAGE_INDEX = 1;
    uint256 internal constant EXPECTED_IPOR_MANAGEMENT_BPS = 30;
    uint256 internal constant EXPECTED_IPOR_PERFORMANCE_BPS = 200;
    uint256 internal constant CURVEYIELD_MANAGEMENT_BPS = 50;
    uint256 internal constant CURVEYIELD_PERFORMANCE_BPS = 800;
    uint256 internal constant EXPECTED_TOTAL_MANAGEMENT_BPS = 80;
    uint256 internal constant EXPECTED_TOTAL_PERFORMANCE_BPS = 1000;

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

    function run() external returns (FusionInstanceCyvbUSDCV3 memory instance, address rewardFuse) {
        require(block.chainid == KATANA_CHAIN_ID, "not Katana");

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address keeper = vm.envOr("KEEPER", deployer);
        address finalOwner = vm.envOr("FINAL_OWNER", VAULT_OWNER);

        require(keeper != address(0), "KEEPER=0");
        require(finalOwner != address(0), "FINAL_OWNER=0");

        _verifyExternalDependencies();
        _verifyMiddleWayPackage();
        _verifyRewardRoute();

        vm.startBroadcast(privateKey);

        instance = FACTORY.clone(
            "CurveYield USDC",
            "cyvbUSDC",
            VB_USDC,
            0,
            deployer,
            MIDDLE_WAY_PACKAGE_INDEX
        );

        _configureRoles(instance, deployer, keeper, finalOwner);
        _configurePrices(instance);
        _configureStrategy(instance);
        _configureFees(instance);
        rewardFuse = _configureRewards(instance);
        _makePublic(instance);
        _handover(instance, deployer, finalOwner);

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

    function _configureRoles(
        FusionInstanceCyvbUSDCV3 memory instance_,
        address deployer_,
        address keeper_,
        address finalOwner_
    ) internal {
        IAccessManagerCyvbUSDCV3 access = IAccessManagerCyvbUSDCV3(instance_.accessManager);

        access.grantRole(ATOMIST_ROLE, deployer_, 0);
        access.grantRole(FUSE_MANAGER_ROLE, deployer_, 0);
        access.grantRole(CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE, deployer_, 0);
        access.grantRole(PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, deployer_, 0);

        access.grantRole(ALPHA_ROLE, keeper_, 0);
        access.grantRole(CLAIM_REWARDS_ROLE, keeper_, 0);
        access.grantRole(UPDATE_MARKETS_BALANCES_ROLE, keeper_, 0);

        // Delegatecalled reward fuse calls RewardsClaimManager.updateBalance() from vault context.
        access.grantRole(UPDATE_REWARDS_BALANCE_ROLE, instance_.plasmaVault, 0);

        if (finalOwner_ != deployer_) {
            access.grantRole(OWNER_ROLE, finalOwner_, 0);
            access.grantRole(ATOMIST_ROLE, finalOwner_, 0);
        }
    }

    /// @dev If the deployer is not the owner, it gives up every role it used for setup (owner already granted).
    function _handover(FusionInstanceCyvbUSDCV3 memory instance_, address deployer_, address finalOwner_) internal {
        if (finalOwner_ == deployer_) return;
        IAccessManagerCyvbUSDCV3 access = IAccessManagerCyvbUSDCV3(instance_.accessManager);
        access.renounceRole(PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, deployer_);
        access.renounceRole(CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE, deployer_);
        access.renounceRole(FUSE_MANAGER_ROLE, deployer_);
        access.renounceRole(ATOMIST_ROLE, deployer_);
        access.renounceRole(OWNER_ROLE, deployer_);
    }

    function _configurePrices(FusionInstanceCyvbUSDCV3 memory instance_) internal {
        address[] memory assets = new address[](2);
        address[] memory sources = new address[](2);

        assets[0] = VB_USDC;
        sources[0] = USD_PRICE_FEED;
        assets[1] = KAT;
        sources[1] = KAT_PRICE_SOURCE;

        IPriceManagerCyvbUSDCV3(instance_.priceManager).setAssetsPriceSources(assets, sources);
    }

    function _configureStrategy(FusionInstanceCyvbUSDCV3 memory instance_) internal {
        IPlasmaVaultGovernanceCyvbUSDCV3 vault =
            IPlasmaVaultGovernanceCyvbUSDCV3(instance_.plasmaVault);

        address[] memory fuses = new address[](1);
        fuses[0] = MORPHO_LIQUIDITY_SUPPLY_FUSE;
        vault.addFuses(fuses);

        vault.addBalanceFuse(MORPHO_LIQUIDITY_IN_MARKETS, MORPHO_LIQUIDITY_BALANCE_FUSE);
        vault.addBalanceFuse(ERC20_VAULT_BALANCE_MARKET, ERC20_BALANCE_FUSE);

        bytes32[] memory markets = new bytes32[](3);
        markets[0] = AVKAT_VBUSDC_MARKET;
        markets[1] = SIUSD_VBUSDC_MARKET;
        markets[2] = WEETH_VBUSDC_MARKET;
        vault.grantMarketSubstrates(MORPHO_LIQUIDITY_IN_MARKETS, markets);

        bytes32[] memory residualAssets = new bytes32[](1);
        residualAssets[0] = bytes32(uint256(uint160(KAT)));
        vault.grantMarketSubstrates(ERC20_VAULT_BALANCE_MARKET, residualAssets);

        InstantWithdrawalFuseParamsCyvbUSDCV3[] memory instant =
            new InstantWithdrawalFuseParamsCyvbUSDCV3[](3);

        instant[0] = InstantWithdrawalFuseParamsCyvbUSDCV3({
            fuse: MORPHO_LIQUIDITY_SUPPLY_FUSE,
            params: _instantWithdrawParams(AVKAT_VBUSDC_MARKET)
        });
        instant[1] = InstantWithdrawalFuseParamsCyvbUSDCV3({
            fuse: MORPHO_LIQUIDITY_SUPPLY_FUSE,
            params: _instantWithdrawParams(SIUSD_VBUSDC_MARKET)
        });
        instant[2] = InstantWithdrawalFuseParamsCyvbUSDCV3({
            fuse: MORPHO_LIQUIDITY_SUPPLY_FUSE,
            params: _instantWithdrawParams(WEETH_VBUSDC_MARKET)
        });

        vault.configureInstantWithdrawalFuses(instant);
    }

    function _configureFees(FusionInstanceCyvbUSDCV3 memory instance_) internal {
        IFeeManagerCyvbUSDCV3 feeManager = IFeeManagerCyvbUSDCV3(instance_.feeManager);

        RecipientFeeCyvbUSDCV3[] memory management = new RecipientFeeCyvbUSDCV3[](1);
        management[0] = RecipientFeeCyvbUSDCV3({
            recipient: CURVEYIELD_FEE_RECEIVER,
            feeValue: CURVEYIELD_MANAGEMENT_BPS
        });
        feeManager.updateManagementFee(management);

        RecipientFeeCyvbUSDCV3[] memory performance = new RecipientFeeCyvbUSDCV3[](1);
        performance[0] = RecipientFeeCyvbUSDCV3({
            recipient: CURVEYIELD_FEE_RECEIVER,
            feeValue: CURVEYIELD_PERFORMANCE_BPS
        });
        feeManager.updatePerformanceFee(performance);
    }

    function _configureRewards(FusionInstanceCyvbUSDCV3 memory instance_) internal returns (address rewardFuse) {
        IRewardsClaimManagerCyvbUSDCV3 rewards =
            IRewardsClaimManagerCyvbUSDCV3(instance_.rewardsManager);

        rewards.setupVestingTime(REWARD_VESTING_TIME);

        rewardFuse = address(
            new KatRewardSwapAndSplitFuse_v3(
                instance_.plasmaVault,
                instance_.rewardsManager,
                CURVEYIELD_SWAP_ROUTER
            )
        );

        address[] memory fuses = new address[](2);
        fuses[0] = MERKL_CLAIM_FUSE;
        fuses[1] = rewardFuse;
        rewards.addRewardFuses(fuses);
    }

    function _makePublic(FusionInstanceCyvbUSDCV3 memory instance_) internal {
        IPlasmaVaultGovernanceCyvbUSDCV3 vault =
            IPlasmaVaultGovernanceCyvbUSDCV3(instance_.plasmaVault);
        vault.convertToPublicVault();
        vault.enableTransferShares();
    }

    function _instantWithdrawParams(bytes32 marketId_) internal pure returns (bytes32[] memory params) {
        params = new bytes32[](2);
        params[0] = bytes32(0);
        params[1] = marketId_;
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

    function _verifyMiddleWayPackage() internal view {
        FeePackageCyvbUSDCV3[] memory packages = FACTORY.getDaoFeePackages();
        require(packages.length > MIDDLE_WAY_PACKAGE_INDEX, "Middle Way package missing");

        FeePackageCyvbUSDCV3 memory selected = packages[MIDDLE_WAY_PACKAGE_INDEX];
        require(selected.managementFee == EXPECTED_IPOR_MANAGEMENT_BPS, "IPOR management changed");
        require(selected.performanceFee == EXPECTED_IPOR_PERFORMANCE_BPS, "IPOR performance changed");
        require(selected.feeRecipient != address(0), "IPOR recipient=0");
    }

    function _verifyRewardRoute() internal view {
        require(
            ICurveYieldSushiV3FeeRouterCyvbUSDCV3(CURVEYIELD_SWAP_ROUTER)
                .routeFor(KAT, VB_USDC).length != 0,
            "KAT->vbUSDC route missing"
        );
    }

    function _verifyDeployment(
        FusionInstanceCyvbUSDCV3 memory instance_,
        address rewardFuse_,
        address keeper_
    ) internal view {
        _verifyIdentityAndPrices(instance_);
        _verifyStrategy(instance_);
        _verifyFees(instance_);
        _verifyRewardsAndRoles(instance_, rewardFuse_, keeper_);
        _verifyRewardRoute();
    }

    function _verifyIdentityAndPrices(FusionInstanceCyvbUSDCV3 memory instance_) internal view {
        require(instance_.underlyingToken == VB_USDC, "wrong underlying");
        require(keccak256(bytes(instance_.assetName)) == keccak256(bytes("CurveYield USDC")), "wrong name");
        require(keccak256(bytes(instance_.assetSymbol)) == keccak256(bytes("cyvbUSDC")), "wrong symbol");

        IPriceManagerCyvbUSDCV3 prices = IPriceManagerCyvbUSDCV3(instance_.priceManager);
        require(prices.getSourceOfAssetPrice(VB_USDC) == USD_PRICE_FEED, "vbUSDC source wrong");
        require(prices.getSourceOfAssetPrice(KAT) == KAT_PRICE_SOURCE, "KAT source wrong");
    }

    function _verifyStrategy(FusionInstanceCyvbUSDCV3 memory instance_) internal view {
        IPlasmaVaultGovernanceCyvbUSDCV3 vault =
            IPlasmaVaultGovernanceCyvbUSDCV3(instance_.plasmaVault);

        bytes32[] memory markets = vault.getMarketSubstrates(MORPHO_LIQUIDITY_IN_MARKETS);
        require(markets.length == 3, "wrong Morpho market count");
        require(markets[0] == AVKAT_VBUSDC_MARKET, "avKAT market wrong");
        require(markets[1] == SIUSD_VBUSDC_MARKET, "siUSD market wrong");
        require(markets[2] == WEETH_VBUSDC_MARKET, "weETH market wrong");

        address[] memory instant = vault.getInstantWithdrawalFuses();
        require(instant.length == 3, "wrong instant withdraw count");
        for (uint256 i; i < 3; ++i) {
            require(instant[i] == MORPHO_LIQUIDITY_SUPPLY_FUSE, "wrong instant withdraw fuse");
        }
    }

    function _verifyFees(FusionInstanceCyvbUSDCV3 memory instance_) internal view {
        IFeeManagerCyvbUSDCV3 fees = IFeeManagerCyvbUSDCV3(instance_.feeManager);
        require(fees.getTotalManagementFee() == EXPECTED_TOTAL_MANAGEMENT_BPS, "management total wrong");
        require(fees.getTotalPerformanceFee() == EXPECTED_TOTAL_PERFORMANCE_BPS, "performance total wrong");

        IPlasmaVaultGovernanceCyvbUSDCV3 vault =
            IPlasmaVaultGovernanceCyvbUSDCV3(instance_.plasmaVault);
        require(
            vault.getManagementFeeData().feeInPercentage == EXPECTED_TOTAL_MANAGEMENT_BPS,
            "vault management wrong"
        );
        require(
            vault.getPerformanceFeeData().feeInPercentage == EXPECTED_TOTAL_PERFORMANCE_BPS,
            "vault performance wrong"
        );
    }

    function _verifyRewardsAndRoles(
        FusionInstanceCyvbUSDCV3 memory instance_,
        address rewardFuse_,
        address keeper_
    ) internal view {
        IRewardsClaimManagerCyvbUSDCV3 rewards =
            IRewardsClaimManagerCyvbUSDCV3(instance_.rewardsManager);

        require(rewards.isRewardFuseSupported(MERKL_CLAIM_FUSE), "Merkl not installed");
        require(rewards.isRewardFuseSupported(rewardFuse_), "reward split fuse not installed");
        require(rewards.getVestingData().vestingTime == REWARD_VESTING_TIME, "vesting wrong");

        IAccessManagerCyvbUSDCV3 access = IAccessManagerCyvbUSDCV3(instance_.accessManager);
        (bool alpha,) = access.hasRole(ALPHA_ROLE, keeper_);
        (bool claimer,) = access.hasRole(CLAIM_REWARDS_ROLE, keeper_);
        (bool vaultUpdater,) = access.hasRole(UPDATE_REWARDS_BALANCE_ROLE, instance_.plasmaVault);

        require(alpha, "keeper lacks ALPHA");
        require(claimer, "keeper lacks CLAIM_REWARDS");
        require(vaultUpdater, "vault lacks reward update");
    }
}
