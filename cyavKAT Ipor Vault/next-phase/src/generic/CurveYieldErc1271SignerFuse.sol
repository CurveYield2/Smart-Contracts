// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {CurveYieldVaultBase1271, CurveYieldErc1271StorageLib} from "../katana/CurveYieldVaultBase1271.sol";

enum Erc1271SignerAction {
    INSTALL, // PLASMA_VAULT_BASE: the wrapper's ORIGINAL_BASE -> the wrapper
    UNINSTALL, // back to ORIGINAL_BASE, exactly
    SET_SIGNER, // authorise / remove a wallet that may sign log-ins for the vault
    SET_PREFIX // the start every accepted message must have (domain + vault address); empty = signing off
}

struct Erc1271SignerEnterData {
    Erc1271SignerAction action;
    address base1271; // a CurveYieldVaultBase1271 deployed for this vault's original base: must be a market substrate
    address signer; // SET_SIGNER
    bool enabled; // SET_SIGNER
    bytes prefix; // SET_PREFIX
}

/// @title CurveYieldErc1271SignerFuse (generic, IPOR style)
/// @notice Gives any Plasma Vault ERC-1271 log-in signing (SIWE-style services) through CurveYieldVaultBase1271, which
/// wraps the vault's own PlasmaVaultBase and delegates everything else to it unchanged. Only personal-sign log-in
/// messages starting with the configured prefix and signed by a configured signer are valid: no permits, no approvals.
/// Generic version of CurveYieldSignatureFuse (no vault address; the wrapper is a granted substrate).
contract CurveYieldErc1271SignerFuse is IFuseCommon {
    address public immutable VERSION;
    uint256 public constant TYPE_BASE_1271 = 7;

    uint256 public immutable override MARKET_ID;
    uint256 public immutable SUBSTRATE_MARKET_ID;

    event Erc1271SignerUpdated(address version, Erc1271SignerAction action, address base1271, address signer, bool enabled);

    error BaseNotGranted(address base1271);
    error UnexpectedBase(address current);
    error ZeroSigner();

    constructor(uint256 marketId_, uint256 substrateMarketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        SUBSTRATE_MARKET_ID = substrateMarketId_;
    }

    function enter(Erc1271SignerEnterData memory data_) external {
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(
            SUBSTRATE_MARKET_ID, bytes32((TYPE_BASE_1271 << 160) | uint256(uint160(data_.base1271)))
        )) revert BaseNotGranted(data_.base1271);
        address original = CurveYieldVaultBase1271(data_.base1271).ORIGINAL_BASE();
        address current = PlasmaVaultStorageLib.getPlasmaVaultBase();
        if (data_.action == Erc1271SignerAction.INSTALL) {
            if (current != original) revert UnexpectedBase(current);
            PlasmaVaultStorageLib.setPlasmaVaultBase(data_.base1271);
        } else if (data_.action == Erc1271SignerAction.UNINSTALL) {
            if (current != data_.base1271) revert UnexpectedBase(current);
            PlasmaVaultStorageLib.setPlasmaVaultBase(original);
        } else if (data_.action == Erc1271SignerAction.SET_SIGNER) {
            if (data_.signer == address(0)) revert ZeroSigner();
            CurveYieldErc1271StorageLib.layout().signers[data_.signer] = data_.enabled;
        } else {
            CurveYieldErc1271StorageLib.layout().prefix = data_.prefix;
        }
        emit Erc1271SignerUpdated(VERSION, data_.action, data_.base1271, data_.signer, data_.enabled);
    }
}
