// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FuseAction, ICyStrategySet} from "../interfaces/CurveYieldPhase2Interfaces.sol";
import {CurveYieldAllocationController, CySets} from "../allocation/CurveYieldAllocationController.sol";
import {CurveYieldMorphoLoopController} from "../morpho/CurveYieldMorphoLoopController.sol";
import {ICyPlasmaVault, ICyRewardsClaimManager} from "../interfaces/CurveYieldPhase2Interfaces.sol";
import {CurveYieldGateConfig, CurveYieldConfigKeys as K, CurveYieldAddrKeys} from "../governance/CurveYieldGateConfig.sol";
import {CurveYieldBundleLib} from "../libraries/CurveYieldBundleLib.sol";
import {CurveYieldManagementFeePpsLib as FeePps} from "../libraries/CurveYieldManagementFeePpsLib.sol";
import {CurveYieldErc20TransferFuse, CurveYieldErc20TransferFuseEnterData} from "../generic/CurveYieldErc20TransferFuse.sol";

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
}

/// @notice PPS backstop (PPS spec B5): pays avKAT into the vault to cancel a measured emergency loss.
interface ICyPpsBackstop {
    function cover(uint256 lossAvkat) external returns (uint256 paid);
}

interface ICyAllocationPlans {
    function planDeploy()
        external view returns (FuseAction[] memory main, FuseAction[] memory pol, uint256 idle, uint256 loopBudget);
    function planReduces() external view returns (address[4] memory sets, FuseAction[][4] memory plans);
    function withdrawSources() external view returns (address[] memory planners);
}

interface ICyLoopExec {
    function planCycle(uint256 supplyAvkat)
        external view returns (FuseAction[] memory actions, uint256 directAvkat, uint256 requiredGainAvkat);
    function needsRelever() external view returns (bool);
    function planCollateralTopUp() external view returns (FuseAction[] memory);
    function planEmergency(uint256 repayKat) external view returns (FuseAction[] memory);
    function allowedLossBps() external view returns (uint256);
}

interface ICyUsdcExec {
    function planRebalance() external view returns (FuseAction[] memory);
}

interface ICyLendRecord {
    function managedAvkat() external view returns (uint256);
    function recordReduction(uint256 amount) external;
}

interface ICyPolExec {
    function planBurnHeld() external view returns (FuseAction[] memory);
    function planBuyback() external view returns (FuseAction[] memory actions, uint256 minGainAvkat);
    function planReduceFallback(uint256 managedTotal) external view returns (FuseAction[] memory);
    function planPolStep(uint256 neededAvkat, uint256 requestFeeBps, bool charged)
        external view returns (FuseAction[] memory attempt, FuseAction[] memory fallbackActions, uint256 plannedAvkat);
    function yieldFeeAction(uint256 amount) external view returns (FuseAction memory);
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
    address transferFuse; // CurveYieldErc20TransferFuse: keeper rewards and the profit split legs
    address guardFuse; // CurveYieldBundleGuardFuse
}

/// @title CurveYieldVaultExecutor
/// @notice Public executor for cyavKAT. It only EXECUTES, and every decision is made ON-CHAIN here (no off-chain logic,
/// D13): plans, numbers and policy come from the contract that owns them (allocation / strategy controllers plan, the
/// governance gate holds the settings and keeper-reward rates, the withdraw manager the request numbers). It holds vault
/// ALPHA and is the withdraw manager's controller, and it calls `vault.execute` several times in one transaction, wrapping
/// each call in `try/catch` where a bundle may fail without failing the transaction (a reverted `execute` rolls back
/// only that bundle):
///   - B1 loop wind-up: one cycle per `execute`, up to `maxCycles`, stopping at the first cycle that reverts;
///   - B2 POL sell-or-burn: `try execute(exit + sale)`, on revert `execute(exit + burn)`;
///   - settlement of a fulfilment: ordinary transfer-fuse bundles from the measured profit.
/// Every bundle either keeps the share price or is paid for (PPS protection spec).
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
    error OnlySelf();
    error PayAboveCeiling(uint256 amount);
    error PpsDropped(uint256 shortfallAvkat);
    error CallerPayAboveMaximum(uint256 payAvkat, uint256 maxPayAvkat);
    error InvalidProfitSplit();
    error InvalidProfitRecipient(address recipient);

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
    event LoopCycled(address indexed loop, uint256 cycle, uint256 producedAvkat, uint256 gainAvkat, uint256 splitOutAvkat);
    event PolSoldOrBurned(address indexed pol, bool sold);
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
    /// maintenance, the free collateral top-up, the loop's wind-up cycles (B1), the allocation controller's deploy plan
    /// (one guarded bundle), then the POL entry and every reduce plan as their own guarded steps. The caller reward comes
    /// only out of the gain.
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
            _windUp(d, s.loop, WindArgs(0, true, true));
            _fulfilWith(d, s, FulfilArgs(address(0), 0, false, 0, 0, false));
            _syncPol(s.pol);
            return;
        }

        _polMaintenance(d, s.pol);
        _topUpLoop(d, s.loop);
        (FuseAction[] memory actions, FuseAction[] memory polDeploy, uint256 idleBefore, uint256 loopBudget) =
            ICyAllocationPlans(d.allocation).planDeploy();
        (uint256 assetsBefore, uint256 supplyBefore) = _ppsSnapshot();
        uint256 steps = _windUp(d, s.loop, WindArgs(loopBudget, false, false));
        if (actions.length != 0) {
            ICyPlasmaVault(VAULT).execute(_guarded(d, actions));
            steps += actions.length;
        }
        steps += _tryGuarded(d, s.pol, polDeploy) + _runReduces(d, s);
        _syncPol(s.pol);
        if (steps == 0) {
            emit NothingToDeploy(msg.sender);
            return;
        }
        uint256 idleAfter = IERC20(AVKAT).balanceOf(VAULT);
        uint256 deployed = idleBefore > idleAfter ? idleBefore - idleAfter : 0;
        uint256 reward = _reward(K.EXEC_DEPLOY_REWARD_BPS, K.EXEC_DEPLOY_REWARD_CAP, deployed, _ppsGain(assetsBefore, supplyBefore));
        _pay(d, reward);
        emit AssetsDeployed(msg.sender, deployed, reward);
    }

    /// @notice The loop's LTV re-lever, the free collateral top-up (no pending requests), the USDC strategy's LTV
    /// rebalance and every reduce plan, each as its own guarded step: a step that would lower the share price is skipped.
    function rebalance() external nonReentrant {
        CyExecutorDeps memory d = _deps;
        CurveYieldAllocationController allocation = CurveYieldAllocationController(d.allocation);
        allocation.checkpoint();
        CySets memory s = allocation.sets();
        uint256 steps;
        if (s.loop != address(0)) {
            steps += _windUp(d, s.loop, WindArgs(0, ICyWmV2(d.withdrawManager).activeUnreleasedShares() != 0, true));
            if (ICyWmV2(d.withdrawManager).activeUnreleasedShares() == 0) steps += _topUpLoop(d, s.loop);
        }
        if (s.usdc != address(0)) steps += _tryGuarded(d, s.usdc, ICyUsdcExec(s.usdc).planRebalance());
        steps += _runReduces(d, s);
        _syncPol(s.pol);
        emit Rebalanced(msg.sender, steps);
    }

    // ---------------------------------------------------------------- scheduled withdrawals

    /// @notice Frees avKAT from the withdrawal sources (in the allocation controller's order) and releases as many
    /// requested shares as it covers, the request fee burned in the same call.
    function fulfillAll() external nonReentrant {
        CyExecutorDeps memory d = _deps;
        _prune(d.withdrawManager, true);
        CySets memory s = CurveYieldAllocationController(d.allocation).sets();
        _fulfilWith(d, s, FulfilArgs(address(0), 0, true, 0, 0, false));
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
        _fulfilWith(d, s, FulfilArgs(requester_, shares_, true, 0, maxChargeShares_, false));
        _syncPol(s.pol);
    }

    // ---------------------------------------------------------------- emergencies (PPS spec B5)

    /// @notice Emergency de-leverage of the loop (only above the emergency LTV): first the free collateral top-up,
    /// then the swap-based de-leverage; its loss is paid in the same transaction by the backstops, in order, and only
    /// then by the caller (at most `maxCallerPayAvkat_`). If they cannot cover it, nothing runs.
    function emergencyRepay(uint256 repayKat_, uint256 maxCallerPayAvkat_) external nonReentrant {
        CyExecutorDeps memory d = _deps;
        CySets memory s = CurveYieldAllocationController(d.allocation).sets();
        _topUpLoop(d, s.loop);
        FuseAction[] memory actions = ICyLoopExec(s.loop).planEmergency(repayKat_);
        if (actions.length == 0) return;
        (uint256 assetsBefore, uint256 supplyBefore) = _ppsSnapshot();
        ICyPlasmaVault(VAULT).execute(actions);
        _coverLoss(assetsBefore, supplyBefore, maxCallerPayAvkat_);
        emit EmergencyDeleveraged(msg.sender, repayKat_);
    }

    // ---------------------------------------------------------------- B1: loop wind-up, one cycle per execute

    /// @dev Up to `maxCycles` cycles. Each asks the loop planner for ONE cycle (its amounts and required profit from the
    /// pre-cycle state) and runs it in `try vault.execute`; the guard in the bundle reverts it unless assets per share rose
    /// by the required profit, and router v2 enforces its protected minimum on the swap. The first cycle that reverts (or that
    /// the planner finds unprofitable) stops the loop, as the former per-cycle fuse did. After a successful cycle the realised
    /// gain (what the swap produced above the conversion value of the KAT borrowed) is split by internal gate-driven legs.
    /// `leaveIdle_`: keep the produced avKAT idle (withdrawals wait for it). `relever_`: no new supply, only re-lever.
    function _windUp(CyExecutorDeps memory d_, address loop_, WindArgs memory w_) private returns (uint256 cycles_) {
        uint256 budget_ = w_.budget;
        bool leaveIdle_ = w_.leaveIdle;
        bool relever_ = w_.relever;
        if (loop_ == address(0)) return 0;
        ICyLoopExec loop = ICyLoopExec(loop_);
        if (relever_ && !loop.needsRelever()) return 0;
        uint256 supply;
        if (!leaveIdle_ && !relever_) {
            uint256 idle = IERC20(AVKAT).balanceOf(VAULT);
            supply = budget_ > idle ? idle : budget_;
        }
        uint256 maxCycles = CurveYieldMorphoLoopController(loop_).params().maxCycles;
        for (uint256 i; i < maxCycles; ++i) {
            (FuseAction[] memory actions, uint256 direct,) = loop.planCycle(supply);
            if (actions.length == 0) break;
            uint256 idleBefore = IERC20(AVKAT).balanceOf(VAULT);
            try this.executeSelf(actions) {} catch (bytes memory reason) {
                emit StepSkipped(loop_, reason);
                break;
            }
            uint256 produced = IERC20(AVKAT).balanceOf(VAULT) + supply - idleBefore;
            uint256 gain = produced > direct ? produced - direct : 0;
            uint256 out = _splitGain(d_, gain);
            ++cycles_;
            emit LoopCycled(loop_, i, produced, gain, out);
            supply = leaveIdle_ ? 0 : produced - out;
        }
    }

    /// @notice The four configured legs are read directly from the governance gate; the vault keeps the rounding remainder.
    function profitSplit(uint256 amount_)
        public view returns (uint256 growth_, uint256 contributors_, uint256 vault_, uint256 rewardsManager_)
    {
        bytes32[] memory keys = new bytes32[](4);
        (keys[0], keys[1], keys[2], keys[3]) =
            (K.SPLIT_GROWTH_BPS, K.SPLIT_CONTRIBUTORS_BPS, K.SPLIT_VAULT_BPS, K.SPLIT_REWARDS_MANAGER_BPS);
        uint256[] memory values = _config(keys);
        if (values[0] + values[1] + values[2] + values[3] != BPS) revert InvalidProfitSplit();
        growth_ = Math.mulDiv(amount_, values[0], BPS);
        contributors_ = Math.mulDiv(amount_, values[1], BPS);
        rewardsManager_ = Math.mulDiv(amount_, values[3], BPS);
        vault_ = amount_ - growth_ - contributors_ - rewardsManager_;
    }

    /// @dev Replaces ONLY the retired external loop-profit splitter. This allocates the pre-existing
    /// vault-loop gain; it never receives or re-splits the original Profit Custody's internal payout.
    /// The full growth leg goes to the gate-configured recipient (V2 custody after P6), with no POL skim.
    function _profitLegs(uint256 amount_, CyExecutorDeps memory deps_)
        private view returns (FuseAction[] memory legs_, uint256 paidOut_, address custody_)
    {
        (uint256 growth, uint256 contributors,, uint256 rewards) = profitSplit(amount_);
        custody_ = _addr(CurveYieldAddrKeys.LOOP_GROWTH_RECIPIENT);
        address contributorsRecipient = _addr(CurveYieldAddrKeys.LOOP_CONTRIBUTORS_RECIPIENT);
        address rewardsRecipient = _addr(CurveYieldAddrKeys.REWARDS_CLAIM_MANAGER);
        if (custody_ == address(0) || custody_ == VAULT || contributorsRecipient == address(0)
            || rewardsRecipient != deps_.rewardsClaimManager || contributorsRecipient == VAULT
            || contributorsRecipient == custody_ || contributorsRecipient == rewardsRecipient || rewardsRecipient == custody_)
            revert InvalidProfitRecipient(contributorsRecipient);
        paidOut_ = growth + contributors + rewards;
        uint256 n = (growth != 0 ? 1 : 0) + (contributors != 0 ? 1 : 0) + (rewards != 0 ? 1 : 0);
        legs_ = new FuseAction[](n);
        uint256 i;
        if (growth != 0) legs_[i++] = _profitTransfer(deps_.transferFuse, custody_, growth);
        if (contributors != 0) legs_[i++] = _profitTransfer(deps_.transferFuse, contributorsRecipient, contributors);
        if (rewards != 0) legs_[i++] = _profitTransfer(deps_.transferFuse, rewardsRecipient, rewards);
    }

    function _profitTransfer(address fuse_, address recipient_, uint256 amount_) private view returns (FuseAction memory) {
        return FuseAction(fuse_, abi.encodeWithSignature("enter((address,address,uint256))", AVKAT, recipient_, amount_));
    }

    /// @dev Best-effort existing vault-loop profit allocation; transfers do not touch Profit Custody's own split.
    function _splitGain(CyExecutorDeps memory d_, uint256 gain_) private returns (uint256 out_) {
        if (gain_ == 0) return 0;
        (FuseAction[] memory legs, uint256 paid, address custody) = _profitLegs(gain_, d_);
        if (legs.length == 0) return 0;
        try this.executeSelf(legs) {
            out_ = paid;
            (,,, uint256 toRewardsManager) = profitSplit(gain_);
            if (toRewardsManager != 0) ICyRewardsClaimManager(d_.rewardsClaimManager).updateBalance();
        } catch (bytes memory reason) {
            emit StepSkipped(custody, reason);
        }
    }

    // ---------------------------------------------------------------- execution internals

    /// @dev Arguments travel in memory structs (not as literals) so the optimizer does not clone the large functions once per
    /// call site (the FunctionSpecializer clones per distinct constant argument).
    struct WindArgs {
        uint256 budget;
        bool leaveIdle;
        bool relever;
    }

    struct FulfilArgs {
        address requester;
        uint256 shares;
        bool useSources;
        uint256 preLoss;
        uint256 maxCharge;
        bool strict;
    }

    /// @dev POL-funded part of one fulfilment (POL spec 3c).
    struct PolStep {
        uint256 provided;
        uint256 cost;
        uint256 floor;
        uint256 chargedShares;
        uint256 chargedAvkat;
        uint256 yieldFee;
    }

    /// @dev Phase 1 (sources, POL sale) -> charge / release (this executor, the manager's controller) -> phase 2 (settlement).
    /// `strict_`: a loss the fee cannot absorb reverts even without sources.
    function _fulfilWith(CyExecutorDeps memory d_, CySets memory s_, FulfilArgs memory f_) private {
        address requester_ = f_.requester;
        uint256 shares_ = f_.shares;
        bool useSources_ = f_.useSources;
        uint256 preLossAvkat_ = f_.preLoss;
        uint256 maxChargeShares_ = f_.maxCharge;
        bool strict_ = f_.strict;
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
            if (needed > idle) lossAvkat += _runWithdrawSources(d_, needed - idle);
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
        _settle(d_, requester_, shares, releasedAssets, lossAvkat, feeShares, pol, s_.pol);
    }

    /// @dev Phase 2: this fulfilment's real profit (its burned fee minus its own loss, minus the POL minimum and the admin
    /// yield fee) is split, and the keeper reward (the gate's exec.fulfilReward rate / cap, never above the profit) is
    /// paid to this executor and passed on to the caller: ordinary transfer-fuse bundles, nothing is paid out of principal.
    function _settle(
        CyExecutorDeps memory d_, address requester_, uint256 shares_, uint256 releasedAssets_, uint256 lossAvkat_,
        uint256 feeShares_, PolStep memory pol_, address polController_
    ) private {
        uint256 before = IERC20(AVKAT).balanceOf(address(this));
        uint256 profit = _fulfilmentProfit(feeShares_, lossAvkat_, pol_);
        uint256 yieldFee = pol_.yieldFee > profit ? profit : pol_.yieldFee;
        profit -= yieldFee;
        uint256 reward = _fulfilReward(releasedAssets_, profit);

        FuseAction[] memory legs;
        if (profit > reward) {
            (legs,,) = _profitLegs(profit - reward, d_);
        }
        uint256 n = legs.length + (yieldFee != 0 ? 1 : 0) + (reward != 0 ? 1 : 0);
        if (n != 0) {
            FuseAction[] memory settleActions = new FuseAction[](n);
            uint256 k;
            if (yieldFee != 0) settleActions[k++] = ICyPolExec(polController_).yieldFeeAction(yieldFee);
            for (uint256 i; i < legs.length; ++i) settleActions[k++] = legs[i];
            if (reward != 0) settleActions[k] = _payAction(d_, reward);
            ICyPlasmaVault(VAULT).execute(settleActions);
        }
        ICyRewardsClaimManager(d_.rewardsClaimManager).updateBalance(); // a split leg may have paid it (role 1100)
        uint256 paid = IERC20(AVKAT).balanceOf(address(this)) - before;
        if (paid != 0) IERC20(AVKAT).safeTransfer(msg.sender, paid);
        emit WithdrawalsFulfilled(msg.sender, requester_, shares_, lossAvkat_, feeShares_, paid);

    }

    function _fulfilmentProfit(uint256 feeShares_, uint256 lossAvkat_, PolStep memory pol_) private view returns (uint256 profit_) {
        uint256 supply = ICyPlasmaVault(VAULT).totalSupply();
        uint256 feeAssets = feeShares_ == 0 ? 0 : feeShares_ * ICyPlasmaVault(VAULT).totalAssets() / (supply + feeShares_);
        profit_ = feeAssets > lossAvkat_ ? feeAssets - lossAvkat_ : 0;
        profit_ = profit_ > pol_.floor ? profit_ - pol_.floor : 0;
    }

    /// @dev The gate's fulfilment reward: exec.fulfilRewardBps of the released assets, capped by exec.fulfilRewardCap
    /// (and MAX_PAY_AVKAT) and by this fulfilment's profit, so it is never paid out of principal.
    function _fulfilReward(uint256 releasedAssets_, uint256 profit_) private view returns (uint256 reward_) {
        return _reward(K.EXEC_FULFIL_REWARD_BPS, K.EXEC_FULFIL_REWARD_CAP, releasedAssets_, profit_);
    }

    /// @dev Phase 1a: the allocation controller's source order, each planner planning with fresh state; the bundles the
    /// planners return carry their own bounded-loss guard. Returns the loss in share-price terms.
    function _runWithdrawSources(CyExecutorDeps memory d_, uint256 neededAvkat_) private returns (uint256) {
        address[] memory planners = ICyAllocationPlans(d_.allocation).withdrawSources();
        (uint256 assetsBefore, uint256 supplyBefore) = _ppsSnapshot();
        uint256 remaining = neededAvkat_;
        for (uint256 i; i < planners.length && remaining != 0; ++i) {
            (FuseAction[] memory actions, uint256 provided) = ICyStrategySet(planners[i]).planWithdraw(remaining, true);
            if (actions.length == 0) continue;
            ICyPlasmaVault(VAULT).execute(actions);
            remaining -= provided > remaining ? remaining : provided;
        }
        return _ppsLoss(assetsBefore, supplyBefore);
    }

    /// @dev Phase 1b (B2): the POL controller plans the exit and the sale; the executor tries the sale and, if it reverts,
    /// burns instead. The POL controller then settles the numbers and a charged requester pays what keeps the vault at its
    /// minimum (through the withdraw manager).
    function _polStep(
        CyExecutorDeps memory d_, ICyWmV2 manager_, address pol_, address requester_, uint256 neededAvkat_, uint256 maxChargeShares_
    ) private returns (PolStep memory r_) {
        uint256 feeBps = manager_.getRequestFee() * BPS / WAD;
        bool charged = maxChargeShares_ != 0 && requester_ != address(0);
        (FuseAction[] memory attempt, FuseAction[] memory fallbackActions, uint256 planned) =
            ICyPolExec(pol_).planPolStep(neededAvkat_, feeBps, charged);
        if (planned == 0) return r_;
        uint256 idleBefore = IERC20(AVKAT).balanceOf(VAULT);
        (uint256 assetsBefore, uint256 supplyBefore) = _ppsSnapshot();
        _sellOrBurn(pol_, attempt, fallbackActions, false, d_);
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

    /// @dev B2: `try execute(attempt)`, on revert `execute(fallback)`. `guarded_`: bracket each with the no-drop guard.
    function _sellOrBurn(
        address pol_, FuseAction[] memory attempt_, FuseAction[] memory fallbackActions_, bool guarded_, CyExecutorDeps memory d_
    ) private returns (bool ok_) {
        try this.executeSelf(guarded_ ? _guarded(d_, attempt_) : attempt_) {
            ok_ = true;
        } catch {
            ICyPlasmaVault(VAULT).execute(guarded_ ? _guarded(d_, fallbackActions_) : fallbackActions_);
        }
        emit PolSoldOrBurned(pol_, ok_);
    }

    /// @dev POL maintenance inside deployAssets, never reverting the deploy: burn held cyavKAT (no drop allowed), then
    /// the automatic buyback, which must RAISE the share price by at least its guaranteed net gain.
    function _polMaintenance(CyExecutorDeps memory d_, address pol_) private {
        if (pol_ == address(0)) return;
        ICyPolExec c = ICyPolExec(pol_);
        c.syncBpt(false); // book every POL change since the last sync (e.g. instant exits)
        _tryGuarded(d_, pol_, c.planBurnHeld());
        (FuseAction[] memory buyback, uint256 minGain) = c.planBuyback();
        if (buyback.length == 0) return;
        try this.executeSelf(CurveYieldBundleLib.wrapWithGain(d_.guardFuse, VAULT, buyback, minGain)) {
            c.recordBuyback();
            c.syncBpt(true);
        } catch (bytes memory reason) {
            emit StepSkipped(pol_, reason);
        }
    }

    function _syncPol(address pol_) private {
        if (pol_ != address(0)) ICyPolExec(pol_).syncBpt(false);
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
    function _tryGuarded(CyExecutorDeps memory d_, address set_, FuseAction[] memory actions_) private returns (uint256) {
        if (actions_.length == 0) return 0;
        try this.executeSelf(_guarded(d_, actions_)) {} catch (bytes memory reason) {
            emit StepSkipped(set_, reason);
        }
        return actions_.length;
    }

    /// @dev Each set's reduce plan (from the allocation controller) as its own guarded step; a lending reduction is
    /// recorded with the amount actually withdrawn; the POL reduce is a B2 sell-or-burn.
    function _runReduces(CyExecutorDeps memory d_, CySets memory s_) private returns (uint256 steps_) {
        (address[4] memory sets, FuseAction[][4] memory plans) = ICyAllocationPlans(d_.allocation).planReduces();
        for (uint256 i; i < 4; ++i) {
            if (plans[i].length == 0) continue;
            if (sets[i] == s_.pol) {
                FuseAction[] memory fallbackActions =
                    ICyPolExec(sets[i]).planReduceFallback(CurveYieldAllocationController(d_.allocation).managedAvkat());
                try this.executeSelf(_guarded(d_, plans[i])) {} catch {
                    _tryGuarded(d_, sets[i], fallbackActions);
                }
                steps_ += plans[i].length;
                continue;
            }
            bool lend = sets[i] == s_.lend;
            uint256 before = lend ? ICyLendRecord(sets[i]).managedAvkat() : 0;
            steps_ += _tryGuarded(d_, sets[i], plans[i]);
            if (lend) {
                uint256 afterAmount = ICyLendRecord(sets[i]).managedAvkat();
                if (before > afterAmount) ICyLendRecord(sets[i]).recordReduction(before - afterAmount);
            }
        }
    }

    /// @dev The free collateral top-up (PPS spec B5.1), as a guarded step.
    function _topUpLoop(CyExecutorDeps memory d_, address loop_) private returns (uint256) {
        if (loop_ == address(0)) return 0;
        return _tryGuarded(d_, loop_, ICyLoopExec(loop_).planCollateralTopUp());
    }

    /// @dev Brackets a bundle with the no-drop guard. The guard keeps a stack of snapshots, so a bundle whose planner
    /// already brackets part of it (e.g. the USDC strategy's LTV check) nests safely.
    function _guarded(CyExecutorDeps memory d_, FuseAction[] memory actions_) private view returns (FuseAction[] memory) {
        if (actions_.length == 0) return actions_;
        return CurveYieldBundleLib.wrap(d_.guardFuse, VAULT, actions_, 0);
    }

    // ---------------------------------------------------------------- measurement

    /// @dev Fresh total assets (every market revalued; role 1000) and fee-adjusted supply.
    /// Management-fee realization is neutral; actual losses and unauthorized dilution are not.
    function _ppsSnapshot() private returns (uint256 assets_, uint256 supply_) {
        assets_ = _refreshedTotalAssets();
        supply_ = FeePps.effectiveSupply(VAULT);
    }

    /// @dev Revalues every market, then the avKAT the vault is short of the snapshot share price.
    function _ppsLoss(uint256 assetsBefore_, uint256 supplyBefore_) private returns (uint256) {
        _refreshedTotalAssets();
        return _ppsShortfall(assetsBefore_, supplyBefore_);
    }

    function _ppsShortfall(uint256 assetsBefore_, uint256 supplyBefore_) private view returns (uint256) {
        ICyPlasmaVault vault = ICyPlasmaVault(VAULT);
        uint256 supply = FeePps.effectiveSupply(VAULT);
        uint256 scaled = supply == 0 ? assetsBefore_ : Math.mulDiv(vault.totalAssets(), supplyBefore_, supply);
        return assetsBefore_ > scaled ? assetsBefore_ - scaled : 0;
    }

    function _ppsGain(uint256 assetsBefore_, uint256 supplyBefore_) private returns (uint256) {
        uint256 assets = _refreshedTotalAssets();
        uint256 supply = FeePps.effectiveSupply(VAULT);
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
        return FuseAction(d_.transferFuse, abi.encodeCall(
            CurveYieldErc20TransferFuse.enter, (CurveYieldErc20TransferFuseEnterData(AVKAT, address(this), amount_))
        ));
    }

    function _prune(address manager_, bool requireComplete_) private {
        (, bool complete) = ICyWmV2(manager_).pruneExpiredRequests(MAX_PRUNE_BATCH);
        if (requireComplete_ && !complete) revert PruningIncomplete();
    }

    function _setDeps(CyExecutorDeps memory d_) private {
        if (d_.allocation == address(0) || d_.withdrawManager == address(0) || d_.rewardsClaimManager == address(0) ||
            d_.transferFuse == address(0) || d_.guardFuse == address(0)) {
            revert InvalidAddress();
        }
        _deps = d_;
        emit DependenciesUpdated(d_);
    }
}
