// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title CyvbWbtcZeroBalanceFuse_v1
/// @notice Zero-value balance fuse for IPOR's official ZERO_BALANCE_MARKET.
/// @dev Mirrors IPOR-Labs/ipor-fusion ZeroBalanceFuse behavior for an execution-only market.
contract CyvbWbtcZeroBalanceFuse_v1 {
    uint256 public constant MARKET_ID = type(uint256).max;

    function balanceOf() external pure returns (uint256) {
        return 0;
    }
}
