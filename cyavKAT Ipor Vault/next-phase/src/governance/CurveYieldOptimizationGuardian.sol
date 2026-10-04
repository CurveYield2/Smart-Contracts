// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

interface ICyGateGuardianLane {
    function executeGuardian(address target, bytes calldata data) external returns (bytes memory);
    function setConfigByGuardian(bytes32 key, uint256 value) external;
}

interface ICyAccessManagerPause {
    function updateTargetClosed(address target, bool closed) external;
}

/// @title CurveYieldOptimizationGuardian (PHASE3_DESIGN_SPEC §1.8, D-G8)
/// @notice The maintenance bot's only handle. Owners: the deployer, the fee Safe and the DAO (any one can act). The bot
/// operator can run registered actions within their bounds, and pause the vault; only owners can unpause.
///   - Actions: id -> (target, selector, takesValue, min, max). `run(id, value)` calls target.selector(value) (or with no
///     argument) through the governance gate's guardian lane, so the gate's allow-list and protections still apply.
///     Typical actions: allocation caps, vKAT allocation, Morpho cap decay, custody wind-up / rebalance.
///   - Pause: the guardian holds IPOR GUARDIAN_ROLE (2) and calls accessManager.updateTargetClosed(vault, …).
contract CurveYieldOptimizationGuardian {
    struct Action {
        address target;
        bytes4 selector;
        bool takesValue;
        bool enabled;
        uint256 min;
        uint256 max;
    }

    ICyGateGuardianLane public immutable GATE;
    ICyAccessManagerPause public immutable ACCESS_MANAGER;
    address public immutable VAULT;

    mapping(address => bool) public isOwner;
    uint256 public ownerCount;
    address public operator;
    Action[] private _actions;

    event OwnerSet(address indexed account, bool isOwner);
    event OperatorSet(address indexed operator);
    event ActionSet(uint256 indexed id, address target, bytes4 selector, bool takesValue, uint256 min, uint256 max, bool enabled);
    event ActionRun(uint256 indexed id, address indexed caller, uint256 value);
    event VaultPaused(address indexed caller, bool closed);

    error NotOwner();
    error NotOperatorOrOwner();
    error ActionDisabled();
    error OutOfBounds(uint256 value, uint256 min, uint256 max);
    error LastOwner();
    error InvalidAddress();

    modifier onlyOwner() {
        if (!isOwner[msg.sender]) revert NotOwner();
        _;
    }

    modifier onlyOperatorOrOwner() {
        if (msg.sender != operator && !isOwner[msg.sender]) revert NotOperatorOrOwner();
        _;
    }

    constructor(address gate_, address accessManager_, address vault_, address[] memory owners_, address operator_) {
        if (gate_ == address(0) || accessManager_ == address(0) || vault_ == address(0) || owners_.length == 0) {
            revert InvalidAddress();
        }
        GATE = ICyGateGuardianLane(gate_);
        ACCESS_MANAGER = ICyAccessManagerPause(accessManager_);
        VAULT = vault_;
        for (uint256 i; i < owners_.length; ++i) {
            if (owners_[i] == address(0) || isOwner[owners_[i]]) revert InvalidAddress();
            isOwner[owners_[i]] = true;
            emit OwnerSet(owners_[i], true);
        }
        ownerCount = owners_.length;
        operator = operator_;
        emit OperatorSet(operator_);
    }

    // ---------------------------------------------------------------- owners

    function setOwner(address account_, bool owner_) external onlyOwner {
        if (account_ == address(0)) revert InvalidAddress();
        if (owner_ == isOwner[account_]) return;
        if (!owner_ && ownerCount == 1) revert LastOwner();
        isOwner[account_] = owner_;
        ownerCount = owner_ ? ownerCount + 1 : ownerCount - 1;
        emit OwnerSet(account_, owner_);
    }

    function setOperator(address operator_) external onlyOwner {
        operator = operator_;
        emit OperatorSet(operator_);
    }

    /// @notice Registers (id == length) or updates an action. Owners set the bot's bounds.
    function setAction(uint256 id_, address target_, bytes4 selector_, bool takesValue_, uint256 min_, uint256 max_, bool enabled_)
        external onlyOwner
    {
        if (target_ == address(0) || min_ > max_) revert InvalidAddress();
        Action memory a = Action(target_, selector_, takesValue_, enabled_, min_, max_);
        if (id_ == _actions.length) _actions.push(a);
        else _actions[id_] = a;
        emit ActionSet(id_, target_, selector_, takesValue_, min_, max_, enabled_);
    }

    // ---------------------------------------------------------------- bot

    function run(uint256 id_, uint256 value_) external onlyOperatorOrOwner returns (bytes memory) {
        Action storage a = _actions[id_];
        if (!a.enabled) revert ActionDisabled();
        bytes memory data;
        if (a.takesValue) {
            if (value_ < a.min || value_ > a.max) revert OutOfBounds(value_, a.min, a.max);
            data = abi.encodeWithSelector(a.selector, value_);
        } else {
            data = abi.encodeWithSelector(a.selector);
        }
        emit ActionRun(id_, msg.sender, value_);
        return GATE.executeGuardian(a.target, data);
    }

    /// @notice Emergency pause: the operator or an owner can close the vault.
    /// @notice Sets a GUARDIAN-class setting in the governance gate, inside the gate's guardian range for that key
    /// (GATE_CONFIG_SPEC G2: numeric bot actions are ranged in the gate, not in this contract's action list).
    function setConfig(bytes32 key_, uint256 value_) external onlyOperatorOrOwner {
        GATE.setConfigByGuardian(key_, value_);
    }

    function pauseVault() external onlyOperatorOrOwner {
        ACCESS_MANAGER.updateTargetClosed(VAULT, true);
        emit VaultPaused(msg.sender, true);
    }

    /// @notice Only owners can reopen the vault.
    function unpauseVault() external onlyOwner {
        ACCESS_MANAGER.updateTargetClosed(VAULT, false);
        emit VaultPaused(msg.sender, false);
    }

    // ---------------------------------------------------------------- views

    function actionOf(uint256 id_) external view returns (Action memory) {
        return _actions[id_];
    }

    function actionsLength() external view returns (uint256) {
        return _actions.length;
    }
}
