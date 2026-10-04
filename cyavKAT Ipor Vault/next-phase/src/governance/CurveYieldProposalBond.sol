// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurveYieldGateConfig, CurveYieldConfigKeys as K} from "../governance/CurveYieldGateConfig.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IAragonTokenVoting, AragonProposalParameters, AragonTally, AragonAction, AragonTargetConfig,
    ICyEngagementMint} from "./CurveYieldAragonInterfaces.sol";

/// @title CurveYieldProposalBond (#6, D-G4 / D-G5 / D-G9)
/// @notice Anyone can request an in-range parameter change by paying a fixed cyavKAT bond (`bondAmount`, default 200).
///   - The proposal-intake bot builds the DAO proposal; the 2-of-3 Safe creates it and calls `linkProposal`, which
///     checks on-chain that the proposal carries exactly the requested call (one action: target, setter(value)).
///   - The Safe can instead `reject` the request (the safety bot refused it): the bond is slashed.
///   - `settle` (anyone) after the vote: executed -> bond refunded + `proposerReward` engagement units;
///     ended and not executed -> slashed.
///   - Neither linked nor rejected within `intakeWindow` (bots down) -> `refund` (anyone) returns the bond.
/// Slash split: one third each to the admin fee receiver, the contributors sink and the engagement rewards; dust to
/// the engagement rewards. `setAdminReceiver` is a separate setter so the governance gate can reserve it for the fee
/// authority (admin fee receivers are never DAO-controlled).
contract CurveYieldProposalBond is Ownable2Step, CurveYieldGateConfig {
    using SafeERC20 for IERC20;

    enum Status {
        None,
        Pending,
        Linked,
        Refunded,
        Rewarded,
        Slashed
    }

    struct Param {
        address target;
        bytes4 selector;
        uint256 min;
        uint256 max;
        bool enabled;
    }

    struct Request {
        address requester;
        uint64 paramId;
        uint64 createdAt;
        Status status;
        uint256 value;
        uint256 bond;
        uint256 proposalId;
    }

    uint256 public constant MAX_PROPOSER_REWARD = 1_000e18;

    IERC20 public immutable CYAVKAT;
    IAragonTokenVoting public immutable VOTING;
    ICyEngagementMint public immutable ENGAGEMENT;
    address public immutable SAFE;

    address public adminReceiver;
    address public contributorsReceiver;
    address public engagementRewards;

    Param[] private _params;
    Request[] private _requests;

    event ParamSet(uint256 indexed paramId, address target, bytes4 selector, uint256 min, uint256 max, bool enabled);
    event Requested(uint256 indexed requestId, address indexed requester, uint256 indexed paramId, uint256 value, uint256 bond);
    event Linked(uint256 indexed requestId, uint256 proposalId);
    event Settled(uint256 indexed requestId, Status status);
    event Slashed(uint256 indexed requestId, uint256 toAdmin, uint256 toContributors, uint256 toEngagement);

    error NotSafe();
    error BadParam();
    error OutOfRange();
    error WrongStatus();
    error ProposalMismatch();
    error VoteNotOver();
    error WindowOpen();
    error InvalidAddress();

    modifier onlySafe() {
        if (msg.sender != SAFE) revert NotSafe();
        _;
    }

    constructor(
        address owner_,
        address cyavkat_,
        address voting_,
        address engagement_,
        address safe_,
        address admin_,
        address contributors_,
        address engagementRewards_,
        address configGate_
    ) Ownable(owner_) CurveYieldGateConfig(configGate_) {
        if (cyavkat_ == address(0) || voting_ == address(0) || engagement_ == address(0) || safe_ == address(0)) {
            revert InvalidAddress();
        }
        CYAVKAT = IERC20(cyavkat_);
        VOTING = IAragonTokenVoting(voting_);
        ENGAGEMENT = ICyEngagementMint(engagement_);
        SAFE = safe_;
        _setAdminReceiver(admin_);
        _setDestinations(contributors_, engagementRewards_);
    }

    /// @notice Bond per request (cyavKAT, 20 decimals), from the governance gate.
    function bondAmount() public view returns (uint256) {
        return _config1(K.BOND_AMOUNT);
    }

    /// @notice Engagement units minted to the proposer of an executed request, from the gate.
    function proposerReward() public view returns (uint256) {
        return _config1(K.BOND_PROPOSER_REWARD);
    }

    /// @notice Time a request may wait unlinked before its bond is refundable, from the gate.
    function intakeWindow() public view returns (uint256) {
        return _config1(K.BOND_INTAKE_WINDOW);
    }

    // ---------------------------------------------------------------- admin (owner = the governance gate)

    function setParam(uint256 paramId_, address target_, bytes4 selector_, uint256 min_, uint256 max_, bool enabled_)
        external onlyOwner
    {
        if (target_ == address(0) || min_ > max_) revert BadParam();
        Param memory p = Param(target_, selector_, min_, max_, enabled_);
        if (paramId_ == _params.length) _params.push(p);
        else _params[paramId_] = p;
        emit ParamSet(paramId_, target_, selector_, min_, max_, enabled_);
    }

    /// @notice Admin fee receiver of the slash split (protected by the governance gate: fee authority only).
    function setAdminReceiver(address admin_) external onlyOwner {
        _setAdminReceiver(admin_);
    }

    function setDestinations(address contributors_, address engagementRewards_) external onlyOwner {
        _setDestinations(contributors_, engagementRewards_);
    }

    // ---------------------------------------------------------------- requests

    function request(uint256 paramId_, uint256 value_) external returns (uint256 id_) {
        Param storage p = _params[paramId_];
        if (!p.enabled) revert BadParam();
        if (value_ < p.min || value_ > p.max) revert OutOfRange();
        uint256 bond = bondAmount();
        CYAVKAT.safeTransferFrom(msg.sender, address(this), bond);
        id_ = _requests.length;
        _requests.push(Request(msg.sender, uint64(paramId_), uint64(block.timestamp), Status.Pending, value_, bond, 0));
        emit Requested(id_, msg.sender, paramId_, value_, bond);
    }

    /// @notice The Safe links the DAO proposal it created for the request; the proposal must carry exactly one action:
    /// target.setter(value).
    function linkProposal(uint256 requestId_, uint256 proposalId_) external onlySafe {
        Request storage r = _requests[requestId_];
        if (r.status != Status.Pending) revert WrongStatus();
        Param storage p = _params[r.paramId];
        (,,,, AragonAction[] memory actions,,) = VOTING.getProposal(proposalId_);
        if (actions.length != 1 || actions[0].to != p.target || actions[0].value != 0
            || keccak256(actions[0].data) != keccak256(abi.encodeWithSelector(p.selector, r.value))) revert ProposalMismatch();
        r.status = Status.Linked;
        r.proposalId = proposalId_;
        emit Linked(requestId_, proposalId_);
    }

    /// @notice The Safe rejects a pending request (the safety check refused it): the bond is slashed.
    function reject(uint256 requestId_) external onlySafe {
        Request storage r = _requests[requestId_];
        if (r.status != Status.Pending) revert WrongStatus();
        _slash(requestId_, r);
    }

    /// @notice After the vote: executed -> refund + proposer reward; ended without execution -> slash.
    function settle(uint256 requestId_) external {
        Request storage r = _requests[requestId_];
        if (r.status != Status.Linked) revert WrongStatus();
        (bool open, bool executed, AragonProposalParameters memory params,,,,) = VOTING.getProposal(r.proposalId);
        if (executed) {
            r.status = Status.Rewarded;
            CYAVKAT.safeTransfer(r.requester, r.bond);
            uint256 reward = proposerReward();
            if (reward != 0) ENGAGEMENT.mint(r.requester, reward);
            emit Settled(requestId_, Status.Rewarded);
            return;
        }
        if (open || block.timestamp <= params.endDate) revert VoteNotOver();
        _slash(requestId_, r);
    }

    /// @notice Neither linked nor rejected within the intake window: the bond goes back to the requester.
    function refund(uint256 requestId_) external {
        Request storage r = _requests[requestId_];
        if (r.status != Status.Pending) revert WrongStatus();
        if (block.timestamp <= r.createdAt + intakeWindow()) revert WindowOpen();
        r.status = Status.Refunded;
        CYAVKAT.safeTransfer(r.requester, r.bond);
        emit Settled(requestId_, Status.Refunded);
    }

    // ---------------------------------------------------------------- views

    function paramOf(uint256 paramId_) external view returns (Param memory) {
        return _params[paramId_];
    }

    function paramsLength() external view returns (uint256) {
        return _params.length;
    }

    function requestOf(uint256 requestId_) external view returns (Request memory) {
        return _requests[requestId_];
    }

    function requestsLength() external view returns (uint256) {
        return _requests.length;
    }

    // ---------------------------------------------------------------- internals

    function _slash(uint256 requestId_, Request storage r_) private {
        r_.status = Status.Slashed;
        uint256 third = r_.bond / 3;
        uint256 toEngagement = r_.bond - 2 * third;
        CYAVKAT.safeTransfer(adminReceiver, third);
        CYAVKAT.safeTransfer(contributorsReceiver, third);
        CYAVKAT.safeTransfer(engagementRewards, toEngagement);
        emit Slashed(requestId_, third, third, toEngagement);
        emit Settled(requestId_, Status.Slashed);
    }

    function _setAdminReceiver(address admin_) private {
        if (admin_ == address(0)) revert InvalidAddress();
        adminReceiver = admin_;
    }

    function _setDestinations(address contributors_, address engagementRewards_) private {
        if (contributors_ == address(0) || engagementRewards_ == address(0)) revert InvalidAddress();
        contributorsReceiver = contributors_;
        engagementRewards = engagementRewards_;
    }
}
