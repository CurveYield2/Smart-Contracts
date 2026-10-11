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
    IRewardsClaimManagerKatana,
    ICurveYieldWithdrawalManager
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

struct CurveYieldControllerV2Dependencies {
    address withdrawManager;
    address rewardsClaimManager;
    address morphoStrategyFuse;
    address vkatStrategyFuse;
    address callerRewardFuse;
    address merklAutoHarvestFuse;
}

interface ICurveYieldControllerV2TargetedManager {
    function releaseFor(address requester_, uint256 timestamp_, uint256 shares_) external;
}

interface ICurveYieldControllerV2Morpho {
    function currentUnwindCostBps() external view returns (uint256 costBps_);
    function quoteUnwindForShares(uint256 shares_)
        external view returns (uint256 costBps_, uint256 extraContributionAvkat_);
    function morphoSnapshot() external view returns (CurveYieldMorphoSnapshot memory snapshot_);
    function totalManagedAvkat() external view returns (uint256 total_);
}

interface ICurveYieldControllerV2VkatReads {
    function vkatAllocationActive() external view returns (bool active_);
    function vkatAllocationBps() external view returns (uint16 allocationBps_);
}

/// @notice Mutable public execution facade which dispatches fixed atomic fuse bundles for cyavKAT.
contract CurveYieldKatanaVaultControllerV2 is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant MAX_PRUNE_BATCH = 500;
    uint8 private constant ACTION_DEPLOY_ASSETS = 0;
    uint8 private constant ACTION_FULFILL_ALL = 2;
    uint8 private constant ACTION_EMERGENCY_REPAY = 3;
    address public immutable VAULT;
    address private constant AVKAT = 0x7231dbaCdFc968E07656D12389AB20De82FbfCeB;

    CurveYieldControllerV2Dependencies private _dependencies;
    bool public harvestActive;
    bool public strategyActive;

    error InvalidAddress(address account_);
    error UnauthorizedStrategyCallback(address caller_);
    error ContributionExceedsMaximum(uint256 amount_, uint256 maximum_);

    event DependenciesUpdated(CurveYieldControllerV2Dependencies dependencies_);
    event AssetsDeployed(address indexed caller_);
    event MerklHarvestDispatched(address indexed caller_);
    event FulfillmentDeferredForPruning();
    event AllWithdrawalsFulfilled(address indexed caller_);
    event TargetWithdrawalFulfilled(address indexed caller_, address indexed requester_);
    event EmergencyRepaymentDispatched(address indexed caller_, uint256 repayKat_);
    event CallerRewardDistributed(address indexed caller_, uint256 amount_);

    constructor(address owner_, address vault_, CurveYieldControllerV2Dependencies memory dependencies_) Ownable(owner_) {
        if (owner_ == address(0)) revert InvalidAddress(owner_);
        if (vault_ == address(0)) revert InvalidAddress(vault_);
        VAULT = vault_;
        _setDependencies(dependencies_);
    }

    function setDependencies(CurveYieldControllerV2Dependencies calldata dependencies_) external onlyOwner {
        _setDependencies(dependencies_);
    }

    function deployAssets() external nonReentrant {
        CurveYieldControllerV2Dependencies memory deps = _dependencies;
        _prune(deps.withdrawManager);
        IRewardsClaimManagerKatana(deps.rewardsClaimManager).transferVestedTokensToVault();
        uint256 rewardBalanceBefore = IERC20(AVKAT).balanceOf(address(this));

        FuseAction[] memory actions = new FuseAction[](5);
        actions[0] = FuseAction(deps.morphoStrategyFuse, abi.encodeWithSignature("deployAssets()"));
        actions[1] = FuseAction(deps.vkatStrategyFuse, abi.encodeWithSignature("publishDeployReward()"));
        actions[2] = FuseAction(deps.morphoStrategyFuse, abi.encodeWithSignature("fundDeployReward()"));
        actions[3] = FuseAction(deps.vkatStrategyFuse, abi.encodeWithSignature("finalizeDeploy()"));
        actions[4] = FuseAction(
            deps.callerRewardFuse,
            abi.encodeWithSignature("enter(uint8,address)", ACTION_DEPLOY_ASSETS, address(this))
        );
        _executeStrategy(actions);

        _distributeCallerReward(msg.sender, rewardBalanceBefore);
        emit AssetsDeployed(msg.sender);
    }

    function harvest(address[] calldata tokens_, uint256[] calldata amounts_, bytes32[][] calldata proofs_)
        external nonReentrant
    {
        CurveYieldControllerV2Dependencies memory deps = _dependencies;
        _prune(deps.withdrawManager);
        uint256 beforeBalance = IERC20(AVKAT).balanceOf(address(this));
        harvestActive = true;
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            deps.merklAutoHarvestFuse,
            abi.encodeWithSignature("harvest(address[],uint256[],bytes32[][])", tokens_, amounts_, proofs_)
        );
        IRewardsClaimManagerKatana(deps.rewardsClaimManager).claimRewards(actions);
        harvestActive = false;
        _distributeCallerReward(msg.sender, beforeBalance);
        emit MerklHarvestDispatched(msg.sender);
    }

    function fulfillAll() external nonReentrant {
        CurveYieldControllerV2Dependencies memory deps = _dependencies;
        (, bool complete) = ICurveYieldWithdrawalManager(deps.withdrawManager).pruneExpiredRequests(MAX_PRUNE_BATCH);
        if (!complete) {
            emit FulfillmentDeferredForPruning();
            return;
        }
        uint256 beforeBalance = IERC20(AVKAT).balanceOf(address(this));
        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = FuseAction(deps.morphoStrategyFuse, abi.encodeWithSignature("fulfillAll()"));
        actions[1] = FuseAction(
            deps.callerRewardFuse,
            abi.encodeWithSignature("enter(uint8,address)", ACTION_FULFILL_ALL, address(this))
        );
        _executeStrategy(actions);
        _distributeCallerReward(msg.sender, beforeBalance);
        emit AllWithdrawalsFulfilled(msg.sender);
    }

    function fulfillFor(address requester_, uint256 shares_, uint256 maxContributionAvkat_) external nonReentrant {
        CurveYieldControllerV2Dependencies memory deps = _dependencies;
        _prune(deps.withdrawManager);
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            deps.morphoStrategyFuse,
            abi.encodeWithSignature(
                "fulfillFor(address,address,uint256,uint256)", msg.sender, requester_, shares_, maxContributionAvkat_
            )
        );
        _executeStrategy(actions);
        emit TargetWithdrawalFulfilled(msg.sender, requester_);
    }

    function emergencyRepay(uint256 repayKat_) external nonReentrant {
        CurveYieldControllerV2Dependencies memory deps = _dependencies;
        _prune(deps.withdrawManager);
        uint256 beforeBalance = IERC20(AVKAT).balanceOf(address(this));
        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = FuseAction(
            deps.morphoStrategyFuse, abi.encodeWithSignature("emergencyRepay(uint256)", repayKat_)
        );
        actions[1] = FuseAction(
            deps.callerRewardFuse,
            abi.encodeWithSignature("enter(uint8,address)", ACTION_EMERGENCY_REPAY, address(this))
        );
        _executeStrategy(actions);
        _distributeCallerReward(msg.sender, beforeBalance);
        emit EmergencyRepaymentDispatched(msg.sender, repayKat_);
    }

    function pruneExpiredRequests() external nonReentrant returns (uint256 processed_, bool complete_) {
        return ICurveYieldWithdrawalManager(_dependencies.withdrawManager).pruneExpiredRequests(MAX_PRUNE_BATCH);
    }

    function currentUnwindCostBps() external view returns (uint256 costBps_) {
        return ICurveYieldControllerV2Morpho(_dependencies.morphoStrategyFuse).currentUnwindCostBps();
    }

    function quoteUnwindForShares(uint256 shares_)
        external view returns (uint256 costBps_, uint256 extraContributionAvkat_)
    {
        return ICurveYieldControllerV2Morpho(_dependencies.morphoStrategyFuse).quoteUnwindForShares(shares_);
    }

    function morphoSnapshot() external view returns (CurveYieldMorphoSnapshot memory snapshot_) {
        return ICurveYieldControllerV2Morpho(_dependencies.morphoStrategyFuse).morphoSnapshot();
    }

    function totalManagedAvkat() external view returns (uint256 total_) {
        return ICurveYieldControllerV2Morpho(_dependencies.morphoStrategyFuse).totalManagedAvkat();
    }

    function releaseActiveSharesFromStrategy(uint256 timestamp_, uint256 shares_) external {
        _requireStrategyCallback();
        ICurveYieldWithdrawalManager(_dependencies.withdrawManager).releaseActiveShares(timestamp_, shares_);
    }

    function releaseForFromStrategy(address requester_, uint256 timestamp_, uint256 shares_) external {
        _requireStrategyCallback();
        ICurveYieldControllerV2TargetedManager(_dependencies.withdrawManager).releaseFor(
            requester_, timestamp_, shares_
        );
    }

    function collectContributionFromStrategy(address caller_, uint256 amount_, uint256 maximum_) external {
        _requireStrategyCallback();
        if (amount_ > maximum_) revert ContributionExceedsMaximum(amount_, maximum_);
        IERC20(AVKAT).safeTransferFrom(caller_, VAULT, amount_);
    }

    function vkatAllocationStatus() external view returns (bool active_, uint16 allocationBps_) {
        ICurveYieldControllerV2VkatReads strategy =
            ICurveYieldControllerV2VkatReads(_dependencies.vkatStrategyFuse);
        return (strategy.vkatAllocationActive(), strategy.vkatAllocationBps());
    }

    function fixedAddresses() external view returns (address[] memory addresses_) {
        addresses_ = new address[](2);
        addresses_[0] = VAULT;
        addresses_[1] = AVKAT;
    }

    function dependencyAddresses() external view returns (address[] memory addresses_) {
        CurveYieldControllerV2Dependencies memory deps = _dependencies;
        addresses_ = new address[](2);
        addresses_[0] = deps.withdrawManager;
        addresses_[1] = deps.rewardsClaimManager;
    }

    function fuseAddresses() external view returns (address[] memory addresses_) {
        CurveYieldControllerV2Dependencies memory deps = _dependencies;
        addresses_ = new address[](4);
        addresses_[0] = deps.morphoStrategyFuse;
        addresses_[1] = deps.vkatStrategyFuse;
        addresses_[2] = deps.callerRewardFuse;
        addresses_[3] = deps.merklAutoHarvestFuse;
    }

    function _setDependencies(CurveYieldControllerV2Dependencies memory deps_) private {
        _requireContract(deps_.withdrawManager);
        _requireContract(deps_.rewardsClaimManager);
        _requireContract(deps_.morphoStrategyFuse);
        _requireContract(deps_.vkatStrategyFuse);
        _requireContract(deps_.callerRewardFuse);
        _requireContract(deps_.merklAutoHarvestFuse);
        _dependencies = deps_;
        emit DependenciesUpdated(deps_);
    }

    function _requireContract(address account_) private view {
        if (account_ == address(0) || account_.code.length == 0) revert InvalidAddress(account_);
    }

    function _distributeCallerReward(address caller_, uint256 balanceBefore_) private {
        uint256 balanceAfter = IERC20(AVKAT).balanceOf(address(this));
        if (balanceAfter <= balanceBefore_) return;
        uint256 amount = balanceAfter - balanceBefore_;
        IERC20(AVKAT).safeTransfer(caller_, amount);
        emit CallerRewardDistributed(caller_, amount);
    }

    function _executeStrategy(FuseAction[] memory actions_) private {
        strategyActive = true;
        IPlasmaVaultKatana(VAULT).execute(actions_);
        strategyActive = false;
    }

    function _requireStrategyCallback() private view {
        if (msg.sender != VAULT || !strategyActive) revert UnauthorizedStrategyCallback(msg.sender);
    }

    function _prune(address withdrawManager_) private {
        ICurveYieldWithdrawalManager(withdrawManager_).pruneExpiredRequests(MAX_PRUNE_BATCH);
    }
}
