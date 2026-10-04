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

interface IVkatVotingEscrowAccounting {
    function ownedTokens(address owner) external view returns (uint256[] memory tokenIds);
    function locked(uint256 tokenId) external view returns (uint256 amount, uint256 start);
}

/// @notice Read-only ERC20-shaped view of KAT locked in an account's vKAT NFTs.
/// @dev MARKET_ID and balanceOf() let this contract replace market 54's balance fuse with a zero
///      balance, while balanceOf(address) lets IPOR's standard ERC20 market account for the position.
contract VkatErc20AccountingAdapter {
    uint256 public constant MARKET_ID = 54;
    string public constant name = "Vault vKAT Accounting Position";
    string public constant symbol = "vKAT Position";
    uint8 public constant decimals = 18;

    IVkatVotingEscrowAccounting private constant VOTING_ESCROW =
        IVkatVotingEscrowAccounting(0x4d6fC15Ca6258b168225D283262743C623c13Ead);

    function balanceOf(address account) external view returns (uint256 balance) {
        uint256[] memory tokenIds = VOTING_ESCROW.ownedTokens(account);
        uint256 length = tokenIds.length;
        for (uint256 i; i < length; ++i) {
            (uint256 amount, ) = VOTING_ESCROW.locked(tokenIds[i]);
            balance += amount;
        }
    }

    function balanceOf() external pure returns (uint256) {
        return 0;
    }
}
