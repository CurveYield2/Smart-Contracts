// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {CurveYieldVaultBase1271, CurveYieldErc1271StorageLib} from "./CurveYieldVaultBase1271.sol";

/// @title CurveYieldQuestSignerConfigFuse
/// @notice Persistent, configuration-only fuse for an already-installed CurveYieldVaultBase1271.
/// @dev Unlike the legacy CurveYieldSignatureFuse this NEVER writes PLASMA_VAULT_BASE. The factory-deployed
/// PlasmaVault and PlasmaVaultBase stay untouched. The vault continues to delegate its base functions through the
/// active ERC-1271 wrapper to its original factory-deployed PlasmaVaultBase. The IPOR vault enforces ALPHA on execute;
/// only its FUSE_MANAGER may register/remove this fuse. Removing the installation fuse does not remove this one.
contract CurveYieldQuestSignerConfigFuse is IFuseCommon {
    uint256 public immutable override MARKET_ID;
    address public immutable VAULT;
    address public immutable BASE_1271;
    address public immutable ORIGINAL_BASE;

    /// @notice Required by the cyavKAT V2 deployment gate. Prior/legacy fuses do not expose this marker.
    function QUEST_SIGNING_LAYER_VERSION() external pure returns (uint256) {
        return 2;
    }

    event QuestSignerSet(address indexed signer, bool enabled);
    event QuestSignPrefixSet(bytes prefix);

    error WrongContext();
    error UnexpectedBase(address current);
    error ZeroSigner();
    error InvalidAddress();

    constructor(uint256 marketId_, address vault_, address base1271_) {
        if (vault_ == address(0) || base1271_ == address(0) || base1271_.code.length == 0) {
            revert InvalidAddress();
        }
        MARKET_ID = marketId_;
        VAULT = vault_;
        BASE_1271 = base1271_;
        ORIGINAL_BASE = CurveYieldVaultBase1271(base1271_).ORIGINAL_BASE();
        if (ORIGINAL_BASE == address(0) || ORIGINAL_BASE.code.length == 0) revert InvalidAddress();
    }

    function setSigner(address signer_, bool enabled_) external {
        _ctx();
        if (signer_ == address(0)) revert ZeroSigner();
        CurveYieldErc1271StorageLib.layout().signers[signer_] = enabled_;
        emit QuestSignerSet(signer_, enabled_);
    }

    function setPrefix(bytes calldata prefix_) external {
        _ctx();
        CurveYieldErc1271StorageLib.layout().prefix = prefix_;
        emit QuestSignPrefixSet(prefix_);
    }

    function _ctx() private view {
        if (address(this) != VAULT) revert WrongContext();
        address current = PlasmaVaultStorageLib.getPlasmaVaultBase();
        if (current != BASE_1271) revert UnexpectedBase(current);
    }
}
