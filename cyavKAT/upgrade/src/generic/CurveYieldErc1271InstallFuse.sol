// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {CurveYieldVaultBase1271} from "../katana/CurveYieldVaultBase1271.sol";
import {CurveYieldSubstrateLib as Sub} from "../libraries/CurveYieldSubstrateLib.sol";

/// @notice enter / exit: the ERC-1271 base to install in / remove from the vault.
struct CurveYieldErc1271InstallFuseEnterData {
    address base1271; // a CurveYieldVaultBase1271 deployed for this vault's original base: must be a granted substrate
}

struct CurveYieldErc1271InstallFuseExitData {
    address base1271;
}

/// @title CurveYieldErc1271InstallFuse (custom: only for NEW vaults; not installed on cyavKAT, exception E3)
/// @notice `enter` sets `PLASMA_VAULT_BASE` from the vault's original base to a CurveYieldVaultBase1271 wrapper (which
/// delegates everything but `isValidSignature` to the original); `exit` restores the original exactly. The wrapper is a
/// typed substrate (`BASE_1271`, `ZERO_BALANCE_MARKET`, E6). Touches no balances: utility fuse. The vault in service
/// (cyavKAT) already runs the wrapper installed by the live `CurveYieldSignatureFuse`; there is no governance setter
/// for the base on this IPOR version (F10).
contract CurveYieldErc1271InstallFuse is IFuseCommon {
    address public immutable VERSION;
    uint256 public immutable override MARKET_ID;

    event CurveYieldErc1271InstallFuseEnter(address version, address base1271, address originalBase);
    event CurveYieldErc1271InstallFuseExit(address version, address base1271, address originalBase);

    error CurveYieldErc1271InstallFuseInvalidMarketId();
    error CurveYieldErc1271InstallFuseBaseNotGranted(address base1271);
    error CurveYieldErc1271InstallFuseUnexpectedBase(address current);
    error CurveYieldErc1271InstallFuseInvalidTransientInputs();

    constructor(uint256 marketId_) {
        if (marketId_ == 0) revert CurveYieldErc1271InstallFuseInvalidMarketId();
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(CurveYieldErc1271InstallFuseEnterData memory data_) public {
        if (!Sub.isGranted(Sub.BASE_1271, data_.base1271)) revert CurveYieldErc1271InstallFuseBaseNotGranted(data_.base1271);
        address original = CurveYieldVaultBase1271(data_.base1271).ORIGINAL_BASE();
        address current = PlasmaVaultStorageLib.getPlasmaVaultBase();
        if (current != original) revert CurveYieldErc1271InstallFuseUnexpectedBase(current);
        PlasmaVaultStorageLib.setPlasmaVaultBase(data_.base1271);
        emit CurveYieldErc1271InstallFuseEnter(VERSION, data_.base1271, original);
    }

    function exit(CurveYieldErc1271InstallFuseExitData memory data_) public {
        if (!Sub.isGranted(Sub.BASE_1271, data_.base1271)) revert CurveYieldErc1271InstallFuseBaseNotGranted(data_.base1271);
        address original = CurveYieldVaultBase1271(data_.base1271).ORIGINAL_BASE();
        address current = PlasmaVaultStorageLib.getPlasmaVaultBase();
        if (current != data_.base1271) revert CurveYieldErc1271InstallFuseUnexpectedBase(current);
        PlasmaVaultStorageLib.setPlasmaVaultBase(original);
        emit CurveYieldErc1271InstallFuseExit(VERSION, data_.base1271, original);
    }

    /// @notice R3 input [base1271]. Output []: configuration-only action.
    function enterTransient() external {
        bytes32[] memory words = TransientStorageLib.getInputs(VERSION);
        if (words.length != 1) revert CurveYieldErc1271InstallFuseInvalidTransientInputs();
        enter(CurveYieldErc1271InstallFuseEnterData(TypeConversionLib.toAddress(words[0])));
        TransientStorageLib.setOutputs(VERSION, new bytes32[](0));
    }

    /// @notice R3 input [base1271]. Output []: configuration-only action.
    function exitTransient() external {
        bytes32[] memory words = TransientStorageLib.getInputs(VERSION);
        if (words.length != 1) revert CurveYieldErc1271InstallFuseInvalidTransientInputs();
        exit(CurveYieldErc1271InstallFuseExitData(TypeConversionLib.toAddress(words[0])));
        TransientStorageLib.setOutputs(VERSION, new bytes32[](0));
    }
}
