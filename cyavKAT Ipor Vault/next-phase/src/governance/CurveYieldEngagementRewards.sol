// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurveYieldGateConfig, CurveYieldConfigKeys as K} from "../governance/CurveYieldGateConfig.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface ICyEngagementToken {
    function balanceAt(address holder, uint256 t) external view returns (uint256);
    function holdersLength() external view returns (uint256);
    function holderAt(uint256 i) external view returns (address);
    function setMintingPaused(bool paused) external;
}

/// @title CurveYieldEngagementRewards (#8)
/// @notice Forwards whitelisted reward tokens to engagement-token holders pro rata to their decayed balances, in epochs:
///   1. `openEpoch()` (anyone, at most every `minEpochInterval`): locks the unreserved balance of every whitelisted
///      token for the epoch, snapshots the time, and pauses engagement minting so balances cannot change;
///   2. `processEpoch(count)` (anyone): records holders' balances at the snapshot time, `count` holders per call; when
///      every holder is recorded the epoch closes and minting resumes;
///   3. `claim(epoch, holder)` (anyone, paid to the holder): the holder's share of each token of that epoch.
/// Receives 33.33% of slashed proposal bonds (cyavKAT) plus any forwarded reward tokens.
contract CurveYieldEngagementRewards is Ownable2Step, CurveYieldGateConfig {
    using SafeERC20 for IERC20;

    struct Epoch {
        uint48 time;
        uint32 holders; // holders to record (fixed at open)
        uint32 cursor;
        bool closed;
        uint256 totalWeight;
        address[] tokens;
        uint256[] amounts;
    }

    ICyEngagementToken public immutable ENGAGEMENT;

    address[] public rewardTokens;
    mapping(address => bool) public isRewardToken;
    mapping(address token => uint256) public reserved; // locked in open or unclaimed epochs

    Epoch[] private _epochs;
    mapping(uint256 epoch => mapping(address holder => uint256)) public weightOf;
    mapping(uint256 epoch => mapping(address holder => bool)) public claimed;

    event RewardTokenSet(address indexed token, bool allowed);
    event EpochOpened(uint256 indexed epoch, uint256 time, uint256 holders);
    event EpochClosed(uint256 indexed epoch, uint256 totalWeight);
    event Claimed(uint256 indexed epoch, address indexed holder);

    error EpochStillOpen();
    error TooSoon();
    error NothingToDistribute();
    error EpochNotClosed();
    error AlreadyClaimed();

    constructor(address owner_, address engagement_, address configGate_) Ownable(owner_) CurveYieldGateConfig(configGate_) {
        ENGAGEMENT = ICyEngagementToken(engagement_);
    }

    /// @notice Minimum time between epochs, from the governance gate.
    function minEpochInterval() public view returns (uint256) {
        return _config1(K.ENGAGEMENT_MIN_EPOCH_INTERVAL);
    }

    // ---------------------------------------------------------------- admin

    function setRewardToken(address token_, bool allowed_) external onlyOwner {
        if (allowed_ && !isRewardToken[token_]) rewardTokens.push(token_);
        isRewardToken[token_] = allowed_;
        emit RewardTokenSet(token_, allowed_);
    }

    // ---------------------------------------------------------------- epochs

    function openEpoch() external returns (uint256 id_) {
        uint256 n = _epochs.length;
        if (n != 0) {
            Epoch storage last = _epochs[n - 1];
            if (!last.closed) revert EpochStillOpen();
            if (block.timestamp < last.time + minEpochInterval()) revert TooSoon();
        }
        uint256 holders = ENGAGEMENT.holdersLength();
        id_ = n;
        Epoch storage e = _epochs.push();
        e.time = uint48(block.timestamp);
        e.holders = uint32(holders);
        bool any;
        for (uint256 i; i < rewardTokens.length; ++i) {
            address token = rewardTokens[i];
            if (!isRewardToken[token]) continue;
            uint256 free = IERC20(token).balanceOf(address(this)) - reserved[token];
            if (free == 0) continue;
            reserved[token] += free;
            e.tokens.push(token);
            e.amounts.push(free);
            any = true;
        }
        if (!any || holders == 0) revert NothingToDistribute();
        ENGAGEMENT.setMintingPaused(true);
        emit EpochOpened(id_, block.timestamp, holders);
    }

    function processEpoch(uint256 count_) external {
        uint256 id = _epochs.length - 1;
        Epoch storage e = _epochs[id];
        if (e.closed) return;
        uint256 end = e.cursor + count_;
        if (end > e.holders) end = e.holders;
        uint256 total = e.totalWeight;
        for (uint256 i = e.cursor; i < end; ++i) {
            address h = ENGAGEMENT.holderAt(i);
            uint256 w = ENGAGEMENT.balanceAt(h, e.time);
            weightOf[id][h] = w;
            total += w;
        }
        e.cursor = uint32(end);
        e.totalWeight = total;
        if (end == e.holders) {
            e.closed = true;
            ENGAGEMENT.setMintingPaused(false);
            emit EpochClosed(id, total);
        }
    }

    function claim(uint256 id_, address holder_) external {
        Epoch storage e = _epochs[id_];
        if (!e.closed) revert EpochNotClosed();
        if (claimed[id_][holder_]) revert AlreadyClaimed();
        claimed[id_][holder_] = true;
        uint256 w = weightOf[id_][holder_];
        if (w != 0 && e.totalWeight != 0) {
            for (uint256 i; i < e.tokens.length; ++i) {
                uint256 amount = e.amounts[i] * w / e.totalWeight;
                if (amount == 0) continue;
                reserved[e.tokens[i]] -= amount;
                IERC20(e.tokens[i]).safeTransfer(holder_, amount);
            }
        }
        emit Claimed(id_, holder_);
    }

    // ---------------------------------------------------------------- views

    function epochsLength() external view returns (uint256) {
        return _epochs.length;
    }

    function epochInfo(uint256 id_)
        external view returns (uint256 time_, uint256 holders_, uint256 cursor_, bool closed_, uint256 totalWeight_)
    {
        Epoch storage e = _epochs[id_];
        return (e.time, e.holders, e.cursor, e.closed, e.totalWeight);
    }

    function epochTokens(uint256 id_) external view returns (address[] memory, uint256[] memory) {
        return (_epochs[id_].tokens, _epochs[id_].amounts);
    }

    function claimable(uint256 id_, address holder_) external view returns (address[] memory tokens_, uint256[] memory amounts_) {
        Epoch storage e = _epochs[id_];
        tokens_ = e.tokens;
        amounts_ = new uint256[](tokens_.length);
        if (!e.closed || claimed[id_][holder_] || e.totalWeight == 0) return (tokens_, amounts_);
        for (uint256 i; i < tokens_.length; ++i) amounts_[i] = e.amounts[i] * weightOf[id_][holder_] / e.totalWeight;
    }
}
