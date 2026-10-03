// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title CyvbWbtcInstantExitGatePreHook_v1
/// @notice Forces cyvbWBTC instant withdraw/redeem calls through the fee gateway.
/// @dev IPOR executes this hook by delegatecall from PlasmaVault, so address(this) is the vault
///      and msg.sender remains the original vault caller.
contract CyvbWbtcInstantExitGatePreHook_v1 {
    address public immutable VERSION;
    address public immutable VAULT;
    address public immutable GATEWAY;

    bytes4 private constant WITHDRAW_SELECTOR = bytes4(keccak256("withdraw(uint256,address,address)"));
    bytes4 private constant REDEEM_SELECTOR = bytes4(keccak256("redeem(uint256,address,address)"));

    error InvalidAddress();
    error WrongVaultContext();
    error UnsupportedSelector(bytes4 selector);
    error InstantExitMustUseGateway(address caller);

    constructor(address vault_, address gateway_) {
        if (vault_ == address(0) || gateway_ == address(0)) revert InvalidAddress();
        if (vault_.code.length == 0 || gateway_.code.length == 0) revert InvalidAddress();

        VERSION = address(this);
        VAULT = vault_;
        GATEWAY = gateway_;
    }

    function run(bytes4 selector_) external view {
        if (address(this) != VAULT) revert WrongVaultContext();
        if (selector_ != WITHDRAW_SELECTOR && selector_ != REDEEM_SELECTOR) {
            revert UnsupportedSelector(selector_);
        }
        if (msg.sender != GATEWAY) revert InstantExitMustUseGateway(msg.sender);
    }
}
