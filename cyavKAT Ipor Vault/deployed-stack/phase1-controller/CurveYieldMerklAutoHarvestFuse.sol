// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {FuseAction, IMerklDistributorKatana} from "./interfaces/CurveYieldKatanaInterfaces.sol";

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

interface ICurveYieldMerklSwapConfig {
    function SWAP_FUSE() external view returns (address);
}

interface ICurveYieldMerklSwapFuse {
    function SWEEP_MARKER() external view returns (bytes32);
}

interface ICurveYieldPlasmaVaultInternal {
    function executeInternal(FuseAction[] calldata actions) external;
}

/// @notice Claims Merkl rewards to the vault and atomically invokes the registered router swap fuse.
contract CurveYieldMerklAutoHarvestFuse is Ownable {
    address public immutable VERSION;
    address public immutable VAULT;
    address public immutable MANAGER;
    address public immutable DISTRIBUTOR;
    address public SWAP_FUSE;

    error InvalidAddress();
    error WrongContext();
    error InvalidInput();
    error SwapNotConsumed();

    event SwapFuseUpdated(address indexed swapFuse);
    event MerklClaimAndSweep(address indexed swapFuse, uint256 claimEntries);

    constructor(address owner_, address vault_, address manager_, address distributor_, address swapFuse_)
        Ownable(owner_)
    {
        if (owner_ == address(0) || vault_ == address(0) || manager_ == address(0) ||
            distributor_ == address(0) || swapFuse_ == address(0)) revert InvalidAddress();
        VERSION = address(this);
        VAULT = vault_;
        MANAGER = manager_;
        DISTRIBUTOR = distributor_;
        SWAP_FUSE = swapFuse_;
    }

    function setSwapFuse(address swapFuse_) external onlyOwner {
        if (address(this) != VERSION) revert WrongContext();
        if (swapFuse_ == address(0)) revert InvalidAddress();
        SWAP_FUSE = swapFuse_;
        emit SwapFuseUpdated(swapFuse_);
    }

    function harvest(address[] calldata tokens_, uint256[] calldata cumulativeAmounts_, bytes32[][] calldata proofs_)
        external
    {
        if (address(this) != VAULT || msg.sender != MANAGER) revert WrongContext();
        uint256 length = tokens_.length;
        if (length == 0 || length != cumulativeAmounts_.length || length != proofs_.length) revert InvalidInput();
        address[] memory users = new address[](length);
        for (uint256 i; i < length; ++i) {
            if (tokens_[i] == address(0)) revert InvalidInput();
            users[i] = VAULT;
            for (uint256 j; j < i; ++j) if (tokens_[j] == tokens_[i]) revert InvalidInput();
        }
        IMerklDistributorKatana(DISTRIBUTOR).claim(users, tokens_, cumulativeAmounts_, proofs_);

        address swapFuse = ICurveYieldMerklSwapConfig(VERSION).SWAP_FUSE();
        bytes32[] memory marker = new bytes32[](1);
        marker[0] = ICurveYieldMerklSwapFuse(swapFuse).SWEEP_MARKER();
        TransientStorageLib.setInputs(swapFuse, marker);
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(swapFuse, abi.encodeWithSignature("swapAllRewards()"));
        ICurveYieldPlasmaVaultInternal(VAULT).executeInternal(actions);
        if (TransientStorageLib.getInputs(swapFuse).length != 0) revert SwapNotConsumed();
        emit MerklClaimAndSweep(swapFuse, length);
    }
}
