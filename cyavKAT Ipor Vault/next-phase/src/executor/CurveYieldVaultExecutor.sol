// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FuseAction} from "../interfaces/CurveYieldPhase2Interfaces.sol";
import {CurveYieldAllocationController, CySets} from "../allocation/CurveYieldAllocationController.sol";
import {CurveYieldMorphoLoopController} from "../morpho/CurveYieldMorphoLoopController.sol";
import {CurveYieldPolController} from "../pol/CurveYieldPolController.sol";
import {ICyPlasmaVault, ICyRewardsClaimManager} from "../interfaces/CurveYieldPhase2Interfaces.sol";
import {CurveYieldGateConfig, CurveYieldConfigKeys as K} from "../governance/CurveYieldGateConfig.sol";
import {
    RequestSourcesData, RequestPolSaleData, RequestSettleData
} from "../withdraw/CurveYieldWithdrawalRequestFuse.sol";
import {RouterSweepData} from "../router/CurveYieldRouterSwapFuseV2.sol";

/// @notice Withdraw manager v2 surface the executor uses (it is the manager's controller).
interface ICyWmV2 {
    function settleOnboardingFee() external returns (uint256);
    function pruneExpiredRequests(uint256 maxEntries) external returns (uint256 processed, bool complete);
    function activeUnreleasedShares() external view returns (uint256);
    function availableSharesOf(address requester) external view returns (uint256);
    function assetsNeededFor(uint256 shares) external view returns (uint256);
    function releasableShares() external view returns (uint256);
    function getRequestFee() external view returns (uint256);
    function releaseActiveShares(uint256 timestamp, uint256 shares) external returns (uint256 feeSharesBurned);
    function releaseFor(address requester, uint256 timestamp, uint256 shares) external returns (uint256 feeSharesBurned);
    function chargeRequestForAssets(address requester, uint256 assets, uint256 maxShares) external returns (uint256 shares);
    function earnRequestFeesForLoss(uint256 lossAssets, uint256 keepBps) external returns (uint256 earned);
}

interface ICyVkatLane {
    function planNativeExitStartFor(uint256 neededAvkat, address withdrawManager, uint256 keepBps)
        external view returns (uint256 shortfall, uint256 exitAvkat, FuseAction[] memory actions);
    function laneMaxAvkat(address withdrawManager, uint256 keepBps) external view returns (uint256);
    function planNativeExitBeginUpTo(uint256 maxAvkat) external view returns (FuseAction[] memory);
    function planNativeExitComplete() external view returns (FuseAction[] memory);
    function planNativeExitCompleteEarly(uint256 tokenId) external view returns (FuseAction[] memory);
    function earlyExitPremiumKat(uint256 tokenId) external view returns (uint256);
    function lastLockId() external view returns (uint256);
    function sync(uint256 lastLockIdBefore, bool newLockIsPosition) external;
}

/// @notice PPS backstop (PPS spec B5): pays avKAT into the vault to cancel a measured emergency loss.
interface ICyPpsBackstop {
    function cover(uint256 lossAvkat) external returns (uint256 paid);
}

interface ICyGuardWrap {
    function wrap(address vault, FuseAction[] calldata actions, uint256 maxPpsDropBps) external view returns (FuseAction[] memory);
    function wrapWithGain(address vault, FuseAction[] calldata actions, uint256 minGainAssets) external view returns (FuseAction[] memory);
}

interface ICyAllocationPlans {
    function planDeploy() external view returns (FuseAction[] memory main, FuseAction[] memory pol, uint256 idle);
    function planReduces() external view returns (address[5] memory sets, FuseAction[][5] memory plans);
    function withdrawSources() external view returns (address[] memory planners);
}

interface ICyLoopExec {
    function planLtvRebalance() external view returns (FuseAction[] memory);
    function planCollateralTopUp() external view returns (FuseAction[] memory);
    function planEmergency(uint256 repayKat) external view returns (FuseAction[] memory);
    function allowedLossBps() external view returns (uint256);
}

interface ICyLpEmergency {
    function planEmergency() external view returns (FuseAction[] memory);
}

interface ICyLendRecord {
    function managedAvkat() external view returns (uint256);
    function recordReduction(uint256 amount) external;
}

interface ICyPolExec {
    function planBurnHeld() external view returns (FuseAction[] memory);
    function planBuyback() external view returns (FuseAction[] memory actions, uint256 minGainAvkat);
    function recordBuyback() external;
    function syncBpt(bool buyback) external;
    function settlePolStep(uint256 providedAvkat, uint256 costAvkat, uint256 requestFeeBps)
        external view returns (uint256 floor, uint256 shortAvkat, uint256 yieldFee);
}

/// @notice Executor wiring. Sets live on the allocation controller; this holds everything else.
struct CyExecutorDeps {
    address allocation;
    address withdrawManager;
    address rewardsClaimManager;
    address merklClaimFuse; // IPOR's official MerklClaimFuse (reward fuse, vault context)
    address swapFuse; // CurveYieldRouterSwapFuseV2: the harvest sweep (reward fuse)
    address transferFuse; // CurveYieldErc20TransferFuse: the deploy keeper reward
    address kat; // native-exit lane: early-completion premiums are paid in KAT
    address guardFuse; // CurveYieldBundleGuardFuse
    address requestFuse; // CurveYieldWithdrawalRequestFuse: fulfilment phases 1 / 2 (and the manager's fee shares)
}

/// @title CurveYieldVaultExecutor
/// @notice Public executor for cyavKAT. It only EXECUTES: every plan, number and policy comes from the contract that
/// owns it (allocation / strategy controllers plan, the governance gate holds the settings and keeper-reward rates,
/// the withdraw manager the request numbers, the withdrawal request fuse the settlement). Holds vault ALPHA and is the withdraw manager's
/// controller. Every bundle either keeps the share price or is paid for (PPS protection spec).
contract CurveYieldVaultExecutor is Ownable2Step, ReentrancyGuard, CurveYieldGateConfig {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;
    uint256 private constant MAX_PRUNE_BATCH = 500;
    uint256 public constant MAX_PAY_AVKAT = 10e18; // hard ceiling on one keeper reward (as the gate's hard cap)

    address public immutable VAULT;
    address public immutable AVKAT;

    CyExecutorDeps private _deps;
    /// @notice PPS backstops, drawn in order before a caller pays anything (PPS spec B5); e.g. the revenue custody v2.
    address[] private _backstops;

    error InvalidAddress();
    error NoScheduledRequests();
    error NothingReleasable();
    error PruningIncomplete();
    error UnwindLossAboveFee(uint256 lossAvkat, uint256 allowedAvkat);
    error NoVkatSet();
    error PremiumAboveMaximum(uint256 premiumKat, uint256 maximumKat);
    error NothingToComplete();
    error OnlySelf();
    error PayAboveCeiling(uint256 amount);
    error LaneNotCovered();
    error PpsDropped(uint256 shortfallAvkat);
    error CallerPayAboveMaximum(uint256 payAvkat, uint256 maxPayAvkat);

    event DependenciesUpdated(CyExecutorDeps deps);
    event BackstopsUpdated(address[] backstops);
    event AssetsDeployed(address indexed caller, uint256 deployedAvkat, uint256 reward);
    event NothingToDeploy(address indexed caller);
    event WithdrawalsFulfilled(
        address indexed caller, address indexed requester, uint256 shares, uint256 lossAvkat, uint256 feeSharesBurned, uint256 reward
    );
    event Rebalanced(address indexed caller, uint256 actions);
    event EmergencyDeleveraged(address indexed caller, uint256 repayKat);
    event EmergencyLossCovered(uint256 lossAvkat, uint256 backstopAvkat, uint256 callerAvkat);
    event HarvestDispatched(address indexed caller, uint256 reward);
    event NativeExitStarted(address indexed caller, uint256 shortfallAvkat, uint256 exitAvkat);
    event NativeExitsBegun(address indexed caller, uint256 count);
    event NativeExitsCompleted(address indexed caller, uint256 count, uint256 lossAvkat, uint256 premiumKat);
    event LaneFeesEarned(uint256 lossAvkat, uint256 feeShares);
    event StepSkipped(address indexed set, bytes reason);

    constructor(address owner_, address vault_, address avkat_, CyExecutorDeps memory deps_, address configGate_)
        Ownable(owner_)
        CurveYieldGateConfig(configGate_)
    {
        if (vault_ == address(0) || avkat_ == address(0)) revert InvalidAddress();
        VAULT = vault_;
        AVKAT = avkat_;
        _setDeps(deps_);
    }

    // ---------------------------------------------------------------- configuration (wiring only)

    function setDependencies(CyExecutorDeps calldata deps_) external onlyOwner {
        _setDeps(deps_);
    }

    /// @notice PPS backstops in the order they are drawn (PPS spec B5). Each must pay the vault in the same call.
    function setBackstops(address[] calldata backstops_) external onlyOwner {
        for (uint256 i; i < backstops_.length; ++i) if (backstops_[i] == address(0)) revert InvalidAddress();
        _backstops = backstops_;
        emit BackstopsUpdated(backstops_);
    }

    function backstops() external view returns (address[] memory) {
        return _backstops;
    }

    function dependencies() external view returns (CyExecutorDeps memory) {
        return _deps;
    }

    // ---------------------------------------------------------------- deploy / rebalance

    /// @notice With scheduled requests: re-lever the loop into idle and release what idle covers. Without: POL
    /// maintenance, the free collateral top-up, the allocation controller's deploy plan (one guarded bundle), then the
    /// POL entry and every reduce plan as their own guarded steps. The caller reward comes only out of the gain.
    function deployAssets() external nonReentrant {
        CyExecutorDeps memory d = _deps;
        _prune(d.withdrawManager, false);
        ICyRewardsClaimManager(d.rewardsClaimManager).transferVestedTokensToVault();
        // ONBOARDING_FEE_SPEC: pay out the onboarding fee shares (best effort: never blocks a deploy)
        try ICyWmV2(d.withdrawManager).settleOnboardingFee() {} catch {}
        CurveYieldAllocationController allocation = CurveYieldAllocationController(d.allocation);
        allocation.checkpoint();
        CySets memory s = allocation.sets();

        if (ICyWmV2(d.withdrawManager).activeUnreleasedShares() != 0) {
            if (s.loop != address(0)) _tryGuarded(s.loop, ICyLoopExec(s.loop).planLtvRebalance());
            _fulfilWith(d, s, address(0), 0, false, 0, 0, false);
            _syncPol(s.pol);
            return;
        }

        _polMaintenance(s.pol);
        _topUpLoop(s.loop);
        uint256 lockIdBefore = _vkatBefore(s.vkat);
        (FuseAction[] memory actions, FuseAction[] memory polDeploy, uint256 idleBefore) =
            ICyAllocationPlans(d.allocation).planDeploy();
        (uint256 assetsBefore, uint256 supplyBefore) = _ppsSnapshot();
        if (actions.length != 0) ICyPlasmaVault(VAULT).execute(_guarded(actions));
        _tryGuarded(s.pol, polDeploy);
        uint256 steps = actions.length + polDeploy.length + _runReduces(s);
        _syncPol(s.pol);
        if (steps == 0) {
            emit NothingToDeploy(msg.sender);
            return;
        }
        _vkatSync(s.vkat, lockIdBefore, true);
        uint256 idleAfter = IERC20(AVKAT).balanceOf(VAULT);
        uint256 deployed = idleBefore > idleAfter ? idleBefore - idleAfter : 0;
        uint256 reward = _reward(K.EXEC_DEPLOY_REWARD_BPS, K.EXEC_DEPLOY_REWARD_CAP, deployed, _ppsGain(assetsBefore, supplyBefore));
        _pay(d, reward);
        emit AssetsDeployed(msg.sender, deployed, reward);
    }

    /// @notice The loop's LTV re-lever, the free collateral top-up (no pending requests) and every reduce plan, each
    /// as its own guarded step: a step that would lower the share price is skipped.
    function rebalance() external nonReentrant {
        CyExecutorDeps memory d = _deps;
        CurveYieldAllocationController allocation = CurveYieldAllocationController(d.allocation);
        allocation.checkpoint();
        CySets memory s = allocation.sets();
        uint256 lockIdBefore = _vkatBefore(s.vkat);
        uint256 steps;
        if (s.loop != address(0)) {
            steps += _tryGuarded(s.loop, ICyLoopExec(s.loop).planLtvRebalance());
            if (ICyWmV2(d.withdrawManager).activeUnreleasedShares() == 0) steps += _topUpLoop(s.loop);
        }
        steps += _runReduces(s);
        _syncPol(s.pol);
        if (steps != 0) _vkatSync(s.vkat, lockIdBefore, false);
        emit Rebalanced(msg.sender, steps);
    }

    // ---------------------------------------------------------------- scheduled withdrawals

    /// @notice Frees avKAT from the withdrawal sources (in the allocation controller's order) and releases as many
    /// requested shares as it covers, the request fee burned in the same call.
    function fulfillAll() external nonReentrant {
        CyExecutorDeps memory d = _deps;
        _prune(d.withdrawManager, true);
        CySets memory s = CurveYieldAllocationController(d.allocation).sets();
        _fulfilWith(d, s, address(0), 0, true, 0, 0, false);
        _syncPol(s.pol);
    }

    /// @notice Same as fulfillAll for one requester. `shares_` 0 = all of the requester's available shares.
    function fulfillFor(address requester_, uint256 shares_) external nonReentrant {
        _fulfillFor(requester_, shares_, 0);
    }

    /// @notice fulfillFor that may also fund the request from POL: the part that would leave the vault below its
    /// minimum profit is charged to this requester (burned from their request), at most `maxChargeShares_`.
    function fulfillFor(address requester_, uint256 shares_, uint256 maxChargeShares_) external nonReentrant {
        _fulfillFor(requester_, shares_, maxChargeShares_);
    }

    /// @dev Runs a (guarded) bundle for a try/catch step without ever reverting the caller.
    function executeSelf(FuseAction[] calldata actions_) external {
        if (msg.sender != address(this)) revert OnlySelf();
        ICyPlasmaVault(VAULT).execute(actions_);
    }

    function pruneExpiredRequests() external nonReentrant returns (uint256 processed_, bool complete_) {
        return ICyWmV2(_deps.withdrawManager).pruneExpiredRequests(MAX_PRUNE_BATCH);
    }

    function _fulfillFor(address requester_, uint256 shares_, uint256 maxChargeShares_) private {
        if (requester_ == address(0)) revert InvalidAddress();
        CyExecutorDeps memory d = _deps;
        _prune(d.withdrawManager, true);
        CySets memory s = CurveYieldAllocationController(d.allocation).sets();
        _fulfilWith(d, s, requester_, shares_, true, 0, maxChargeShares_, false);
        _syncPol(s.pol);
    }

    // ---------------------------------------------------------------- emergencies (PPS spec B5)

    /// @notice Emergency de-leverage of the loop (only above the emergency LTV): first the free collateral top-up,
    /// then the swap-based de-leverage; its loss is paid in the same transaction by the backstops, in order, and only
    /// then by the caller (at most `maxCallerPayAvkat_`). If they cannot cover it, nothing runs.
    function emergencyRepay(uint256 repayKat_, uint256 maxCallerPayAvkat_) external nonReentrant {
        CySets memory s = CurveYieldAllocationController(_deps.allocation).sets();
        _topUpLoop(s.loop);
        FuseAction[] memory actions = ICyLoopExec(s.loop).planEmergency(repayKat_);
        if (actions.length == 0) return;
        (uint256 assetsBefore, uint256 supplyBefore) = _ppsSnapshot();
        ICyPlasmaVault(VAULT).execute(actions);
        _coverLoss(assetsBefore, supplyBefore, maxCallerPayAvkat_);
        emit EmergencyDeleveraged(msg.sender, repayKat_);
    }

    /// @notice Emergency de-leverage of the LP holder's Morpho position; its loss is paid like emergencyRepay's.
    function lpEmergency(uint256 maxCallerPayAvkat_) external nonReentrant {
        CySets memory s = CurveYieldAllocationController(_deps.allocation).sets();
        if (s.lp == address(0)) return;
        FuseAction[] memory actions = ICyLpEmergency(s.lp).planEmergency();
        if (actions.length == 0) return;
        (uint256 assetsBefore, uint256 supplyBefore) = _ppsSnapshot();
        ICyPlasmaVault(VAULT).execute(actions);
        _coverLoss(assetsBefore, supplyBefore, maxCallerPayAvkat_);
        emit EmergencyDeleveraged(msg.sender, 0);
    }

    // ---------------------------------------------------------------- harvest

    /// @notice Merkl harvest in one reward bundle through the rewards claim manager: IPOR's official MerklClaimFuse
    /// claims (the listed tokens stay in the vault), the swap fuse converts them into avKAT through the swap router v2,
    /// pays the keeper reward (gate rate, capped) to this executor and sends the rest to the rewards claim manager to
    /// vest. The reward is passed on to the caller.
    function harvest(address[] calldata tokens_, uint256[] calldata amounts_, bytes32[][] calldata proofs_)
        external nonReentrant
    {
        CyExecutorDeps memory d = _deps;
        uint256 before = IERC20(AVKAT).balanceOf(address(this));
        bytes32[] memory k = new bytes32[](2);
        (k[0], k[1]) = (K.EXEC_HARVEST_REWARD_BPS, K.EXEC_HARVEST_REWARD_CAP);
        uint256[] memory rate = _config(k);
        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = FuseAction(d.merklClaimFuse, abi.encodeWithSignature(
            "claim(address[],uint256[],bytes32[][],address[])", tokens_, amounts_, proofs_, tokens_
        ));
        actions[1] = FuseAction(d.swapFuse, abi.encodeWithSignature(
            "sweep((address[],address,uint256,uint256,address))",
            RouterSweepData(tokens_, AVKAT, rate[0], rate[1] > MAX_PAY_AVKAT ? MAX_PAY_AVKAT : rate[1], address(this))
        ));
        ICyRewardsClaimManager(d.rewardsClaimManager).claimRewards(actions);
        ICyRewardsClaimManager(d.rewardsClaimManager).updateBalance(); // start vesting what the sweep sent
        uint256 received = IERC20(AVKAT).balanceOf(address(this)) - before;
        if (received != 0) IERC20(AVKAT).safeTransfer(msg.sender, received);
        emit HarvestDispatched(msg.sender, received);
    }

    // ---------------------------------------------------------------- native-exit lane

    /// @notice Starts vKAT exits for the scheduled-request shortfall (sized by the vKAT controller). The queue fee
    /// they book is paid in the same transaction by the served requests' escrowed request fees; the transaction
    /// reverts unless the share price ends at or above its start (PPS spec A1).
    function startNativeExit() external nonReentrant {
        CyExecutorDeps memory d = _deps;
        CySets memory s = CurveYieldAllocationController(d.allocation).sets();
        if (s.vkat == address(0) || s.loop == address(0)) revert NoVkatSet();
        ICyWmV2 manager = ICyWmV2(d.withdrawManager);
        uint256 active = manager.activeUnreleasedShares();
        if (active == 0) revert NoScheduledRequests();
        (uint256 shortfall, uint256 exitAvkat, FuseAction[] memory actions) = ICyVkatLane(s.vkat)
            .planNativeExitStartFor(manager.assetsNeededFor(active), d.withdrawManager, _keepBps(s.loop));
        if (shortfall == 0) return;
        if (exitAvkat == 0) revert LaneNotCovered();
        _runLane(d, s, actions);
        emit NativeExitStarted(msg.sender, shortfall, exitAvkat);
    }

    /// @notice Begins the exits of lane NFTs prepared in an earlier block, as many as the escrowed fees can pay for.
    function beginNativeExits() external nonReentrant {
        CyExecutorDeps memory d = _deps;
        CySets memory s = CurveYieldAllocationController(d.allocation).sets();
        if (s.vkat == address(0)) revert NoVkatSet();
        ICyVkatLane lane = ICyVkatLane(s.vkat);
        FuseAction[] memory actions =
            lane.planNativeExitBeginUpTo(lane.laneMaxAvkat(d.withdrawManager, _keepBps(s.loop)));
        if (actions.length == 0) revert LaneNotCovered();
        _runLane(d, s, actions);
        emit NativeExitsBegun(msg.sender, actions.length);
    }

    /// @notice Completes every exit at the minimum fee (60 days), then releases the covered shares.
    function completeNativeExits() external nonReentrant {
        CyExecutorDeps memory d = _deps;
        CySets memory s = CurveYieldAllocationController(d.allocation).sets();
        if (s.vkat == address(0)) revert NoVkatSet();
        FuseAction[] memory actions = ICyVkatLane(s.vkat).planNativeExitComplete();
        if (actions.length == 0) revert NothingToComplete();
        uint256 lockIdBefore = _vkatBefore(s.vkat);
        (uint256 assetsBefore, uint256 supplyBefore) = _ppsSnapshot();
        ICyPlasmaVault(VAULT).execute(actions);
        uint256 loss = _ppsLoss(assetsBefore, supplyBefore); // the queue fee was paid at start / begin
        _vkatSync(s.vkat, lockIdBefore, false);
        _fulfilWith(d, s, address(0), 0, false, loss, 0, false);
        emit NativeExitsCompleted(msg.sender, actions.length, loss, 0);
    }

    /// @notice Completes one exit now: the caller pays the queue fee above its minimum in KAT (the vKAT controller's
    /// quote, at most `maxPremiumKat_`); a loss the request fee cannot absorb reverts.
    function completeNativeExitEarly(uint256 tokenId_, uint256 maxPremiumKat_) external nonReentrant {
        CyExecutorDeps memory d = _deps;
        CySets memory s = CurveYieldAllocationController(d.allocation).sets();
        if (s.vkat == address(0)) revert NoVkatSet();
        if (ICyVkatLane(s.vkat).planNativeExitCompleteEarly(tokenId_).length == 0) revert NothingToComplete();
        uint256 premium = ICyVkatLane(s.vkat).earlyExitPremiumKat(tokenId_);
        if (premium > maxPremiumKat_) revert PremiumAboveMaximum(premium, maxPremiumKat_);
        (uint256 assetsBefore, uint256 supplyBefore) = _ppsSnapshot();
        if (premium != 0) IERC20(d.kat).safeTransferFrom(msg.sender, VAULT, premium);
        FuseAction[] memory actions = ICyVkatLane(s.vkat).planNativeExitCompleteEarly(tokenId_); // planned after the premium
        uint256 lockIdBefore = _vkatBefore(s.vkat);
        ICyPlasmaVault(VAULT).execute(actions);
        _vkatSync(s.vkat, lockIdBefore, false);
        uint256 loss = _ppsLoss(assetsBefore, supplyBefore);
        _fulfilWith(d, s, address(0), 0, false, loss, 0, true);
        emit NativeExitsCompleted(msg.sender, 1, loss, premium);
    }

    // ---------------------------------------------------------------- execution internals

    /// @dev POL-funded part of one fulfilment (POL spec 3c).
    struct PolStep {
        uint256 provided;
        uint256 cost;
        uint256 floor;
        uint256 chargedShares;
        uint256 chargedAvkat;
        uint256 yieldFee;
    }

    /// @dev Phase 1 (request fuse: sources, POL sale) -> charge / release (this executor, the manager's controller) ->
    /// phase 2 (request fuse: settlement). `strict_`: a loss the fee cannot absorb reverts even without sources.
    function _fulfilWith(
        CyExecutorDeps memory d_, CySets memory s_, address requester_, uint256 shares_, bool useSources_,
        uint256 preLossAvkat_, uint256 maxChargeShares_, bool strict_
    ) private {
        ICyWmV2 manager = ICyWmV2(d_.withdrawManager);
        uint256 wanted = requester_ == address(0) ? manager.activeUnreleasedShares() : manager.availableSharesOf(requester_);
        if (shares_ != 0 && shares_ < wanted) wanted = shares_;
        if (wanted == 0) {
            if (useSources_) revert NoScheduledRequests();
            return;
        }
        uint256 lossAvkat = preLossAvkat_;
        PolStep memory pol;
        if (useSources_) {
            uint256 needed = manager.assetsNeededFor(wanted);
            uint256 idle = IERC20(AVKAT).balanceOf(VAULT);
            if (needed > idle) lossAvkat += _runWithdrawSources(d_, s_, needed - idle);
            if (s_.pol != address(0)) {
                needed = manager.assetsNeededFor(wanted);
                idle = IERC20(AVKAT).balanceOf(VAULT);
                if (needed > idle) {
                    pol = _polStep(d_, manager, s_.pol, requester_, needed - idle, maxChargeShares_);
                    lossAvkat += pol.cost > pol.chargedAvkat ? pol.cost - pol.chargedAvkat : 0;
                }
            }
        }
        uint256 releasable = manager.releasableShares();
        uint256 shares = wanted < releasable ? wanted : releasable;
        if (shares == 0) {
            if (useSources_) revert NothingReleasable();
            return;
        }
        uint256 releasedAssets = ICyPlasmaVault(VAULT).previewRedeem(shares);
        uint256 allowed = s_.loop == address(0) ? 0 : releasedAssets * ICyLoopExec(s_.loop).allowedLossBps() / BPS;
        if (lossAvkat > allowed) {
            if (useSources_ || strict_) revert UnwindLossAboveFee(lossAvkat, allowed);
            return;
        }
        uint256 feeShares;
        if (useSources_) {
            feeShares = requester_ == address(0)
                ? manager.releaseActiveShares(block.timestamp - 1, shares)
                : manager.releaseFor(requester_, block.timestamp - 1, shares);
        } else {
            try manager.releaseActiveShares(block.timestamp - 1, shares) returns (uint256 burned) {
                feeShares = burned;
            } catch {
                return;
            }
        }
        _settle(d_, s_, requester_, shares, releasedAssets, lossAvkat, feeShares, pol);
    }

    /// @dev Phase 2 through the request fuse (its settings come from the gate); the keeper reward it pays to this
    /// executor goes on to the caller.
    function _settle(
        CyExecutorDeps memory d_, CySets memory s_, address requester_, uint256 shares_, uint256 releasedAssets_,
        uint256 lossAvkat_, uint256 feeShares_, PolStep memory pol_
    ) private {
        uint256 before = IERC20(AVKAT).balanceOf(address(this));
        FuseAction[] memory one = new FuseAction[](1);
        one[0] = FuseAction(d_.requestFuse, abi.encodeWithSignature(
            "settle((address,uint256,uint256,uint256,uint256,address,uint256,uint256,uint256,uint256,uint256))",
            RequestSettleData({
                requester: requester_, shares: shares_, releasedAssets: releasedAssets_, lossAvkat: lossAvkat_,
                feeShares: feeShares_, polController: s_.pol, polProvided: pol_.provided, polCost: pol_.cost,
                polChargedShares: pol_.chargedShares, polFloor: pol_.floor, polYieldFee: pol_.yieldFee
            })
        ));
        ICyPlasmaVault(VAULT).execute(one);
        ICyRewardsClaimManager(d_.rewardsClaimManager).updateBalance(); // a split leg may have paid it (role 1100)
        uint256 reward = IERC20(AVKAT).balanceOf(address(this)) - before;
        if (reward != 0) IERC20(AVKAT).safeTransfer(msg.sender, reward);
        emit WithdrawalsFulfilled(msg.sender, requester_, shares_, lossAvkat_, feeShares_, reward);
    }

    /// @dev Phase 1a through the request fuse (the allocation controller's source order); returns the loss in
    /// share-price terms.
    function _runWithdrawSources(CyExecutorDeps memory d_, CySets memory s_, uint256 neededAvkat_) private returns (uint256) {
        FuseAction[] memory one = new FuseAction[](1);
        one[0] = FuseAction(d_.requestFuse, abi.encodeWithSignature(
            "runSources((uint256,address[]))",
            RequestSourcesData(neededAvkat_, ICyAllocationPlans(d_.allocation).withdrawSources())
        ));
        (uint256 assetsBefore, uint256 supplyBefore) = _ppsSnapshot();
        uint256 lockIdBefore = _vkatBefore(s_.vkat);
        ICyPlasmaVault(VAULT).execute(one);
        _vkatSync(s_.vkat, lockIdBefore, false);
        return _ppsLoss(assetsBefore, supplyBefore);
    }

    /// @dev Phase 1b through the request fuse (the POL controller plans the sale); the POL controller settles the numbers
    /// and a charged requester pays what keeps the vault at its minimum (through the withdraw manager).
    function _polStep(
        CyExecutorDeps memory d_, ICyWmV2 manager_, address pol_, address requester_, uint256 neededAvkat_, uint256 maxChargeShares_
    ) private returns (PolStep memory r_) {
        uint256 feeBps = manager_.getRequestFee() * BPS / WAD;
        bool charged = maxChargeShares_ != 0 && requester_ != address(0);
        FuseAction[] memory one = new FuseAction[](1);
        one[0] = FuseAction(d_.requestFuse, abi.encodeWithSignature(
            "runPolSale((address,uint256,uint256,bool))", RequestPolSaleData(pol_, neededAvkat_, feeBps, charged)
        ));
        uint256 idleBefore = IERC20(AVKAT).balanceOf(VAULT);
        (uint256 assetsBefore, uint256 supplyBefore) = _ppsSnapshot();
        ICyPlasmaVault(VAULT).execute(one);
        r_.cost = _ppsLoss(assetsBefore, supplyBefore);
        uint256 idleAfter = IERC20(AVKAT).balanceOf(VAULT);
        r_.provided = idleAfter > idleBefore ? idleAfter - idleBefore : 0;
        if (r_.provided == 0) return r_;
        uint256 short;
        (r_.floor, short, r_.yieldFee) = ICyPolExec(pol_).settlePolStep(r_.provided, r_.cost, feeBps);
        if (short != 0) {
            if (!charged) revert UnwindLossAboveFee(r_.cost, r_.cost > short ? r_.cost - short : 0);
            r_.chargedAvkat = short;
            r_.chargedShares = manager_.chargeRequestForAssets(requester_, short, maxChargeShares_);
        }
    }

    /// @dev POL maintenance inside deployAssets, never reverting the deploy: burn held cyavKAT (no drop allowed), then
    /// the automatic buyback, which must RAISE the share price by at least its guaranteed net gain.
    function _polMaintenance(address pol_) private {
        if (pol_ == address(0)) return;
        ICyPolExec c = ICyPolExec(pol_);
        c.syncBpt(false); // book every POL change since the last sync (e.g. instant exits)
        _tryGuarded(pol_, c.planBurnHeld());
        (FuseAction[] memory buyback, uint256 minGain) = c.planBuyback();
        if (buyback.length == 0 || _deps.guardFuse == address(0)) return;
        try this.executeSelf(ICyGuardWrap(_deps.guardFuse).wrapWithGain(VAULT, buyback, minGain)) {
            c.recordBuyback();
            c.syncBpt(true);
        } catch (bytes memory reason) {
            emit StepSkipped(pol_, reason);
        }
    }

    function _syncPol(address pol_) private {
        if (pol_ != address(0)) ICyPolExec(pol_).syncBpt(false);
    }

    /// @dev Executes a lane bundle, earns (and burns) request fees worth the loss it booked (the withdraw manager
    /// converts), and requires the share price to end at or above its start (PPS spec A1.4).
    function _runLane(CyExecutorDeps memory d_, CySets memory s_, FuseAction[] memory actions_) private {
        (uint256 assetsBefore, uint256 supplyBefore) = _ppsSnapshot();
        uint256 lockIdBefore = _vkatBefore(s_.vkat);
        ICyPlasmaVault(VAULT).execute(actions_);
        _vkatSync(s_.vkat, lockIdBefore, false);
        uint256 loss = _ppsLoss(assetsBefore, supplyBefore);
        if (loss == 0) return;
        uint256 earned = ICyWmV2(d_.withdrawManager).earnRequestFeesForLoss(loss, _keepBps(s_.loop));
        emit LaneFeesEarned(loss, earned);
        if (_ppsShortfall(assetsBefore, supplyBefore) != 0) revert LaneNotCovered();
    }

    /// @dev Pays an emergency's measured loss — the backstops in order, then the caller up to `maxCallerPay_` — and
    /// requires the share price back at or above the snapshot (PPS spec B5).
    function _coverLoss(uint256 assetsBefore_, uint256 supplyBefore_, uint256 maxCallerPay_) private {
        uint256 loss = _ppsLoss(assetsBefore_, supplyBefore_);
        if (loss == 0) return;
        uint256 fromBackstops;
        for (uint256 i; i < _backstops.length; ++i) {
            uint256 left = _ppsShortfall(assetsBefore_, supplyBefore_);
            if (left == 0) break;
            try ICyPpsBackstop(_backstops[i]).cover(left) returns (uint256 paid) {
                fromBackstops += paid;
            } catch {}
        }
        uint256 fromCaller = _ppsShortfall(assetsBefore_, supplyBefore_);
        if (fromCaller != 0) {
            if (fromCaller > maxCallerPay_) revert CallerPayAboveMaximum(fromCaller, maxCallerPay_);
            IERC20(AVKAT).safeTransferFrom(msg.sender, VAULT, fromCaller);
            uint256 left = _ppsShortfall(assetsBefore_, supplyBefore_);
            if (left != 0) revert PpsDropped(left);
        }
        emit EmergencyLossCovered(loss, fromBackstops, fromCaller);
    }

    /// @dev One set's plan as its own guarded step (no share-price drop); a failure is skipped and reported.
    function _tryGuarded(address set_, FuseAction[] memory actions_) private returns (uint256) {
        if (actions_.length == 0) return 0;
        try this.executeSelf(_guarded(actions_)) {} catch (bytes memory reason) {
            emit StepSkipped(set_, reason);
        }
        return actions_.length;
    }

    /// @dev Each set's reduce plan (from the allocation controller) as its own guarded step; a lending reduction is
    /// recorded with the amount actually withdrawn.
    function _runReduces(CySets memory s_) private returns (uint256 steps_) {
        (address[5] memory sets, FuseAction[][5] memory plans) = ICyAllocationPlans(_deps.allocation).planReduces();
        for (uint256 i; i < 5; ++i) {
            if (plans[i].length == 0) continue;
            bool lend = sets[i] == s_.lend;
            uint256 before = lend ? ICyLendRecord(sets[i]).managedAvkat() : 0;
            steps_ += _tryGuarded(sets[i], plans[i]);
            if (lend) {
                uint256 afterAmount = ICyLendRecord(sets[i]).managedAvkat();
                if (before > afterAmount) ICyLendRecord(sets[i]).recordReduction(before - afterAmount);
            }
        }
    }

    /// @dev The free collateral top-up (PPS spec B5.1), as a guarded step.
    function _topUpLoop(address loop_) private returns (uint256) {
        if (loop_ == address(0)) return 0;
        return _tryGuarded(loop_, ICyLoopExec(loop_).planCollateralTopUp());
    }

    function _guarded(FuseAction[] memory actions_) private view returns (FuseAction[] memory) {
        address guard = _deps.guardFuse;
        if (guard == address(0) || actions_.length == 0) return actions_;
        return ICyGuardWrap(guard).wrap(VAULT, actions_, 0);
    }

    // ---------------------------------------------------------------- measurement

    /// @dev Fresh total assets (every market revalued; role 1000) and supply.
    function _ppsSnapshot() private returns (uint256 assets_, uint256 supply_) {
        assets_ = _refreshedTotalAssets();
        supply_ = ICyPlasmaVault(VAULT).totalSupply();
    }

    /// @dev Revalues every market, then the avKAT the vault is short of the snapshot share price.
    function _ppsLoss(uint256 assetsBefore_, uint256 supplyBefore_) private returns (uint256) {
        _refreshedTotalAssets();
        return _ppsShortfall(assetsBefore_, supplyBefore_);
    }

    function _ppsShortfall(uint256 assetsBefore_, uint256 supplyBefore_) private view returns (uint256) {
        ICyPlasmaVault vault = ICyPlasmaVault(VAULT);
        uint256 supply = vault.totalSupply();
        uint256 scaled = supply == 0 ? assetsBefore_ : Math.mulDiv(vault.totalAssets(), supplyBefore_, supply);
        return assetsBefore_ > scaled ? assetsBefore_ - scaled : 0;
    }

    function _ppsGain(uint256 assetsBefore_, uint256 supplyBefore_) private returns (uint256) {
        uint256 assets = _refreshedTotalAssets();
        uint256 supply = ICyPlasmaVault(VAULT).totalSupply();
        uint256 scaled = supply == 0 ? 0 : Math.mulDiv(assets, supplyBefore_, supply);
        return scaled > assetsBefore_ ? scaled - assetsBefore_ : 0;
    }

    function _refreshedTotalAssets() private returns (uint256) {
        ICyPlasmaVault vault = ICyPlasmaVault(VAULT);
        return vault.updateMarketsBalances(vault.getActiveMarketsInBalanceFuses());
    }

    // ---------------------------------------------------------------- helpers

    /// @dev The gate's keeper reward for this action (bps of the basis, capped), never more than the call gained.
    function _reward(bytes32 bpsKey_, bytes32 capKey_, uint256 basis_, uint256 spare_) private view returns (uint256 r_) {
        if (basis_ == 0 || spare_ == 0) return 0;
        bytes32[] memory k = new bytes32[](2);
        (k[0], k[1]) = (bpsKey_, capKey_);
        uint256[] memory v = _config(k);
        r_ = basis_ * v[0] / BPS;
        if (r_ > v[1]) r_ = v[1];
        if (r_ > spare_) r_ = spare_;
        if (r_ > MAX_PAY_AVKAT) r_ = MAX_PAY_AVKAT;
    }

    function _pay(CyExecutorDeps memory d_, uint256 amount_) private {
        if (amount_ == 0) return;
        FuseAction[] memory one = new FuseAction[](1);
        one[0] = _payAction(d_, amount_);
        ICyPlasmaVault(VAULT).execute(one);
        IERC20(AVKAT).safeTransfer(msg.sender, amount_);
    }

    function _payAction(CyExecutorDeps memory d_, uint256 amount_) private view returns (FuseAction memory) {
        if (amount_ > MAX_PAY_AVKAT) revert PayAboveCeiling(amount_);
        return FuseAction(d_.transferFuse, abi.encodeWithSignature("enter((address,address,uint256))", AVKAT, address(this), amount_));
    }

    function _keepBps(address loop_) private view returns (uint256) {
        return CurveYieldMorphoLoopController(loop_).params().minUnwindProfitBps;
    }

    function _vkatBefore(address vkat_) private view returns (uint256) {
        return vkat_ == address(0) ? 0 : ICyVkatLane(vkat_).lastLockId();
    }

    function _vkatSync(address vkat_, uint256 lockIdBefore_, bool deploy_) private {
        if (vkat_ != address(0)) ICyVkatLane(vkat_).sync(lockIdBefore_, deploy_);
    }

    function _prune(address manager_, bool requireComplete_) private {
        (, bool complete) = ICyWmV2(manager_).pruneExpiredRequests(MAX_PRUNE_BATCH);
        if (requireComplete_ && !complete) revert PruningIncomplete();
    }

    function _setDeps(CyExecutorDeps memory d_) private {
        if (d_.allocation == address(0) || d_.withdrawManager == address(0) || d_.rewardsClaimManager == address(0) ||
            d_.merklClaimFuse == address(0) || d_.swapFuse == address(0) || d_.transferFuse == address(0) ||
            d_.kat == address(0) || d_.guardFuse == address(0) || d_.requestFuse == address(0)) {
            revert InvalidAddress();
        }
        _deps = d_;
        emit DependenciesUpdated(d_);
    }
}
