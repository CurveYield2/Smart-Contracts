// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface ICyRcmUpdate {
    function updateBalance() external;
}

/// @title CurveYieldPlusYieldBooster (#20)
/// @notice Collects cyavKAT for cyavKAT+ holders (30% of deposit / withdraw fees, 10% of loop profit) and releases it
/// into the vault gradually: `boost()` (anyone, at most every `interval`) sends `dripBps` of the balance to the cyavKAT+
/// RewardsClaimManager and starts its vesting, so the PPS rises smoothly instead of in jumps. Nothing leaves the
/// cyavKAT+ holders' economy.
contract CurveYieldPlusYieldBooster is Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    IERC20 public immutable CYAVKAT;
    address public rewardsManager;
    uint256 public dripBps = 1_000; // 10% of the balance per boost
    uint256 public interval = 1 days;
    uint256 public lastBoost;

    event Boosted(uint256 amount);

    error TooSoon();
    error BadParams();

    constructor(address owner_, address cyavkat_, address rewardsManager_) Ownable(owner_) {
        CYAVKAT = IERC20(cyavkat_);
        rewardsManager = rewardsManager_;
    }

    function setParams(address rewardsManager_, uint256 dripBps_, uint256 interval_) external onlyOwner {
        if (rewardsManager_ == address(0) || dripBps_ == 0 || dripBps_ > BPS || interval_ < 1 hours || interval_ > 30 days) {
            revert BadParams();
        }
        (rewardsManager, dripBps, interval) = (rewardsManager_, dripBps_, interval_);
    }

    function boost() external returns (uint256 amount_) {
        if (block.timestamp < lastBoost + interval) revert TooSoon();
        lastBoost = block.timestamp;
        amount_ = CYAVKAT.balanceOf(address(this)) * dripBps / BPS;
        if (amount_ == 0) return 0;
        CYAVKAT.safeTransfer(rewardsManager, amount_);
        ICyRcmUpdate(rewardsManager).updateBalance(); // the booster holds UPDATE_REWARDS_BALANCE on the cyavKAT+ RCM
        emit Boosted(amount_);
    }
}
