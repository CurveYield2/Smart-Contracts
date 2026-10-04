// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @dev Minimal Aragon OSx v1.4 TokenVoting (MajorityVotingBase) surface, ABI-identical to the plugin.
struct AragonAction {
    address to;
    uint256 value;
    bytes data;
}

struct AragonTargetConfig {
    address target;
    uint8 operation;
}

struct AragonProposalParameters {
    uint8 votingMode;
    uint32 supportThreshold;
    uint64 startDate;
    uint64 endDate;
    uint64 snapshotTimepoint;
    uint256 minVotingPower;
}

struct AragonTally {
    uint256 abstain;
    uint256 yes;
    uint256 no;
}

interface IAragonTokenVoting {
    /// @dev VoteOption: 0 None, 1 Abstain, 2 Yes, 3 No
    function getVoteOption(uint256 proposalId, address voter) external view returns (uint8);

    function getProposal(uint256 proposalId)
        external
        view
        returns (
            bool open,
            bool executed,
            AragonProposalParameters memory parameters,
            AragonTally memory tally,
            AragonAction[] memory actions,
            uint256 allowFailureMap,
            AragonTargetConfig memory targetConfig
        );
}

interface ICyVotingLockView {
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256);
    function ownPowerAt(address account, uint256 timepoint) external view returns (uint256);
    function accountAt(address account, uint256 timepoint)
        external view returns (uint256 amount, uint256 start, address delegatee);
}

interface ICyEngagementMint {
    function mint(address to, uint256 amount) external;
}
