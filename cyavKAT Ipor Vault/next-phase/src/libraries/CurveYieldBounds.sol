// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @notice Inclusive [min, max] range fixed at construction (#9: limits are constructor values, not constants).
struct CyBound {
    uint256 min;
    uint256 max;
}

library CurveYieldBounds {
    error InvalidBound(bytes32 setting, uint256 min, uint256 max);
    error OutOfBounds(bytes32 setting, uint256 value, uint256 min, uint256 max);

    function validate(CyBound memory bound_, bytes32 setting_) internal pure {
        if (bound_.min > bound_.max) revert InvalidBound(setting_, bound_.min, bound_.max);
    }

    function check(CyBound memory bound_, bytes32 setting_, uint256 value_) internal pure returns (uint256) {
        if (value_ < bound_.min || value_ > bound_.max) revert OutOfBounds(setting_, value_, bound_.min, bound_.max);
        return value_;
    }
}
