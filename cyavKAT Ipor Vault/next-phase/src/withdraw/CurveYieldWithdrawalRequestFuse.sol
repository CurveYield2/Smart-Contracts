// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {IPlasmaVaultBase} from "contracts/interfaces/IPlasmaVaultBase.sol";
import {FuseAction, ICyStrategySet} from "../interfaces/CurveYieldPhase2Interfaces.sol";
import {ICurveYieldConfigGate, CurveYieldConfigKeys as K, CurveYieldAddrKeys} from "../governance/CurveYieldGateConfig.sol";

interface ICyRequestFuseSelf {
    function executeInternal(FuseAction[] calldata calls) external;
}

interface ICyRequestFusePol {
    function planPolStep(uint256 neededAvkat, uint256 requestFeeBps, bool charged)
        external view returns (FuseAction[] memory actions, uint256 plannedAvkat);
    function yieldFeeAction(uint256 amount) external view returns (FuseAction memory);
}

interface ICyRequestFuseSplitter {
    function splitLegs(uint256 amount, address transferFuse) external view returns (FuseAction[] memory legs, uint256 toRewardsManager);
}

/// @notice Phase 1a: the withdrawal source plan (planners in order, each planning with fresh state).
struct RequestSourcesData {
    uint256 amount;
    address[] planners;
}

/// @notice Phase 1b: the POL-funded part (the POL controller plans the sale at its floor).
struct RequestPolSaleData {
    address polController;
    uint256 neededAvkat;
    uint256 requestFeeBps;
    bool charged;
}

/// @notice Phase 2: the settlement of one fulfilment, from the executor's measurements.
struct RequestSettleData {
    address requester;
    uint256 shares;
    uint256 releasedAssets;
    uint256 lossAvkat; // loss of this fulfilment's own unwind (share-price terms)
    uint256 feeShares; // request-fee shares burned by the release
    address polController; // 0 when POL was not used
    uint256 polProvided;
    uint256 polCost;
    uint256 polChargedShares;
    uint256 polFloor; // the vault's minimum on the POL-funded part
    uint256 polYieldFee; // admin yield fee on the POL real profit
}

/// @title CurveYieldWithdrawalRequestFuse
/// @notice Every vault-side step of a withdrawal request's life (cyavKAT, WM v2):
///   - request-fee shares: `moveRequestFeeShares` / `configureManagerAssetAllowance`, called by the vault's withdraw
///     manager (it is the manager's `requestFeeFuse`);
///   - fulfilment phase 1: `runSources` (the withdrawal source plan) and `runPolSale` (the POL-funded part);
///   - fulfilment phase 2: `settle` (this fulfilment's real profit: fee minus loss, the POL minimum and admin yield fee,
///     the keeper reward at the gate's exec.fulfilReward rate / cap, the profit split legs), executed as transfer-fuse
///     actions. The keeper reward goes to the caller of the vault execution (the executor, a granted recipient).
/// The executor orders the phases and makes the withdraw-manager calls between them (release / charge must come from
/// the manager's controller and run their own vault execution). Planners must be granted as `6 << 160 | planner` in
/// SUBSTRATE_MARKET_ID.
contract CurveYieldWithdrawalRequestFuse is IFuseCommon {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 public constant TYPE_PLANNER = 6;
    uint256 public constant MAX_REWARD = 10e18; // as the gate's hard cap on exec.fulfilRewardCap
    uint256 private constant BPS = 10_000;

    address public immutable VERSION;
    uint256 public immutable override MARKET_ID;
    uint256 public immutable SUBSTRATE_MARKET_ID;
    address public immutable CONFIG_GATE; // a gate migration redeploys this (stateless) fuse
    /// @notice Wired in the gate (`CurveYieldAddrKeys.LOOP_PROFIT_SPLITTER`, GATE_CONFIG_SPEC §10). CurveYieldLoopProfitSplitter: the profit split legs
    function SPLITTER() public view returns (address) {
        return ICurveYieldConfigGate(CONFIG_GATE).addr(CurveYieldAddrKeys.LOOP_PROFIT_SPLITTER);
    }
    /// @notice Wired in the gate (`CurveYieldAddrKeys.TRANSFER_FUSE`, GATE_CONFIG_SPEC §10). CurveYieldErc20TransferFuse: every settlement transfer
    function TRANSFER_FUSE() public view returns (address) {
        return ICurveYieldConfigGate(CONFIG_GATE).addr(CurveYieldAddrKeys.TRANSFER_FUSE);
    }

    event RequestFeeSharesMoved(address indexed manager, address indexed from, address indexed to, uint256 amount);
    event ManagerAssetAllowanceConfigured(address indexed manager, address indexed previousManager);
    event SourcesRun(address version, uint256 amount, uint256 planned);
    event PolSaleRun(address version, uint256 needed, uint256 planned);
    event FulfilmentSettled(
        address version, address indexed requester, uint256 shares, uint256 lossAvkat, uint256 feeShares, uint256 profit,
        uint256 reward, uint256 polProvided, uint256 polCost, uint256 polChargedShares, uint256 polYieldFee
    );

    error UnauthorizedCaller(address caller);
    error InvalidFeeMovement(address from, address to);
    error PlannerNotGranted(address planner);
    error InvalidAddress();

    constructor(uint256 marketId_, uint256 substrateMarketId_, address configGate_) {
        if (configGate_ == address(0)) revert InvalidAddress();
        VERSION = address(this);
        MARKET_ID = marketId_;
        SUBSTRATE_MARKET_ID = substrateMarketId_;
        CONFIG_GATE = configGate_;
    }

    // ---------------------------------------------------------------- request-fee shares (withdraw manager)

    /// @notice Moves request-fee shares between a requester and the withdraw manager (escrow in, refund out).
    function moveRequestFeeShares(address from_, address to_, uint256 amount_) external {
        address manager = _requireManager();
        if (amount_ == 0) return;
        if (from_ != manager && to_ != manager) revert InvalidFeeMovement(from_, to_);
        PlasmaVaultStorageLib.getPlasmaVaultBase().functionDelegateCall(
            abi.encodeWithSelector(IPlasmaVaultBase.updateInternal.selector, from_, to_, amount_)
        );
        emit RequestFeeSharesMoved(manager, from_, to_, amount_);
    }

    /// @notice Rotates the vault-asset allowance the manager's custody transfers use.
    function configureManagerAssetAllowance(address previousManager_) external {
        address manager = _requireManager();
        IERC20 token = IERC20(IERC4626(address(this)).asset());
        if (previousManager_ != address(0) && previousManager_ != manager) token.forceApprove(previousManager_, 0);
        token.forceApprove(manager, type(uint256).max);
        emit ManagerAssetAllowanceConfigured(manager, previousManager_);
    }

    // ---------------------------------------------------------------- fulfilment phase 1

    function runSources(RequestSourcesData memory d_) external returns (uint256 planned_) {
        uint256 remaining = d_.amount;
        for (uint256 i; i < d_.planners.length && remaining != 0; ++i) {
            _requirePlanner(d_.planners[i]);
            (FuseAction[] memory actions, uint256 provided) = ICyStrategySet(d_.planners[i]).planWithdraw(remaining, true);
            if (actions.length == 0) continue;
            ICyRequestFuseSelf(address(this)).executeInternal(actions);
            if (provided > remaining) provided = remaining;
            remaining -= provided;
            planned_ += provided;
        }
        emit SourcesRun(VERSION, d_.amount, planned_);
    }

    function runPolSale(RequestPolSaleData memory d_) external returns (uint256 planned_) {
        _requirePlanner(d_.polController);
        FuseAction[] memory actions;
        (actions, planned_) = ICyRequestFusePol(d_.polController).planPolStep(d_.neededAvkat, d_.requestFeeBps, d_.charged);
        if (planned_ != 0) ICyRequestFuseSelf(address(this)).executeInternal(actions);
        emit PolSaleRun(VERSION, d_.neededAvkat, planned_);
    }

    // ---------------------------------------------------------------- fulfilment phase 2

    /// @notice Splits ONLY this fulfilment's real profit (its burned fee minus its own loss, minus the POL minimum and
    /// the admin yield fee) and pays the keeper reward out of it (D2): nothing is paid out of principal.
    function settle(RequestSettleData memory d_) external returns (uint256 profit_, uint256 reward_) {
        uint256 supply = IERC20(address(this)).totalSupply();
        uint256 feeAssets = d_.feeShares == 0 ? 0 : d_.feeShares * IERC4626(address(this)).totalAssets() / (supply + d_.feeShares);
        profit_ = feeAssets > d_.lossAvkat ? feeAssets - d_.lossAvkat : 0;
        profit_ = profit_ > d_.polFloor ? profit_ - d_.polFloor : 0;
        uint256 yieldFee = d_.polYieldFee > profit_ ? profit_ : d_.polYieldFee;
        profit_ -= yieldFee;
        reward_ = _reward(d_.releasedAssets, profit_);

        FuseAction[] memory legs;
        if (profit_ > reward_) (legs,) = ICyRequestFuseSplitter(SPLITTER()).splitLegs(profit_ - reward_, TRANSFER_FUSE());
        uint256 n = legs.length + (yieldFee != 0 ? 1 : 0) + (reward_ != 0 ? 1 : 0);
        if (n != 0) {
            FuseAction[] memory settleActions = new FuseAction[](n);
            uint256 k;
            if (yieldFee != 0) settleActions[k++] = ICyRequestFusePol(d_.polController).yieldFeeAction(yieldFee);
            for (uint256 i; i < legs.length; ++i) settleActions[k++] = legs[i];
            if (reward_ != 0) {
                settleActions[k] = FuseAction(TRANSFER_FUSE(), abi.encodeWithSignature(
                    "enter((address,address,uint256))", IERC4626(address(this)).asset(), msg.sender, reward_
                ));
            }
            ICyRequestFuseSelf(address(this)).executeInternal(settleActions);
        }
        emit FulfilmentSettled(
            VERSION, d_.requester, d_.shares, d_.lossAvkat, d_.feeShares, profit_, reward_, d_.polProvided, d_.polCost,
            d_.polChargedShares, yieldFee
        );
    }

    // ---------------------------------------------------------------- internals

    /// @dev The gate's fulfilment reward: exec.fulfilRewardBps of the released assets, capped by exec.fulfilRewardCap
    /// (and MAX_REWARD) and by this fulfilment's profit, so it is never paid out of principal.
    function _reward(uint256 releasedAssets_, uint256 profit_) private view returns (uint256 reward_) {
        if (profit_ == 0) return 0;
        bytes32[] memory keys = new bytes32[](2);
        (keys[0], keys[1]) = (K.EXEC_FULFIL_REWARD_BPS, K.EXEC_FULFIL_REWARD_CAP);
        uint256[] memory v = ICurveYieldConfigGate(CONFIG_GATE).getMany(keys);
        reward_ = releasedAssets_ * v[0] / BPS;
        if (reward_ > v[1]) reward_ = v[1];
        if (reward_ > MAX_REWARD) reward_ = MAX_REWARD;
        if (reward_ > profit_) reward_ = profit_;
    }

    function _requireManager() private view returns (address manager_) {
        manager_ = PlasmaVaultStorageLib.getWithdrawManager().manager;
        if (manager_ == address(0) || msg.sender != manager_) revert UnauthorizedCaller(msg.sender);
    }

    function _requirePlanner(address planner_) private view {
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(
            SUBSTRATE_MARKET_ID, bytes32((TYPE_PLANNER << 160) | uint256(uint160(planner_)))
        )) revert PlannerNotGranted(planner_);
    }
}
