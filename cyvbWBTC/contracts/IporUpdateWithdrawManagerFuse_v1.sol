// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

struct UpdateWithdrawManagerFuseEnterData {
    address newManager;
}

/// @title IporUpdateWithdrawManagerFuse_v1
/// @notice Standalone port of IPOR Fusion's UpdateWithdrawManagerMaintenanceFuse (`enter` only): points the PlasmaVault
///         at a new withdraw manager by writing PlasmaVaultStorageLib's corrected WITHDRAW_MANAGER slot (IL-6952).
///         Used once by DeployCyvbWBTC to install CyvbWbtcWithdrawManager_v1. Runs by delegatecall in the vault (ALPHA).
contract IporUpdateWithdrawManagerFuse_v1 {
    /// @dev PlasmaVaultStorageLib.WITHDRAW_MANAGER (corrected, IL-6952)
    bytes32 private constant WITHDRAW_MANAGER = 0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event WithdrawManagerUpdated(address version, address newManager);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(UpdateWithdrawManagerFuseEnterData memory data_) external {
        if (data_.newManager == address(0)) return;
        bytes32 slot = WITHDRAW_MANAGER;
        address manager = data_.newManager;
        assembly {
            sstore(slot, manager)
        }
        emit WithdrawManagerUpdated(VERSION, manager);
    }

    function exit(bytes memory) external pure {}
}
