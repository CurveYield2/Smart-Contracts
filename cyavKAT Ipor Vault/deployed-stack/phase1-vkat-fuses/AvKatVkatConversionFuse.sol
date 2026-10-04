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

interface IAvKatConversion {
    function balanceOf(address owner) external view returns (uint256);
    function withdrawTokenId(uint256 assets, address receiver, address owner) external returns (uint256 tokenId);
    function depositTokenId(uint256 tokenId, address receiver) external returns (uint256 shares);
}

interface IVkatNftConversion {
    function ownerOf(uint256 tokenId) external view returns (address);
    function approve(address spender, uint256 tokenId) external;
}

interface IVkatEscrowConversion {
    function locked(uint256 tokenId) external view returns (uint256 amount, uint256 start);
}

contract AvKatVkatConversionFuse {
    uint256 public constant MARKET_ID = 54;
    address public immutable VERSION;

    address private constant VAULT = 0xEd83daf48429cfb2C650Fd721b9241e180fd4548;
    IAvKatConversion private constant AVKAT = IAvKatConversion(0x7231dbaCdFc968E07656D12389AB20De82FbfCeB);
    IVkatNftConversion private constant VKAT = IVkatNftConversion(0x106F7D67Ea25Cb9eFf5064CF604ebf6259Ff296d);
    IVkatEscrowConversion private constant ESCROW = IVkatEscrowConversion(0x4d6fC15Ca6258b168225D283262743C623c13Ead);

    error WrongVault();
    error InvalidAmount();
    error SharesSpentTooHigh(uint256 spent, uint256 maximum);
    error SharesReceivedTooLow(uint256 received, uint256 minimum);
    error WrongNftOwner(uint256 tokenId);
    error InsufficientLockedKAT(uint256 tokenId, uint256 lockedAmount, uint256 expected);
    error ShareReturnMismatch(uint256 returned, uint256 observed);

    event AvKatConvertedToVkat(uint256 indexed tokenId, uint256 katAssets, uint256 sharesSpent);
    event VkatConvertedToAvKat(uint256 indexed tokenId, uint256 sharesReceived);

    constructor() {
        VERSION = address(this);
    }

    function enter(uint256 katAssets, uint256 maxSharesBurned) external returns (uint256 tokenId) {
        if (address(this) != VAULT) revert WrongVault();
        if (katAssets == 0 || maxSharesBurned == 0) revert InvalidAmount();

        uint256 sharesBefore = AVKAT.balanceOf(address(this));
        tokenId = AVKAT.withdrawTokenId(katAssets, address(this), address(this));
        uint256 sharesSpent = sharesBefore - AVKAT.balanceOf(address(this));
        if (sharesSpent == 0 || sharesSpent > maxSharesBurned) {
            revert SharesSpentTooHigh(sharesSpent, maxSharesBurned);
        }
        if (VKAT.ownerOf(tokenId) != address(this)) revert WrongNftOwner(tokenId);
        (uint256 lockedAmount, ) = ESCROW.locked(tokenId);
        if (lockedAmount < katAssets) revert InsufficientLockedKAT(tokenId, lockedAmount, katAssets);

        VkatFuseStorageLib.add(tokenId);
        emit AvKatConvertedToVkat(tokenId, katAssets, sharesSpent);
    }

    function exit(uint256 tokenId, uint256 minSharesReceived) external returns (uint256 sharesReceived) {
        if (address(this) != VAULT) revert WrongVault();
        if (!VkatFuseStorageLib.contains(tokenId)) revert VkatFuseStorageLib.TokenNotTracked(tokenId);
        if (VKAT.ownerOf(tokenId) != address(this)) revert WrongNftOwner(tokenId);

        uint256 sharesBefore = AVKAT.balanceOf(address(this));
        VKAT.approve(address(AVKAT), tokenId);
        uint256 returned = AVKAT.depositTokenId(tokenId, address(this));
        sharesReceived = AVKAT.balanceOf(address(this)) - sharesBefore;
        if (sharesReceived < minSharesReceived) revert SharesReceivedTooLow(sharesReceived, minSharesReceived);
        if (returned != sharesReceived) revert ShareReturnMismatch(returned, sharesReceived);

        VkatFuseStorageLib.remove(tokenId);
        emit VkatConvertedToAvKat(tokenId, sharesReceived);
    }
}
