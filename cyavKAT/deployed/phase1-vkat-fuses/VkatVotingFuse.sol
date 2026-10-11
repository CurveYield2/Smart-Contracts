// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

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

import {VkatFuseStorageLib} from "./VkatFuseStorageLib.sol";

interface IVkatDelegationAdapter {
    function delegate(address delegatee) external;
    function delegates(address account) external view returns (address);
}

interface IVkatAddressGaugeVoter {
    struct GaugeVote {
        uint256 weight;
        address gauge;
    }

    function vote(GaugeVote[] calldata votes) external;
    function reset() external;
    function gaugeExists(address gauge) external view returns (bool);
    function isActive(address gauge) external view returns (bool);
}

contract VkatVotingFuse {
    uint256 public constant MARKET_ID = 54;
    address public immutable VERSION;

    address private constant VAULT = 0x5E4D67594c2BA85249231D483ebf3C9f55382c37;
    IVkatDelegationAdapter private constant ADAPTER = IVkatDelegationAdapter(0xB67Ac05e2C1d8592692a90BF61712274b988f25A);
    IVkatAddressGaugeVoter private constant VOTER = IVkatAddressGaugeVoter(0x5e755A3C5dc81A79DE7a7cEF192FFA60964c9352);

    error WrongVault();
    error NoTrackedVkat();
    error NotSelfDelegated();
    error InvalidVote();
    error GaugeNotGranted(address gauge);
    error GaugeNotActive(address gauge);

    event VkatSelfDelegated();
    event VkatGaugeVoteCast();
    event VkatGaugeVoteReset();

    constructor() {
        VERSION = address(this);
    }

    function delegateToVault() external {
        if (address(this) != VAULT) revert WrongVault();
        if (VkatFuseStorageLib.tokenIds().values.length == 0) revert NoTrackedVkat();
        ADAPTER.delegate(address(this));
        if (ADAPTER.delegates(address(this)) != address(this)) revert NotSelfDelegated();
        emit VkatSelfDelegated();
    }

    function vote(IVkatAddressGaugeVoter.GaugeVote[] calldata votes) external {
        if (address(this) != VAULT) revert WrongVault();
        if (VkatFuseStorageLib.tokenIds().values.length == 0) revert NoTrackedVkat();
        if (ADAPTER.delegates(address(this)) != address(this)) revert NotSelfDelegated();
        if (votes.length == 0) revert InvalidVote();
        for (uint256 i; i < votes.length; ++i) {
            if (votes[i].weight == 0) revert InvalidVote();
            address gauge = votes[i].gauge;
            if (!VkatFuseStorageLib.isGaugeGranted(MARKET_ID, gauge)) revert GaugeNotGranted(gauge);
            if (!VOTER.gaugeExists(gauge) || !VOTER.isActive(gauge)) revert GaugeNotActive(gauge);
        }
        VOTER.vote(votes);
        emit VkatGaugeVoteCast();
    }

    function reset() external {
        if (address(this) != VAULT) revert WrongVault();
        VOTER.reset();
        emit VkatGaugeVoteReset();
    }
}
