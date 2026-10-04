// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title CyvbWbtcGatewayGatePreHook_v3
/// @notice Makes the cyvbWBTC gateway mandatory for every direct user deposit/mint and instant exit.
/// @dev IPOR executes pre-hooks by delegatecall from PlasmaVault. Therefore address(this) is the
///      PlasmaVault while msg.sender is the actual caller of the user-facing ERC4626 function.
///      Scheduled redeemFromRequest is intentionally NOT gated.
contract CyvbWbtcGatewayGatePreHook_v3 {
    address public immutable VERSION;
    address public immutable VAULT;
    address public immutable GATEWAY;

    bytes4 private constant DEPOSIT_SELECTOR = bytes4(keccak256("deposit(uint256,address)"));
    bytes4 private constant MINT_SELECTOR = bytes4(keccak256("mint(uint256,address)"));
    bytes4 private constant DEPOSIT_WITH_PERMIT_SELECTOR =
        bytes4(keccak256("depositWithPermit(uint256,address,uint256,uint8,bytes32,bytes32)"));
    bytes4 private constant WITHDRAW_SELECTOR = bytes4(keccak256("withdraw(uint256,address,address)"));
    bytes4 private constant REDEEM_SELECTOR = bytes4(keccak256("redeem(uint256,address,address)"));

    error InvalidAddress();
    error WrongVaultContext();
    error UnsupportedSelector(bytes4 selector);
    error GatewayRequired(address caller, bytes4 selector);

    constructor(address vault_, address gateway_) {
        if (vault_ == address(0) || gateway_ == address(0)) revert InvalidAddress();
        if (vault_.code.length == 0 || gateway_.code.length == 0) revert InvalidAddress();

        VERSION = address(this);
        VAULT = vault_;
        GATEWAY = gateway_;
    }

    function run(bytes4 selector_) external view {
        if (address(this) != VAULT) revert WrongVaultContext();

        if (
            selector_ != DEPOSIT_SELECTOR &&
            selector_ != MINT_SELECTOR &&
            selector_ != DEPOSIT_WITH_PERMIT_SELECTOR &&
            selector_ != WITHDRAW_SELECTOR &&
            selector_ != REDEEM_SELECTOR
        ) revert UnsupportedSelector(selector_);

        if (msg.sender != GATEWAY) revert GatewayRequired(msg.sender, selector_);
    }
}
