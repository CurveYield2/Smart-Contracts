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

interface IVkatNftBalance {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IVkatEscrowBalance {
    function locked(uint256 tokenId) external view returns (uint256 amount, uint256 start);
}

interface IKatPriceManager {
    function getAssetPrice(address asset) external view returns (uint256 price, uint256 decimals);
}

contract VkatBalanceFuse {
    uint256 public constant MARKET_ID = 54;
    address public immutable VERSION;

    address private constant VAULT = 0x5E4D67594c2BA85249231D483ebf3C9f55382c37;
    address private constant KAT = 0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d;
    IVkatNftBalance private constant VKAT = IVkatNftBalance(0x106F7D67Ea25Cb9eFf5064CF604ebf6259Ff296d);
    IVkatEscrowBalance private constant ESCROW = IVkatEscrowBalance(0x4d6fC15Ca6258b168225D283262743C623c13Ead);
    IKatPriceManager private constant PRICE_MANAGER = IKatPriceManager(0x7B46bfc6b34f032030cd1dD5814a7663cE4447D6);

    error InvalidKatPrice();

    constructor() {
        VERSION = address(this);
    }

    // Returns USD WAD, as required by IPOR Fusion's market-balance-fuse interface.
    function balanceOf() external view returns (uint256 usdWad) {
        VkatFuseStorageLib.TokenIds storage ids = VkatFuseStorageLib.tokenIds();
        uint256 count = ids.values.length;
        if (count == 0) return 0;

        (uint256 price, uint256 priceDecimals) = PRICE_MANAGER.getAssetPrice(KAT);
        if (price == 0 || priceDecimals > 36) revert InvalidKatPrice();
        uint256 divisor = 10 ** priceDecimals;

        for (uint256 i; i < count; ++i) {
            uint256 tokenId = ids.values[i];
            try VKAT.ownerOf(tokenId) returns (address owner) {
                if (owner != VAULT) continue;
            } catch {
                continue;
            }
            (uint256 amount, ) = ESCROW.locked(tokenId);
            usdWad += amount * price / divisor;
        }
    }
}
