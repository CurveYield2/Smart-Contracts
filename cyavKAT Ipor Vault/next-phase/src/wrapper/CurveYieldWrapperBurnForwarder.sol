// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface ICyWrapperFeeSplitter {
    function distribute() external;
}

/// @title CurveYieldWrapperBurnForwarder
/// @notice Turns the live wrapper fee split (40 admin / 30 contributors / 30 burn, fixed in CurveYieldWrapperFeeSplitter
/// 0xB537…8799, which the wcyavKAT wrapper points at immutably) into the approved 40 / 40 / 20:
/// the splitter's burn destination is this contract, which sends 2/3 of what it receives to the vault's withdraw
/// manager (burned: 20% of the fees) and 1/3 to the contributors receiver (+10%: 40% in total).
/// `distribute()` (anyone) runs the splitter's distribute first, then splits this contract's balance.
/// Reversible: point the splitter's burn destination back at the withdraw manager.
contract CurveYieldWrapperBurnForwarder is Ownable2Step {
    using SafeERC20 for IERC20;

    IERC20 public immutable CYAVKAT;
    ICyWrapperFeeSplitter public immutable SPLITTER;
    address public contributorsReceiver;
    address public burnWithdrawManager; // the vault's current withdraw manager

    event Forwarded(uint256 toBurn, uint256 toContributors);
    event DestinationsUpdated(address contributorsReceiver, address burnWithdrawManager);

    error InvalidAddress();

    constructor(address owner_, IERC20 cyavkat_, address splitter_, address contributors_, address withdrawManager_)
        Ownable(owner_)
    {
        if (address(cyavkat_) == address(0) || splitter_ == address(0)) revert InvalidAddress();
        CYAVKAT = cyavkat_;
        SPLITTER = ICyWrapperFeeSplitter(splitter_);
        _setDestinations(contributors_, withdrawManager_);
    }

    /// @notice Same shape as the splitter's setter, so both are re-pointed together (e.g. at the WM v2 cutover).
    function setDestinations(address contributors_, address withdrawManager_) external onlyOwner {
        _setDestinations(contributors_, withdrawManager_);
    }

    function distribute() external {
        SPLITTER.distribute();
        uint256 bal = CYAVKAT.balanceOf(address(this));
        if (bal == 0) return;
        uint256 toBurn = bal * 2 / 3;
        uint256 toContributors = bal - toBurn;
        CYAVKAT.safeTransfer(burnWithdrawManager, toBurn);
        CYAVKAT.safeTransfer(contributorsReceiver, toContributors);
        emit Forwarded(toBurn, toContributors);
    }

    function _setDestinations(address contributors_, address withdrawManager_) private {
        if (contributors_ == address(0) || withdrawManager_ == address(0)) revert InvalidAddress();
        contributorsReceiver = contributors_;
        burnWithdrawManager = withdrawManager_;
        emit DestinationsUpdated(contributors_, withdrawManager_);
    }
}
