// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurveYieldAddrKeys, ICurveYieldConfigGate} from "../governance/CurveYieldGateConfig.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface ICyLeaderboardView {
    function currentSeason() external view returns (uint256);
    function holders(address user) external view returns (bool registered, uint32 lastEpoch, uint32 season, uint256 lastBalance);
    function registeredLength() external view returns (uint256);
    function registeredAt(uint256 i) external view returns (address);
}

interface ICyEngagementView {
    function holdersLength() external view returns (uint256);
    function holderAt(uint256 i) external view returns (address);
    function balanceOf(address holder) external view returns (uint256);
}

/// @title CurveYieldSpecialRewards (#22, special reward distribution)
/// @notice Holds cyavKAT (cyavKAT+ fee / profit shares, point purchases) and distributes it, in epochs, to eligible
/// cyavKAT+ holders pro rata to their weight:
///   eligible = registered in the current leaderboard season OR holding engagement tokens
///   balance  = cyavKAT+ held directly + cyavKAT+ attributed through registered forwarders (LP tokens holding cyavKAT+,
///              attributed pro rata to the user's share of the forwarder's supply)
///   weight   = min(balance now, balance at the user's previous epoch snapshot) - the first `exemptShares`
///              (a balance counts only once held across two consecutive snapshots: moving shares mid-epoch between
///              accounts cannot double count, and just-in-time deposits earn nothing)
/// `openEpoch()` (anyone, every `minInterval`): admin share (`adminBps`, 0–20%, protected) and caller reward
/// (`callerBps` 0.01–4%, capped at `callerRewardCap`) are paid; the rest is locked for the epoch.
/// `processEpoch(count)` (anyone, paginated) snapshots eligible users; `claim(epoch, user)` pays pro rata.
contract CurveYieldSpecialRewards is Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_FORWARDERS = 10;

    struct Epoch {
        uint48 time;
        uint32 lbCursor;
        uint32 engCursor;
        uint32 lbLength;
        uint32 engLength;
        bool closed;
        uint256 amount;
        uint256 totalWeight;
        address opener;
        uint256 toAdmin;
        uint256 toCaller;
    }

    IERC20 public immutable CYAVKAT;
    IERC20 public immutable PLUS;
    /// @notice Wired in the gate (`CurveYieldAddrKeys.LEADERBOARD`, GATE_CONFIG_SPEC §10).
    function LEADERBOARD() public view returns (ICyLeaderboardView) {
        return ICyLeaderboardView(ICurveYieldConfigGate(GATE).addr(CurveYieldAddrKeys.LEADERBOARD));
    }
    ICyEngagementView public immutable ENGAGEMENT;

    address public adminReceiver;
    uint256 public adminBps = 1_000; // 0..2,000 (protected: fee authority)
    uint256 public callerBps = 10; // 1..400 (0.01%..4%)
    uint256 public callerRewardCap = 20e20; // cyavKAT (20 decimals), 0..20
    uint256 public exemptShares; // cyavKAT+ (22 decimals), 0..20 cyavKAT+
    uint256 public minInterval = 7 days;
    uint256 public forwarderFee; // cyavKAT+ (0..500) to register a forwarder
    uint256 public forwarderMin; // cyavKAT+ (0..10,000) a forwarder must hold to stay registered
    uint256 public reserved; // cyavKAT locked in open / unclaimed epochs

    address[] public forwarders;
    mapping(address => bool) public isForwarder;
    Epoch[] private _epochs;
    mapping(address => uint256) public lastBalance; // at the user's previous snapshot
    mapping(uint256 epoch => mapping(address => uint256)) public weightOf;
    mapping(uint256 epoch => mapping(address => bool)) public processed;
    mapping(uint256 epoch => mapping(address => bool)) public claimed;

    event EpochOpened(uint256 indexed epoch, uint256 amount, uint256 toAdmin, uint256 toCaller);
    event EpochClosed(uint256 indexed epoch, uint256 totalWeight);
    event Claimed(uint256 indexed epoch, address indexed user, uint256 amount);
    event ForwarderRegistered(address indexed forwarder);
    event ForwarderRemoved(address indexed forwarder);

    error BadParams();
    error EpochOpen();
    error TooSoon();
    error NothingToDistribute();
    error NotClosed();
    error AlreadyClaimed();
    error ForwarderRejected();
    /// @notice The governance gate (wiring anchor, GATE_CONFIG_SPEC §10).
    address public immutable GATE;

    constructor(address owner_, address cyavkat_, address plus_, address gate_, address engagement_, address admin_)
        Ownable(owner_)
    {
        CYAVKAT = IERC20(cyavkat_);
        PLUS = IERC20(plus_);
        GATE = gate_;
        ENGAGEMENT = ICyEngagementView(engagement_);
        adminReceiver = admin_;
    }

    // ---------------------------------------------------------------- admin

    /// @notice Admin share and receiver: protected by the governance gate (fee authority only).
    function setAdmin(address admin_, uint256 adminBps_) external onlyOwner {
        if (admin_ == address(0) || adminBps_ > 2_000) revert BadParams();
        (adminReceiver, adminBps) = (admin_, adminBps_);
    }

    function setParams(
        uint256 callerBps_, uint256 callerRewardCap_, uint256 exemptShares_, uint256 minInterval_, uint256 forwarderFee_,
        uint256 forwarderMin_
    ) external onlyOwner {
        if (callerBps_ < 1 || callerBps_ > 400 || callerRewardCap_ > 20e20 || exemptShares_ > 20e22
            || minInterval_ < 1 days || minInterval_ > 90 days || forwarderFee_ > 500e22 || forwarderMin_ > 10_000e22) {
            revert BadParams();
        }
        (callerBps, callerRewardCap, exemptShares, minInterval, forwarderFee, forwarderMin) =
            (callerBps_, callerRewardCap_, exemptShares_, minInterval_, forwarderFee_, forwarderMin_);
    }

    // ---------------------------------------------------------------- forwarders

    /// @notice Permissionless: registers a contract holding cyavKAT+ (e.g. an LP token) whose holders get its
    /// cyavKAT+ attributed pro rata. Costs `forwarderFee` cyavKAT+ (to the admin receiver).
    function registerForwarder(address forwarder_) external {
        if (isForwarder[forwarder_] || forwarders.length >= MAX_FORWARDERS || forwarder_.code.length == 0
            || PLUS.balanceOf(forwarder_) < forwarderMin || forwarder_ == address(PLUS)) revert ForwarderRejected();
        if (forwarderFee != 0) PLUS.safeTransferFrom(msg.sender, adminReceiver, forwarderFee);
        isForwarder[forwarder_] = true;
        forwarders.push(forwarder_);
        emit ForwarderRegistered(forwarder_);
    }

    // ---------------------------------------------------------------- epochs

    function openEpoch() external returns (uint256 id_) {
        uint256 n = _epochs.length;
        if (n != 0) {
            Epoch storage last = _epochs[n - 1];
            if (!last.closed) revert EpochOpen();
            if (block.timestamp < last.time + minInterval) revert TooSoon();
        }
        _pruneForwarders();
        uint256 pool = CYAVKAT.balanceOf(address(this)) - reserved;
        if (pool == 0) revert NothingToDistribute();
        uint256 toAdmin = pool * adminBps / BPS;
        uint256 toCaller = pool * callerBps / BPS;
        if (toCaller > callerRewardCap) toCaller = callerRewardCap;
        uint256 amount = pool - toAdmin - toCaller;
        id_ = n;
        _epochs.push(Epoch({
            time: uint48(block.timestamp), lbCursor: 0, engCursor: 0,
            lbLength: uint32(LEADERBOARD().registeredLength()), engLength: uint32(ENGAGEMENT.holdersLength()),
            closed: false, amount: amount, totalWeight: 0, opener: msg.sender, toAdmin: toAdmin, toCaller: toCaller
        }));
        reserved += pool; // admin + caller are paid at close, and only if the epoch has weight
        emit EpochOpened(id_, amount, toAdmin, toCaller);
    }

    /// @notice Snapshots up to `count_` users (leaderboard registrants first, then engagement holders).
    function processEpoch(uint256 count_) external {
        uint256 id = _epochs.length - 1;
        Epoch storage e = _epochs[id];
        if (e.closed) return;
        uint256 season = LEADERBOARD().currentSeason();
        uint256 total = e.totalWeight;
        while (count_ != 0 && e.lbCursor < e.lbLength) {
            address u = LEADERBOARD().registeredAt(e.lbCursor++);
            (bool registered,, uint32 s,) = LEADERBOARD().holders(u);
            if (registered && s == season) total += _snapshot(id, u);
            --count_;
        }
        while (count_ != 0 && e.engCursor < e.engLength) {
            address u = ENGAGEMENT.holderAt(e.engCursor++);
            if (ENGAGEMENT.balanceOf(u) != 0) total += _snapshot(id, u);
            --count_;
        }
        e.totalWeight = total;
        if (e.lbCursor == e.lbLength && e.engCursor == e.engLength) {
            e.closed = true;
            if (total == 0) {
                // nobody eligible: the WHOLE pool rolls into the next epoch; no admin share or caller reward is taken
                reserved -= e.amount + e.toAdmin + e.toCaller;
            } else {
                reserved -= e.toAdmin + e.toCaller;
                if (e.toAdmin != 0) CYAVKAT.safeTransfer(adminReceiver, e.toAdmin);
                if (e.toCaller != 0) CYAVKAT.safeTransfer(e.opener, e.toCaller);
            }
            emit EpochClosed(id, total);
        }
    }

    function claim(uint256 id_, address user_) external returns (uint256 amount_) {
        Epoch storage e = _epochs[id_];
        if (!e.closed) revert NotClosed();
        if (claimed[id_][user_]) revert AlreadyClaimed();
        claimed[id_][user_] = true;
        uint256 w = weightOf[id_][user_];
        if (w == 0 || e.totalWeight == 0) return 0;
        amount_ = e.amount * w / e.totalWeight;
        reserved -= amount_;
        CYAVKAT.safeTransfer(user_, amount_);
        emit Claimed(id_, user_, amount_);
    }

    // ---------------------------------------------------------------- views

    function epochsLength() external view returns (uint256) {
        return _epochs.length;
    }

    function epochInfo(uint256 id_) external view returns (Epoch memory) {
        return _epochs[id_];
    }

    /// @notice cyavKAT+ held directly plus attributed through registered forwarders.
    function balanceWithForwarders(address user_) public view returns (uint256 b_) {
        b_ = PLUS.balanceOf(user_);
        for (uint256 i; i < forwarders.length; ++i) {
            IERC20 f = IERC20(forwarders[i]);
            uint256 supply = f.totalSupply();
            if (supply == 0) continue;
            uint256 share = f.balanceOf(user_);
            if (share != 0) b_ += PLUS.balanceOf(address(f)) * share / supply;
        }
    }

    // ---------------------------------------------------------------- internals

    function _snapshot(uint256 id_, address user_) private returns (uint256 w_) {
        if (processed[id_][user_]) return 0; // listed in both registries
        processed[id_][user_] = true;
        uint256 cur = balanceWithForwarders(user_);
        uint256 prev = lastBalance[user_];
        lastBalance[user_] = cur;
        uint256 eff = cur < prev ? cur : prev;
        w_ = eff > exemptShares ? eff - exemptShares : 0;
        if (w_ != 0) weightOf[id_][user_] = w_;
    }

    function _pruneForwarders() private {
        uint256 i;
        while (i < forwarders.length) {
            address f = forwarders[i];
            if (PLUS.balanceOf(f) < forwarderMin) {
                isForwarder[f] = false;
                forwarders[i] = forwarders[forwarders.length - 1];
                forwarders.pop();
                emit ForwarderRemoved(f);
            } else {
                ++i;
            }
        }
    }
}
