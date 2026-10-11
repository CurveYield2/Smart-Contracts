// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {
    IERC20Katana,
    IAvKatKatana,
    IVkatNftKatana,
    IVkatEscrowKatana
} from "./interfaces/CurveYieldKatanaInterfaces.sol";

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

library CurveYieldVkatTrackingLib {
    bytes32 private constant TOKEN_IDS_SLOT = keccak256("curveyield.ipor.vkat.token-ids.v1");

    struct TokenIds {
        uint256[] values;
        mapping(uint256 tokenId => uint256 indexPlusOne) indexPlusOne;
    }

    error TokenNotTracked(uint256 tokenId);

    function tokenIds() internal pure returns (TokenIds storage ids) {
        bytes32 slot = TOKEN_IDS_SLOT;
        assembly { ids.slot := slot }
    }

    function contains(uint256 tokenId_) internal view returns (bool) {
        return tokenIds().indexPlusOne[tokenId_] != 0;
    }

    function remove(uint256 tokenId_) internal {
        TokenIds storage ids = tokenIds();
        uint256 indexPlusOne = ids.indexPlusOne[tokenId_];
        if (indexPlusOne == 0) revert TokenNotTracked(tokenId_);
        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = ids.values.length - 1;
        if (index != lastIndex) {
            uint256 moved = ids.values[lastIndex];
            ids.values[index] = moved;
            ids.indexPlusOne[moved] = indexPlusOne;
        }
        ids.values.pop();
        delete ids.indexPlusOne[tokenId_];
    }
}

/// @notice Converts exactly the needed portion of a tracked vKAT NFT back into avKAT.
/// @dev This is the minimal partial-exit extension of the deployed AvKatVkatConversionFuseV2.
contract CurveYieldVkatPartialConversionFuse {
    uint256 public constant MARKET_ID = 54;
    uint256 public constant MIN_VKAT_SPLIT_KAT = 230 ether;

    address public constant VAULT = 0x5E4D67594c2BA85249231D483ebf3C9f55382c37;
    IAvKatKatana public constant AVKAT = IAvKatKatana(0x7231dbaCdFc968E07656D12389AB20De82FbfCeB);
    IVkatNftKatana public constant VKAT = IVkatNftKatana(0x106F7D67Ea25Cb9eFf5064CF604ebf6259Ff296d);
    IVkatEscrowKatana public constant ESCROW = IVkatEscrowKatana(0x4d6fC15Ca6258b168225D283262743C623c13Ead);
    address public immutable VERSION;

    error WrongVault();
    error InvalidAmount();
    error WrongNftOwner(uint256 tokenId);
    error SplitBelowLiveMinimum(uint256 requestedKat, uint256 liveMinimumKat);
    error RemainderBelowLiveMinimum(uint256 remainderKat, uint256 liveMinimumKat);
    error SharesReceivedTooLow(uint256 received, uint256 minimum);
    error ShareReturnMismatch(uint256 returned, uint256 observed);
    error InvalidSplitToken(uint256 tokenId);

    event VkatPartiallyConverted(
        uint256 indexed originalTokenId,
        uint256 indexed splitTokenId,
        uint256 katAmount,
        uint256 sharesReceived
    );
    event VkatFullyConverted(uint256 indexed tokenId, uint256 katAmount, uint256 sharesReceived);

    constructor() {
        VERSION = address(this);
    }

    function exit(
        uint256 tokenId_,
        uint256 requestedKat_,
        uint256 minSharesReceived_
    ) external returns (uint256 sharesReceived) {
        _validateTrackedOwner(tokenId_);
        (uint256 lockedKat, ) = ESCROW.locked(tokenId_);
        if (requestedKat_ == 0 || requestedKat_ > lockedKat) revert InvalidAmount();
        if (requestedKat_ == lockedKat) return _exitWhole(tokenId_, lockedKat, minSharesReceived_);

        uint256 liveMinimum = ESCROW.minDeposit();
        if (requestedKat_ < liveMinimum) revert SplitBelowLiveMinimum(requestedKat_, liveMinimum);
        uint256 remainder = lockedKat - requestedKat_;
        if (remainder < liveMinimum) revert RemainderBelowLiveMinimum(remainder, liveMinimum);

        uint256 splitTokenId = ESCROW.split(tokenId_, requestedKat_);
        if (splitTokenId == tokenId_ || VKAT.ownerOf(splitTokenId) != VAULT) {
            revert InvalidSplitToken(splitTokenId);
        }
        (uint256 splitLockedKat, ) = ESCROW.locked(splitTokenId);
        if (splitLockedKat != requestedKat_) revert InvalidSplitToken(splitTokenId);

        sharesReceived = _depositNft(splitTokenId, minSharesReceived_);
        emit VkatPartiallyConverted(tokenId_, splitTokenId, requestedKat_, sharesReceived);
    }

    function exitWhole(uint256 tokenId_, uint256 minSharesReceived_) external returns (uint256 sharesReceived) {
        _validateTrackedOwner(tokenId_);
        (uint256 lockedKat, ) = ESCROW.locked(tokenId_);
        sharesReceived = _exitWhole(tokenId_, lockedKat, minSharesReceived_);
    }

    function _exitWhole(
        uint256 tokenId_,
        uint256 lockedKat_,
        uint256 minSharesReceived_
    ) private returns (uint256 sharesReceived) {
        sharesReceived = _depositNft(tokenId_, minSharesReceived_);
        CurveYieldVkatTrackingLib.remove(tokenId_);
        emit VkatFullyConverted(tokenId_, lockedKat_, sharesReceived);
    }

    function _depositNft(uint256 tokenId_, uint256 minSharesReceived_) private returns (uint256 sharesReceived) {
        uint256 beforeBalance = IERC20Katana(address(AVKAT)).balanceOf(VAULT);
        VKAT.approve(address(AVKAT), tokenId_);
        uint256 returnedShares = AVKAT.depositTokenId(tokenId_, VAULT);
        uint256 afterBalance = IERC20Katana(address(AVKAT)).balanceOf(VAULT);
        sharesReceived = afterBalance - beforeBalance;
        if (returnedShares != sharesReceived) revert ShareReturnMismatch(returnedShares, sharesReceived);
        if (sharesReceived < minSharesReceived_) {
            revert SharesReceivedTooLow(sharesReceived, minSharesReceived_);
        }
    }

    function _validateTrackedOwner(uint256 tokenId_) private view {
        if (address(this) != VAULT) revert WrongVault();
        if (!CurveYieldVkatTrackingLib.contains(tokenId_)) {
            revert CurveYieldVkatTrackingLib.TokenNotTracked(tokenId_);
        }
        if (VKAT.ownerOf(tokenId_) != VAULT) revert WrongNftOwner(tokenId_);
    }
}
