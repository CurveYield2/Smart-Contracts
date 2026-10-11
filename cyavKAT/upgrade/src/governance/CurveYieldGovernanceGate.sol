// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

interface ICurveYieldIporAccessManager {
    function hasRole(uint64 roleId, address account) external view returns (bool member, uint32 executionDelay);
}

/// @notice An operational layer over the EXISTING IPOR Access Manager and factory vault.
/// Authorization is checked exclusively against the IPOR Access Manager; this contract does not issue roles.
/// The original IPOR OWNER/ATOMIST remain the permission authorities. The gate receives vault-local
/// IPOR roles through the existing Access Manager and uses only ordinary CALLs to act on those grants.
/// Admin fee operations have a distinct, self-administered authorization lane. All other
/// governance roles remain in the original IPOR Access Manager. Fee authority is isolated
/// here because IPOR ADMIN_ROLE can override AccessManager role administrators.
contract CurveYieldGovernanceGate {
    using Address for address;

    uint64 public constant IPOR_OWNER_ROLE = 1;
    uint64 public constant IPOR_GUARDIAN_ROLE = 2;
    uint64 public constant IPOR_ATOMIST_ROLE = 100;

    address public immutable iporAccessManager;
    address public immutable adminReceiver; // initial fee receiver; fee-role rotation does not change a payout recipient
    address public adminFeeRoleHolder; // sole dedicated ADMIN_FEE authority; not an IPOR role
    bool public feeHandoverComplete; // after V4 handover, sensitive bootstrap writers are also ADMIN_FEE-only
    mapping(address target => bool) public isFeeBearingTarget;
    mapping(address target => mapping(bytes4 selector => bool)) public isProtectedCall;
    mapping(address target => mapping(bytes4 selector => bool)) public isGuardianCall;
    mapping(address target => mapping(bytes4 selector => bool)) public isAdminFeeCall;

    event ProtectedCallSet(address indexed target, bytes4 indexed selector, bool protectedCall);
    event Executed(address indexed caller, address indexed target, bytes4 selector, bool protectedPath);
    event GuardianCallSet(address indexed target, bytes4 indexed selector, bool allowed);
    event AdminFeeRoleTransferred(address indexed previousHolder, address indexed newHolder);
    event AdminFeeCallSet(address indexed target, bytes4 indexed selector);

    error NotIporRole(uint64 role, address account);
    error ProtectedCall(address target, bytes4 selector);
    error InvalidAddress();
    error NotGuardianCall(address target, bytes4 selector);
    error ImmutableFeeConfig(bytes32 key);
    error FeeConfigRegistrySealed();
    bool public feeConfigRegistrationSealed;
    error ProtectionCannotBeRemoved();
    error FeeSensitiveWiringLocked(bytes32 key);
    error NotAdminFeeRole(address caller);
    error NotAdminFeeCall(address target, bytes4 selector);
    error FeeOwnershipCannotEscape(address target);

    modifier onlyIporOwner() { _requireIporRole(IPOR_OWNER_ROLE, msg.sender); _; }
    modifier onlyIporOperator() { _requireOperator(); _; }
    modifier onlyAdminFeeRole() {
        if (msg.sender != adminFeeRoleHolder) revert NotAdminFeeRole(msg.sender);
        _;
    }

    constructor(address accessManager_, address adminReceiver_) {
        if (accessManager_.code.length == 0 || adminReceiver_ == address(0)) revert InvalidAddress();
        iporAccessManager = accessManager_;
        adminReceiver = adminReceiver_;
        adminFeeRoleHolder = adminReceiver_;
        emit AdminFeeRoleTransferred(address(0), adminReceiver_);
    }

    function _hasIporRole(uint64 role_, address account_) internal view returns (bool) {
        (bool active, uint32 delay) = ICurveYieldIporAccessManager(iporAccessManager).hasRole(role_, account_);
        return active && delay == 0; // never bypass IPOR execution delays through the gate
    }

    function _requireIporRole(uint64 role_, address account_) internal view {
        if (!_hasIporRole(role_, account_)) revert NotIporRole(role_, account_);
    }

    function _requireOperator() internal view {
        if (!_hasIporRole(IPOR_OWNER_ROLE, msg.sender) && !_hasIporRole(IPOR_ATOMIST_ROLE, msg.sender)) {
            revert NotIporRole(IPOR_ATOMIST_ROLE, msg.sender);
        }
    }

    /// @notice ONLY the current ADMIN_FEE role holder can assign its successor. Neither IPOR
    /// OWNER/ADMIN nor this gate's operating lane can grant, revoke or seize the role.
    /// @notice Called exactly once after ownership and vault fee-role handover.
    /// P0/P2 are allowed to initialize substrate and wiring keys with IPOR OWNER; after
    /// handover their fee-routing data requires the ADMIN_FEE role.
    function activateFeeHandover() external onlyAdminFeeRole {
        feeHandoverComplete = true;
    }

    function transferAdminFeeRole(address successor_) external onlyAdminFeeRole {
        if (successor_ == address(0)) revert InvalidAddress();
        address prior = adminFeeRoleHolder;
        adminFeeRoleHolder = successor_;
        emit AdminFeeRoleTransferred(prior, successor_);
    }

    /// @notice Explicitly allowlist an admin-fee setter. This does not grant any IPOR role,
    /// and cannot turn ownership/role-management/nested execution selectors into fee calls.
    function registerAdminFeeCalls(address target_, bytes4[] calldata selectors_) external onlyAdminFeeRole {
        if (target_ == address(this) || target_ == iporAccessManager || target_.code.length == 0)
            revert InvalidAddress();
        for (uint256 i; i < selectors_.length; ++i) {
            if (!_feeSelector(selectors_[i])) revert NotAdminFeeCall(target_, selectors_[i]);
            isFeeBearingTarget[target_] = true;
            isAdminFeeCall[target_][selectors_[i]] = true;
            isProtectedCall[target_][selectors_[i]] = true; // prevent all ordinary execution lanes
            emit AdminFeeCallSet(target_, selectors_[i]);
        }
    }

    /// @notice Sole gate dispatch for changing admin-fee rates, fee recipients and fee routing.
    /// Configured (target,selector) pairs only; the admin-fee role is self-administered.
    function executeAdminFee(address target_, bytes calldata data_) external onlyAdminFeeRole returns (bytes memory) {
        bytes4 sel = _selector(data_);
        if (!isAdminFeeCall[target_][sel] || !_feeSelector(sel) || target_.code.length == 0)
            revert NotAdminFeeCall(target_, sel);
        _checkTargetOwnership(target_);
        _checkArgRanges(target_, data_);
        emit Executed(msg.sender, target_, sel, true);
        return target_.functionCall(data_);
    }

    /// @dev Owned fee modules MUST belong to the gate; ownerless IPOR factory
    /// modules are authorized through the original IPOR Access Manager instead.
    function _checkTargetOwnership(address target_) private view {
        (bool ok, bytes memory response) = target_.staticcall(abi.encodeWithSignature("owner()"));
        if (ok && response.length >= 32 && abi.decode(response, (address)) != address(this))
            revert ProtectedCall(target_, bytes4(0));
    }

    /// @dev An exhaustive selection of admin-fee mutators exposed by this stack.
    /// New fee-capable contracts require an explicit reviewed update to this code.
    function _feeSelector(bytes4 sel) private pure returns (bool) {
        return
            sel == bytes4(keccak256("setAdminReceiver(address)")) ||
            sel == bytes4(keccak256("setDestinations(address,address)")) ||
            sel == bytes4(keccak256("setFeeRecipient(address)")) ||
            sel == bytes4(keccak256("setFeeBps(uint16)")) ||
            sel == bytes4(keccak256("setRouteFeeBps(address,address,uint16)")) ||
            sel == bytes4(keccak256("clearRouteFee(address,address)")) ||
            sel == bytes4(keccak256("setFees(uint256,uint256)")) ||
            sel == bytes4(keccak256("configurePerformanceFee(address,uint256)")) ||
            sel == bytes4(keccak256("configureManagementFee(address,uint256)")) ||
            sel == bytes4(keccak256("updatePerformanceFee((address,uint256)[])")) ||
            sel == bytes4(keccak256("updateManagementFee((address,uint256)[])")) ||
            sel == bytes4(keccak256("setDepositFee(uint256)")) ||
            sel == bytes4(keccak256("updateHighWaterMarkPerformanceFee()")) ||
            sel == bytes4(keccak256("updateIntervalHighWaterMarkPerformanceFee(uint32)")) ||
            sel == bytes4(keccak256("updateWithdrawFee(uint256)")) ||
            sel == bytes4(keccak256("updateRequestFee(uint256)")) ||
            sel == bytes4(keccak256("setFeeSplit(address[3],uint16[3],bool)")) ||
            sel == bytes4(keccak256("setOnboardingAdmin(address)")) ||
            sel == bytes4(keccak256("setBurnOnlyFee(address,bool)")) ||
            sel == bytes4(keccak256("setRevenueShareBps(uint16)")) ||
            sel == bytes4(keccak256("setWindupDistributionBps(uint16,uint16)")) ||
            sel == bytes4(keccak256("setProfitCustody(address)")) ||
            sel == bytes4(keccak256("setConfig(address,address)"));
    }

    /// @notice Operational-only calls. Fee, role management, ownership transfer and arbitrary nested dispatch are
    /// hard blocked, including if the IPOR OWNER authorizes this transaction. There is no bypass/fee lane.
    function execute(address target_, bytes calldata data_) external onlyIporOperator returns (bytes memory) {
        bytes4 sel = _selector(data_);
        if (isProtected(target_, data_)) revert ProtectedCall(target_, sel);
        _checkArgRanges(target_, data_);
        emit Executed(msg.sender, target_, sel, false);
        return target_.functionCall(data_);
    }

    /// @notice Explicitly restricted recovery/maintenance operations, NOT fee setters.
    /// These existing protected owners-only operations remain available to IPOR OWNER.
    function executeRestricted(address target_, bytes calldata data_) external onlyIporOwner returns (bytes memory) {
        bytes4 sel = _selector(data_);
        if (target_ == iporAccessManager || target_ == address(this) ||
            !_restrictedSelector(sel) || !isProtectedCall[target_][sel])
            revert ProtectedCall(target_, sel);
        _checkTargetOwnership(target_);
        _checkArgRanges(target_, data_);
        emit Executed(msg.sender, target_, sel, true);
        return target_.functionCall(data_);
    }

    function _restrictedSelector(bytes4 sel) private pure returns (bool) {
        return sel == bytes4(keccak256("setCoverer(address,bool)")) ||
            sel == bytes4(keccak256("setCharmVaultAllowed(address,bool)")) ||
            sel == bytes4(keccak256("setOperator(address,bool)")) ||
            sel == bytes4(keccak256("setPolVenues((address,address,address,address,address))")) ||
            sel == bytes4(keccak256("polExitToAvkat(uint256,uint256)")) ||
            sel == bytes4(keccak256("scheduleFullUnwind(address)")) ||
            sel == bytes4(keccak256("executeFullUnwind()"));
    }

    /// @notice Accept a factory-independent CurveYield Ownable2Step handover into the gate.
    /// No arbitrary ABI supplied: this entrypoint can only accept pending ownership.
    function acceptContractOwnership(address target_) external onlyIporOwner {
        if (target_ == address(this) || target_ == iporAccessManager) revert InvalidAddress();
        target_.functionCall(abi.encodeWithSignature("acceptOwnership()"));
    }

    /// @notice Rollback requires fee-role approval so the IPOR owner cannot take fee-setting
    /// modules out of the protected gate by itself.
    function transferContractOwnershipToAdminSafe(address target_) external onlyAdminFeeRole {
        if (target_ == address(this) || target_ == iporAccessManager) revert InvalidAddress();
        if (isFeeBearingTarget[target_]) revert FeeOwnershipCannotEscape(target_);
        target_.functionCall(abi.encodeWithSignature("transferOwnership(address)", adminReceiver));
    }

    /// @notice Only IPOR GUARDIAN members, restricted to previously allowlisted non-fee calls.
    function executeGuardian(address target_, bytes calldata data_) external returns (bytes memory) {
        _requireIporRole(IPOR_GUARDIAN_ROLE, msg.sender);
        bytes4 sel = _selector(data_);
        if (!isGuardianCall[target_][sel]) revert NotGuardianCall(target_, sel);
        if (isProtected(target_, data_)) revert ProtectedCall(target_, sel);
        _checkArgRanges(target_, data_);
        emit Executed(msg.sender, target_, sel, false);
        return target_.functionCall(data_);
    }

    function setGuardianCall(address target_, bytes4 selector_, bool allowed_) external onlyIporOwner {
        if (allowed_ && _alwaysForbidden(selector_)) revert ProtectedCall(target_, selector_);
        isGuardianCall[target_][selector_] = allowed_;
        emit GuardianCallSet(target_, selector_, allowed_);
    }

    /// @notice Only ADD permanent protected selectors. Neither owners nor guardians can unprotect fees.
    function setProtectedCalls(address target_, bytes4[] calldata selectors_, bool protected_) external onlyIporOwner {
        if (!protected_) revert ProtectionCannotBeRemoved();
        for (uint256 i; i < selectors_.length; ++i) {
            isProtectedCall[target_][selectors_[i]] = true;
            emit ProtectedCallSet(target_, selectors_[i], true);
        }
    }

    function isProtected(address target_, bytes calldata data_) public view returns (bool) {
        if (target_ == address(this) || target_ == iporAccessManager) return true;
        bytes4 sel = _selector(data_);
        // General-purpose execution is permitted ONLY against an Ownable operational contract
        // actually owned by the gate. Fee-owning and arbitrary third-party targets are never dispatchable.
        (bool ok, bytes memory result) = target_.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || result.length < 32 || abi.decode(result, (address)) != address(this)) return true;
        return isProtectedCall[target_][sel] || _alwaysForbidden(sel);
    }

    /// @dev Immutable system-wide denylist. Unrecognized admin-fee selectors in future contracts MUST be added
    /// here before deployment. A gate must never be granted access to an arbitrary fee adapter/call wrapper.
    function _alwaysForbidden(bytes4 sel) private pure returns (bool) {
        return
            sel == bytes4(keccak256("transferOwnership(address)")) ||
            sel == bytes4(keccak256("renounceOwnership()")) ||
            sel == bytes4(keccak256("acceptOwnership()")) ||
            sel == bytes4(keccak256("multicall(bytes[])")) ||
            sel == bytes4(keccak256("multicall(uint256,bytes[])")) ||
            sel == bytes4(keccak256("execute(address,bytes)")) ||
            sel == bytes4(keccak256("execute(address,uint256,bytes)")) ||
            sel == bytes4(keccak256("grantRole(uint64,address,uint32)")) ||
            sel == bytes4(keccak256("revokeRole(uint64,address)")) ||
            sel == bytes4(keccak256("renounceRole(uint64,address)")) ||
            sel == bytes4(keccak256("setTargetFunctionRole(address,bytes4[],uint64)")) ||
            sel == bytes4(keccak256("setRoleAdmin(uint64,uint64)")) ||
            sel == bytes4(keccak256("setRoleGuardian(uint64,uint64)")) ||
            sel == bytes4(keccak256("setAdminReceiver(address)")) ||
            sel == bytes4(keccak256("setDestinations(address,address)")) ||
            sel == bytes4(keccak256("setFeeRecipient(address)")) ||
            sel == bytes4(keccak256("setFeeBps(uint16)")) ||
            sel == bytes4(keccak256("setFeeSplit(address[3],uint16[3],bool)")) ||
            sel == bytes4(keccak256("setOnboardingAdmin(address)")) ||
            sel == bytes4(keccak256("setBurnOnlyFee(address,bool)")) ||
            sel == bytes4(keccak256("setProfitCustody(address)")) ||
            sel == bytes4(keccak256("setRouteFeeBps(address,address,uint16)")) ||
            sel == bytes4(keccak256("clearRouteFee(address,address)")) ||
            sel == bytes4(keccak256("setFees(uint256,uint256)")) ||
            sel == bytes4(keccak256("configurePerformanceFee(address,uint256)")) ||
            sel == bytes4(keccak256("configureManagementFee(address,uint256)")) ||
            sel == bytes4(keccak256("updatePerformanceFee((address,uint256)[])")) ||
            sel == bytes4(keccak256("updateManagementFee((address,uint256)[])")) ||
            sel == bytes4(keccak256("setDepositFee(uint256)")) ||
            sel == bytes4(keccak256("updateHighWaterMarkPerformanceFee()")) ||
            sel == bytes4(keccak256("updateIntervalHighWaterMarkPerformanceFee(uint32)")) ||
            sel == bytes4(keccak256("updateWithdrawFee(uint256)")) ||
            sel == bytes4(keccak256("updateRequestFee(uint256)")) ||
            sel == bytes4(keccak256("setRevenueShareBps(uint16)")) ||
            sel == bytes4(keccak256("setWindupDistributionBps(uint16,uint16)")) ||
            sel == bytes4(keccak256("setConfigGate(address)")) ||
            sel == bytes4(keccak256("scheduleFullUnwind(address)")) ||
            sel == bytes4(keccak256("executeFullUnwind()"));
    }

    // ================================================================ wiring registry (GATE_CONFIG_SPEC §10)
    //
    // Stack-internal wiring: key → address. Stack contracts look up their stack dependencies here at call time, so any
    // single contract can be replaced without redeploying the others (deploy it, then repoint its key).
    //   registerAddr: once per key, authorized via the existing IPOR Access Manager
    //   setAddr: IPOR operator for ordinary keys; ADMIN_FEE only for fee routing keys
    // The new address must have code; every change emits AddrSet so bots and dashboards can alert on it.

    mapping(bytes32 key => address) private _addrs;
    bytes32[] private _addrKeys;

    event AddrSet(bytes32 indexed key, address indexed oldAddr, address indexed newAddr);

    error AddrUnset(bytes32 key);
    error AddrExists(bytes32 key);
    error NoCode(address account);

    /// @notice The address wired to `key_`; reverts when the key is unset (a missing dependency must never read as 0).
    function addr(bytes32 key_) external view returns (address addr_) {
        addr_ = _addrs[key_];
        if (addr_ == address(0)) revert AddrUnset(key_);
    }

    /// @notice The address wired to `key_`, or address(0) when unset (optional dependencies).
    function addrOrZero(bytes32 key_) external view returns (address) {
        return _addrs[key_];
    }

    function addrKeys() external view returns (bytes32[] memory) {
        return _addrKeys;
    }

    /// @notice Wires a key for the first time under existing IPOR operator authority.
    function registerAddr(bytes32 key_, address addr_) external {
        if (feeHandoverComplete &&
            (key_ == keccak256("addr.revenueCustody") || key_ == keccak256("addr.loopGrowthRecipient") ||
             key_ == keccak256("addr.loopContributorsRecipient"))) {
            if (msg.sender != adminFeeRoleHolder) revert NotAdminFeeRole(msg.sender);
        } else _requireOperator();
        if (_addrs[key_] != address(0)) revert AddrExists(key_);
        _addrKeys.push(key_);
        _setAddr(key_, addr_);
    }

    /// @notice Repoints normal dependencies via IPOR roles, fee routing via ADMIN_FEE only.
    function setAddr(bytes32 key_, address addr_) external {
        // Fee-sensitive payout routing can only change under the self-administered fee authority.
        if (key_ == keccak256("addr.revenueCustody") || key_ == keccak256("addr.loopGrowthRecipient") ||
            key_ == keccak256("addr.loopContributorsRecipient")) {
            if (msg.sender != adminFeeRoleHolder) revert NotAdminFeeRole(msg.sender);
        }
        if (key_ != keccak256("addr.revenueCustody") && key_ != keccak256("addr.loopGrowthRecipient") &&
            key_ != keccak256("addr.loopContributorsRecipient"))
            _requireOperator();
        if (_addrs[key_] == address(0)) revert AddrUnset(key_);
        _setAddr(key_, addr_);
    }

    function _setAddr(bytes32 key_, address addr_) private {
        if (addr_.code.length == 0) revert NoCode(addr_);
        emit AddrSet(key_, _addrs[key_], addr_);
        _addrs[key_] = addr_;
    }

    // ================================================================ config registry (GATE_CONFIG_SPEC)
    //
    // Every numerical setting of the cyavKAT system: value, current range, hard caps, authority class and
    // the group rules it takes part in. Contracts read their values with getMany(keys) in one call.
    //   FEE      administered exclusively by the self-managed ADMIN_FEE role
    //   DAO      existing IPOR OWNER/ATOMIST role-holders set operational values
    //   GUARDIAN IPOR GUARDIAN role-holders may change values inside the guardian range
    // Hard caps are fixed when a key is registered and can never change: every range and value stays inside them.

    uint8 public constant CLASS_FEE = 1;
    uint8 public constant CLASS_DAO = 2;
    uint8 public constant CLASS_GUARDIAN = 3;
    uint8 public constant RULE_SUM_EQ = 1; // sum(keys) == bound
    uint8 public constant RULE_SUM_LE = 2; // sum(keys) <= bound
    uint8 public constant RULE_ORDER_LE = 3; // keys[0] <= keys[1] <= ...
    uint8 public constant RULE_ORDER_LT = 4; // keys[0] < keys[1] < ...
    uint8 public constant RULE_EACH_LE = 5; // every key <= bound
    uint8 public constant RULE_LOCK = 6; // refused while `lockTarget.lockSelector()` returns true (e.g. an active season)

    struct Config {
        uint256 value;
        uint256 min;
        uint256 max;
        uint256 hardMin;
        uint256 hardMax;
        uint256 guardianMin;
        uint256 guardianMax;
        uint8 class;
        bool registered;
    }

    struct Rule {
        uint8 kind;
        uint256 bound;
        bytes32[] keys;
        address lockTarget;
        bytes4 lockSelector;
    }

    mapping(bytes32 key => Config) private _configs;
    bytes32[] private _keys;
    Rule[] private _rules;
    mapping(bytes32 key => uint256[] ruleIds) private _rulesOf;

    event ConfigRegistered(bytes32 indexed key, uint8 class, uint256 value, uint256 hardMin, uint256 hardMax);
    event ConfigSet(bytes32 indexed key, uint256 oldValue, uint256 newValue, address indexed by);
    event RangeSet(bytes32 indexed key, uint256 min, uint256 max);
    event GuardianRangeSet(bytes32 indexed key, uint256 min, uint256 max);
    event RuleAdded(uint256 indexed ruleId, uint8 kind, uint256 bound, bytes32[] keys);

    error UnknownKey(bytes32 key);
    error KeyExists(bytes32 key);
    error OutOfRange(bytes32 key, uint256 value, uint256 min, uint256 max);
    error NotAllowed(bytes32 key, address caller);
    error RuleViolated(uint256 ruleId);
    error BadRule();

    /// @notice Registers a key with its hard caps, class and initial value (IPOR OWNER; once per key).
    function registerConfig(bytes32 key_, uint8 class_, uint256 hardMin_, uint256 hardMax_, uint256 value_)
        external onlyIporOwner
    {
        Config storage c = _configs[key_];
        if (c.registered) revert KeyExists(key_);
        if (class_ == CLASS_FEE && feeConfigRegistrationSealed) revert FeeConfigRegistrySealed();
        if (class_ < CLASS_FEE || class_ > CLASS_GUARDIAN || hardMin_ > hardMax_) revert BadRule();
        if (value_ < hardMin_ || value_ > hardMax_) revert OutOfRange(key_, value_, hardMin_, hardMax_);
        (c.value, c.min, c.max, c.hardMin, c.hardMax, c.class, c.registered) =
            (value_, hardMin_, hardMax_, hardMin_, hardMax_, class_, true);
        _keys.push(key_);
        emit ConfigRegistered(key_, class_, value_, hardMin_, hardMax_);
    }

    /// @notice Closes initial fee-key registration to lock the schema. Existing FEE keys
    /// remain adjustable by the self-managed ADMIN_FEE role, within fixed hard caps.
    function sealFeeConfiguration() external onlyIporOwner {
        feeConfigRegistrationSealed = true;
    }

    /// @notice Adds a group rule over registered keys (IPOR OWNER). Checked on every change of any of its keys.
    function addRule(uint8 kind_, uint256 bound_, bytes32[] calldata keys_, address lockTarget_, bytes4 lockSelector_)
        external onlyIporOwner returns (uint256 ruleId_)
    {
        if (kind_ < RULE_SUM_EQ || kind_ > RULE_LOCK || keys_.length == 0) revert BadRule();
        if (kind_ == RULE_LOCK && lockTarget_ == address(0)) revert BadRule();
        if ((kind_ == RULE_ORDER_LE || kind_ == RULE_ORDER_LT) && keys_.length < 2) revert BadRule();
        ruleId_ = _rules.length;
        _rules.push(Rule(kind_, bound_, keys_, lockTarget_, lockSelector_));
        for (uint256 i; i < keys_.length; ++i) {
            if (!_configs[keys_[i]].registered) revert UnknownKey(keys_[i]);
            _rulesOf[keys_[i]].push(ruleId_);
        }
        if (kind_ != RULE_LOCK) _checkRule(ruleId_);
        emit RuleAdded(ruleId_, kind_, bound_, keys_);
    }

    /// @notice FEE-class keys are writable ONLY by the ADMIN_FEE role; other keys require IPOR operator authority.
    /// All values are written first, then every
    /// rule touching a changed key is checked, so splits can be changed in one call.
    function setConfigs(bytes32[] calldata keys_, uint256[] calldata values_) external {
        if (keys_.length != values_.length) revert BadRule();
        for (uint256 i; i < keys_.length; ++i) {
            Config storage c = _existing(keys_[i]);
            if (c.class == CLASS_FEE) {
                if (msg.sender != adminFeeRoleHolder) revert NotAdminFeeRole(msg.sender);
            } else _requireOperator();
            _write(keys_[i], c, values_[i], c.min, c.max);
        }
        _checkRulesOf(keys_);
        _syncBoundMarkets(keys_);
    }

    /// @notice Guardian lane: one GUARDIAN key, inside its guardian range.
    function setConfigByGuardian(bytes32 key_, uint256 value_) external {
        Config storage c = _existing(key_);
        if (!_hasIporRole(IPOR_GUARDIAN_ROLE, msg.sender) || c.class != CLASS_GUARDIAN)
            revert NotAllowed(key_, msg.sender);
        uint256 lo = c.guardianMin > c.min ? c.guardianMin : c.min;
        uint256 hi = c.guardianMax < c.max ? c.guardianMax : c.max;
        _write(key_, c, value_, lo, hi);
        bytes32[] memory one = new bytes32[](1);
        one[0] = key_;
        _checkRulesOf(one);
        _syncBoundMarkets(one);
    }

    /// @notice FEE key ranges require ADMIN_FEE; other key ranges require IPOR operator.
    function setConfigRange(bytes32 key_, uint256 min_, uint256 max_) external {
        Config storage c = _existing(key_);
        if (c.class == CLASS_FEE) {
            if (msg.sender != adminFeeRoleHolder) revert NotAdminFeeRole(msg.sender);
        } else _requireOperator();
        if (min_ > max_ || min_ < c.hardMin || max_ > c.hardMax) revert OutOfRange(key_, min_, c.hardMin, c.hardMax);
        if (c.value < min_ || c.value > max_) revert OutOfRange(key_, c.value, min_, max_);
        (c.min, c.max) = (min_, max_);
        emit RangeSet(key_, min_, max_);
    }

    /// @notice The guardian's range for a GUARDIAN key (IPOR OWNER/ATOMIST).
    function setGuardianRange(bytes32 key_, uint256 min_, uint256 max_) external {
        _requireOperator();
        Config storage c = _existing(key_);
        if (c.class != CLASS_GUARDIAN || min_ > max_) revert BadRule();
        (c.guardianMin, c.guardianMax) = (min_, max_);
        emit GuardianRangeSet(key_, min_, max_);
    }

    /// @notice The values of `keys_`, in order (one call per reading contract).
    function getMany(bytes32[] calldata keys_) external view returns (uint256[] memory values_) {
        values_ = new uint256[](keys_.length);
        for (uint256 i; i < keys_.length; ++i) values_[i] = _existing(keys_[i]).value;
    }

    function getConfig(bytes32 key_) external view returns (Config memory) {
        return _existing(key_);
    }

    function configKeys() external view returns (bytes32[] memory) {
        return _keys;
    }

    function rule(uint256 ruleId_) external view returns (Rule memory) {
        return _rules[ruleId_];
    }

    function _existing(bytes32 key_) private view returns (Config storage c_) {
        c_ = _configs[key_];
        if (!c_.registered) revert UnknownKey(key_);
    }

    function _write(bytes32 key_, Config storage c_, uint256 value_, uint256 min_, uint256 max_) private {
        if (value_ < min_ || value_ > max_) revert OutOfRange(key_, value_, min_, max_);
        emit ConfigSet(key_, c_.value, value_, msg.sender);
        c_.value = value_;
    }

    function _checkRulesOf(bytes32[] memory keys_) private view {
        for (uint256 i; i < keys_.length; ++i) {
            uint256[] storage ids = _rulesOf[keys_[i]];
            for (uint256 j; j < ids.length; ++j) _checkRule(ids[j]);
        }
    }

    function _checkRule(uint256 ruleId_) private view {
        Rule storage r = _rules[ruleId_];
        uint256 n = r.keys.length;
        if (r.kind == RULE_LOCK) {
            (bool ok, bytes memory ret) = r.lockTarget.staticcall(abi.encodeWithSelector(r.lockSelector));
            if (!ok || ret.length < 32 || abi.decode(ret, (bool))) revert RuleViolated(ruleId_);
            return;
        }
        if (r.kind == RULE_SUM_EQ || r.kind == RULE_SUM_LE) {
            uint256 sum;
            for (uint256 i; i < n; ++i) sum += _configs[r.keys[i]].value;
            if (r.kind == RULE_SUM_EQ ? sum != r.bound : sum > r.bound) revert RuleViolated(ruleId_);
            return;
        }
        if (r.kind == RULE_EACH_LE) {
            for (uint256 i; i < n; ++i) if (_configs[r.keys[i]].value > r.bound) revert RuleViolated(ruleId_);
            return;
        }
        for (uint256 i = 1; i < n; ++i) {
            uint256 a = _configs[r.keys[i - 1]].value;
            uint256 b = _configs[r.keys[i]].value;
            if (r.kind == RULE_ORDER_LE ? a > b : a >= b) revert RuleViolated(ruleId_);
        }
    }

    // ================================================================ substrate bindings (IPOR_FUSE_CONFORMANCE_SPEC R5)
    //
    // The gate WRITES the settings the fuses read as substrates, in the same transaction that changes them. A fuse reads
    // its market's substrates on every call, so the vault never depends on a contract that can be repointed after the
    // fact. IPOR's `grantMarketSubstrates` replaces a market's whole list, so each synced market keeps a STATIC list
    // (tokens, targets, recipients: IPOR OWNER only) plus BINDINGS from gate keys to typed entries. Requires the
    // gate to hold the vault's FUSE_MANAGER role. Interim (E6): the typed entries live in ZERO_BALANCE_MARKET, UTS entries
    // in market 12, until IPOR assigns ids.

    uint8 public constant BIND_UTS_SLIPPAGE = 1; // UniversalTokenSwapperSubstrateLib Slippage entry: 3 << 248 | value (WAD)
    uint8 public constant BIND_GUARD_MAX_PPS_DROP = 2; // CurveYieldSubstrateLib GUARD_MAX_PPS_DROP (0x20): value bps
    uint8 public constant BIND_TRANSFER_CAP = 3; // CurveYieldSubstrateLib TRANSFER_CAP (0x12): extra = token, value = cap
    uint8 public constant BIND_GUARD_MAX_LTV = 4; // CurveYieldSubstrateLib GUARD_MAX_LTV (0x21): extra = Morpho market id, value bps

    struct SubstrateBinding {
        bytes32 key;
        uint8 kind;
        bytes32 extra;
    }

    address public substrateVault;
    mapping(uint256 marketId => bytes32[]) private _staticSubstrates;
    mapping(uint256 marketId => SubstrateBinding[]) private _bindings;
    mapping(bytes32 key => uint256[]) private _marketsOfKey;
    uint256[] private _syncedMarkets;
    mapping(uint256 marketId => bool) private _isSyncedMarket;

    event SubstrateVaultSet(address indexed vault);
    event SubstratesSynced(uint256 indexed marketId, uint256 count);

    error BadBinding();

    function setSubstrateVault(address vault_) external onlyIporOwner {
        if (vault_ == address(0)) revert InvalidAddress();
        substrateVault = vault_;
        emit SubstrateVaultSet(vault_);
    }

    /// @notice The fixed part of a synced market's substrates (tokens, targets, recipients). IPOR OWNER only: these
    /// entries decide where the fuses may send assets. Does not sync.
    function setStaticSubstrates(uint256 marketId_, bytes32[] calldata substrates_) external {
        if (feeHandoverComplete) {
            if (msg.sender != adminFeeRoleHolder) revert NotAdminFeeRole(msg.sender);
        } else _requireIporRole(IPOR_OWNER_ROLE, msg.sender);
        _staticSubstrates[marketId_] = substrates_;
        _trackMarket(marketId_);
    }

    /// @notice Binds a registered config key to a typed entry of a market. IPOR OWNER only. Does not sync.
    function addSubstrateBinding(uint256 marketId_, bytes32 key_, uint8 kind_, bytes32 extra_) external onlyIporOwner {
        if (!_configs[key_].registered || kind_ < BIND_UTS_SLIPPAGE || kind_ > BIND_GUARD_MAX_LTV) revert BadBinding();
        _bindings[marketId_].push(SubstrateBinding(key_, kind_, extra_));
        _marketsOfKey[key_].push(marketId_);
        _trackMarket(marketId_);
    }

    function clearSubstrateBindings(uint256 marketId_) external onlyIporOwner {
        SubstrateBinding[] storage b = _bindings[marketId_];
        for (uint256 i; i < b.length; ++i) {
            uint256[] storage ms = _marketsOfKey[b[i].key];
            for (uint256 j; j < ms.length; ++j) {
                if (ms[j] == marketId_) {
                    ms[j] = ms[ms.length - 1];
                    ms.pop();
                    break;
                }
            }
        }
        delete _bindings[marketId_];
    }

    /// @notice Pushes the market's static entries and the current values of its bound keys into the vault. Permissionless:
    /// it only writes what this gate already holds.
    function syncSubstrates(uint256 marketId_) public {
        address vault = substrateVault;
        if (vault == address(0)) revert InvalidAddress();
        bytes32[] memory list = previewSubstrates(marketId_);
        vault.functionCall(abi.encodeWithSignature("grantMarketSubstrates(uint256,bytes32[])", marketId_, list));
        emit SubstratesSynced(marketId_, list.length);
    }

    /// @notice What `syncSubstrates` writes now: the static entries, then the bound keys' current values as typed entries.
    function previewSubstrates(uint256 marketId_) public view returns (bytes32[] memory list_) {
        bytes32[] storage fixedList = _staticSubstrates[marketId_];
        SubstrateBinding[] storage b = _bindings[marketId_];
        list_ = new bytes32[](fixedList.length + b.length);
        for (uint256 i; i < fixedList.length; ++i) list_[i] = fixedList[i];
        for (uint256 i; i < b.length; ++i) list_[fixedList.length + i] = _encodeBinding(b[i]);
    }

    function staticSubstrates(uint256 marketId_) external view returns (bytes32[] memory) {
        return _staticSubstrates[marketId_];
    }

    function substrateBindings(uint256 marketId_) external view returns (SubstrateBinding[] memory) {
        return _bindings[marketId_];
    }

    function _encodeBinding(SubstrateBinding storage b_) private view returns (bytes32) {
        uint256 value = _configs[b_.key].value;
        if (b_.kind == BIND_UTS_SLIPPAGE) return bytes32((uint256(3) << 248) | value);
        if (b_.kind == BIND_GUARD_MAX_PPS_DROP) return bytes32((uint256(0x20) << 248) | value);
        if (b_.kind == BIND_TRANSFER_CAP) {
            if (value >= (1 << 88)) revert BadBinding();
            return bytes32((uint256(0x12) << 248) | (value << 160) | (uint256(b_.extra) & type(uint160).max));
        }
        return bytes32((uint256(0x21) << 248) | (value << 160) | (uint256(b_.extra) & type(uint160).max));
    }

    function _trackMarket(uint256 marketId_) private {
        if (_isSyncedMarket[marketId_]) return;
        _isSyncedMarket[marketId_] = true;
        _syncedMarkets.push(marketId_);
    }

    /// @dev After a config write: re-sync every market that has a binding on a changed key (once each).
    function _syncBoundMarkets(bytes32[] memory keys_) private {
        if (substrateVault == address(0)) return;
        uint256[] memory done = new uint256[](8);
        uint256 n;
        for (uint256 i; i < keys_.length; ++i) {
            uint256[] storage ms = _marketsOfKey[keys_[i]];
            for (uint256 j; j < ms.length; ++j) {
                bool seen;
                for (uint256 k; k < n; ++k) if (done[k] == ms[j]) seen = true;
                if (seen) continue;
                if (n == done.length) revert BadBinding();
                done[n++] = ms[j];
                syncSubstrates(ms[j]);
            }
        }
    }

    // ================================================================ passthroughs (fuses, live contracts)
    //
    // Values that stay in their own contract (fuses stay usable by other vaults; live contracts cannot read the gate).
    // A registered numeric ARGUMENT of a (target, selector) gets a range and a class: every gate path (execute,
    // executeAdminFee, executeGuardian) checks it; a FEE-class argument protects normal execution.
    // Reading is a plain view on the target (`passRead`).

    struct ArgRange {
        uint256 min;
        uint256 max;
        uint256 hardMin;
        uint256 hardMax;
        uint8 class;
        bool registered;
    }

    mapping(address target => mapping(bytes4 selector => uint256[] argIndexes)) private _rangedArgs;
    mapping(address target => mapping(bytes4 selector => mapping(uint256 argIndex => ArgRange))) private _argRanges;

    event ArgRangeRegistered(address indexed target, bytes4 indexed selector, uint256 argIndex, uint8 class, uint256 hardMin, uint256 hardMax);
    event ArgRangeSet(address indexed target, bytes4 indexed selector, uint256 argIndex, uint256 min, uint256 max);

    error ArgOutOfRange(address target, bytes4 selector, uint256 argIndex, uint256 value);

    /// @notice Registers the hard caps and class of a setter's numeric argument (IPOR OWNER; once).
    function registerArgRange(address target_, bytes4 selector_, uint256 argIndex_, uint8 class_, uint256 hardMin_, uint256 hardMax_)
        external onlyIporOwner
    {
        ArgRange storage a = _argRanges[target_][selector_][argIndex_];
        if (a.registered || class_ < CLASS_FEE || class_ > CLASS_DAO || hardMin_ > hardMax_) revert BadRule();
        (a.min, a.max, a.hardMin, a.hardMax, a.class, a.registered) = (hardMin_, hardMax_, hardMin_, hardMax_, class_, true);
        _rangedArgs[target_][selector_].push(argIndex_);
        if (class_ == CLASS_FEE) isProtectedCall[target_][selector_] = true;
        emit ArgRangeRegistered(target_, selector_, argIndex_, class_, hardMin_, hardMax_);
    }

    /// @notice Change a passthrough range within hard caps; fee classes require ADMIN_FEE.
    function setArgRange(address target_, bytes4 selector_, uint256 argIndex_, uint256 min_, uint256 max_) external {
        ArgRange storage a = _argRanges[target_][selector_][argIndex_];
        if (!a.registered) revert BadRule();
        if (a.class == CLASS_FEE) {
            if (msg.sender != adminFeeRoleHolder) revert NotAdminFeeRole(msg.sender);
        } else _requireOperator();
        if (min_ > max_ || min_ < a.hardMin || max_ > a.hardMax) revert BadRule();
        (a.min, a.max) = (min_, max_);
        emit ArgRangeSet(target_, selector_, argIndex_, min_, max_);
    }

    /// @notice Reads a value from a passthrough target (a plain view call).
    function passRead(address target_, bytes calldata data_) external view returns (bytes memory) {
        return target_.functionStaticCall(data_);
    }

    /// @dev Every registered numeric argument of this call must be inside its range (static ABI slots only).
    function _checkArgRanges(address target_, bytes calldata data_) private view {
        bytes4 sel = _selector(data_);
        uint256[] storage idx = _rangedArgs[target_][sel];
        for (uint256 i; i < idx.length; ++i) {
            uint256 at = 4 + idx[i] * 32;
            if (data_.length < at + 32) revert ArgOutOfRange(target_, sel, idx[i], 0);
            uint256 v = uint256(bytes32(data_[at:at + 32]));
            ArgRange storage a = _argRanges[target_][sel][idx[i]];
            if (v < a.min || v > a.max) revert ArgOutOfRange(target_, sel, idx[i], v);
        }
    }

    function _selector(bytes calldata data_) private pure returns (bytes4) {
        return data_.length >= 4 ? bytes4(data_[:4]) : bytes4(0);
    }
}
