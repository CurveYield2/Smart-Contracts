// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FuseAction, ICyStrategySet} from "../interfaces/CurveYieldPhase2Interfaces.sol";
import {CurveYieldGateConfig, CurveYieldConfigKeys as K} from "../governance/CurveYieldGateConfig.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    ICyAvKatVkat, ICyVkatEscrowFull, ICyExitQueue, ICyEpochClock, ICyGaugeVoter, ICyVkatNft
} from "./CurveYieldVkatInterfaces.sol";
import {
    VeLockEnterData, VeConvertEnterData, VeVoteEnterData, VeExitBeginEnterData, VeExitWithdrawEnterData
} from "../generic/CurveYieldVeFuses.sol";
import {CurveYieldMorphoLoopLib, CyLoopEnv, CyLoopSnapshot} from "../morpho/CurveYieldMorphoLoopLib.sol";

interface ICyVkatLoopView {
    function env() external view returns (CyLoopEnv memory);
    function params() external view returns (CyLoopParamsTarget memory);
}

/// @dev Leading fields of CyLoopParams (ABI-compatible prefix read): only targetLtvBps is used here.
struct CyLoopParamsTarget {
    uint16 allocationBps;
    uint16 rampZoneBps;
    uint16 baseWindupProfitBps;
    uint16 rampStartProfitBps;
    uint16 rampEndProfitBps;
    uint16 minUnwindProfitBps;
    uint16 targetLtvBps;
}

interface ICyVkatEscrowCounter {
    function lastLockId() external view returns (uint256);
}

interface ICyLaneFeeHeadroom {
    function escrowedFeeHeadroomShares(uint256 keepBps) external view returns (uint256);
}

interface ICyLaneVault {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

interface ICyVkatEscrowCounterKat {
    function balanceOf(address account) external view returns (uint256);
}

struct CyVkatEnv {
    address vault;
    address avkat;
    address nft;
    address escrow;
    address exitQueue;
    address epochClock;
    address gaugeVoter;
    address delegationAdapter;
    address loopController; // native-exit lane repays this loop and uses its LTV headroom
}

struct CyVkatParams {
    uint16 allocationBps; // vKAT share of managed avKAT (the bot sets it from gauge real yield, #17)
    uint16 nativeExitMaxLtvBps; // lane may lift the loop LTV up to this to start exits (spec: 76.2%)
    uint32 deployWindow; // lock new avKAT only in the last `deployWindow` seconds before the vote closes
}

/// @notice The generic voting-escrow fuses this controller plans for (fuse standardization). The native-exit lane's
/// loop steps use the loop's IPOR collateral / borrow fuses (from the loop controller's env).
struct CyVkatFuses {
    address lock; // CurveYieldVeLockFuse
    address convert; // CurveYieldVeConvertFuse
    address vote; // CurveYieldVeVoteFuse
    address exitBegin; // CurveYieldVeExitBeginFuse
    address exitWithdraw; // CurveYieldVeExitWithdrawFuse
}

/// @notice vKAT set controller (split of the v1 vKAT monolith, #9) plus the native-exit lane (spec §2.8).
/// Holds one voting position NFT, lane NFTs being prepared, and exit tickets in the vKAT exit queue. The lane converts
/// avKAT to KAT at the conversion rate for the minimum 2.5% fee after the full 60-day cooldown, never earlier.
contract CurveYieldVkatController is ICyStrategySet, Ownable2Step, CurveYieldGateConfig {

    uint256 private constant BPS = 10_000;

    CyVkatEnv private _env;
    CyVkatFuses private _fuses;
    address public executor;
    address[] private _gauges;
    uint256[] private _weights;

    uint256 public positionTokenId;
    uint256[] private _prepared;
    uint256[] private _exiting;
    /// @notice Exit tickets that came from loop headroom (prepared lane NFTs) rather than the voting position: they free
    /// ~0.30 avKAT per avKAT at completion instead of ~1.30 (PPS spec A1.1).
    mapping(uint256 tokenId => bool) public fromHeadroom;

    error InvalidAddress();
    error FusesAlreadySet();
    error InvalidVoteTargets();
    error OnlyVault(address caller);
    error OnlyExecutor(address caller);

    event ExecutorUpdated(address indexed executor);
    event FusesSet(CyVkatFuses fuses);
    event VoteTargetsUpdated(address[] gauges, uint256[] weights);
    event PositionUpdated(uint256 tokenId);
    event ExitPrepared(uint256 indexed tokenId);
    event ExitStarted(uint256 indexed tokenId);
    event ExitCompleted(uint256 indexed tokenId);

    modifier onlyExecutor() {
        if (msg.sender != executor) revert OnlyExecutor(msg.sender);
        _;
    }

    constructor(
        address owner_,
        CyVkatEnv memory env_,
        address configGate_,
        address[] memory gauges_,
        uint256[] memory weights_
    ) Ownable(owner_) CurveYieldGateConfig(configGate_) {
        if (env_.vault == address(0) || env_.avkat == address(0) || env_.nft == address(0) ||
            env_.escrow == address(0) || env_.exitQueue == address(0) || env_.epochClock == address(0) ||
            env_.gaugeVoter == address(0) || env_.delegationAdapter == address(0) || env_.loopController == address(0)
        ) revert InvalidAddress();
        _env = env_;
        _setVoteTargets(gauges_, weights_);
    }

    // ---------------------------------------------------------------- configuration

    function setExecutor(address executor_) external onlyOwner {
        if (executor_ == address(0)) revert InvalidAddress();
        executor = executor_;
        emit ExecutorUpdated(executor_);
    }

    function setFuses(CyVkatFuses calldata fuses_) external onlyOwner {
        if (_fuses.lock != address(0)) revert FusesAlreadySet();
        if (fuses_.lock == address(0) || fuses_.convert == address(0) || fuses_.vote == address(0) ||
            fuses_.exitBegin == address(0) || fuses_.exitWithdraw == address(0)
        ) revert InvalidAddress();
        _fuses = fuses_;
        emit FusesSet(fuses_);
    }

    function setVoteTargets(address[] calldata gauges_, uint256[] calldata weights_) external onlyOwner {
        _setVoteTargets(gauges_, weights_);
    }

    function env() external view returns (CyVkatEnv memory) {
        return _env;
    }

    /// @notice The vKAT set's settings, read from the governance gate.
    function params() public view returns (CyVkatParams memory p_) {
        bytes32[] memory k = new bytes32[](3);
        (k[0], k[1], k[2]) = (K.VKAT_ALLOCATION_BPS, K.VKAT_NATIVE_EXIT_MAX_LTV_BPS, K.VKAT_DEPLOY_WINDOW);
        uint256[] memory v = _config(k);
        p_ = CyVkatParams(uint16(v[0]), uint16(v[1]), uint32(v[2]));
    }

    function fuses() external view returns (CyVkatFuses memory) {
        return _fuses;
    }

    function voteTargets() external view returns (address[] memory, uint256[] memory) {
        return (_gauges, _weights);
    }

    function preparedTokens() external view returns (uint256[] memory) {
        return _prepared;
    }

    function exitingTokens() external view returns (uint256[] memory) {
        return _exiting;
    }

    // ---------------------------------------------------------------- bookkeeping (the executor syncs after each bundle)

    /// @notice Escrow lock-id counter: the executor reads it before a bundle and passes it to sync().
    function lastLockId() external view returns (uint256) {
        return ICyVkatEscrowCounter(_env.escrow).lastLockId();
    }

    /// @notice Reconciles the tracked NFTs with on-chain state after a bundle (generic fuses do not report back):
    ///   voting position: kept while the vault owns it; queued -> exit ticket; gone (converted) -> 0
    ///   prepared lane NFTs: queued -> exit tickets; gone -> dropped
    ///   exit tickets: dropped once no longer the vault's ticket (completed)
    ///   locks created in the bundle (ids after lastLockIdBefore): owned -> the voting position when
    ///   `newLockIsPosition_` and there is none, else a prepared lane NFT; queued for the vault -> exit tickets
    function sync(uint256 lastLockIdBefore_, bool newLockIsPosition_) external onlyExecutor {
        uint256 pos = positionTokenId;
        if (pos != 0 && !_owned(pos)) {
            if (_ticket(pos)) {
                _exiting.push(pos);
                emit ExitStarted(pos);
            }
            positionTokenId = 0;
            emit PositionUpdated(0);
        }
        for (uint256 i; i < _prepared.length;) {
            uint256 id = _prepared[i];
            if (_owned(id)) { ++i; continue; }
            if (_ticket(id)) {
                _exiting.push(id);
                fromHeadroom[id] = true;
                emit ExitStarted(id);
            }
            _prepared[i] = _prepared[_prepared.length - 1];
            _prepared.pop();
        }
        for (uint256 i; i < _exiting.length;) {
            uint256 id = _exiting[i];
            if (_ticket(id)) { ++i; continue; }
            delete fromHeadroom[id];
            emit ExitCompleted(id);
            _exiting[i] = _exiting[_exiting.length - 1];
            _exiting.pop();
        }
        uint256 last = ICyVkatEscrowCounter(_env.escrow).lastLockId();
        for (uint256 id = lastLockIdBefore_ + 1; id <= last; ++id) {
            if (_owned(id)) {
                if (newLockIsPosition_ && positionTokenId == 0) {
                    positionTokenId = id;
                    emit PositionUpdated(id);
                } else if (id != positionTokenId) {
                    _prepared.push(id);
                    emit ExitPrepared(id);
                }
            } else if (_ticket(id) && !_contains(_exiting, id)) {
                _exiting.push(id);
                emit ExitStarted(id);
            }
        }
    }

    function _owned(uint256 id_) private view returns (bool) {
        (uint256 amount,) = ICyVkatEscrowFull(_env.escrow).locked(id_);
        if (amount == 0) return false;
        try ICyVkatNft(_env.nft).ownerOf(id_) returns (address owner) {
            return owner == _env.vault;
        } catch {
            return false;
        }
    }

    function _ticket(uint256 id_) private view returns (bool) {
        return ICyExitQueue(_env.exitQueue).ticketHolder(id_) == _env.vault;
    }

    function isPrepared(uint256 tokenId_) external view returns (bool) {
        return _contains(_prepared, tokenId_);
    }

    function isExiting(uint256 tokenId_) external view returns (bool) {
        return _contains(_exiting, tokenId_);
    }

    // ---------------------------------------------------------------- views

    /// @notice Lock new avKAT only while voting is active and the vote closes within `deployWindow`.
    function allocationActive() public view returns (bool) {
        return ICyGaugeVoter(_env.gaugeVoter).votingActive() &&
            ICyEpochClock(_env.epochClock).epochVoteEndsIn() <= params().deployWindow;
    }

    /// @notice vKAT converts back to avKAT (free) only in the first half of the two-week epoch.
    function conversionAvailable() public view returns (bool) {
        ICyEpochClock clock = ICyEpochClock(_env.epochClock);
        return clock.elapsedInEpoch() < clock.epochDuration() / 2 &&
            ICyVkatEscrowFull(_env.escrow).canSplit(_env.vault);
    }

    function positionAvkat() public view returns (uint256) {
        return _lockedAvkat(positionTokenId);
    }

    /// @notice avKAT value of lane NFTs: prepared (vault-owned) + exiting (in the queue), at the conversion rate.
    /// The 2.5% exit fee is booked when an exit completes, together with the request-fee burn.
    function laneAvkat() public view returns (uint256 total_) {
        for (uint256 i; i < _prepared.length; ++i) total_ += _lockedAvkat(_prepared[i]);
        for (uint256 i; i < _exiting.length; ++i) total_ += _lockedAvkat(_exiting[i]);
    }

    /// @notice Gross KAT locked in exit tickets (valued net of the minimum fee by the exit position token, market 7).
    function exitingKat() external view returns (uint256 total_) {
        for (uint256 i; i < _exiting.length; ++i) {
            (uint256 amount,) = ICyVkatEscrowFull(_env.escrow).locked(_exiting[i]);
            total_ += amount;
        }
    }

    /// @notice Gross KAT in exit tickets, split by where the exited avKAT came from (voting position / loop headroom).
    function exitingKatBySource() external view returns (uint256 fromPositionKat_, uint256 fromHeadroomKat_) {
        for (uint256 i; i < _exiting.length; ++i) {
            (uint256 amount,) = ICyVkatEscrowFull(_env.escrow).locked(_exiting[i]);
            if (fromHeadroom[_exiting[i]]) fromHeadroomKat_ += amount;
            else fromPositionKat_ += amount;
        }
    }

    function managedAvkat() external view override returns (uint256) {
        return positionAvkat() + laneAvkat();
    }

    function allocationBps() external view override returns (uint256) {
        return params().allocationBps;
    }

    // ---------------------------------------------------------------- plans (ICyStrategySet)

    function planDeploy(uint256 budgetAvkat_, uint256 managedTotal_)
        external view override returns (FuseAction[] memory actions_, uint256 consumedAvkat_)
    {
        if (budgetAvkat_ == 0 || !allocationActive()) return (actions_, 0);
        uint256 target = managedTotal_ * params().allocationBps / BPS;
        uint256 current = positionAvkat();
        if (current >= target) return (actions_, 0);
        consumedAvkat_ = target - current;
        if (consumedAvkat_ > budgetAvkat_) consumedAvkat_ = budgetAvkat_;
        if (ICyAvKatVkat(_env.avkat).previewRedeem(consumedAvkat_) < ICyVkatEscrowFull(_env.escrow).minDeposit()) {
            return (new FuseAction[](0), 0);
        }
        actions_ = new FuseAction[](2);
        uint256 pos = _owned(positionTokenId) ? positionTokenId : 0;
        actions_[0] = _lockAction(consumedAvkat_, pos);
        actions_[1] = _voteAction(pos); // 0 when this lock creates the position (its id is not known yet)
    }

    /// @notice Over target: convert the excess back to avKAT, free, during the conversion window only.
    function planReduce(uint256 managedTotal_)
        external view override returns (FuseAction[] memory actions_, uint256 releasedAvkat_)
    {
        if (!conversionAvailable()) return (actions_, 0);
        uint256 target = managedTotal_ * params().allocationBps / BPS;
        uint256 current = positionAvkat();
        if (current <= target) return (actions_, 0);
        releasedAvkat_ = current - target;
        actions_ = new FuseAction[](1);
        actions_[0] = _convertAction(releasedAvkat_);
    }

    /// @notice Free conversion during the conversion window; the native-exit lane is planned separately.
    function planWithdraw(uint256 neededAvkat_, bool)
        external view override returns (FuseAction[] memory actions_, uint256 providedAvkat_)
    {
        if (neededAvkat_ == 0 || !conversionAvailable()) return (actions_, 0);
        uint256 convertible = positionAvkat();
        providedAvkat_ = neededAvkat_ < convertible ? neededAvkat_ : convertible;
        if (providedAvkat_ == 0) return (actions_, 0);
        actions_ = new FuseAction[](1);
        actions_[0] = _convertAction(providedAvkat_);
    }

    /// @notice Instant withdrawals (through CurveYieldPlannedInstantWithdrawFuse): free conversion, window only.
    function planInstantWithdraw(uint256 amount_) external view returns (FuseAction[] memory actions_) {
        (actions_,) = this.planWithdraw(amount_, false);
    }

    // ---------------------------------------------------------------- native-exit lane plans

    /// @notice Sizes and plans a native-exit start (PPS spec A1.1) for scheduled requests needing `neededAvkat_`: the
    /// shortfall that idle avKAT + in-flight exits cannot cover (position tickets free ~1.30 avKAT per avKAT exited,
    /// headroom tickets ~0.30), then the exit that frees it — the voting position first, loop headroom after — capped
    /// at `maxExitAvkat_` (what the served requests' escrowed fees can pay).
    function planNativeExitStartFor(uint256 neededAvkat_, address withdrawManager_, uint256 keepBps_)
        external view returns (uint256 shortfall_, uint256 exitAvkat_, FuseAction[] memory actions_)
    {
        uint256 maxExitAvkat_ = laneMaxAvkat(withdrawManager_, keepBps_);
        uint256 fromPositionBps = (BPS - ICyExitQueue(_env.exitQueue).minFeePercent()) * BPS
            / ICyVkatLoopView(_env.loopController).params().targetLtvBps;
        uint256 fromHeadroomBps = fromPositionBps - BPS;
        (uint256 posKat, uint256 headKat) = this.exitingKatBySource();
        ICyAvKatVkat avkat = ICyAvKatVkat(_env.avkat);
        uint256 covered = ICyVkatEscrowCounterKat(_env.avkat).balanceOf(_env.vault)
            + avkat.convertToShares(posKat) * fromPositionBps / BPS + avkat.convertToShares(headKat) * fromHeadroomBps / BPS;
        if (neededAvkat_ <= covered) return (0, 0, actions_);
        shortfall_ = neededAvkat_ - covered;
        uint256 fromPosition = Math.mulDiv(shortfall_, BPS, fromPositionBps, Math.Rounding.Ceil);
        uint256 position = positionAvkat();
        if (fromPosition > position) fromPosition = position;
        uint256 released = fromPosition * fromPositionBps / BPS;
        uint256 rest = shortfall_ > released ? shortfall_ - released : 0;
        exitAvkat_ = fromPosition + Math.mulDiv(rest, BPS, fromHeadroomBps, Math.Rounding.Ceil);
        if (exitAvkat_ > maxExitAvkat_) exitAvkat_ = maxExitAvkat_;
        if (exitAvkat_ != 0) actions_ = this.planNativeExitStart(exitAvkat_);
    }

    /// @notice Largest lane exit (avKAT) whose queue fee the served requests' escrowed request fees can pay, keeping
    /// `keepBps_` of each request for its release (PPS spec A1.3).
    function laneMaxAvkat(address withdrawManager_, uint256 keepBps_) public view returns (uint256) {
        uint256 feeBps = ICyExitQueue(_env.exitQueue).minFeePercent();
        if (feeBps == 0) return type(uint256).max;
        uint256 headroom = ICyLaneVault(_env.vault).convertToAssets(
            ICyLaneFeeHeadroom(withdrawManager_).escrowedFeeHeadroomShares(keepBps_)
        );
        return headroom * BPS / feeBps;
    }

    /// @notice Start exits worth `exitAvkat_`: first from the vKAT position (split, exit begins now), the rest from
    /// loop LTV headroom up to `nativeExitMaxLtvBps` (new lock; its exit begins next block via planNativeExitBegin).
    function planNativeExitStart(uint256 exitAvkat_) external view returns (FuseAction[] memory actions_) {
        if (exitAvkat_ == 0) return actions_;
        uint256 fromPosition = positionAvkat();
        if (fromPosition > exitAvkat_) fromPosition = exitAvkat_;
        uint256 rest = exitAvkat_ - fromPosition;
        FuseAction[] memory prepare = rest == 0 ? new FuseAction[](0) : _prepareActions(rest);
        actions_ = new FuseAction[]((fromPosition != 0 ? 1 : 0) + prepare.length);
        uint256 k;
        if (fromPosition != 0) actions_[k++] = _exitBeginAction(positionTokenId, fromPosition);
        for (uint256 i; i < prepare.length; ++i) actions_[k++] = prepare[i];
    }

    /// @dev Lane step 1: withdraw loop collateral within the lane's LTV cap and lock it into a NEW NFT (its exit begins
    /// in a later block). Same math as the Phase 2 prepare fuse; nothing when under the escrow minimum.
    function _prepareActions(uint256 avkatWanted_) private view returns (FuseAction[] memory actions_) {
        CyLoopEnv memory loopEnv = ICyVkatLoopView(_env.loopController).env();
        CyLoopSnapshot memory s = CurveYieldMorphoLoopLib.snapshot(loopEnv);
        if (s.collateralAvkat == 0 || s.collateralValueKat == 0) return actions_;
        uint256 mustRemain = Math.mulDiv(
            s.debtKat * BPS, s.collateralAvkat, s.collateralValueKat * params().nativeExitMaxLtvBps, Math.Rounding.Ceil
        );
        if (mustRemain >= s.collateralAvkat) return actions_;
        uint256 withdraw = s.collateralAvkat - mustRemain;
        if (withdraw > avkatWanted_) withdraw = avkatWanted_;
        if (ICyAvKatVkat(_env.avkat).previewRedeem(withdraw) < ICyVkatEscrowFull(_env.escrow).minDeposit()) return actions_;
        actions_ = new FuseAction[](2);
        actions_[0] = CurveYieldMorphoLoopLib.collateralAction(loopEnv, false, withdraw);
        actions_[1] = _lockAction(withdraw, 0); // a separate lane NFT (sync() records it as prepared)
    }

    /// @notice Begin the exits of prepared lane NFTs (created in an earlier block).
    function planNativeExitBegin() external view returns (FuseAction[] memory actions_) {
        uint256 n = _prepared.length;
        actions_ = new FuseAction[](n);
        for (uint256 i; i < n; ++i) actions_[i] = _exitBeginAction(_prepared[i], 0);
    }

    /// @notice Begin the exits of prepared lane NFTs whose total avKAT stays within `maxAvkat_` (PPS spec A1.3: only as
    /// many as the served requests' escrowed fees can pay for; the rest stay vault-owned locks at full value).
    function planNativeExitBeginUpTo(uint256 maxAvkat_) external view returns (FuseAction[] memory actions_) {
        uint256 n = _prepared.length;
        uint256[] memory pick = new uint256[](n);
        uint256 k;
        uint256 used;
        for (uint256 i; i < n; ++i) {
            uint256 value = _lockedAvkat(_prepared[i]);
            if (used + value > maxAvkat_) continue;
            used += value;
            pick[k++] = _prepared[i];
        }
        actions_ = new FuseAction[](k);
        for (uint256 i; i < k; ++i) actions_[i] = _exitBeginAction(pick[i], 0);
    }

    /// @notice Complete exits whose fee has decayed to the minimum (full 60-day cooldown). Never earlier.
    function planNativeExitComplete() external view returns (FuseAction[] memory actions_) {
        uint256 n;
        uint256[] memory ready = new uint256[](_exiting.length);
        for (uint256 i; i < _exiting.length; ++i) {
            if (exitAtMinimumFee(_exiting[i])) ready[n++] = _exiting[i];
        }
        uint256 katBefore; // KAT already idle (none on the normal path)
        for (uint256 i; i < n; ++i) actions_ = _concat(actions_, _completeActions(ready[i], katBefore));
    }

    /// @dev Lane step 3 (exact, same block): withdraw the ticket's KAT (fee from the queue), repay loop debt with all
    /// the KAT the vault will hold, release collateral back down to the loop target LTV.
    function _completeActions(uint256 tokenId_, uint256 katIdle_) private view returns (FuseAction[] memory actions_) {
        CyLoopEnv memory loopEnv = ICyVkatLoopView(_env.loopController).env();
        (uint256 amount,) = ICyVkatEscrowFull(_env.escrow).locked(tokenId_);
        uint256 received = amount - ICyExitQueue(_env.exitQueue).calculateFee(tokenId_);
        CyLoopSnapshot memory s = CurveYieldMorphoLoopLib.snapshot(loopEnv);
        uint256 repay = katIdle_ + received;
        if (repay > s.debtKat) repay = s.debtKat;
        uint256 released;
        uint256 debtAfter = s.debtKat - repay;
        if (s.collateralAvkat != 0 && s.collateralValueKat != 0) {
            uint256 target = ICyVkatLoopView(_env.loopController).params().targetLtvBps;
            uint256 mustRemain = Math.mulDiv(debtAfter * BPS, s.collateralAvkat, s.collateralValueKat * target, Math.Rounding.Ceil);
            if (mustRemain < s.collateralAvkat) released = s.collateralAvkat - mustRemain;
        }
        actions_ = new FuseAction[](1 + (repay != 0 ? 1 : 0) + (released != 0 ? 1 : 0));
        uint256 k;
        actions_[k++] = FuseAction(_fuses.exitWithdraw, abi.encodeWithSignature(
            "enter((address,uint256))", VeExitWithdrawEnterData(_env.escrow, tokenId_)
        ));
        if (repay != 0) actions_[k++] = CurveYieldMorphoLoopLib.borrowAction(loopEnv, false, repay);
        if (released != 0) actions_[k] = CurveYieldMorphoLoopLib.collateralAction(loopEnv, false, released);
    }

    /// @notice The exit queue minimum fee in bps (live: 250 = 2.5%, reached after the 60-day cooldown).
    function exitMinFeeBps() external view returns (uint256) {
        return ICyExitQueue(_env.exitQueue).minFeePercent();
    }

    /// @notice True once the exit queue charges only its minimum fee on this ticket (2.5% after 60 days).
    function exitAtMinimumFee(uint256 tokenId_) public view returns (bool) {
        if (!ICyExitQueue(_env.exitQueue).canExit(tokenId_)) return false;
        return earlyExitPremiumKat(tokenId_) == 0;
    }

    /// @notice KAT a caller must pay to complete this exit now: the queue fee above the minimum 2.5% (the vault
    /// covers the 2.5%). 0 once the cooldown has passed. E.g. day 30: 13.75% fee -> premium 11.25% of the ticket.
    function earlyExitPremiumKat(uint256 tokenId_) public view returns (uint256) {
        ICyExitQueue queue = ICyExitQueue(_env.exitQueue);
        (uint256 amount,) = ICyVkatEscrowFull(_env.escrow).locked(tokenId_);
        uint256 fee = queue.calculateFee(tokenId_);
        uint256 houseFee = amount * queue.minFeePercent() / BPS;
        return fee > houseFee + 1 ? fee - houseFee : 0;
    }

    /// @notice Early completion of one exit (caller pays `earlyExitPremiumKat` to the vault first; the executor does that).
    function planNativeExitCompleteEarly(uint256 tokenId_) external view returns (FuseAction[] memory actions_) {
        if (!_contains(_exiting, tokenId_) || !ICyExitQueue(_env.exitQueue).canExit(tokenId_)) return actions_;
        // the executor has already moved the caller's premium (KAT above the 2.5% fee) into the vault: repay it too
        actions_ = _completeActions(tokenId_, ICyVkatEscrowCounterKat(ICyVkatLoopView(_env.loopController).env().kat).balanceOf(_env.vault));
    }

    // ---------------------------------------------------------------- generic fuse calls

    function _lockAction(uint256 shares_, uint256 mergeInto_) private view returns (FuseAction memory) {
        return FuseAction(_fuses.lock, abi.encodeWithSignature(
            "enter((address,address,address,uint256,uint256))",
            VeLockEnterData(_env.avkat, _env.escrow, _env.nft, shares_, mergeInto_)
        ));
    }

    function _convertAction(uint256 shares_) private view returns (FuseAction memory) {
        return FuseAction(_fuses.convert, abi.encodeWithSignature(
            "enter((address,address,address,uint256,uint256))",
            VeConvertEnterData(_env.avkat, _env.escrow, _env.nft, positionTokenId, shares_)
        ));
    }

    function _voteAction(uint256 position_) private view returns (FuseAction memory) {
        return FuseAction(_fuses.vote, abi.encodeWithSignature(
            "enter((address,address,address,address,uint256,address[],uint256[]))",
            VeVoteEnterData(_env.escrow, _env.nft, _env.gaugeVoter, _env.delegationAdapter, position_, _gauges, _weights)
        ));
    }

    function _exitBeginAction(uint256 tokenId_, uint256 splitShares_) private view returns (FuseAction memory) {
        return FuseAction(_fuses.exitBegin, abi.encodeWithSignature(
            "enter((address,address,address,uint256,uint256))",
            VeExitBeginEnterData(_env.avkat, _env.escrow, _env.nft, tokenId_, splitShares_)
        ));
    }

    function _concat(FuseAction[] memory a_, FuseAction[] memory b_) private pure returns (FuseAction[] memory c_) {
        c_ = new FuseAction[](a_.length + b_.length);
        for (uint256 i; i < a_.length; ++i) c_[i] = a_[i];
        for (uint256 i; i < b_.length; ++i) c_[a_.length + i] = b_[i];
    }

    // ---------------------------------------------------------------- internal

    function _lockedAvkat(uint256 tokenId_) private view returns (uint256) {
        if (tokenId_ == 0) return 0;
        (uint256 amount,) = ICyVkatEscrowFull(_env.escrow).locked(tokenId_);
        return amount == 0 ? 0 : ICyAvKatVkat(_env.avkat).convertToShares(amount);
    }

    function _setVoteTargets(address[] memory gauges_, uint256[] memory weights_) private {
        if (gauges_.length == 0 || gauges_.length != weights_.length) revert InvalidVoteTargets();
        delete _gauges;
        delete _weights;
        for (uint256 i; i < gauges_.length; ++i) {
            if (gauges_[i] == address(0) || weights_[i] == 0) revert InvalidVoteTargets();
            _gauges.push(gauges_[i]);
            _weights.push(weights_[i]);
        }
        emit VoteTargetsUpdated(gauges_, weights_);
    }

    function _remove(uint256[] storage list_, uint256 id_) private {
        uint256 n = list_.length;
        for (uint256 i; i < n; ++i) {
            if (list_[i] == id_) {
                list_[i] = list_[n - 1];
                list_.pop();
                return;
            }
        }
    }

    function _contains(uint256[] storage list_, uint256 id_) private view returns (bool) {
        for (uint256 i; i < list_.length; ++i) if (list_[i] == id_) return true;
        return false;
    }
}
