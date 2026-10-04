// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {CurveYieldVaultBase1271, CurveYieldErc1271StorageLib} from "./CurveYieldVaultBase1271.sol";

/// @title CurveYieldSignatureFuse
/// @notice Run by the vault (execute, ALPHA) to switch its ERC-1271 login signing on and off and to configure it.
///   install()             PLASMA_VAULT_BASE: original -> CurveYieldVaultBase1271 (wraps the original)
///   uninstall()           PLASMA_VAULT_BASE: back to the original, exactly
///   setSigner(a, on)      authorize / remove a wallet that may sign log-ins for the vault
///   setPrefix(bytes)      the start every signed message must have (domain + vault address); empty = signing off
/// Touches no balances; MARKET_ID is ERC20_VAULT_BALANCE (7) only because IPOR refreshes the fuse's market after
/// execute (registered markets only).
contract CurveYieldSignatureFuse is IFuseCommon {
    uint256 public immutable override MARKET_ID;
    address public immutable VAULT;
    address public immutable BASE_1271;
    address public immutable ORIGINAL_BASE;

    event QuestSigningInstalled(address base1271, address originalBase);
    event QuestSigningUninstalled(address originalBase);
    event QuestSignerSet(address indexed signer, bool enabled);
    event QuestSignPrefixSet(bytes prefix);

    error WrongContext();
    error UnexpectedBase(address current);
    error ZeroSigner();

    constructor(uint256 marketId_, address vault_, address base1271_) {
        MARKET_ID = marketId_;
        VAULT = vault_;
        BASE_1271 = base1271_;
        ORIGINAL_BASE = CurveYieldVaultBase1271(base1271_).ORIGINAL_BASE();
    }

    function install() external {
        _ctx();
        address current = PlasmaVaultStorageLib.getPlasmaVaultBase();
        if (current != ORIGINAL_BASE) revert UnexpectedBase(current);
        PlasmaVaultStorageLib.setPlasmaVaultBase(BASE_1271);
        emit QuestSigningInstalled(BASE_1271, ORIGINAL_BASE);
    }

    function uninstall() external {
        _ctx();
        address current = PlasmaVaultStorageLib.getPlasmaVaultBase();
        if (current != BASE_1271) revert UnexpectedBase(current);
        PlasmaVaultStorageLib.setPlasmaVaultBase(ORIGINAL_BASE);
        emit QuestSigningUninstalled(ORIGINAL_BASE);
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
    }
}
