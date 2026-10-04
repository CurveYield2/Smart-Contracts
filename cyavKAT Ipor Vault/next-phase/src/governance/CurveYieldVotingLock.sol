// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title CurveYieldVotingLock (#7)
/// @notice The cyavKAT DAO's voting token. Lock cyavKAT to vote; voting power ramps linearly from 0 to the locked
/// amount over `RAMP` and drops immediately (pro rata) on unlock. Power can be delegated. Non-transferable.
///
/// Aragon TokenVoting (v1.4) compatibility: OpenZeppelin `IVotes` plus ERC-6372 `clock()` in timestamp mode, and the
/// ERC-20 views TokenVotingSetup probes. `getPastTotalSupply` is the total LOCKED (not ramped), so the quorum is
/// measured against every locked share (the conservative direction).
///
/// Ramp model: each account has one (amount, start). Adding x to a lock of a started at s moves the start to the
/// amount-weighted average (a·s + x·now)/(a+x); starts are rounded UP to the next UTC day, so every kink of the
/// piecewise-linear power (start, start + RAMP) is on a day boundary. Each delegatee's power is stored as a
/// checkpointed (bias, slope) with per-day slope changes; a past lookup walks at most RAMP/1 day + 1 boundaries.
/// Bias is kept scaled by RAMP so all arithmetic is exact.
contract CurveYieldVotingLock is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 public constant DAY = 1 days;

    /// @notice The locked token (cyavKAT).
    IERC20 public immutable TOKEN;
    /// @notice Time for a lock's voting power to reach its amount.
    uint256 public immutable RAMP;

    string public name;
    string public symbol;

    struct AccountCp {
        uint48 time;
        uint48 start; // ramp start (day boundary)
        address delegatee; // effective delegatee (never zero once the account has locked)
        uint256 amount;
    }

    struct PowerCp {
        uint48 time;
        uint208 amount; // total amount delegated to this delegatee (caps the power)
        int256 biasX; // power * RAMP at `time`
        int256 slope; // d(biasX)/dt = sum of amounts currently ramping
    }

    struct SupplyCp {
        uint48 time;
        uint208 total;
    }

    mapping(address account => AccountCp[]) private _accounts;
    mapping(address delegatee => PowerCp[]) private _powers;
    mapping(address delegatee => mapping(uint256 day => int256)) private _slopeChange;
    SupplyCp[] private _supply;

    event Locked(address indexed account, uint256 amount, uint256 newAmount, uint256 newStart);
    event Unlocked(address indexed account, uint256 amount, uint256 newAmount);
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event DelegateVotesChanged(address indexed delegate, uint256 previousVotes, uint256 newVotes);

    error ZeroAmount();
    error InvalidRamp();
    error InsufficientLocked(uint256 locked, uint256 requested);
    error NonTransferable();
    error Unsupported();

    constructor(address token_, uint256 ramp_, string memory name_, string memory symbol_) {
        if (token_ == address(0)) revert ZeroAmount();
        if (ramp_ < 1 days || ramp_ > 180 days || ramp_ % DAY != 0) revert InvalidRamp();
        TOKEN = IERC20(token_);
        RAMP = ramp_;
        name = name_;
        symbol = symbol_;
    }

    // ---------------------------------------------------------------- lock / unlock / delegate

    /// @notice Locks `amount_` cyavKAT. The ramp start moves to the amount-weighted average of old and new.
    function lock(uint256 amount_) external nonReentrant {
        if (amount_ == 0) revert ZeroAmount();
        TOKEN.safeTransferFrom(msg.sender, address(this), amount_);
        AccountCp memory a = _account(msg.sender);
        address d = a.delegatee == address(0) ? msg.sender : a.delegatee;
        uint256 newAmount = a.amount + amount_;
        uint256 weighted = (a.amount * uint256(a.start) + amount_ * block.timestamp) / newAmount;
        uint256 newStart = _ceilDay(weighted);
        _move(msg.sender, a, d, newAmount, newStart);
        _writeSupply(_totalLocked() + amount_);
        emit Locked(msg.sender, amount_, newAmount, newStart);
    }

    /// @notice Unlocks `amount_`; voting power drops pro rata immediately (the ramp start is unchanged).
    function unlock(uint256 amount_) external nonReentrant {
        if (amount_ == 0) revert ZeroAmount();
        AccountCp memory a = _account(msg.sender);
        if (amount_ > a.amount) revert InsufficientLocked(a.amount, amount_);
        _move(msg.sender, a, a.delegatee, a.amount - amount_, a.start);
        _writeSupply(_totalLocked() - amount_);
        TOKEN.safeTransfer(msg.sender, amount_);
        emit Unlocked(msg.sender, amount_, a.amount - amount_);
    }

    /// @notice Delegates all of the caller's voting power (present and future) to `to_` (zero = self).
    function delegate(address to_) external nonReentrant {
        if (to_ == address(0)) to_ = msg.sender;
        AccountCp memory a = _account(msg.sender);
        address from = a.delegatee == address(0) ? msg.sender : a.delegatee;
        if (from == to_ && a.delegatee != address(0)) return;
        _move(msg.sender, a, to_, a.amount, a.start);
        emit DelegateChanged(msg.sender, from, to_);
    }

    function delegateBySig(address, uint256, uint256, uint8, bytes32, bytes32) external pure {
        revert Unsupported();
    }

    // ---------------------------------------------------------------- IVotes / ERC-6372

    function clock() public view returns (uint48) {
        return uint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=timestamp";
    }

    function delegates(address account_) external view returns (address) {
        address d = _account(account_).delegatee;
        return d == address(0) ? account_ : d;
    }

    function getVotes(address account_) external view returns (uint256) {
        return _powerAt(account_, block.timestamp);
    }

    function getPastVotes(address account_, uint256 timepoint_) external view returns (uint256) {
        return _powerAt(account_, _past(timepoint_));
    }

    function getPastTotalSupply(uint256 timepoint_) external view returns (uint256) {
        return _supplyAt(_past(timepoint_));
    }

    // ---------------------------------------------------------------- per-account views (rewards)

    /// @notice The account's own lock and delegatee at `timepoint_`.
    function accountAt(address account_, uint256 timepoint_)
        external view returns (uint256 amount_, uint256 start_, address delegatee_)
    {
        AccountCp memory a = _accountAt(account_, timepoint_);
        return (a.amount, a.start, a.delegatee == address(0) ? account_ : a.delegatee);
    }

    /// @notice The account's own ramped power at `timepoint_`, regardless of where it is delegated.
    function ownPowerAt(address account_, uint256 timepoint_) public view returns (uint256) {
        AccountCp memory a = _accountAt(account_, timepoint_);
        return _ramped(a.amount, a.start, timepoint_);
    }

    function lockedOf(address account_) external view returns (uint256) {
        return _account(account_).amount;
    }

    // ---------------------------------------------------------------- ERC-20 views (non-transferable)

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function totalSupply() external view returns (uint256) {
        return _totalLocked();
    }

    function balanceOf(address account_) external view returns (uint256) {
        return _account(account_).amount;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    function approve(address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    // ---------------------------------------------------------------- internals: moves

    /// @dev Replaces the account's (amount, start, delegatee) and moves its power function between delegatees.
    function _move(address account_, AccountCp memory old_, address newDelegatee_, uint256 newAmount_, uint256 newStart_)
        private
    {
        address oldDelegatee = old_.delegatee;
        if (oldDelegatee != address(0) && old_.amount != 0) {
            _applyFunction(oldDelegatee, old_.amount, old_.start, false);
        }
        if (newAmount_ != 0) _applyFunction(newDelegatee_, newAmount_, newStart_, true);
        _writeAccount(account_, AccountCp(uint48(block.timestamp), newStart_.toUint48(), newDelegatee_, newAmount_));
    }

    /// @dev Adds (or removes) the function amount·clamp((t − start)/RAMP) to a delegatee's checkpointed power.
    function _applyFunction(address d_, uint256 amount_, uint256 start_, bool add_) private {
        uint256 before = _powerAt(d_, block.timestamp);
        PowerCp memory p = _projected(d_, block.timestamp);
        int256 amt = amount_.toInt256();
        int256 sign = add_ ? int256(1) : int256(-1);
        uint256 end = start_ + RAMP;
        uint256 nowTs = block.timestamp;

        uint256 elapsed = nowTs <= start_ ? 0 : (nowTs >= end ? RAMP : nowTs - start_);
        p.biasX += sign * amt * int256(elapsed);
        if (start_ <= nowTs && nowTs < end) p.slope += sign * amt;
        if (start_ > nowTs) _slopeChange[d_][start_] += sign * amt;
        if (end > nowTs) _slopeChange[d_][end] -= sign * amt;
        p.amount = add_ ? p.amount + amount_.toUint208() : p.amount - amount_.toUint208();
        p.time = uint48(nowTs);

        PowerCp[] storage cps = _powers[d_];
        uint256 n = cps.length;
        if (n != 0 && cps[n - 1].time == nowTs) cps[n - 1] = p;
        else cps.push(p);
        emit DelegateVotesChanged(d_, before, _powerAt(d_, nowTs));
    }

    // ---------------------------------------------------------------- internals: lookups

    /// @dev The delegatee's (bias, slope) state carried forward to `t_` from the latest checkpoint at or before it.
    function _projected(address d_, uint256 t_) private view returns (PowerCp memory p_) {
        PowerCp[] storage cps = _powers[d_];
        uint256 i = _upperLookup(cps, t_);
        if (i == 0) return p_;
        p_ = cps[i - 1];
        uint256 time = p_.time;
        uint256 last = time + RAMP + DAY; // no slope change is ever scheduled beyond this
        uint256 b = (time / DAY + 1) * DAY;
        while (b <= t_ && b <= last) {
            p_.biasX += p_.slope * int256(b - time);
            time = b;
            p_.slope += _slopeChange[d_][b];
            b += DAY;
        }
        p_.biasX += p_.slope * int256(t_ - time);
        p_.time = uint48(t_);
    }

    function _powerAt(address d_, uint256 t_) private view returns (uint256) {
        PowerCp memory p = _projected(d_, t_);
        if (p.biasX <= 0) return 0;
        uint256 power = uint256(p.biasX) / RAMP;
        return power > p.amount ? p.amount : power;
    }

    function _ramped(uint256 amount_, uint256 start_, uint256 t_) private view returns (uint256) {
        if (t_ <= start_) return 0;
        uint256 elapsed = t_ - start_;
        return elapsed >= RAMP ? amount_ : amount_ * elapsed / RAMP;
    }

    function _account(address account_) private view returns (AccountCp memory a_) {
        AccountCp[] storage cps = _accounts[account_];
        if (cps.length != 0) a_ = cps[cps.length - 1];
    }

    function _accountAt(address account_, uint256 t_) private view returns (AccountCp memory a_) {
        AccountCp[] storage cps = _accounts[account_];
        uint256 lo;
        uint256 hi = cps.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (cps[mid].time > t_) hi = mid;
            else lo = mid + 1;
        }
        if (lo != 0) a_ = cps[lo - 1];
    }

    function _upperLookup(PowerCp[] storage cps_, uint256 t_) private view returns (uint256 lo_) {
        uint256 hi = cps_.length;
        while (lo_ < hi) {
            uint256 mid = (lo_ + hi) / 2;
            if (cps_[mid].time > t_) hi = mid;
            else lo_ = mid + 1;
        }
    }

    function _supplyAt(uint256 t_) private view returns (uint256) {
        uint256 lo;
        uint256 hi = _supply.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_supply[mid].time > t_) hi = mid;
            else lo = mid + 1;
        }
        return lo == 0 ? 0 : _supply[lo - 1].total;
    }

    function _totalLocked() private view returns (uint256) {
        uint256 n = _supply.length;
        return n == 0 ? 0 : _supply[n - 1].total;
    }

    function _writeAccount(address account_, AccountCp memory a_) private {
        AccountCp[] storage cps = _accounts[account_];
        uint256 n = cps.length;
        if (n != 0 && cps[n - 1].time == a_.time) cps[n - 1] = a_;
        else cps.push(a_);
    }

    function _writeSupply(uint256 total_) private {
        uint256 n = _supply.length;
        if (n != 0 && _supply[n - 1].time == block.timestamp) _supply[n - 1].total = total_.toUint208();
        else _supply.push(SupplyCp(uint48(block.timestamp), total_.toUint208()));
    }

    /// @dev Past lookups are capped at the current time (Aragon snapshots are `timestamp - 1`).
    function _past(uint256 t_) private view returns (uint256) {
        return t_ > block.timestamp ? block.timestamp : t_;
    }

    function _ceilDay(uint256 t_) private pure returns (uint256) {
        return (t_ + DAY - 1) / DAY * DAY;
    }
}
