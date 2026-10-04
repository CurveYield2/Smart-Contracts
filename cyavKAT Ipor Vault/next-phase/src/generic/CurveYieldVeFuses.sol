// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";

/// @notice Aragon-style voting escrow (VotingEscrowV1_2_0: lock NFTs, split / merge, 2-step withdrawal via an exit queue).
interface ICyVeEscrow {
    function minDeposit() external view returns (uint256);
    function locked(uint256 tokenId) external view returns (uint256 amount, uint256 start);
    function split(uint256 tokenId, uint256 amount) external returns (uint256 newTokenId);
    function merge(uint256 fromTokenId, uint256 toTokenId) external;
    function beginWithdrawal(uint256 tokenId) external;
    function withdraw(uint256 tokenId) external;
}

interface ICyVeNft {
    function ownerOf(uint256 tokenId) external view returns (address);
    function approve(address spender, uint256 tokenId) external;
}

/// @notice ERC-4626 wrapper over the escrow's token that mints / burns lock NFTs (e.g. avKAT over KAT).
interface ICyVeWrapper {
    function balanceOf(address account) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);
    function depositTokenId(uint256 tokenId, address receiver) external returns (uint256 shares);
    function withdrawTokenId(uint256 assets, address receiver, address owner) external returns (uint256 tokenId);
}

interface ICyVeGaugeVoter {
    struct GaugeVote {
        uint256 weight;
        address gauge;
    }
    function votingActive() external view returns (bool);
    function vote(GaugeVote[] calldata votes) external;
    function gaugeExists(address gauge) external view returns (bool);
    function isActive(address gauge) external view returns (bool);
}

interface ICyVeDelegation {
    function delegate(address delegatee) external;
    function delegates(address account) external view returns (address);
}

/// @notice Shared checks for the generic voting-escrow fuses. Every external contract they touch (escrow, lock NFT,
/// wrapper, gauge voter, delegation adapter, gauges) must be granted as a substrate of SUBSTRATE_MARKET_ID (the live
/// cyavKAT vault uses market 54 for this list). No vault address, no controller: positions are passed in by the
/// caller's planner and checked against the NFT's owner.
abstract contract CurveYieldVeFuseBase is IFuseCommon {
    address public immutable VERSION;
    uint256 public immutable override MARKET_ID;
    uint256 public immutable SUBSTRATE_MARKET_ID;

    error NotGranted(address account);
    error NotOwnedByVault(uint256 tokenId);

    constructor(uint256 marketId_, uint256 substrateMarketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        SUBSTRATE_MARKET_ID = substrateMarketId_;
    }

    function _granted(address account_) internal view {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(SUBSTRATE_MARKET_ID, account_)) revert NotGranted(account_);
    }

    /// @dev A live lock owned by the vault.
    function _isVaultPosition(address escrow_, address nft_, uint256 tokenId_) internal view returns (bool) {
        if (tokenId_ == 0) return false;
        (uint256 amount,) = ICyVeEscrow(escrow_).locked(tokenId_);
        return amount != 0 && ICyVeNft(nft_).ownerOf(tokenId_) == address(this);
    }
}

struct VeLockEnterData {
    address wrapper; // e.g. avKAT
    address escrow;
    address nft;
    uint256 maxShares; // wrapper shares to lock (capped by the vault's balance)
    uint256 mergeIntoTokenId; // 0 = keep the new lock as its own NFT (e.g. an exit-lane lock)
}

/// @title VeLockFuse: wrapper shares -> a lock NFT, merged into an existing vault position or kept separate.
contract CurveYieldVeLockFuse is CurveYieldVeFuseBase {
    event VeLocked(address version, uint256 newTokenId, uint256 intoTokenId, uint256 shares, uint256 lockedAmount);

    constructor(uint256 marketId_, uint256 substrateMarketId_) CurveYieldVeFuseBase(marketId_, substrateMarketId_) {}

    function enter(VeLockEnterData memory d_) external returns (uint256 tokenId_) {
        _granted(d_.wrapper);
        _granted(d_.escrow);
        _granted(d_.nft);
        ICyVeWrapper w = ICyVeWrapper(d_.wrapper);
        uint256 balance = w.balanceOf(address(this));
        uint256 shares = d_.maxShares > balance ? balance : d_.maxShares;
        uint256 assets = w.previewRedeem(shares);
        if (assets < ICyVeEscrow(d_.escrow).minDeposit()) return 0; // below the escrow minimum: nothing to do
        tokenId_ = w.withdrawTokenId(assets, address(this), address(this));
        if (d_.mergeIntoTokenId != 0) {
            if (!_isVaultPosition(d_.escrow, d_.nft, d_.mergeIntoTokenId)) revert NotOwnedByVault(d_.mergeIntoTokenId);
            ICyVeEscrow(d_.escrow).merge(tokenId_, d_.mergeIntoTokenId);
            tokenId_ = d_.mergeIntoTokenId;
        }
        emit VeLocked(VERSION, tokenId_, d_.mergeIntoTokenId, shares, assets);
    }
}

struct VeConvertEnterData {
    address wrapper;
    address escrow;
    address nft;
    uint256 positionTokenId; // the vault's lock to convert from
    uint256 wrapperShares; // wrapper shares wanted back
}

/// @title VeConvertFuse: part or all of a vault lock back into wrapper shares (split, then deposit the NFT).
/// Takes the whole lock when the remainder would fall under the escrow minimum. Timing rules (e.g. only in the
/// first half of an epoch) are the planner's policy.
contract CurveYieldVeConvertFuse is CurveYieldVeFuseBase {
    event VeConverted(address version, uint256 fromTokenId, uint256 convertedTokenId, uint256 amount, uint256 sharesReceived, bool wholePosition);

    constructor(uint256 marketId_, uint256 substrateMarketId_) CurveYieldVeFuseBase(marketId_, substrateMarketId_) {}

    function enter(VeConvertEnterData memory d_) external returns (uint256 received_) {
        _granted(d_.wrapper);
        _granted(d_.escrow);
        _granted(d_.nft);
        if (d_.wrapperShares == 0 || !_isVaultPosition(d_.escrow, d_.nft, d_.positionTokenId)) return 0;
        ICyVeEscrow escrow = ICyVeEscrow(d_.escrow);
        ICyVeWrapper w = ICyVeWrapper(d_.wrapper);
        (uint256 locked,) = escrow.locked(d_.positionTokenId);
        uint256 minimum = escrow.minDeposit();
        uint256 amount = w.previewMint(d_.wrapperShares);
        uint256 tokenId;
        bool whole = amount + minimum >= locked;
        if (whole) {
            (tokenId, amount) = (d_.positionTokenId, locked);
        } else {
            if (amount < minimum) return 0;
            tokenId = escrow.split(d_.positionTokenId, amount);
        }
        uint256 before = w.balanceOf(address(this));
        ICyVeNft(d_.nft).approve(d_.wrapper, tokenId);
        w.depositTokenId(tokenId, address(this));
        received_ = w.balanceOf(address(this)) - before;
        emit VeConverted(VERSION, d_.positionTokenId, tokenId, amount, received_, whole);
    }
}

struct VeVoteEnterData {
    address escrow;
    address nft;
    address gaugeVoter;
    address delegation;
    uint256 positionTokenId;
    address[] gauges; // each must be granted and active
    uint256[] weights;
}

/// @title VeVoteFuse: (re)delegates to the vault itself if needed and casts the vault's gauge votes.
contract CurveYieldVeVoteFuse is CurveYieldVeFuseBase {
    error GaugeNotActive(address gauge);
    error LengthMismatch();

    event VeVoted(address version, uint256 positionTokenId, uint256 gauges);

    constructor(uint256 marketId_, uint256 substrateMarketId_) CurveYieldVeFuseBase(marketId_, substrateMarketId_) {}

    function enter(VeVoteEnterData memory d_) external {
        _granted(d_.escrow);
        _granted(d_.nft);
        _granted(d_.gaugeVoter);
        _granted(d_.delegation);
        if (d_.gauges.length != d_.weights.length) revert LengthMismatch();
        // 0 = no check (e.g. the first lock was created earlier in the same bundle and its id is not known yet)
        if (d_.positionTokenId != 0 && !_isVaultPosition(d_.escrow, d_.nft, d_.positionTokenId)) return;
        ICyVeGaugeVoter voter = ICyVeGaugeVoter(d_.gaugeVoter);
        if (!voter.votingActive()) return;
        ICyVeDelegation adapter = ICyVeDelegation(d_.delegation);
        if (adapter.delegates(address(this)) != address(this)) adapter.delegate(address(this));
        ICyVeGaugeVoter.GaugeVote[] memory votes = new ICyVeGaugeVoter.GaugeVote[](d_.gauges.length);
        for (uint256 i; i < d_.gauges.length; ++i) {
            _granted(d_.gauges[i]);
            if (!voter.gaugeExists(d_.gauges[i]) || !voter.isActive(d_.gauges[i])) revert GaugeNotActive(d_.gauges[i]);
            votes[i] = ICyVeGaugeVoter.GaugeVote(d_.weights[i], d_.gauges[i]);
        }
        voter.vote(votes);
        emit VeVoted(VERSION, d_.positionTokenId, d_.gauges.length);
    }
}

struct VeExitBeginEnterData {
    address wrapper; // only for `splitWrapperShares` sizing
    address escrow;
    address nft;
    uint256 tokenId; // the vault lock to exit from
    uint256 splitWrapperShares; // 0 = exit the whole `tokenId`; else split this many wrapper-shares' worth off and exit that
}

/// @title VeExitBeginFuse: starts the escrow's withdrawal (exit queue) for a vault lock, optionally split off first.
contract CurveYieldVeExitBeginFuse is CurveYieldVeFuseBase {
    event VeExitBegun(address version, uint256 fromTokenId, uint256 exitingTokenId, uint256 amount);

    constructor(uint256 marketId_, uint256 substrateMarketId_) CurveYieldVeFuseBase(marketId_, substrateMarketId_) {}

    function enter(VeExitBeginEnterData memory d_) external returns (uint256 exitingTokenId_) {
        _granted(d_.escrow);
        _granted(d_.nft);
        if (!_isVaultPosition(d_.escrow, d_.nft, d_.tokenId)) revert NotOwnedByVault(d_.tokenId);
        ICyVeEscrow escrow = ICyVeEscrow(d_.escrow);
        exitingTokenId_ = d_.tokenId;
        if (d_.splitWrapperShares != 0) {
            _granted(d_.wrapper);
            (uint256 locked,) = escrow.locked(d_.tokenId);
            uint256 minimum = escrow.minDeposit();
            uint256 amount = ICyVeWrapper(d_.wrapper).previewRedeem(d_.splitWrapperShares);
            if (amount + minimum < locked) {
                if (amount < minimum) return 0;
                exitingTokenId_ = escrow.split(d_.tokenId, amount);
            }
        }
        ICyVeNft(d_.nft).approve(d_.escrow, exitingTokenId_);
        escrow.beginWithdrawal(exitingTokenId_);
        (uint256 exiting,) = escrow.locked(exitingTokenId_);
        emit VeExitBegun(VERSION, d_.tokenId, exitingTokenId_, exiting);
    }
}

struct VeExitWithdrawEnterData {
    address escrow;
    uint256 tokenId; // a vault lock whose exit has matured (or is completed early: the planner's policy)
}

/// @title VeExitWithdrawFuse: completes the escrow withdrawal of an exiting lock; the underlying lands in the vault.
contract CurveYieldVeExitWithdrawFuse is CurveYieldVeFuseBase {
    event VeExitWithdrawn(address version, uint256 tokenId);

    constructor(uint256 marketId_, uint256 substrateMarketId_) CurveYieldVeFuseBase(marketId_, substrateMarketId_) {}

    function enter(VeExitWithdrawEnterData memory d_) external {
        _granted(d_.escrow);
        ICyVeEscrow(d_.escrow).withdraw(d_.tokenId);
        emit VeExitWithdrawn(VERSION, d_.tokenId);
    }
}
