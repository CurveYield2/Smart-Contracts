// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

interface IPlasmaVaultBaseGetterBurnV1 {
    function PLASMA_VAULT_BASE() external view returns (address);
}

interface IPlasmaVaultBaseBurnV1 {
    function updateInternal(address from, address to, uint256 value) external;
}

struct BurnRequestFeeDataEnter {
    uint256 amount;
}

/// @title IporBurnRequestFeeFuse_v1
/// @notice Standalone port of IPOR Fusion's CURRENT official BurnRequestFeeFuse (IPOR-Labs/ipor-fusion main,
///         contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol, `enter` only). Burns the shares held by the
///         vault's WithdrawManager (here: the 0.75% onboarding-fee shares) through PlasmaVaultBase.updateInternal.
/// @dev Why a port: the Katana FusionFactory still installs the pre-IL-6952 fuse (0x44D368e8...Df36e), which reads
///      the legacy withdraw-manager slot and reverts on new vaults. This copy reads the corrected slot with the legacy
///      fallback, exactly like upstream's PlasmaVaultStorageLib.getWithdrawManagerAddressWithLegacyFallback().
///      Runs by delegatecall in the PlasmaVault (ALPHA via execute).
contract IporBurnRequestFeeFuse_v1 {
    /// @dev PlasmaVaultStorageLib.WITHDRAW_MANAGER (corrected, IL-6952)
    bytes32 private constant WITHDRAW_MANAGER = 0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100;
    /// @dev PlasmaVaultStorageLib.WITHDRAW_MANAGER_LEGACY_SLOT (pre-IL-6952)
    bytes32 private constant WITHDRAW_MANAGER_LEGACY_SLOT =
        0xb37e8684757599da669b8aea811ee2b3693b2582d2c730fab3f4965fa2ec3e11;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event BurnRequestFeeEnter(address version, uint256 amount);

    error BurnRequestFeeWithdrawManagerNotSet();
    error BurnRequestFeePlasmaVaultBaseNotSet();
    error BurnRequestFeeExitNotImplemented();
    error BurnRequestFeeCallFailed(bytes reason);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(BurnRequestFeeDataEnter memory data_) public {
        address withdrawManager = _withdrawManager();
        if (withdrawManager == address(0)) revert BurnRequestFeeWithdrawManagerNotSet();
        if (data_.amount == 0) return;

        address plasmaVaultBase = IPlasmaVaultBaseGetterBurnV1(address(this)).PLASMA_VAULT_BASE();
        if (plasmaVaultBase == address(0)) revert BurnRequestFeePlasmaVaultBaseNotSet();

        (bool ok, bytes memory reason) = plasmaVaultBase.delegatecall(
            abi.encodeWithSelector(IPlasmaVaultBaseBurnV1.updateInternal.selector, withdrawManager, address(0), data_.amount)
        );
        if (!ok) revert BurnRequestFeeCallFailed(reason);

        emit BurnRequestFeeEnter(VERSION, data_.amount);
    }

    function exit(bytes calldata) external pure {
        revert BurnRequestFeeExitNotImplemented();
    }

    function _withdrawManager() private view returns (address manager_) {
        bytes32 slot = WITHDRAW_MANAGER;
        assembly {
            manager_ := sload(slot)
        }
        if (manager_ == address(0)) {
            bytes32 legacy = WITHDRAW_MANAGER_LEGACY_SLOT;
            assembly {
                manager_ := sload(legacy)
            }
        }
    }
}
