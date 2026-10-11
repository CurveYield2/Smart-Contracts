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

library VkatFuseStorageLib {
    bytes32 private constant TOKEN_IDS_SLOT = keccak256("curveyield.ipor.vkat.token-ids.v1");

    // Exact ERC-7201 market-substrate slot of the deployed IPOR Fusion PlasmaVaultStorageLib.
    bytes32 private constant IPOR_MARKET_SUBSTRATES_SLOT =
        0x78e40624004925a4ef6749756748b1deddc674477302d5b7fe18e5335cde3900;

    struct TokenIds {
        uint256[] values;
        mapping(uint256 => uint256) indexPlusOne;
    }

    error TokenAlreadyTracked(uint256 tokenId);
    error TokenNotTracked(uint256 tokenId);

    function tokenIds() internal pure returns (TokenIds storage ids) {
        bytes32 slot = TOKEN_IDS_SLOT;
        assembly {
            ids.slot := slot
        }
    }

    function add(uint256 tokenId) internal {
        TokenIds storage ids = tokenIds();
        if (ids.indexPlusOne[tokenId] != 0) revert TokenAlreadyTracked(tokenId);
        ids.values.push(tokenId);
        ids.indexPlusOne[tokenId] = ids.values.length;
    }

    function remove(uint256 tokenId) internal {
        TokenIds storage ids = tokenIds();
        uint256 indexPlusOne = ids.indexPlusOne[tokenId];
        if (indexPlusOne == 0) revert TokenNotTracked(tokenId);
        uint256 lastIndex = ids.values.length - 1;
        uint256 index = indexPlusOne - 1;
        if (index != lastIndex) {
            uint256 lastId = ids.values[lastIndex];
            ids.values[index] = lastId;
            ids.indexPlusOne[lastId] = indexPlusOne;
        }
        ids.values.pop();
        delete ids.indexPlusOne[tokenId];
    }

    function contains(uint256 tokenId) internal view returns (bool) {
        return tokenIds().indexPlusOne[tokenId] != 0;
    }

    function isGaugeGranted(uint256 marketId, address gauge) internal view returns (bool) {
        bytes32 marketSlot = keccak256(abi.encode(marketId, IPOR_MARKET_SUBSTRATES_SLOT));
        bytes32 gaugeKey = bytes32(uint256(uint160(gauge)));
        bytes32 allowanceSlot = keccak256(abi.encode(gaugeKey, marketSlot));
        uint256 allowance;
        assembly {
            allowance := sload(allowanceSlot)
        }
        return allowance == 1;
    }
}
