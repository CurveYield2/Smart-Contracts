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

interface IAvKatMerge {
    function balanceOf(address owner) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function withdrawTokenId(uint256 assets, address receiver, address owner) external returns (uint256 tokenId);
}

interface IVkatNftMerge {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IVkatEscrowMerge {
    function locked(uint256 tokenId) external view returns (uint256 amount, uint256 start);
    function minDeposit() external view returns (uint256);
    function merge(uint256 fromTokenId, uint256 toTokenId) external;
}

/// @notice Converts every idle avKAT share into a temporary vKAT lock and atomically merges it into
/// an existing tracked vKAT position, leaving only the destination NFT.
contract AvKatVkatMergeFuse {
    uint256 public constant MARKET_ID = 54;
    address public immutable VERSION;

    address private constant VAULT = 0x5E4D67594c2BA85249231D483ebf3C9f55382c37;
    IAvKatMerge private constant AVKAT = IAvKatMerge(0x7231dbaCdFc968E07656D12389AB20De82FbfCeB);
    IVkatNftMerge private constant VKAT = IVkatNftMerge(0x106F7D67Ea25Cb9eFf5064CF604ebf6259Ff296d);
    IVkatEscrowMerge private constant ESCROW = IVkatEscrowMerge(0x4d6fC15Ca6258b168225D283262743C623c13Ead);

    error WrongVault();
    error InvalidAmount();
    error DestinationNotTracked(uint256 tokenId);
    error WrongNftOwner(uint256 tokenId);
    error KatAssetsTooLow(uint256 assets, uint256 minimum);
    error SharesRemain(uint256 remaining);
    error InvalidTemporaryToken(uint256 tokenId);
    error MergeAmountMismatch(uint256 observed, uint256 expected);

    event AvKatMergedIntoVkat(
        uint256 indexed temporaryTokenId,
        uint256 indexed destinationTokenId,
        uint256 katAssets,
        uint256 sharesSpent
    );

    constructor() {
        VERSION = address(this);
    }

    function enterAll(uint256 destinationTokenId, uint256 minKatAssets)
        external
        returns (uint256 temporaryTokenId, uint256 katAssets)
    {
        if (address(this) != VAULT) revert WrongVault();
        if (!VkatFuseStorageLib.contains(destinationTokenId)) revert DestinationNotTracked(destinationTokenId);
        if (VKAT.ownerOf(destinationTokenId) != VAULT) revert WrongNftOwner(destinationTokenId);

        uint256 sharesBefore = AVKAT.balanceOf(VAULT);
        if (sharesBefore == 0) revert InvalidAmount();
        katAssets = AVKAT.previewRedeem(sharesBefore);
        uint256 liveMinimum = ESCROW.minDeposit();
        if (katAssets < liveMinimum || katAssets < minKatAssets) {
            revert KatAssetsTooLow(katAssets, liveMinimum > minKatAssets ? liveMinimum : minKatAssets);
        }

        (uint256 destinationBefore, ) = ESCROW.locked(destinationTokenId);
        temporaryTokenId = AVKAT.withdrawTokenId(katAssets, VAULT, VAULT);
        if (temporaryTokenId == destinationTokenId || VKAT.ownerOf(temporaryTokenId) != VAULT) {
            revert InvalidTemporaryToken(temporaryTokenId);
        }
        (uint256 temporaryAmount, ) = ESCROW.locked(temporaryTokenId);
        if (temporaryAmount < katAssets) revert MergeAmountMismatch(temporaryAmount, katAssets);

        uint256 sharesRemaining = AVKAT.balanceOf(VAULT);
        if (sharesRemaining != 0) revert SharesRemain(sharesRemaining);
        ESCROW.merge(temporaryTokenId, destinationTokenId);

        (uint256 destinationAfter, ) = ESCROW.locked(destinationTokenId);
        uint256 expected = destinationBefore + temporaryAmount;
        if (destinationAfter != expected) revert MergeAmountMismatch(destinationAfter, expected);

        emit AvKatMergedIntoVkat(temporaryTokenId, destinationTokenId, temporaryAmount, sharesBefore);
        katAssets = temporaryAmount;
    }
}
