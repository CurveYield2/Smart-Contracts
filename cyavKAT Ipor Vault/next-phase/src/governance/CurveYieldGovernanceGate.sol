// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title CurveYieldGovernanceGate (PHASE3_DESIGN_SPEC §1.9)
/// @notice The owner of record of every CurveYield contract and the holder of the vault's IPOR roles. The DAO acts only
/// through `execute`, which refuses PROTECTED calls; only FEE_AUTHORITY holders can make protected calls
/// (`executeProtected`) or change what is protected. The DAO therefore can never change an admin-fee receiver or
/// percentage, move a contract out of the gate, or grant itself a fee role — whoever is allowed to propose.
///
/// A call is protected when any of these hold:
///   - (target, selector) is in the protected list (admin-fee setters, set by FEE_AUTHORITY);
///   - the selector is an ownership move: transferOwnership(address), renounceOwnership();
///   - the selector is a generic call wrapper on ANY target (multicall(bytes[]), multicall(uint256,bytes[]),
///     execute(address,bytes), execute(address,uint256,bytes)): a wrapper keeps msg.sender == gate for its inner calls,
///     so it could smuggle a protected call past this outer-selector check;
///   - the target is a registered access manager and the call is not on its DAO allowlist: only grantRole / revokeRole /
///     renounceRole on NON-protected roles, and labelRole. Everything else there (multicall, execute, schedule,
///     setTargetFunctionRole, setRoleAdmin, updateAuthority, setTargetClosed, …) is protected. revokeRole / renounceRole
///     of a role held by the gate itself are protected too: the DAO cannot strip the gate of its own roles;
///   - the target is the gate itself.
/// FEE_AUTHORITY is self-administered: holders grant and revoke it; the last holder cannot be removed.
/// Guardian lane: the Optimization Guardian contract may call (target, selector) pairs the DAO or a fee authority
/// allowed with `setGuardianCall`; protected calls are refused there too.
contract CurveYieldGovernanceGate {
    using Address for address;

    bytes4 private constant TRANSFER_OWNERSHIP = bytes4(keccak256("transferOwnership(address)"));
    bytes4 private constant RENOUNCE_OWNERSHIP = bytes4(keccak256("renounceOwnership()"));
    // OpenZeppelin AccessManager (IPOR IporFusionAccessManager) role management
    bytes4 private constant AM_GRANT_ROLE = bytes4(keccak256("grantRole(uint64,address,uint32)"));
    bytes4 private constant AM_REVOKE_ROLE = bytes4(keccak256("revokeRole(uint64,address)"));
    bytes4 private constant AM_RENOUNCE_ROLE = bytes4(keccak256("renounceRole(uint64,address)"));
    bytes4 private constant AM_LABEL_ROLE = bytes4(keccak256("labelRole(uint64,string)"));
    // generic call wrappers (OZ Multicall, Uniswap-style multicall, AccessManager.execute, account-style execute)
    bytes4 private constant MULTICALL = bytes4(keccak256("multicall(bytes[])"));
    bytes4 private constant MULTICALL_DEADLINE = bytes4(keccak256("multicall(uint256,bytes[])"));
    bytes4 private constant EXECUTE_2 = bytes4(keccak256("execute(address,bytes)"));
    bytes4 private constant EXECUTE_3 = bytes4(keccak256("execute(address,uint256,bytes)"));

    address public dao;
    mapping(address => bool) public isFeeAuthority;
    uint256 public feeAuthorityCount;
    mapping(address target => mapping(bytes4 selector => bool)) public isProtectedCall;
    mapping(address => bool) public isAccessManager;
    mapping(address accessManager => mapping(uint64 roleId => bool)) public isProtectedRole;
    address public guardian;
    mapping(address target => mapping(bytes4 selector => bool)) public isGuardianCall;

    event DaoSet(address indexed dao);
    event FeeAuthoritySet(address indexed account, bool granted);
    event ProtectedCallSet(address indexed target, bytes4 indexed selector, bool protectedCall);
    event AccessManagerSet(address indexed accessManager, bool registered);
    event ProtectedRoleSet(address indexed accessManager, uint64 indexed roleId, bool protectedRole);
    event Executed(address indexed caller, address indexed target, bytes4 selector, bool protectedPath);
    event GuardianSet(address indexed guardian);
    event GuardianCallSet(address indexed target, bytes4 indexed selector, bool allowed);

    error NotDao();
    error NotFeeAuthority();
    error ProtectedCall(address target, bytes4 selector);
    error LastFeeAuthority();
    error InvalidAddress();
    error NotGuardianCall(address target, bytes4 selector);

    /// @notice Admin fee receiver read by the stack (e.g. the harvest's 10% admin share). Fee authority only: admin
    /// fees are the fee authority's, never the DAO's.
    address public adminReceiver;
    event AdminReceiverSet(address indexed oldReceiver, address indexed newReceiver);

    function setAdminReceiver(address receiver_) external onlyFeeAuthority {
        if (receiver_ == address(0)) revert InvalidAddress();
        emit AdminReceiverSet(adminReceiver, receiver_);
        adminReceiver = receiver_;
    }

    modifier onlyFeeAuthority() {
        if (!isFeeAuthority[msg.sender]) revert NotFeeAuthority();
        _;
    }

    constructor(address dao_, address feeAuthority_) {
        if (dao_ == address(0) || feeAuthority_ == address(0)) revert InvalidAddress();
        dao = dao_;
        isFeeAuthority[feeAuthority_] = true;
        feeAuthorityCount = 1;
        emit DaoSet(dao_);
        emit FeeAuthoritySet(feeAuthority_, true);
    }

    // ---------------------------------------------------------------- calls

    /// @notice The DAO's only path: forwards the call unless it is protected.
    function execute(address target_, bytes calldata data_) external returns (bytes memory) {
        if (msg.sender != dao) revert NotDao();
        bytes4 sel = _selector(data_);
        if (isProtected(target_, data_)) revert ProtectedCall(target_, sel);
        _checkArgRanges(target_, data_);
        emit Executed(msg.sender, target_, sel, false);
        return target_.functionCall(data_);
    }

    /// @notice FEE_AUTHORITY path: any call, including protected ones (never to the gate itself).
    function executeProtected(address target_, bytes calldata data_) external onlyFeeAuthority returns (bytes memory) {
        if (target_ == address(this)) revert InvalidAddress();
        _checkArgRanges(target_, data_);
        emit Executed(msg.sender, target_, _selector(data_), true);
        return target_.functionCall(data_);
    }

    /// @notice Guardian lane: only allow-listed, never protected.
    function executeGuardian(address target_, bytes calldata data_) external returns (bytes memory) {
        bytes4 sel = _selector(data_);
        if (msg.sender != guardian || !isGuardianCall[target_][sel]) revert NotGuardianCall(target_, sel);
        if (isProtected(target_, data_)) revert ProtectedCall(target_, sel);
        _checkArgRanges(target_, data_);
        emit Executed(msg.sender, target_, sel, false);
        return target_.functionCall(data_);
    }

    /// @notice The DAO or a fee authority sets the guardian contract and its allowed calls.
    function setGuardian(address guardian_) external {
        _onlyDaoOrFeeAuthority();
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    function setGuardianCall(address target_, bytes4 selector_, bool allowed_) external {
        _onlyDaoOrFeeAuthority();
        isGuardianCall[target_][selector_] = allowed_;
        emit GuardianCallSet(target_, selector_, allowed_);
    }

    /// @notice True if the DAO may not make this call.
    function isProtected(address target_, bytes calldata data_) public view returns (bool) {
        if (target_ == address(this)) return true;
        bytes4 sel = _selector(data_);
        if (sel == TRANSFER_OWNERSHIP || sel == RENOUNCE_OWNERSHIP) return true;
        if (sel == MULTICALL || sel == MULTICALL_DEADLINE || sel == EXECUTE_2 || sel == EXECUTE_3) return true;
        if (isProtectedCall[target_][sel]) return true;
        if (isAccessManager[target_]) {
            if (sel == AM_LABEL_ROLE) return false;
            if (sel != AM_GRANT_ROLE && sel != AM_REVOKE_ROLE && sel != AM_RENOUNCE_ROLE) return true; // allowlist
            if (data_.length < 68) return true; // (uint64 role, address account, …)
            if (sel != AM_GRANT_ROLE && address(uint160(uint256(bytes32(data_[36:68])))) == address(this)) return true;
            return isProtectedRole[target_][uint64(uint256(bytes32(data_[4:36])))];
        }
        return false;
    }

    // ---------------------------------------------------------------- fee authority administration

    function setFeeAuthority(address account_, bool granted_) external onlyFeeAuthority {
        if (account_ == address(0)) revert InvalidAddress();
        if (granted_ == isFeeAuthority[account_]) return;
        if (!granted_ && feeAuthorityCount == 1) revert LastFeeAuthority();
        isFeeAuthority[account_] = granted_;
        feeAuthorityCount = granted_ ? feeAuthorityCount + 1 : feeAuthorityCount - 1;
        emit FeeAuthoritySet(account_, granted_);
    }

    function setProtectedCalls(address target_, bytes4[] calldata selectors_, bool protected_) external onlyFeeAuthority {
        for (uint256 i; i < selectors_.length; ++i) {
            isProtectedCall[target_][selectors_[i]] = protected_;
            emit ProtectedCallSet(target_, selectors_[i], protected_);
        }
    }

    function setAccessManager(address accessManager_, bool registered_) external onlyFeeAuthority {
        isAccessManager[accessManager_] = registered_;
        emit AccessManagerSet(accessManager_, registered_);
    }

    function setProtectedRoles(address accessManager_, uint64[] calldata roleIds_, bool protected_) external onlyFeeAuthority {
        for (uint256 i; i < roleIds_.length; ++i) {
            isProtectedRole[accessManager_][roleIds_[i]] = protected_;
            emit ProtectedRoleSet(accessManager_, roleIds_[i], protected_);
        }
    }

    /// @notice Replaces the DAO address (e.g. a DAO migration). The DAO itself or a fee authority.
    function setDao(address dao_) external {
        _onlyDaoOrFeeAuthority();
        if (dao_ == address(0)) revert InvalidAddress();
        dao = dao_;
        emit DaoSet(dao_);
    }

    function _onlyDaoOrFeeAuthority() private view {
        if (msg.sender != dao && !isFeeAuthority[msg.sender]) revert NotDao();
    }

    // ================================================================ wiring registry (GATE_CONFIG_SPEC §10)
    //
    // Stack-internal wiring: key → address. Stack contracts look up their stack dependencies here at call time, so any
    // single contract can be replaced without redeploying the others (deploy it, then repoint its key).
    //   registerAddr: first time per key — the DAO or a fee authority (deployment, before / after the DAO handover)
    //   setAddr:      repointing an existing key — DAO only (WIRING class; the DAO's own timelock is the delay)
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

    /// @notice Wires a key for the first time (DAO or fee authority).
    function registerAddr(bytes32 key_, address addr_) external {
        _onlyDaoOrFeeAuthority();
        if (_addrs[key_] != address(0)) revert AddrExists(key_);
        _addrKeys.push(key_);
        _setAddr(key_, addr_);
    }

    /// @notice Repoints an existing key (DAO only).
    function setAddr(bytes32 key_, address addr_) external {
        if (msg.sender != dao) revert NotDao();
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
    // Every numerical setting of the cyavKAT system: value, current range, immutable hard caps, authority class and
    // the group rules it takes part in. Contracts read their values with getMany(keys) in one call.
    //   FEE      only a fee authority sets the value or the range (admin-fee settings; the DAO never can)
    //   DAO      the DAO or a fee authority sets the value and the range
    //   GUARDIAN as DAO, and the guardian may set the value inside the key's guardian range
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

    /// @notice Registers a key with its hard caps, class and initial value (fee authority; once per key).
    function registerConfig(bytes32 key_, uint8 class_, uint256 hardMin_, uint256 hardMax_, uint256 value_)
        external onlyFeeAuthority
    {
        Config storage c = _configs[key_];
        if (c.registered) revert KeyExists(key_);
        if (class_ < CLASS_FEE || class_ > CLASS_GUARDIAN || hardMin_ > hardMax_) revert BadRule();
        if (value_ < hardMin_ || value_ > hardMax_) revert OutOfRange(key_, value_, hardMin_, hardMax_);
        (c.value, c.min, c.max, c.hardMin, c.hardMax, c.class, c.registered) =
            (value_, hardMin_, hardMax_, hardMin_, hardMax_, class_, true);
        _keys.push(key_);
        emit ConfigRegistered(key_, class_, value_, hardMin_, hardMax_);
    }

    /// @notice Adds a group rule over registered keys (fee authority). Checked on every change of any of its keys.
    function addRule(uint8 kind_, uint256 bound_, bytes32[] calldata keys_, address lockTarget_, bytes4 lockSelector_)
        external onlyFeeAuthority returns (uint256 ruleId_)
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

    /// @notice Sets values (DAO or fee authority; FEE keys fee authority only). All values are written first, then every
    /// rule touching a changed key is checked, so splits can be changed in one call.
    function setConfigs(bytes32[] calldata keys_, uint256[] calldata values_) external {
        if (keys_.length != values_.length) revert BadRule();
        for (uint256 i; i < keys_.length; ++i) {
            Config storage c = _existing(keys_[i]);
            if (c.class == CLASS_FEE ? !isFeeAuthority[msg.sender] : (msg.sender != dao && !isFeeAuthority[msg.sender])) {
                revert NotAllowed(keys_[i], msg.sender);
            }
            _write(keys_[i], c, values_[i], c.min, c.max);
        }
        _checkRulesOf(keys_);
    }

    /// @notice Guardian lane: one GUARDIAN key, inside its guardian range.
    function setConfigByGuardian(bytes32 key_, uint256 value_) external {
        Config storage c = _existing(key_);
        if (msg.sender != guardian || c.class != CLASS_GUARDIAN) revert NotAllowed(key_, msg.sender);
        uint256 lo = c.guardianMin > c.min ? c.guardianMin : c.min;
        uint256 hi = c.guardianMax < c.max ? c.guardianMax : c.max;
        _write(key_, c, value_, lo, hi);
        bytes32[] memory one = new bytes32[](1);
        one[0] = key_;
        _checkRulesOf(one);
    }

    /// @notice Changes a key's range, inside its hard caps; the current value must stay inside. DAO for DAO / GUARDIAN
    /// keys, fee authority for every key.
    function setConfigRange(bytes32 key_, uint256 min_, uint256 max_) external {
        Config storage c = _existing(key_);
        if (c.class == CLASS_FEE ? !isFeeAuthority[msg.sender] : (msg.sender != dao && !isFeeAuthority[msg.sender])) {
            revert NotAllowed(key_, msg.sender);
        }
        if (min_ > max_ || min_ < c.hardMin || max_ > c.hardMax) revert OutOfRange(key_, min_, c.hardMin, c.hardMax);
        if (c.value < min_ || c.value > max_) revert OutOfRange(key_, c.value, min_, max_);
        (c.min, c.max) = (min_, max_);
        emit RangeSet(key_, min_, max_);
    }

    /// @notice The guardian's range for a GUARDIAN key (DAO or fee authority).
    function setGuardianRange(bytes32 key_, uint256 min_, uint256 max_) external {
        _onlyDaoOrFeeAuthority();
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

    // ================================================================ passthroughs (fuses, live contracts)
    //
    // Values that stay in their own contract (fuses stay usable by other vaults; live contracts cannot read the gate).
    // A registered numeric ARGUMENT of a (target, selector) gets a range and a class: every gate path (execute,
    // executeProtected, executeGuardian) checks it, and a FEE-class argument makes the call fee-authority only.
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

    /// @notice Registers the hard caps and class of a setter's numeric argument (fee authority; once).
    function registerArgRange(address target_, bytes4 selector_, uint256 argIndex_, uint8 class_, uint256 hardMin_, uint256 hardMax_)
        external onlyFeeAuthority
    {
        ArgRange storage a = _argRanges[target_][selector_][argIndex_];
        if (a.registered || class_ < CLASS_FEE || class_ > CLASS_DAO || hardMin_ > hardMax_) revert BadRule();
        (a.min, a.max, a.hardMin, a.hardMax, a.class, a.registered) = (hardMin_, hardMax_, hardMin_, hardMax_, class_, true);
        _rangedArgs[target_][selector_].push(argIndex_);
        if (class_ == CLASS_FEE) isProtectedCall[target_][selector_] = true;
        emit ArgRangeRegistered(target_, selector_, argIndex_, class_, hardMin_, hardMax_);
    }

    /// @notice Narrows or widens a passthrough argument's range inside its hard caps (DAO for DAO class, fee authority).
    function setArgRange(address target_, bytes4 selector_, uint256 argIndex_, uint256 min_, uint256 max_) external {
        ArgRange storage a = _argRanges[target_][selector_][argIndex_];
        if (!a.registered) revert BadRule();
        if (a.class == CLASS_FEE ? !isFeeAuthority[msg.sender] : (msg.sender != dao && !isFeeAuthority[msg.sender])) {
            revert NotDao();
        }
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
