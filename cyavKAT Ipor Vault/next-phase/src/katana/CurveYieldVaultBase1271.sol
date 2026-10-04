// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @notice Namespaced (ERC-7201) storage for the vault's ERC-1271 login signer, written only by
/// CurveYieldSignatureFuse (delegatecalled by the vault) and read by CurveYieldVaultBase1271 (delegatecalled by the vault).
library CurveYieldErc1271StorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("curveyield.vault.erc1271")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0x9cdfb86b5df26253870327d020bdb1a8c872979d779c2d3bac3d2bcc1c7fac00;

    struct Layout {
        mapping(address => bool) signers;
        bytes prefix; // every accepted message starts with this (binds the domain AND the vault address)
    }

    function layout() internal pure returns (Layout storage l_) {
        bytes32 slot = SLOT;
        assembly {
            l_.slot := slot
        }
    }
}

/// @title CurveYieldVaultBase1271
/// @notice Gives an IPOR PlasmaVault ERC-1271 so it can sign in to off-chain services (Katana Quests: SIWE / EIP-4361)
/// as itself. Installed as the vault's PLASMA_VAULT_BASE by CurveYieldSignatureFuse: the vault's fallback delegatecalls
/// here; `isValidSignature` is answered here and EVERY other call is delegated unchanged to ORIGINAL_BASE (the vault's
/// real PlasmaVaultBase). Uninstall restores ORIGINAL_BASE exactly.
///
/// A signature is valid only when ALL hold:
///   signature = abi.encode(bytes message, bytes ecdsaSig)
///   hash      = EIP-191 personal-sign hash of `message`   (so it can never match an EIP-712 permit / Permit2 hash)
///   message   starts with the configured prefix             ("app.katana.network wants you to sign in with your
///                                                            Ethereum account:\n<vault>\n": one domain, this vault)
///   ecdsaSig  = personal_sign of the SAME message by an authorized signer (e.g. the operator's browser wallet)
/// The vault therefore signs nothing but log-in messages for the configured domain; no approvals, no permits.
contract CurveYieldVaultBase1271 {
    bytes4 internal constant MAGIC = 0x1626ba7e;
    bytes4 internal constant INVALID = 0xffffffff;

    address public immutable ORIGINAL_BASE;

    error ZeroBase();

    constructor(address originalBase_) {
        if (originalBase_ == address(0)) revert ZeroBase();
        ORIGINAL_BASE = originalBase_;
    }

    function isValidSignature(bytes32 hash_, bytes calldata signature_) external view returns (bytes4) {
        if (signature_.length < 128) return INVALID; // two dynamic-bytes heads at least
        (bytes memory message, bytes memory sig) = abi.decode(signature_, (bytes, bytes));
        CurveYieldErc1271StorageLib.Layout storage l = CurveYieldErc1271StorageLib.layout();
        bytes memory prefix = l.prefix;
        uint256 n = prefix.length;
        if (n == 0 || message.length < n) return INVALID;
        if (MessageHashUtils.toEthSignedMessageHash(message) != hash_) return INVALID;
        bytes32 head;
        assembly {
            head := keccak256(add(message, 0x20), n)
        }
        if (head != keccak256(prefix)) return INVALID;
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash_, sig);
        if (err != ECDSA.RecoverError.NoError || !l.signers[signer]) return INVALID;
        return MAGIC;
    }

    /// @notice Views of the vault's login-signing setup (answered through the vault while installed).
    function isQuestSigner(address signer_) external view returns (bool) {
        return CurveYieldErc1271StorageLib.layout().signers[signer_];
    }

    function questSignPrefix() external view returns (bytes memory) {
        return CurveYieldErc1271StorageLib.layout().prefix;
    }

    /// @dev Everything else: the vault's original base, unchanged (same storage, same msg.sender, return data bubbled).
    fallback() external {
        address base = ORIGINAL_BASE;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), base, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
