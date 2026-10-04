// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ICyErc20, ICyRewardsClaimManager} from "../interfaces/CurveYieldPhase2Interfaces.sol";

interface ICyProfitSplitter {
    function split(uint256 amount)
        external view returns (uint256 growth, uint256 contributors, uint256 vault, uint256 rewardsManager);
    function growthCustody() external view returns (address);
    function contributorsRecipient() external view returns (address);
    function REWARDS_CLAIM_MANAGER() external view returns (address);
}

/// @notice Moves a profit amount out of the vault per the splitter (runs in vault context, #16).
/// The vault's own share simply stays in the vault.
library CurveYieldProfitSplitLib {
    error ProfitTransferFailed(address to, uint256 amount);

    event LoopProfitSplit(uint256 profit, uint256 growth, uint256 contributors, uint256 vault, uint256 rewardsManager);

    function distribute(address splitter_, address avkat_, uint256 profit_) internal returns (uint256 sentOut_) {
        if (profit_ == 0) return 0;
        ICyProfitSplitter splitter = ICyProfitSplitter(splitter_);
        (uint256 growth, uint256 contributors, uint256 vault, uint256 rewardsManager) = splitter.split(profit_);
        _send(avkat_, splitter.growthCustody(), growth);
        _send(avkat_, splitter.contributorsRecipient(), contributors);
        if (rewardsManager != 0) {
            address manager = splitter.REWARDS_CLAIM_MANAGER();
            _send(avkat_, manager, rewardsManager);
            ICyRewardsClaimManager(manager).updateBalance();
        }
        sentOut_ = growth + contributors + rewardsManager;
        emit LoopProfitSplit(profit_, growth, contributors, vault, rewardsManager);
    }

    function _send(address token_, address to_, uint256 amount_) private {
        if (amount_ != 0 && !ICyErc20(token_).transfer(to_, amount_)) revert ProfitTransferFailed(to_, amount_);
    }
}
