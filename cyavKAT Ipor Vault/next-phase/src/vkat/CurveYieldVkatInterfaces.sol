// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @notice avKAT (ERC-4626 over KAT with vKAT NFT deposit/withdraw).
interface ICyAvKatVkat {
    function balanceOf(address account) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);
    function depositTokenId(uint256 tokenId, address receiver) external returns (uint256 shares);
    function withdrawTokenId(uint256 assets, address receiver, address owner) external returns (uint256 tokenId);
}

/// @notice vKAT escrow (VotingEscrowV1_2_0 on Katana).
interface ICyVkatEscrowFull {
    function minDeposit() external view returns (uint256);
    function canSplit(address account) external view returns (bool);
    function locked(uint256 tokenId) external view returns (uint256 amount, uint256 start);
    function ownedTokens(address owner) external view returns (uint256[] memory);
    function split(uint256 tokenId, uint256 amount) external returns (uint256 newTokenId);
    function merge(uint256 fromTokenId, uint256 toTokenId) external;
    function beginWithdrawal(uint256 tokenId) external;
    function withdraw(uint256 tokenId) external;
    function queue() external view returns (address);
}

interface ICyVkatNft {
    function ownerOf(uint256 tokenId) external view returns (address);
    function approve(address spender, uint256 tokenId) external;
}

/// @notice vKAT DynamicExitQueue: fee decays linearly from `feePercent` (25%) to `minFeePercent` (2.5%) over `cooldown`
/// (60 days). Verified on a Katana fork 2026-09-24: 25.000% day 0, 13.750% day 30, 2.500% day 60.
interface ICyExitQueue {
    function cooldown() external view returns (uint48);
    function minFeePercent() external view returns (uint256);
    function canExit(uint256 tokenId) external view returns (bool);
    function calculateFee(uint256 tokenId) external view returns (uint256);
    function ticketHolder(uint256 tokenId) external view returns (address);
}

interface ICyEpochClock {
    function elapsedInEpoch() external view returns (uint256);
    function epochDuration() external view returns (uint256);
    function epochVoteEndsIn() external view returns (uint256);
}

interface ICyDelegationAdapter {
    function delegate(address delegatee) external;
    function delegates(address account) external view returns (address);
}

interface ICyGaugeVoter {
    struct GaugeVote {
        uint256 weight;
        address gauge;
    }
    function votingActive() external view returns (bool);
    function vote(GaugeVote[] calldata votes) external;
    function gaugeExists(address gauge) external view returns (bool);
    function isActive(address gauge) external view returns (bool);
}
