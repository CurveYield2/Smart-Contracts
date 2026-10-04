// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title CurveYieldEngagementToken (#8)
/// @notice Non-transferable governance reward shares that decay. Earned by proposers, voters and delegators of passed
/// proposals (minted by authorised minters); they weight the pro-rata reward-token distributions of
/// CurveYieldEngagementRewards.
///
/// Decay: each lot decays linearly to zero over DECAY (6 months) of "decay time". Decay time runs at full speed,
/// half speed while the lot is slowed once, and quarter speed while slowed twice.
/// Slowing: every unit earned slows SLOW_PER_UNIT (2) existing units for SLOW (4 months), oldest lots first; a lot that
/// is already slowed twice has its earlier-expiring window extended instead. Slowing applies to whole lots, so the last
/// lot slowed may cover slightly more than the exact budget.
/// Holdings are lots, at most MAX_LOTS (64) per holder: fully decayed lots are dropped first, then the two oldest lots
/// are merged (value-preserving; the merged lot keeps the older lot's decay progress and slow windows).
/// Decay time is kept in quarter-seconds so the 1x / 0.5x / 0.25x speeds are exact integers.
contract CurveYieldEngagementToken is Ownable2Step {
    using SafeCast for uint256;

    uint256 public constant DECAY = 180 days;
    uint256 public constant SLOW = 120 days;
    uint256 public constant SLOW_PER_UNIT = 2;
    uint256 public constant MAX_LOTS = 64;
    uint256 private constant Q = 4; // quarter-seconds per second
    uint256 private constant DECAY_Q = DECAY * Q;

    struct Lot {
        uint128 amount; // units at zero decay
        uint128 consumedQ; // decay time consumed at lastUpdate, quarter-seconds
        uint48 lastUpdate;
        uint48 slowA; // slow windows: active while block.timestamp < until
        uint48 slowB;
    }

    string public constant name = "CurveYield Engagement";
    string public constant symbol = "cyENG";
    uint8 public constant decimals = 18;

    mapping(address holder => Lot[]) private _lots;
    address[] private _holders;
    mapping(address => bool) public isHolder;
    mapping(address => bool) public isMinter;
    /// @notice The rewards distributor; it pauses minting while it snapshots an epoch.
    address public distributor;
    bool public mintingPaused;

    event Minted(address indexed to, uint256 amount, uint256 slowedUnits);
    event MinterSet(address indexed minter, bool allowed);
    event DistributorSet(address indexed distributor);
    event MintingPaused(bool paused);

    error NotMinter();
    error NotDistributor();
    error Paused();
    error NonTransferable();
    error ZeroAmount();

    constructor(address owner_) Ownable(owner_) {}

    // ---------------------------------------------------------------- admin

    function setMinter(address minter_, bool allowed_) external onlyOwner {
        isMinter[minter_] = allowed_;
        emit MinterSet(minter_, allowed_);
    }

    function setDistributor(address distributor_) external onlyOwner {
        distributor = distributor_;
        emit DistributorSet(distributor_);
    }

    function setMintingPaused(bool paused_) external {
        if (msg.sender != distributor) revert NotDistributor();
        mintingPaused = paused_;
        emit MintingPaused(paused_);
    }

    // ---------------------------------------------------------------- mint

    /// @notice Mints `amount_` new units to `to_` as a fresh lot, after slowing 2 units per unit of `to_`'s existing lots.
    function mint(address to_, uint256 amount_) external {
        if (!isMinter[msg.sender]) revert NotMinter();
        if (mintingPaused) revert Paused();
        if (amount_ == 0) revert ZeroAmount();
        Lot[] storage lots = _lots[to_];
        uint256 slowed = _slow(lots, amount_ * SLOW_PER_UNIT);
        _makeRoom(lots);
        lots.push(Lot(amount_.toUint128(), 0, uint48(block.timestamp), 0, 0));
        if (!isHolder[to_]) {
            isHolder[to_] = true;
            _holders.push(to_);
        }
        emit Minted(to_, amount_, slowed);
    }

    // ---------------------------------------------------------------- views

    function balanceOf(address holder_) external view returns (uint256) {
        return balanceAt(holder_, block.timestamp);
    }

    /// @notice Balance at `t_` (valid for any `t_` at or after the holder's last lot update).
    function balanceAt(address holder_, uint256 t_) public view returns (uint256 balance_) {
        Lot[] storage lots = _lots[holder_];
        for (uint256 i; i < lots.length; ++i) balance_ += _value(lots[i], t_);
    }

    function lotsOf(address holder_) external view returns (Lot[] memory) {
        return _lots[holder_];
    }

    function holdersLength() external view returns (uint256) {
        return _holders.length;
    }

    function holderAt(uint256 i_) external view returns (address) {
        return _holders[i_];
    }

    // ERC-20 shape for wallets / explorers; not transferable.
    function transfer(address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    function approve(address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    // ---------------------------------------------------------------- internals

    /// @dev Slows existing lots oldest first until `budget_` units are covered; returns the units slowed.
    function _slow(Lot[] storage lots_, uint256 budget_) private returns (uint256 slowed_) {
        uint256 nowTs = block.timestamp;
        uint48 until = uint48(nowTs + SLOW);
        for (uint256 i; i < lots_.length && slowed_ < budget_; ++i) {
            Lot storage lot = lots_[i];
            uint256 value = _value(lot, nowTs);
            if (value == 0) continue;
            _checkpoint(lot, nowTs);
            if (lot.slowA <= nowTs) lot.slowA = until;
            else if (lot.slowB <= nowTs) lot.slowB = until;
            else if (lot.slowA <= lot.slowB) lot.slowA = until;
            else lot.slowB = until;
            slowed_ += value;
        }
    }

    /// @dev Keeps at most MAX_LOTS - 1 lots before a push: drops decayed lots, then merges the two oldest.
    function _makeRoom(Lot[] storage lots_) private {
        if (lots_.length < MAX_LOTS) return;
        uint256 nowTs = block.timestamp;
        uint256 w;
        for (uint256 r; r < lots_.length; ++r) {
            if (_value(lots_[r], nowTs) == 0) continue;
            if (w != r) lots_[w] = lots_[r];
            ++w;
        }
        while (lots_.length > w) lots_.pop();
        if (lots_.length < MAX_LOTS) return;
        // merge lots[1] into lots[0], preserving value: amount = value / remaining fraction of the older lot
        Lot storage a = lots_[0];
        _checkpoint(a, nowTs);
        uint256 value = _value(a, nowTs) + _value(lots_[1], nowTs);
        a.amount = (value * DECAY_Q / (DECAY_Q - a.consumedQ)).toUint128();
        for (uint256 i = 1; i + 1 < lots_.length; ++i) lots_[i] = lots_[i + 1];
        lots_.pop();
    }

    function _checkpoint(Lot storage lot_, uint256 t_) private {
        lot_.consumedQ = _consumedAt(lot_, t_).toUint128();
        lot_.lastUpdate = uint48(t_);
    }

    function _value(Lot storage lot_, uint256 t_) private view returns (uint256) {
        uint256 c = _consumedAt(lot_, t_);
        return c >= DECAY_Q ? 0 : uint256(lot_.amount) * (DECAY_Q - c) / DECAY_Q;
    }

    /// @dev Decay time consumed at `t_`: integrates the speed (4 / 2 / 1 quarter-seconds per second for 0 / 1 / 2 active
    /// slow windows) from lastUpdate, with breakpoints at the window ends.
    function _consumedAt(Lot storage lot_, uint256 t_) private view returns (uint256 c_) {
        c_ = lot_.consumedQ;
        uint256 from = lot_.lastUpdate;
        if (t_ <= from) return c_;
        uint256 a = lot_.slowA;
        uint256 b = lot_.slowB;
        (uint256 e1, uint256 e2) = a <= b ? (a, b) : (b, a); // window ends, ascending
        uint256[3] memory ends = [e1, e2, t_];
        for (uint256 i; i < 3 && from < t_; ++i) {
            uint256 segEnd = ends[i] < t_ ? ends[i] : t_;
            if (segEnd <= from) continue;
            uint256 active = (a > from ? 1 : 0) + (b > from ? 1 : 0);
            c_ += (Q >> active) * (segEnd - from);
            from = segEnd;
        }
        if (c_ > DECAY_Q) c_ = DECAY_Q;
    }
}
