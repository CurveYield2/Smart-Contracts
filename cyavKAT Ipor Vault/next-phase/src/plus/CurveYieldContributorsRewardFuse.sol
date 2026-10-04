// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurveYieldAddrKeys, ICurveYieldConfigGate} from "../governance/CurveYieldGateConfig.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ICyMainVault {
    function deposit(uint256 assets, address receiver) external returns (uint256);
}

interface ICyPlusRouter {
    function deposit(uint256 cyAmount, address receiver) external returns (uint256);
}

interface ICyTopBoard {
    function leaderboard() external view returns (address[] memory users, uint256[] memory points);
}

/// @title CurveYieldContributorsRewardFuse (#23)
/// @notice Custody for the contributors' share of system revenue (the loop profit splitter's contributors share in avKAT,
/// the wrapper fee splitter's 30% and the proposal bond's slash third in cyavKAT). Reports no vault accounting: what
/// arrives here has already left the vault's books.
///   convert()                   anyone: avKAT -> cyavKAT (main vault deposit) -> cyavKAT+ (router, whitelisted: no fee)
///   distributeLeaderboard(bps)  owner: bps of the distributable cyavKAT+ to the current top-100, pro rata to points
///   distributeGovernance(bps)   owner: bps of the distributable cyavKAT+ to the engagement rewards contract, which pays
///                               engagement-token holders pro rata in its next epoch
///   grand prize                 `grandPrizeBps` of all cyavKAT+ held is reserved until `grandPrizeUnlock`; after that,
///                               grandPrizeEvent() (anyone) pays it to the top-100 pro rata and resets, so a new % and
///                               date can be configured (setGrandPrize, owner)
contract CurveYieldContributorsRewardFuse is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    IERC20 public immutable AVKAT;
    IERC20 public immutable CYAVKAT;
    IERC20 public immutable PLUS;
    /// @notice Wired in the gate (`CurveYieldAddrKeys.PLUS_DEPOSIT_ROUTER`, GATE_CONFIG_SPEC §10).
    function PLUS_ROUTER() public view returns (address) {
        return ICurveYieldConfigGate(GATE).addr(CurveYieldAddrKeys.PLUS_DEPOSIT_ROUTER);
    }
    /// @notice Wired in the gate (`CurveYieldAddrKeys.LEADERBOARD`, GATE_CONFIG_SPEC §10).
    function LEADERBOARD() public view returns (ICyTopBoard) {
        return ICyTopBoard(ICurveYieldConfigGate(GATE).addr(CurveYieldAddrKeys.LEADERBOARD));
    }
    address public engagementRewards;

    uint256 public grandPrizeBps; // share of all held cyavKAT+ reserved for the grand prize
    uint256 public grandPrizeUnlock; // timestamp

    event Converted(uint256 avkatIn, uint256 cyavkatIn, uint256 plusShares);
    event Distributed(bool leaderboard, uint256 amount, uint256 recipients);
    event GrandPrizeSet(uint256 bps, uint256 unlock);
    event GrandPrizePaid(uint256 amount, uint256 recipients);

    error BadParams();
    error GrandPrizeLocked();
    error NothingToPay();
    /// @notice The governance gate (wiring anchor, GATE_CONFIG_SPEC §10).
    address public immutable GATE;

    constructor(
        address owner_, address avkat_, address cyavkat_, address plus_, address gate_,
        address engagementRewards_
    ) Ownable(owner_) {
        AVKAT = IERC20(avkat_);
        CYAVKAT = IERC20(cyavkat_);
        PLUS = IERC20(plus_);
        GATE = gate_;
        engagementRewards = engagementRewards_;
    }

    function setEngagementRewards(address rewards_) external onlyOwner {
        engagementRewards = rewards_;
    }

    /// @notice Reserve `bps_` of all cyavKAT+ held for a grand prize unlocking at `unlock_`. Only when no grand prize is
    /// pending (the previous one was paid, or none was set).
    function setGrandPrize(uint256 bps_, uint256 unlock_) external onlyOwner {
        if (grandPrizeBps != 0) revert BadParams();
        if (bps_ == 0 || bps_ > BPS || unlock_ <= block.timestamp) revert BadParams();
        (grandPrizeBps, grandPrizeUnlock) = (bps_, unlock_);
        emit GrandPrizeSet(bps_, unlock_);
    }

    function convert() external nonReentrant returns (uint256 shares_) {
        uint256 avkatIn = AVKAT.balanceOf(address(this));
        if (avkatIn != 0) {
            AVKAT.forceApprove(address(CYAVKAT), avkatIn);
            ICyMainVault(address(CYAVKAT)).deposit(avkatIn, address(this));
        }
        uint256 cyIn = CYAVKAT.balanceOf(address(this));
        if (cyIn == 0) return 0;
        CYAVKAT.forceApprove(PLUS_ROUTER(), cyIn);
        shares_ = ICyPlusRouter(PLUS_ROUTER()).deposit(cyIn, address(this));
        emit Converted(avkatIn, cyIn, shares_);
    }

    /// @notice cyavKAT+ not reserved for the grand prize.
    function distributable() public view returns (uint256) {
        uint256 held = PLUS.balanceOf(address(this));
        return held - held * grandPrizeBps / BPS;
    }

    function distributeLeaderboard(uint256 bps_) external onlyOwner nonReentrant {
        if (bps_ == 0 || bps_ > BPS) revert BadParams();
        uint256 amount = distributable() * bps_ / BPS;
        uint256 n = _payTopBoard(amount);
        emit Distributed(true, amount, n);
    }

    function distributeGovernance(uint256 bps_) external onlyOwner nonReentrant {
        if (bps_ == 0 || bps_ > BPS || engagementRewards == address(0)) revert BadParams();
        uint256 amount = distributable() * bps_ / BPS;
        if (amount == 0) revert NothingToPay();
        PLUS.safeTransfer(engagementRewards, amount); // cyavKAT+ must be a whitelisted reward token there
        emit Distributed(false, amount, 0);
    }

    function grandPrizeEvent() external nonReentrant {
        if (grandPrizeBps == 0 || block.timestamp < grandPrizeUnlock) revert GrandPrizeLocked();
        uint256 held = PLUS.balanceOf(address(this));
        uint256 amount = held * grandPrizeBps / BPS;
        (grandPrizeBps, grandPrizeUnlock) = (0, 0); // reset: a new prize can be configured
        uint256 n = _payTopBoard(amount);
        emit GrandPrizePaid(amount, n);
    }

    /// @dev Pays `amount_` cyavKAT+ to the leaderboard's current top-100, pro rata to season points.
    function _payTopBoard(uint256 amount_) private returns (uint256 n_) {
        if (amount_ == 0) revert NothingToPay();
        (address[] memory users, uint256[] memory points) = LEADERBOARD().leaderboard();
        uint256 total;
        for (uint256 i; i < users.length; ++i) total += points[i];
        if (total == 0) revert NothingToPay();
        for (uint256 i; i < users.length; ++i) {
            uint256 part = amount_ * points[i] / total;
            if (part == 0) continue;
            PLUS.safeTransfer(users[i], part);
            ++n_;
        }
    }
}
