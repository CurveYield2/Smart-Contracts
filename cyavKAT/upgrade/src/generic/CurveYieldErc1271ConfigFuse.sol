// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {CurveYieldErc1271StorageLib} from "../katana/CurveYieldVaultBase1271.sol";
import {CurveYieldSubstrateLib as Sub} from "../libraries/CurveYieldSubstrateLib.sol";

/// @notice enter: configure the log-in signing of a vault whose base is a granted ERC-1271 wrapper.
struct CurveYieldErc1271ConfigFuseEnterData {
    address signer; // the wallet that may sign log-ins for the vault (address(0) = leave signers unchanged)
    bool enabled;
    bool updatePrefix;
    bytes prefix; // the start every accepted message must have (domain + vault address); empty = signing off
}

/// @title CurveYieldErc1271ConfigFuse (custom: only for NEW vaults; not installed on cyavKAT, exception E3)
/// @notice Writes the signer and the message prefix of the ERC-1271 wrapper into the vault's ERC-7201 storage
/// (`io.curveyield.erc1271`), only while the vault's installed base is a granted `BASE_1271` substrate. Split from the
/// install fuse (one action per fuse). Utility fuse: `ZERO_BALANCE_MARKET`.
contract CurveYieldErc1271ConfigFuse is IFuseCommon {
    address public immutable VERSION;
    uint256 public immutable override MARKET_ID;

    event CurveYieldErc1271ConfigFuseEnter(address version, address signer, bool enabled, bool prefixUpdated);

    error CurveYieldErc1271ConfigFuseInvalidMarketId();
    error CurveYieldErc1271ConfigFuseBaseNotGranted(address current);
    error CurveYieldErc1271ConfigFuseExitNotSupported();
    error CurveYieldErc1271ConfigFuseInvalidTransientInputs();

    constructor(uint256 marketId_) {
        if (marketId_ == 0) revert CurveYieldErc1271ConfigFuseInvalidMarketId();
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(CurveYieldErc1271ConfigFuseEnterData memory data_) public {
        address current = PlasmaVaultStorageLib.getPlasmaVaultBase();
        if (!Sub.isGranted(Sub.BASE_1271, current)) revert CurveYieldErc1271ConfigFuseBaseNotGranted(current);
        CurveYieldErc1271StorageLib.Layout storage l = CurveYieldErc1271StorageLib.layout();
        if (data_.signer != address(0)) l.signers[data_.signer] = data_.enabled;
        if (data_.updatePrefix) l.prefix = data_.prefix;
        emit CurveYieldErc1271ConfigFuseEnter(VERSION, data_.signer, data_.enabled, data_.updatePrefix);
    }

    function exit(bytes calldata) external pure {
        revert CurveYieldErc1271ConfigFuseExitNotSupported();
    }

    /// @notice R3 transient format: [signer, enabled(0/1), updatePrefix(0/1),
    /// prefixByteLength, prefixBytesWord0, prefixBytesWord1, ...]. Each prefix
    /// word stores bytes in network order (first byte in the most significant byte).
    function enterTransient() external {
        bytes32[] memory words = TransientStorageLib.getInputs(VERSION);
        if (words.length < 4) revert CurveYieldErc1271ConfigFuseInvalidTransientInputs();
        uint256 size = uint256(words[3]);
        if (size > 512 || words.length != 4 + ((size + 31) / 32)
            || uint256(words[1]) > 1 || uint256(words[2]) > 1) {
            revert CurveYieldErc1271ConfigFuseInvalidTransientInputs();
        }
        bytes memory prefix = new bytes(size);
        for (uint256 i; i < size; ++i) {
            prefix[i] = bytes1(uint8(uint256(words[4 + i / 32]) >> (248 - 8 * (i % 32))));
        }
        enter(CurveYieldErc1271ConfigFuseEnterData({
            signer: TypeConversionLib.toAddress(words[0]),
            enabled: uint256(words[1]) == 1, updatePrefix: uint256(words[2]) == 1, prefix: prefix
        }));
        TransientStorageLib.setOutputs(VERSION, new bytes32[](0));
    }

    function exitTransient() external pure {
        revert CurveYieldErc1271ConfigFuseExitNotSupported();
    }
}
