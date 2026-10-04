// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title CyvbWbtcGatewayGatePreHook_v3
/// @notice Minimal IPOR PauseFunctionPreHook-style gate that permits only the configured gateway.
/// @dev This hook is registered only on the direct deposit/mint/withdraw/redeem selectors that must
///      route through the fee gateway. PlasmaVault itself supplies the selector to run(bytes4).
contract CyvbWbtcGatewayGatePreHook_v3 {
    address public immutable GATEWAY;

    error ZeroAddress();
    error GatewayRequired(bytes4 selector);

    constructor(address gateway_) {
        if (gateway_ == address(0)) revert ZeroAddress();
        GATEWAY = gateway_;
    }

    function run(bytes4 selector_) external view {
        if (msg.sender != GATEWAY) revert GatewayRequired(selector_);
    }
}
