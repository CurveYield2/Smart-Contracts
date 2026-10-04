// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title CurveYieldWrapperFeeSplitter
/// @notice Receives the wcyavKAT wrapper's fees (cyavKAT) and splits them on `distribute()` (anyone):
///   40% admin fee receiver, 30% contributors reward sink, 30% to the vault's withdraw manager, where the vault's IPOR
///   BurnRequestFeeFuse burns it (shares down, assets unchanged: PPS up for every holder).
/// The split is fixed. Destinations are owner-settable through two separate setters so the governance gate can protect
/// `setAdminReceiver` (admin fees: fee authority only) while `setDestinations` (contributors, burn) stays with the DAO.
contract CurveYieldWrapperFeeSplitter is Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant ADMIN_BPS = 4_000;
    uint256 public constant CONTRIBUTORS_BPS = 3_000; // the remaining 3,000 is burned

    IERC20 public immutable CYAVKAT;
    address public adminReceiver;
    address public contributorsReceiver;
    address public burnWithdrawManager; // the vault's current withdraw manager

    event Distributed(uint256 toAdmin, uint256 toContributors, uint256 toBurn);
    event AdminReceiverUpdated(address adminReceiver);
    event DestinationsUpdated(address contributorsReceiver, address burnWithdrawManager);

    error InvalidAddress();

    constructor(address owner_, IERC20 cyavkat_, address admin_, address contributors_, address withdrawManager_)
        Ownable(owner_)
    {
        if (address(cyavkat_) == address(0)) revert InvalidAddress();
        CYAVKAT = cyavkat_;
        _setAdminReceiver(admin_);
        _setDestinations(contributors_, withdrawManager_);
    }

    /// @notice Admin fee receiver (protected by the governance gate: fee authority only).
    function setAdminReceiver(address admin_) external onlyOwner {
        _setAdminReceiver(admin_);
    }

    function setDestinations(address contributors_, address withdrawManager_) external onlyOwner {
        _setDestinations(contributors_, withdrawManager_);
    }

    /// @notice Splits the whole cyavKAT balance 40 / 30 / 30 (burn).
    function distribute() external {
        uint256 bal = CYAVKAT.balanceOf(address(this));
        if (bal == 0) return;
        uint256 toAdmin = bal * ADMIN_BPS / BPS;
        uint256 toContributors = bal * CONTRIBUTORS_BPS / BPS;
        uint256 toBurn = bal - toAdmin - toContributors;
        CYAVKAT.safeTransfer(adminReceiver, toAdmin);
        CYAVKAT.safeTransfer(contributorsReceiver, toContributors);
        CYAVKAT.safeTransfer(burnWithdrawManager, toBurn);
        emit Distributed(toAdmin, toContributors, toBurn);
    }

    function _setAdminReceiver(address admin_) private {
        if (admin_ == address(0)) revert InvalidAddress();
        adminReceiver = admin_;
        emit AdminReceiverUpdated(admin_);
    }

    function _setDestinations(address contributors_, address withdrawManager_) private {
        if (contributors_ == address(0) || withdrawManager_ == address(0)) revert InvalidAddress();
        contributorsReceiver = contributors_;
        burnWithdrawManager = withdrawManager_;
        emit DestinationsUpdated(contributors_, withdrawManager_);
    }
}
