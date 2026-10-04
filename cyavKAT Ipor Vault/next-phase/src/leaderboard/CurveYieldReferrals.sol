// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurveYieldGateConfig, CurveYieldConfigKeys as K} from "../governance/CurveYieldGateConfig.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title CurveYieldReferrals (#24, 2-tier public referral registry)
/// @notice Who referred whom. The leaderboard reads `referrerOf` for tier 1 and tier 2 (the referrer's referrer).
///   - `claim(targets)`: a referrer pre-claims addresses that hold no cyavKAT yet (never deposited), paying
///     `claimFee` cyavKAT per address (0–100). An address can be claimed once; at most MAX_OPEN open claims
///     (claimed, still not deposited) per referrer.
///   - `setMyReferrer(r)`: after depositing, a user names their referrer once, free; it overrides any pre-claim.
///   - Admin (owner) can change any referrer.
/// Partner programs beyond tier 2 are off-chain admin allocations (PHASE4_DESIGN_SPEC P4-5).
contract CurveYieldReferrals is Ownable2Step, CurveYieldGateConfig {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_OPEN = 10;
    uint256 public constant MAX_CLAIM_FEE = 100e20; // 100 cyavKAT (20 decimals)

    IERC20 public immutable CYAVKAT;
    address public feeReceiver;

    mapping(address => address) public referrerOf;
    mapping(address => address) public claimedBy; // pre-deposit claims
    mapping(address => bool) public selfNamed; // user already named their referrer
    mapping(address => address[]) private _openClaims;

    event Claimed(address indexed referrer, address indexed target);
    event ReferrerSet(address indexed user, address indexed referrer, bool byUser);

    error AlreadyClaimed(address target);
    error HasDeposited(address target);
    error TooManyOpenClaims();
    error AlreadyNamed();
    error InvalidReferrer();
    error FeeTooHigh();

    constructor(address owner_, address cyavkat_, address feeReceiver_, address configGate_)
        Ownable(owner_)
        CurveYieldGateConfig(configGate_)
    {
        CYAVKAT = IERC20(cyavkat_);
        feeReceiver = feeReceiver_;
    }

    /// @notice Fee per claimed address (cyavKAT), from the governance gate.
    function claimFee() public view returns (uint256) {
        return _config1(K.REFERRALS_CLAIM_FEE);
    }

    /// @notice Receiver of the claim fee (the fee itself is in the governance gate, FEE class).
    function setFeeReceiver(address receiver_) external onlyOwner {
        feeReceiver = receiver_;
    }

    function claim(address[] calldata targets_) external {
        _pruneOpen(msg.sender);
        if (_openClaims[msg.sender].length + targets_.length > MAX_OPEN) revert TooManyOpenClaims();
        for (uint256 i; i < targets_.length; ++i) {
            address t = targets_[i];
            if (t == msg.sender || t == address(0)) revert InvalidReferrer();
            if (claimedBy[t] != address(0) || referrerOf[t] != address(0)) revert AlreadyClaimed(t);
            if (CYAVKAT.balanceOf(t) != 0) revert HasDeposited(t);
            claimedBy[t] = msg.sender;
            referrerOf[t] = msg.sender;
            _openClaims[msg.sender].push(t);
            emit Claimed(msg.sender, t);
        }
        uint256 fee = claimFee() * targets_.length;
        if (fee != 0) CYAVKAT.safeTransferFrom(msg.sender, feeReceiver, fee);
    }

    /// @notice Once, after depositing: name your referrer (free). Overrides a pre-deposit claim.
    function setMyReferrer(address referrer_) external {
        if (selfNamed[msg.sender]) revert AlreadyNamed();
        if (referrer_ == msg.sender || referrer_ == address(0) || referrerOf[referrer_] == msg.sender) revert InvalidReferrer();
        if (CYAVKAT.balanceOf(msg.sender) == 0) revert InvalidReferrer();
        selfNamed[msg.sender] = true;
        referrerOf[msg.sender] = referrer_;
        emit ReferrerSet(msg.sender, referrer_, true);
    }

    function adminSetReferrer(address user_, address referrer_) external onlyOwner {
        if (referrer_ == user_) revert InvalidReferrer();
        referrerOf[user_] = referrer_;
        emit ReferrerSet(user_, referrer_, false);
    }

    function openClaimsOf(address referrer_) external view returns (address[] memory) {
        return _openClaims[referrer_];
    }

    /// @dev Drops claims whose target has since deposited (no longer "open").
    function _pruneOpen(address referrer_) private {
        address[] storage open = _openClaims[referrer_];
        uint256 i;
        while (i < open.length) {
            if (CYAVKAT.balanceOf(open[i]) != 0 || referrerOf[open[i]] != referrer_) {
                open[i] = open[open.length - 1];
                open.pop();
            } else {
                ++i;
            }
        }
    }
}
