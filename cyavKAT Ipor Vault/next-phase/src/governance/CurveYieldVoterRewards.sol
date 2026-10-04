// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CurveYieldGateConfig, CurveYieldConfigKeys as K} from "../governance/CurveYieldGateConfig.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IAragonTokenVoting, AragonProposalParameters, AragonTally, AragonAction, AragonTargetConfig, ICyVotingLockView,
    ICyEngagementMint} from "./CurveYieldAragonInterfaces.sol";

/// @title CurveYieldVoterRewards (#8, D-G4 / D-G7)
/// @notice Pull-based engagement rewards for passed (executed) proposals of the DAO's TokenVoting plugin.
/// Each executed proposal has a voter pool of `voterPool` engagement units, shared by voting power at the proposal's
/// snapshot, over all votes cast (yes + no + abstain):
///   - a voter earns pool x (own self-delegated power + delegated-in power x delegateeCut x haircut) / total cast
///   - a delegator whose delegatee voted earns pool x own power x (1 - haircut) / total cast
///   defaults: haircut 50% (delegators keep half), delegateeCut 20% of that haircut; the rest is not minted.
/// Anyone can claim for anyone (paid to the account); once per (proposal, account).
contract CurveYieldVoterRewards is Ownable2Step, CurveYieldGateConfig {
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_POOL = 1_000e18;

    IAragonTokenVoting public immutable VOTING;
    ICyVotingLockView public immutable LOCK;
    ICyEngagementMint public immutable ENGAGEMENT;


    mapping(uint256 proposalId => mapping(address => bool)) public claimed;

    event RewardClaimed(uint256 indexed proposalId, address indexed account, uint256 amount, bool asDelegator);

    error NotExecuted();
    error AlreadyClaimed();
    error NothingEarned();
    error OutOfBounds();

    constructor(address owner_, address voting_, address lock_, address engagement_, address configGate_)
        Ownable(owner_)
        CurveYieldGateConfig(configGate_)
    {
        VOTING = IAragonTokenVoting(voting_);
        LOCK = ICyVotingLockView(lock_);
        ENGAGEMENT = ICyEngagementMint(engagement_);
    }

    /// @notice Voter pool per proposal, delegator haircut and delegatee cut (bps), from the governance gate.
    function params() public view returns (uint256 voterPool_, uint256 delegatorHaircutBps_, uint256 delegateeCutBps_) {
        bytes32[] memory k = new bytes32[](3);
        (k[0], k[1], k[2]) = (K.VOTER_POOL, K.VOTER_DELEGATOR_HAIRCUT_BPS, K.VOTER_DELEGATEE_CUT_BPS);
        uint256[] memory v = _config(k);
        return (v[0], v[1], v[2]);
    }

    function claim(uint256 proposalId_, address account_) external returns (uint256 amount_) {
        if (claimed[proposalId_][account_]) revert AlreadyClaimed();
        bool asDelegator;
        (amount_, asDelegator) = earned(proposalId_, account_);
        if (amount_ == 0) revert NothingEarned();
        claimed[proposalId_][account_] = true;
        ENGAGEMENT.mint(account_, amount_);
        emit RewardClaimed(proposalId_, account_, amount_, asDelegator);
    }

    /// @notice Engagement units `account_` can claim for `proposalId_` (0 if not executed or not eligible).
    function earned(uint256 proposalId_, address account_) public view returns (uint256 amount_, bool asDelegator_) {
        (, bool executed, AragonProposalParameters memory proposalParams, AragonTally memory tally,,,) =
            VOTING.getProposal(proposalId_);
        if (!executed || claimed[proposalId_][account_]) return (0, false);
        uint256 cast = tally.yes + tally.no + tally.abstain;
        if (cast == 0) return (0, false);
        uint256 snap = proposalParams.snapshotTimepoint;
        (,, address delegatee) = LOCK.accountAt(account_, snap);
        uint256 own = LOCK.ownPowerAt(account_, snap);

        if (delegatee == account_) {
            // voter: own power in full, delegated-in power at the delegatee cut of the haircut
            if (VOTING.getVoteOption(proposalId_, account_) == 0) return (0, false);
            uint256 votes = LOCK.getPastVotes(account_, snap);
            uint256 delegatedIn = votes > own ? votes - own : 0;
            (uint256 pool, uint256 haircut, uint256 cut) = params();
            uint256 weight = own + delegatedIn * haircut * cut / (BPS * BPS);
            return (pool * weight / cast, false);
        }
        // delegator: only if its delegatee voted
        if (VOTING.getVoteOption(proposalId_, delegatee) == 0) return (0, true);
        (uint256 pool2, uint256 haircut2,) = params();
        return (pool2 * own * (BPS - haircut2) / (BPS * cast), true);
    }
}
