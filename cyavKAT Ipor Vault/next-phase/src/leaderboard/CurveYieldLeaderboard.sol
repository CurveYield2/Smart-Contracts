// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurveYieldGateConfig, CurveYieldConfigKeys as K, CurveYieldAddrKeys} from "../governance/CurveYieldGateConfig.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {CurveYieldSeasonPoints} from "./CurveYieldSeasonPoints.sol";

interface ICyReferrals {
    function referrerOf(address user) external view returns (address);
}

/// @notice Per-season parameters; set with the season and frozen for its duration.
struct CySeasonParams {
    uint48 start;
    uint48 end;
    uint16 initialRateBps; // earning rate on day 1 (of the maximum)
    uint8 cliffCount; // 0..3
    uint48[3] cliffAt;
    uint16[3] cliffRateBps; // rate reached at each cliff (increasing); 100% at `end`
    uint256 pointsPerShareEpoch; // points per 1 cyavKAT (1e20) held for one epoch at 100% rate
    uint16 longHoldBonusBps; // + per consecutive epoch held
    uint16 tier1Bps; // share of a referee's holding points credited to its referrer (<= 4,000)
    uint16 tier2Bps; // ... to the referrer's referrer (<= 2,000)
    CyTiers refTiers; // referral points relative to the referrer's own (holding + bought) points
    uint256 buyRate; // points per 1 cyavKAT spent at full rate
    CyTiers buyTiers; // bought points relative to own (holding + referral) points
    uint16 adminCapBps; // admin-allocated points <= this share of all points (500..3,000)
    uint256 minBalance; // cyavKAT to register / stay registered (<= 1,000 cyavKAT)
    uint256 registrationFee; // cyavKAT (<= 100 cyavKAT)
}

/// @notice Piecewise reduction: full rate while credited/own < fullUntilBps; then minus cut1Bps; from cut2FromBps on,
/// minus cut1Bps + cut2Bps (cumulative).
struct CyTiers {
    uint32 fullUntilBps;
    uint16 cut1Bps;
    uint32 cut2FromBps;
    uint16 cut2Bps;
}

/// @title CurveYieldLeaderboard (#24)
/// @notice Seasonal, non-transferable points (one CurveYieldSeasonPoints token per season) for:
///   1. holding cyavKAT — 2-week epochs; points on min(balance at the previous account, balance now) (PHASE4 P4-3),
///      per tranche with a long-hold bonus (+bonus per consecutive epoch). Decreases remove the newest tranches first;
///      increases start a new tranche with no bonus. Only registered addresses earn (a contract cannot list holders).
///   2. referrals — tier 1 / tier 2 of every point the referee earns (holding, bought and admin-allocated; referral
///      points themselves never cascade), capped against the referrer's own points.
///   3. buying points with cyavKAT — tiered rate against own points; the spend is split to four destinations.
///   4. admin allocation (pointsAllocator; off-chain partner programs) — capped at adminCapBps of all points.
/// Every season is a 100% fresh start: users register again, and balances, tranches (long-hold ages) and points all
/// begin anew; nothing carries over from an earlier season.
/// Earning follows the season's ramp (initial rate, up to 3 cliffs, linear between, 100% at the end).
/// Accounting is permissionless and paginated: accountArray / accountAll / accountLeaderboard / accountRange.
contract CurveYieldLeaderboard is Ownable2Step, CurveYieldGateConfig {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant EPOCH = 14 days;
    uint256 public constant BOARD = 100;
    uint256 public constant MAX_TRANCHES = 8;
    uint256 private constant ONE_SHARE = 1e20;

    struct Tranche {
        uint128 amount;
        uint32 age; // consecutive epochs held
    }

    struct Holder {
        bool registered;
        uint32 lastEpoch; // last accounted epoch index (of the season)
        uint32 season; // season the holder is registered in (registration is per season)
        uint256 lastBalance;
    }

    struct UserPoints {
        uint128 hold;
        uint128 ref;
        uint128 buy;
        uint128 admin;
    }

    IERC20 public immutable CYAVKAT;
    /// @notice Wired in the gate (`CurveYieldAddrKeys.REFERRALS`, GATE_CONFIG_SPEC §10).
    function REFERRALS() public view returns (ICyReferrals) {
        return ICyReferrals(_addr(CurveYieldAddrKeys.REFERRALS));
    }

    uint256 public currentSeason; // 0 = none yet
    mapping(uint256 => CySeasonParams) private _params;
    mapping(uint256 => CurveYieldSeasonPoints) public seasonToken;
    mapping(uint256 => uint256) public totalPoints;
    mapping(uint256 => uint256) public adminPoints;
    mapping(uint256 season => mapping(address => UserPoints)) private _points;

    address[] private _registered;
    mapping(address => Holder) public holders;
    mapping(address => Tranche[]) private _tranches;

    address[BOARD] private _board; // sorted, most points first (current season)
    uint256 public boardCount;
    mapping(address => uint256) private _boardPos; // 1-based

    address public pointsAllocator;
    // spend split for bought points (bps, each <= 5,000, sum 10,000)
    address public adminReceiver;
    address public specialRewards;
    address public growthCustody;
    address public plusBooster;

    event SeasonStarted(uint256 indexed season, address token, uint256 start, uint256 end);
    event Registered(address indexed user, uint256 balance);
    event Deregistered(address indexed user);
    event PointsCredited(uint256 indexed season, address indexed user, uint8 kind, uint256 amount);

    error SeasonActive();
    error NoActiveSeason();
    error BadParams(string what);
    error NotRegistered();
    error AlreadyRegistered();
    error BelowMinimum();
    error NotAllocator();
    error AdminCapExceeded();

    constructor(address owner_, address cyavkat_, address configGate_)
        Ownable(owner_)
        CurveYieldGateConfig(configGate_)
    {
        CYAVKAT = IERC20(cyavkat_);
    }

    /// @notice Point-purchase split (admin / special rewards / growth custody / booster, bps), from the governance gate.
    /// The gate refuses changes while a season is active (its lock rule calls seasonActive()).
    function buySplitBps() public view returns (uint256[4] memory bps_) {
        bytes32[] memory k = new bytes32[](4);
        (k[0], k[1], k[2], k[3]) = (K.LEADERBOARD_BUY_SPLIT_0, K.LEADERBOARD_BUY_SPLIT_1, K.LEADERBOARD_BUY_SPLIT_2, K.LEADERBOARD_BUY_SPLIT_3);
        uint256[] memory v = _config(k);
        (bps_[0], bps_[1], bps_[2], bps_[3]) = (v[0], v[1], v[2], v[3]);
    }

    /// @notice True while a season is active (the gate's lock rule for the buy split).
    function seasonActive() external view returns (bool) {
        return _isActive();
    }

    // ---------------------------------------------------------------- admin (owner = the governance gate)

    /// @notice Starts the next season. Only when no season is active; parameters are frozen for the season.
    function startSeason(CySeasonParams calldata p_, string calldata name_, string calldata symbol_) external onlyOwner {
        if (currentSeason != 0 && block.timestamp < _params[currentSeason].end) revert SeasonActive();
        _validate(p_);
        uint256 id = currentSeason + 1;
        _params[id] = p_;
        seasonToken[id] = new CurveYieldSeasonPoints(id, name_, symbol_);
        currentSeason = id;
        // new season: fresh leaderboard
        for (uint256 i; i < boardCount; ++i) delete _boardPos[_board[i]];
        boardCount = 0;
        emit SeasonStarted(id, address(seasonToken[id]), p_.start, p_.end);
    }

    function setPointsAllocator(address allocator_) external onlyOwner {
        pointsAllocator = allocator_;
    }

    /// @notice Admin receiver of point purchases (protected by the governance gate: fee authority only).
    function setAdminReceiver(address admin_) external onlyOwner {
        adminReceiver = admin_;
    }

    function setBuyDestinations(address special_, address growth_, address booster_) external onlyOwner {
        (specialRewards, growthCustody, plusBooster) = (special_, growth_, booster_);
    }

    // ---------------------------------------------------------------- users

    function register() external {
        uint256 s = currentSeason;
        if (!_isActive()) revert NoActiveSeason();
        Holder storage h = holders[msg.sender];
        if (_isRegistered(msg.sender)) revert AlreadyRegistered();
        CySeasonParams storage p = _params[s];
        uint256 bal = CYAVKAT.balanceOf(msg.sender);
        if (bal < p.minBalance) revert BelowMinimum();
        if (p.registrationFee != 0) CYAVKAT.safeTransferFrom(msg.sender, _feeSink(), p.registrationFee);
        if (h.season == 0 && !_known(msg.sender)) _registered.push(msg.sender);
        h.registered = true;
        h.season = uint32(s);
        h.lastEpoch = uint32(_epochIndex(p, block.timestamp));
        h.lastBalance = bal;
        delete _tranches[msg.sender];
        if (bal != 0) _tranches[msg.sender].push(Tranche(uint128(bal), 0));
        emit Registered(msg.sender, bal);
    }

    /// @notice Buys points with cyavKAT at the season's tiered rate; the spend is split to the four destinations.
    function buyPoints(uint256 amount_) external returns (uint256 points_) {
        uint256 s = currentSeason;
        if (!_isActive()) revert NoActiveSeason();
        if (!_isRegistered(msg.sender)) revert NotRegistered();
        CySeasonParams storage p = _params[s];
        CYAVKAT.safeTransferFrom(msg.sender, address(this), amount_);
        address[4] memory to = [adminReceiver, specialRewards, growthCustody, plusBooster];
        uint256[4] memory split = buySplitBps();
        uint256 sent;
        for (uint256 i; i < 4; ++i) {
            uint256 part = i == 3 ? amount_ - sent : amount_ * split[i] / BPS;
            sent += part;
            if (part != 0) CYAVKAT.safeTransfer(to[i], part);
        }
        UserPoints storage up = _points[s][msg.sender];
        uint256 raw = amount_ * p.buyRate / ONE_SHARE;
        points_ = _tiered(up.buy, uint256(up.hold) + up.ref, raw, p.buyTiers);
        _credit(s, msg.sender, 2, points_);
        _creditReferrers(s, p, msg.sender, points_);
    }

    /// @notice Off-chain programs (partners): admin-allocated points, capped at adminCapBps of all points.
    function adminAllocate(address[] calldata users_, uint256[] calldata amounts_) external {
        if (msg.sender != pointsAllocator) revert NotAllocator();
        uint256 s = currentSeason;
        if (!_isActive()) revert NoActiveSeason();
        uint256 sum;
        for (uint256 i; i < users_.length; ++i) sum += amounts_[i];
        if ((adminPoints[s] + sum) * BPS > uint256(_params[s].adminCapBps) * (totalPoints[s] + sum)) revert AdminCapExceeded();
        adminPoints[s] += sum;
        CySeasonParams storage p = _params[s];
        for (uint256 i; i < users_.length; ++i) {
            _credit(s, users_[i], 3, amounts_[i]);
            _creditReferrers(s, p, users_[i], amounts_[i]);
        }
    }

    // ---------------------------------------------------------------- accounting (anyone)

    function accountArray(address[] calldata users_) external {
        for (uint256 i; i < users_.length; ++i) _account(users_[i]);
    }

    function accountAll(uint256 cursor_, uint256 count_) external returns (uint256 next_) {
        uint256 end = cursor_ + count_;
        if (end > _registered.length) end = _registered.length;
        for (uint256 i = cursor_; i < end; ++i) _account(_registered[i]);
        return end;
    }

    function accountLeaderboard() external {
        address[BOARD] memory b = _board;
        uint256 n = boardCount;
        for (uint256 i; i < n; ++i) _account(b[i]);
    }

    function accountRange(uint256 minPoints_, uint256 maxPoints_, uint256 cursor_, uint256 count_)
        external returns (uint256 next_)
    {
        uint256 s = currentSeason;
        uint256 end = cursor_ + count_;
        if (end > _registered.length) end = _registered.length;
        for (uint256 i = cursor_; i < end; ++i) {
            uint256 pts = pointsOf(s, _registered[i]);
            if (pts >= minPoints_ && pts <= maxPoints_) _account(_registered[i]);
        }
        return end;
    }

    // ---------------------------------------------------------------- views

    function params(uint256 season_) external view returns (CySeasonParams memory) {
        return _params[season_];
    }

    function pointsOf(uint256 season_, address user_) public view returns (uint256) {
        UserPoints storage up = _points[season_][user_];
        return uint256(up.hold) + up.ref + up.buy + up.admin;
    }

    function pointsBreakdown(uint256 season_, address user_) external view returns (UserPoints memory) {
        return _points[season_][user_];
    }

    /// @notice The top 100 of the current season, most points first.
    function leaderboard() external view returns (address[] memory users_, uint256[] memory points_) {
        uint256 n = boardCount;
        users_ = new address[](n);
        points_ = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            users_[i] = _board[i];
            points_[i] = pointsOf(currentSeason, _board[i]);
        }
    }

    function registeredLength() external view returns (uint256) {
        return _registered.length;
    }

    function registeredAt(uint256 i_) external view returns (address) {
        return _registered[i_];
    }

    /// @notice Earning rate (bps of maximum) at time t_ for the given season.
    function rateAt(uint256 season_, uint256 t_) public view returns (uint256) {
        CySeasonParams storage p = _params[season_];
        if (t_ <= p.start) return p.initialRateBps;
        if (t_ >= p.end) return BPS;
        uint256 fromT = p.start;
        uint256 fromR = p.initialRateBps;
        for (uint256 i; i < p.cliffCount; ++i) {
            if (t_ <= p.cliffAt[i]) return fromR + (p.cliffRateBps[i] - fromR) * (t_ - fromT) / (p.cliffAt[i] - fromT);
            fromT = p.cliffAt[i];
            fromR = p.cliffRateBps[i];
        }
        return fromR + (BPS - fromR) * (t_ - fromT) / (p.end - fromT);
    }

    // ---------------------------------------------------------------- internals

    function _account(address user_) private {
        uint256 s = currentSeason;
        if (s == 0) return;
        Holder storage h = holders[user_];
        if (!_isRegistered(user_)) return; // registered in an earlier season only: must register again
        CySeasonParams storage p = _params[s];
        uint256 e = _epochIndex(p, block.timestamp < p.end ? block.timestamp : p.end);
        if (e <= h.lastEpoch) return;
        uint256 bal = CYAVKAT.balanceOf(user_);
        uint256 held = bal < h.lastBalance ? bal : h.lastBalance;
        Tranche[] storage tr = _tranches[user_];
        _shrink(tr, held);

        uint256 pts;
        for (uint256 ep = h.lastEpoch; ep < e; ++ep) {
            uint256 rate = rateAt(s, p.start + ep * EPOCH + EPOCH / 2);
            for (uint256 i; i < tr.length; ++i) {
                uint256 base = uint256(tr[i].amount) * p.pointsPerShareEpoch / ONE_SHARE;
                pts += base * (BPS + uint256(p.longHoldBonusBps) * tr[i].age) / BPS * rate / BPS;
                tr[i].age += 1;
            }
        }
        if (bal > held) _addTranche(tr, bal - held);
        h.lastEpoch = uint32(e);
        h.lastBalance = bal;
        if (pts != 0) {
            _credit(s, user_, 0, pts);
            _creditReferrers(s, p, user_, pts);
        }
        if (bal < p.minBalance) {
            h.registered = false;
            emit Deregistered(user_);
        }
    }

    function _creditReferrers(uint256 s_, CySeasonParams storage p_, address user_, uint256 pts_) private {
        address r1 = REFERRALS().referrerOf(user_);
        if (r1 == address(0) || !_isRegistered(r1)) return;
        _creditRef(s_, p_, r1, pts_ * p_.tier1Bps / BPS);
        address r2 = REFERRALS().referrerOf(r1);
        if (r2 == address(0) || r2 == user_ || !_isRegistered(r2)) return;
        _creditRef(s_, p_, r2, pts_ * p_.tier2Bps / BPS);
    }

    function _creditRef(uint256 s_, CySeasonParams storage p_, address r_, uint256 raw_) private {
        if (raw_ == 0) return;
        UserPoints storage up = _points[s_][r_];
        uint256 granted = _tiered(up.ref, uint256(up.hold) + up.buy, raw_, p_.refTiers);
        if (granted != 0) _credit(s_, r_, 1, granted);
    }

    /// @dev Credits `raw_` new points against a tiered schedule relative to `own_`, given `already_` credited in this
    /// category. Piecewise: each part is reduced by the tier its running total falls in.
    function _tiered(uint256 already_, uint256 own_, uint256 raw_, CyTiers memory t_) private pure returns (uint256 out_) {
        uint256 cum = already_;
        uint256 left = raw_;
        uint256 b1 = own_ * t_.fullUntilBps / BPS;
        uint256 b2 = own_ * t_.cut2FromBps / BPS;
        while (left != 0) {
            uint256 cut;
            uint256 room;
            if (cum < b1) (cut, room) = (0, b1 - cum);
            else if (cum < b2) (cut, room) = (t_.cut1Bps, b2 - cum);
            else (cut, room) = (uint256(t_.cut1Bps) + t_.cut2Bps, type(uint256).max);
            // `room` is measured in credited points; the raw input that fills it at this tier's rate, rounded UP so
            // the running total always reaches the boundary (rounding down could stall 1 wei short forever)
            uint256 rate = BPS - cut;
            uint256 rawForRoom = room == type(uint256).max ? left : (room * BPS + rate - 1) / rate;
            uint256 take = rawForRoom < left ? rawForRoom : left;
            uint256 got = take * rate / BPS;
            if (got == 0 || rate == 0) {
                // nothing can advance: finish the remainder at this tier's rate and stop (bounded: at most 3 passes)
                out_ += left * rate / BPS;
                break;
            }
            out_ += got;
            cum += got;
            left -= take;
        }
    }

    function _credit(uint256 s_, address user_, uint8 kind_, uint256 amount_) private {
        if (amount_ == 0) return;
        UserPoints storage up = _points[s_][user_];
        if (kind_ == 0) up.hold += uint128(amount_);
        else if (kind_ == 1) up.ref += uint128(amount_);
        else if (kind_ == 2) up.buy += uint128(amount_);
        else up.admin += uint128(amount_);
        totalPoints[s_] += amount_;
        seasonToken[s_].mint(user_, amount_);
        _updateBoard(user_, pointsOf(s_, user_));
        emit PointsCredited(s_, user_, kind_, amount_);
    }

    function _updateBoard(address user_, uint256 pts_) private {
        uint256 pos = _boardPos[user_];
        uint256 n = boardCount;
        if (pos == 0) {
            if (n == BOARD) {
                address last = _board[BOARD - 1];
                if (pts_ <= pointsOf(currentSeason, last)) return;
                delete _boardPos[last];
                n = BOARD - 1;
            }
            _board[n] = user_;
            pos = n + 1;
            boardCount = n + 1;
        }
        // bubble up
        uint256 i = pos - 1;
        while (i > 0 && pointsOf(currentSeason, _board[i - 1]) < pts_) {
            _board[i] = _board[i - 1];
            _boardPos[_board[i]] = i + 1;
            --i;
        }
        _board[i] = user_;
        _boardPos[user_] = i + 1;
    }

    /// @dev Removes the newest tranches first until the total equals `held_`.
    function _shrink(Tranche[] storage tr_, uint256 held_) private {
        uint256 total;
        for (uint256 i; i < tr_.length; ++i) total += tr_[i].amount;
        while (total > held_ && tr_.length != 0) {
            Tranche storage last = tr_[tr_.length - 1];
            uint256 excess = total - held_;
            if (last.amount <= excess) {
                total -= last.amount;
                tr_.pop();
            } else {
                last.amount -= uint128(excess);
                total = held_;
            }
        }
    }

    /// @dev New tranche (age 0); at the cap, merges into the newest tranche at the lower (newer) age.
    function _addTranche(Tranche[] storage tr_, uint256 amount_) private {
        if (tr_.length < MAX_TRANCHES) {
            tr_.push(Tranche(uint128(amount_), 0));
        } else {
            Tranche storage last = tr_[tr_.length - 1];
            last.amount += uint128(amount_);
            last.age = 0;
        }
    }

    function _epochIndex(CySeasonParams storage p_, uint256 t_) private view returns (uint256) {
        return t_ <= p_.start ? 0 : (t_ - p_.start) / EPOCH;
    }

    function _isActive() private view returns (bool) {
        uint256 s = currentSeason;
        return s != 0 && block.timestamp >= _params[s].start && block.timestamp < _params[s].end;
    }

    function _isRegistered(address user_) private view returns (bool) {
        Holder storage h = holders[user_];
        return h.registered && h.season == currentSeason;
    }

    function _known(address user_) private view returns (bool) {
        return holders[user_].season != 0;
    }

    function _feeSink() private view returns (address) {
        return specialRewards != address(0) ? specialRewards : adminReceiver;
    }

    function _validate(CySeasonParams calldata p_) private view {
        if (p_.start < block.timestamp || p_.end <= p_.start + EPOCH) revert BadParams("dates");
        if (p_.initialRateBps > BPS || p_.cliffCount > 3) revert BadParams("ramp");
        uint256 lastT = p_.start;
        uint256 lastR = p_.initialRateBps;
        for (uint256 i; i < p_.cliffCount; ++i) {
            if (p_.cliffAt[i] <= lastT || p_.cliffAt[i] > p_.end || p_.cliffRateBps[i] < lastR || p_.cliffRateBps[i] > BPS) {
                revert BadParams("cliff");
            }
            (lastT, lastR) = (p_.cliffAt[i], p_.cliffRateBps[i]);
        }
        if (p_.tier1Bps > 4_000 || p_.tier2Bps > 2_000) revert BadParams("referral tiers");
        _validateTiers(p_.refTiers, 2_000, 50_000, 2_000, 5_000, 4_000, 100_000, 3_000, 5_000, "ref");
        _validateTiers(p_.buyTiers, 1_000, 5_000, 2_000, 5_000, 2_500, 20_000, 2_000, 5_000, "buy");
        if (p_.adminCapBps < 500 || p_.adminCapBps > 3_000) revert BadParams("admin cap");
        if (p_.minBalance > 1_000e20 || p_.registrationFee > 100e20) revert BadParams("registration");
        // buy rate: points of 10..1,000 cyavKAT held for 4..26 epochs, per cyavKAT spent
        uint256 per = p_.pointsPerShareEpoch;
        if (p_.buyRate < per * 10 * 4 || p_.buyRate > per * 1_000 * 26) revert BadParams("buy rate");
    }

    function _validateTiers(
        CyTiers calldata t_, uint256 fullMin, uint256 fullMax, uint256 c1Min, uint256 c1Max, uint256 c2FromMin,
        uint256 c2FromMax, uint256 c2Min, uint256 c2Max, string memory what_
    ) private pure {
        if (t_.fullUntilBps < fullMin || t_.fullUntilBps > fullMax || t_.cut1Bps < c1Min || t_.cut1Bps > c1Max
            || t_.cut2FromBps < c2FromMin || t_.cut2FromBps > c2FromMax || t_.cut2FromBps < t_.fullUntilBps
            || t_.cut2Bps < c2Min || t_.cut2Bps > c2Max || uint256(t_.cut1Bps) + t_.cut2Bps > BPS) revert BadParams(what_);
    }
}
