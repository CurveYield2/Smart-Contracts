// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title CyvbWbtcLtvConfig_v3
/// @notice Governance-owned LTV policy and single f(x) position registry for cyvbWBTC.
/// @dev Configurability is +/-10% RELATIVE to each user-specified baseline (20% total range).
contract CyvbWbtcLtvConfig_v3 {
    uint16 public constant BPS = 10_000;

    uint16 public constant BASE_TARGET_LTV_BPS = 5_000;
    uint16 public constant BASE_HIGH_TRIGGER_BPS = 6_000;
    uint16 public constant BASE_HIGH_RESET_BPS = 5_800;
    uint16 public constant BASE_LOW_TRIGGER_BPS = 4_500;
    uint16 public constant BASE_LOW_RESET_BPS = 5_000;

    // +/-10% relative ranges.
    uint16 public constant MIN_TARGET_LTV_BPS = 4_500;
    uint16 public constant MAX_TARGET_LTV_BPS = 5_500;

    uint16 public constant MIN_HIGH_TRIGGER_BPS = 5_400;
    uint16 public constant MAX_HIGH_TRIGGER_BPS = 6_600;

    uint16 public constant MIN_HIGH_RESET_BPS = 5_220;
    uint16 public constant MAX_HIGH_RESET_BPS = 6_380;

    uint16 public constant MIN_LOW_TRIGGER_BPS = 4_050;
    uint16 public constant MAX_LOW_TRIGGER_BPS = 4_950;

    uint16 public constant MIN_LOW_RESET_BPS = 4_500;
    uint16 public constant MAX_LOW_RESET_BPS = 5_500;

    uint16 public constant INSTANT_WITHDRAW_MAX_LTV_BPS = 5_500;

    struct LtvPolicy {
        uint16 targetLtvBps;
        uint16 highTriggerBps;
        uint16 highResetBps;
        uint16 lowTriggerBps;
        uint16 lowResetBps;
    }

    address public owner;
    address public pendingOwner;
    address public vault;
    uint256 public positionId;

    LtvPolicy private _policy;

    error NotOwner();
    error NotPendingOwner();
    error NotVault();
    error ZeroAddress();
    error VaultAlreadySet();
    error PositionAlreadySet(uint256 currentPositionId);
    error ZeroPositionId();
    error ValueOutOfRange();
    error InvalidOrdering();

    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event VaultBound(address indexed vault);
    event PositionIdRecorded(uint256 indexed positionId);
    event LtvPolicyUpdated(
        uint16 targetLtvBps,
        uint16 highTriggerBps,
        uint16 highResetBps,
        uint16 lowTriggerBps,
        uint16 lowResetBps
    );

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        _policy = LtvPolicy({
            targetLtvBps: BASE_TARGET_LTV_BPS,
            highTriggerBps: BASE_HIGH_TRIGGER_BPS,
            highResetBps: BASE_HIGH_RESET_BPS,
            lowTriggerBps: BASE_LOW_TRIGGER_BPS,
            lowResetBps: BASE_LOW_RESET_BPS
        });
        emit OwnershipTransferred(address(0), owner_);
        emit LtvPolicyUpdated(
            BASE_TARGET_LTV_BPS,
            BASE_HIGH_TRIGGER_BPS,
            BASE_HIGH_RESET_BPS,
            BASE_LOW_TRIGGER_BPS,
            BASE_LOW_RESET_BPS
        );
    }

    function getLtvPolicy() external view returns (LtvPolicy memory) {
        return _policy;
    }

    function setLtvPolicy(
        uint16 targetLtvBps_,
        uint16 highTriggerBps_,
        uint16 highResetBps_,
        uint16 lowTriggerBps_,
        uint16 lowResetBps_
    ) external onlyOwner {
        if (
            targetLtvBps_ < MIN_TARGET_LTV_BPS ||
            targetLtvBps_ > MAX_TARGET_LTV_BPS ||
            highTriggerBps_ < MIN_HIGH_TRIGGER_BPS ||
            highTriggerBps_ > MAX_HIGH_TRIGGER_BPS ||
            highResetBps_ < MIN_HIGH_RESET_BPS ||
            highResetBps_ > MAX_HIGH_RESET_BPS ||
            lowTriggerBps_ < MIN_LOW_TRIGGER_BPS ||
            lowTriggerBps_ > MAX_LOW_TRIGGER_BPS ||
            lowResetBps_ < MIN_LOW_RESET_BPS ||
            lowResetBps_ > MAX_LOW_RESET_BPS
        ) revert ValueOutOfRange();

        // Hysteresis/order invariant:
        // low trigger < low reset <= normal target <= high reset < high trigger.
        if (
            lowTriggerBps_ >= lowResetBps_ ||
            lowResetBps_ > targetLtvBps_ ||
            targetLtvBps_ > highResetBps_ ||
            highResetBps_ >= highTriggerBps_
        ) revert InvalidOrdering();

        _policy = LtvPolicy({
            targetLtvBps: targetLtvBps_,
            highTriggerBps: highTriggerBps_,
            highResetBps: highResetBps_,
            lowTriggerBps: lowTriggerBps_,
            lowResetBps: lowResetBps_
        });

        emit LtvPolicyUpdated(
            targetLtvBps_,
            highTriggerBps_,
            highResetBps_,
            lowTriggerBps_,
            lowResetBps_
        );
    }

    function bindVault(address vault_) external onlyOwner {
        if (vault_ == address(0) || vault_.code.length == 0) revert ZeroAddress();
        if (vault != address(0)) revert VaultAlreadySet();
        vault = vault_;
        emit VaultBound(vault_);
    }

    function recordPositionId(uint256 positionId_) external {
        if (msg.sender != vault) revert NotVault();
        if (positionId_ == 0) revert ZeroPositionId();
        if (positionId != 0) revert PositionAlreadySet(positionId);
        positionId = positionId_;
        emit PositionIdRecorded(positionId_);
    }

    function transferOwnership(address newOwner_) external onlyOwner {
        if (newOwner_ == address(0)) revert ZeroAddress();
        pendingOwner = newOwner_;
        emit OwnershipTransferStarted(owner, newOwner_);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previousOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(previousOwner, owner);
    }
}
