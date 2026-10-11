// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    FuseAction,
    IPlasmaVaultKatana,
    ICurveYieldWithdrawalManager,
    IRewardsClaimManagerKatana
} from "./interfaces/CurveYieldKatanaInterfaces.sol";
import {CurveYieldMorphoSnapshot} from "./CurveYieldMorphoStrategyFuse.sol";

/**
 * @title CurveYield System Component
 * @notice CurveYield is a decentralized NGO building optimized DeFi systems for the good of all.
 *
 * @dev CurveYield integrates specialized AMM infrastructure, tokenized yield strategies, credit
 * markets, and protocol-owned liquidity into a unified, capital-efficient liquidity stack governed
 * by an open, international DAO community.
 *
 * Protocol operations are enhanced by cross-chain bridging and messaging, MEV capture systems,
 * off-chain to on-chain automation, and peer-to-peer data networks.
 *
 * This contract is one component of the CurveYield system.
 *
 * CurveYield uses proven DeFi primitives where possible and adds targeted coordination and
 * capital-efficiency-enhancing contracts where needed. Users and integrators must review
 * CurveYield documentation before use.
 *
 * Learn more:
 * Documentation: https://docs.curveyield.com
 * dApp: https://curveyield.online
 * GitHub: https://github.com/curveyield
 *
 * Decentralized links may have limited or delayed availability during periods of high network activity:
 * https://curveyield.eth.limo
 * https://curveyield.dao
 *
 * Note: curveyield.dao may require a Brave Browser or an Unstoppable Domains browser plugin to use.
 */

struct CurveYieldControllerDependencies {
    address withdrawManager;
    address rewardsClaimManager;
    address morphoStrategyFuse;
    address vkatStrategyFuse;
    address callerRewardFuse;
    address merklAutoHarvestFuse;
}

interface ICurveYieldControllerTargetedManager {
    function releaseFor(address requester_, uint256 timestamp_, uint256 shares_) external;
}

interface ICurveYieldControllerMorphoReads {
    function currentUnwindCostBps() external returns (uint256 costBps_);
    function quoteUnwindForShares(uint256 shares_)
        external returns (uint256 costBps_, uint256 extraContributionAvkat_);
    function morphoSnapshot() external view returns (CurveYieldMorphoSnapshot memory snapshot_);
    function totalManagedAvkat() external view returns (uint256 total_);
}

interface ICurveYieldControllerVkatReads {
    function vkatWindowStatus()
        external view returns (bool intoVkat_, uint256 midpoint_, uint256 windowStart_, uint256 windowEnd_);
}

/// @notice Permissionless execution layer which dispatches fixed atomic fuse bundles for cyavKAT.
contract CurveYieldKatanaVaultController is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant MAX_PRUNE_BATCH = 500;
    uint8 private constant ACTION_DEPLOY_ASSETS = 0;
    uint8 private constant ACTION_FULFILL_ALL = 2;
    uint8 private constant ACTION_EMERGENCY_REPAY = 3;
    address private constant VAULT = 0x5E4D67594c2BA85249231D483ebf3C9f55382c37;
    address private constant AVKAT = 0x7231dbaCdFc968E07656D12389AB20De82FbfCeB;

    IPlasmaVaultKatana private immutable PLASMA_VAULT;
    ICurveYieldWithdrawalManager private immutable WITHDRAW_MANAGER;
    IRewardsClaimManagerKatana private immutable REWARDS_MANAGER;
    address private immutable MORPHO_STRATEGY_FUSE;
    address private immutable VKAT_STRATEGY_FUSE;
    address private immutable CALLER_REWARD_FUSE;
    address private immutable MERKL_AUTO_HARVEST_FUSE;

    bool public harvestActive;
    bool public strategyActive;

    error InvalidAddress();
    error UnauthorizedStrategyCallback(address caller_);
    error ContributionExceedsMaximum(uint256 amount_, uint256 maximum_);

    event AssetsDeployed(address indexed caller_);
    event MerklHarvestDispatched(address indexed caller_);
    event FulfillmentDeferredForPruning();
    event AllWithdrawalsFulfilled(address indexed caller_);
    event TargetWithdrawalFulfilled(address indexed caller_, address indexed requester_);
    event EmergencyRepaymentDispatched(address indexed caller_, uint256 repayKat_);
    event CallerRewardDistributed(address indexed caller_, uint256 amount_);

    constructor(address owner_, CurveYieldControllerDependencies memory dependencies_) Ownable(owner_) {
        if (
            owner_ == address(0) || dependencies_.withdrawManager == address(0) ||
            dependencies_.rewardsClaimManager == address(0) || dependencies_.morphoStrategyFuse == address(0) ||
            dependencies_.vkatStrategyFuse == address(0) || dependencies_.callerRewardFuse == address(0) ||
            dependencies_.merklAutoHarvestFuse == address(0)
        ) revert InvalidAddress();
        PLASMA_VAULT = IPlasmaVaultKatana(VAULT);
        WITHDRAW_MANAGER = ICurveYieldWithdrawalManager(dependencies_.withdrawManager);
        REWARDS_MANAGER = IRewardsClaimManagerKatana(dependencies_.rewardsClaimManager);
        MORPHO_STRATEGY_FUSE = dependencies_.morphoStrategyFuse;
        VKAT_STRATEGY_FUSE = dependencies_.vkatStrategyFuse;
        CALLER_REWARD_FUSE = dependencies_.callerRewardFuse;
        MERKL_AUTO_HARVEST_FUSE = dependencies_.merklAutoHarvestFuse;
    }

    function deployAssets() external nonReentrant {
        _prune();
        REWARDS_MANAGER.transferVestedTokensToVault();
        uint256 rewardBalanceBefore = IERC20(AVKAT).balanceOf(address(this));
        FuseAction[] memory actions = new FuseAction[](5);
        actions[0] = FuseAction(VKAT_STRATEGY_FUSE, abi.encodeWithSignature("prepareDeploy()"));
        actions[1] = FuseAction(MORPHO_STRATEGY_FUSE, abi.encodeWithSignature("deployAssets(address)", msg.sender));
        actions[2] = FuseAction(VKAT_STRATEGY_FUSE, abi.encodeWithSignature("publishDeployReward()"));
        actions[3] = FuseAction(
            CALLER_REWARD_FUSE,
            abi.encodeWithSignature("enter(uint8,address)", ACTION_DEPLOY_ASSETS, address(this))
        );
        actions[4] = FuseAction(VKAT_STRATEGY_FUSE, abi.encodeWithSignature("finalizeDeploy()"));
        _executeStrategy(actions);
        _distributeCallerReward(msg.sender, rewardBalanceBefore);
        emit AssetsDeployed(msg.sender);
    }

    function harvest(
        address[] calldata tokens_,
        uint256[] calldata cumulativeAmounts_,
        bytes32[][] calldata proofs_
    ) external nonReentrant {
        _prune();
        uint256 executorBefore = IERC20(AVKAT).balanceOf(address(this));
        harvestActive = true;
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            MERKL_AUTO_HARVEST_FUSE,
            abi.encodeWithSignature("harvest(address[],uint256[],bytes32[][])", tokens_, cumulativeAmounts_, proofs_)
        );
        REWARDS_MANAGER.claimRewards(actions);
        harvestActive = false;
        uint256 executorAfter = IERC20(AVKAT).balanceOf(address(this));
        if (executorAfter > executorBefore) IERC20(AVKAT).safeTransfer(msg.sender, executorAfter - executorBefore);
        emit MerklHarvestDispatched(msg.sender);
    }

    function fulfillAll() external nonReentrant {
        (, bool complete) = WITHDRAW_MANAGER.pruneExpiredRequests(MAX_PRUNE_BATCH);
        if (!complete) {
            emit FulfillmentDeferredForPruning();
            return;
        }
        FuseAction[] memory actions = new FuseAction[](2);
        uint256 rewardBalanceBefore = IERC20(AVKAT).balanceOf(address(this));
        actions[0] = FuseAction(MORPHO_STRATEGY_FUSE, abi.encodeWithSignature("fulfillAll(address)", msg.sender));
        actions[1] = FuseAction(
            CALLER_REWARD_FUSE,
            abi.encodeWithSignature("enter(uint8,address)", ACTION_FULFILL_ALL, address(this))
        );
        _executeStrategy(actions);
        _distributeCallerReward(msg.sender, rewardBalanceBefore);
        emit AllWithdrawalsFulfilled(msg.sender);
    }

    function fulfillFor(address requester_, uint256 shares_, uint256 maxContributionAvkat_) external nonReentrant {
        _prune();
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            MORPHO_STRATEGY_FUSE,
            abi.encodeWithSignature(
                "fulfillFor(address,address,uint256,uint256)",
                msg.sender, requester_, shares_, maxContributionAvkat_
            )
        );
        _executeStrategy(actions);
        emit TargetWithdrawalFulfilled(msg.sender, requester_);
    }

    function emergencyRepay(uint256 repayKat_) external nonReentrant {
        _prune();
        FuseAction[] memory actions = new FuseAction[](2);
        uint256 rewardBalanceBefore = IERC20(AVKAT).balanceOf(address(this));
        actions[0] = FuseAction(
            MORPHO_STRATEGY_FUSE,
            abi.encodeWithSignature("emergencyRepay(address,uint256)", msg.sender, repayKat_)
        );
        actions[1] = FuseAction(
            CALLER_REWARD_FUSE,
            abi.encodeWithSignature("enter(uint8,address)", ACTION_EMERGENCY_REPAY, address(this))
        );
        _executeStrategy(actions);
        _distributeCallerReward(msg.sender, rewardBalanceBefore);
        emit EmergencyRepaymentDispatched(msg.sender, repayKat_);
    }

    function pruneExpiredRequests() external nonReentrant returns (uint256 processed_, bool complete_) {
        return WITHDRAW_MANAGER.pruneExpiredRequests(MAX_PRUNE_BATCH);
    }

    function currentUnwindCostBps() external returns (uint256 costBps_) {
        return ICurveYieldControllerMorphoReads(MORPHO_STRATEGY_FUSE).currentUnwindCostBps();
    }

    function quoteUnwindForShares(uint256 shares_)
        external returns (uint256 costBps_, uint256 extraContributionAvkat_)
    {
        return ICurveYieldControllerMorphoReads(MORPHO_STRATEGY_FUSE).quoteUnwindForShares(shares_);
    }

    function morphoSnapshot() external view returns (CurveYieldMorphoSnapshot memory snapshot_) {
        return ICurveYieldControllerMorphoReads(MORPHO_STRATEGY_FUSE).morphoSnapshot();
    }

    function totalManagedAvkat() external view returns (uint256 total_) {
        return ICurveYieldControllerMorphoReads(MORPHO_STRATEGY_FUSE).totalManagedAvkat();
    }

    function vkatWindowStatus()
        external view returns (bool intoVkat_, uint256 midpoint_, uint256 windowStart_, uint256 windowEnd_)
    {
        return ICurveYieldControllerVkatReads(VKAT_STRATEGY_FUSE).vkatWindowStatus();
    }

    function releaseActiveSharesFromStrategy(uint256 timestamp_, uint256 shares_) external {
        _requireStrategyCallback();
        WITHDRAW_MANAGER.releaseActiveShares(timestamp_, shares_);
    }

    function releaseForFromStrategy(address requester_, uint256 timestamp_, uint256 shares_) external {
        _requireStrategyCallback();
        ICurveYieldControllerTargetedManager(address(WITHDRAW_MANAGER)).releaseFor(requester_, timestamp_, shares_);
    }

    function collectContributionFromStrategy(address caller_, uint256 amount_, uint256 maximum_) external {
        _requireStrategyCallback();
        if (amount_ > maximum_) revert ContributionExceedsMaximum(amount_, maximum_);
        IERC20(AVKAT).safeTransferFrom(caller_, VAULT, amount_);
    }

    function fixedAddresses() external pure returns (address[] memory addresses_) {
        addresses_ = new address[](2);
        addresses_[0] = VAULT;
        addresses_[1] = AVKAT;
    }

    function dependencyAddresses() external view returns (address[] memory addresses_) {
        addresses_ = new address[](2);
        addresses_[0] = address(WITHDRAW_MANAGER);
        addresses_[1] = address(REWARDS_MANAGER);
    }

    function fuseAddresses() external view returns (address[] memory addresses_) {
        addresses_ = new address[](4);
        addresses_[0] = MORPHO_STRATEGY_FUSE;
        addresses_[1] = VKAT_STRATEGY_FUSE;
        addresses_[2] = CALLER_REWARD_FUSE;
        addresses_[3] = MERKL_AUTO_HARVEST_FUSE;
    }

    function _executeStrategy(FuseAction[] memory actions_) private {
        strategyActive = true;
        PLASMA_VAULT.execute(actions_);
        strategyActive = false;
    }

    function _distributeCallerReward(address caller_, uint256 balanceBefore_) private {
        uint256 balanceAfter = IERC20(AVKAT).balanceOf(address(this));
        if (balanceAfter <= balanceBefore_) return;
        uint256 amount = balanceAfter - balanceBefore_;
        IERC20(AVKAT).safeTransfer(caller_, amount);
        emit CallerRewardDistributed(caller_, amount);
    }

    function _requireStrategyCallback() private view {
        if (msg.sender != VAULT || !strategyActive) revert UnauthorizedStrategyCallback(msg.sender);
    }

    function _prune() private {
        WITHDRAW_MANAGER.pruneExpiredRequests(MAX_PRUNE_BATCH);
    }
}
