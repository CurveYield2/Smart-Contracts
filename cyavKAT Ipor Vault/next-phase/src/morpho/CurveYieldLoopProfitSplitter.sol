// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CurveYieldGateConfig, CurveYieldConfigKeys as K, CurveYieldAddrKeys} from "../governance/CurveYieldGateConfig.sol";
import {ICyErc20, FuseAction} from "../interfaces/CurveYieldPhase2Interfaces.sol";

/// @notice Holds the #16 profit split and the contributors' share until the Phase 4 contributors fuse exists (D5).
/// The split applies to loop wind-up profit and to unwind profit (request fee kept above the loss, D2).
contract CurveYieldLoopProfitSplitter is Ownable2Step, CurveYieldGateConfig {
    uint256 private constant BPS = 10_000;

    address public immutable AVKAT;
    /// @notice Wired in the gate (`CurveYieldAddrKeys.REWARDS_CLAIM_MANAGER`, GATE_CONFIG_SPEC §10).
    function REWARDS_CLAIM_MANAGER() public view returns (address) {
        return _addr(CurveYieldAddrKeys.REWARDS_CLAIM_MANAGER);
    }

    address public growthCustody;
    address public contributorsSink;

    error InvalidAddress();
    error ContributorsSinkNotSet();

    event GrowthCustodyUpdated(address indexed custody);
    event ContributorsSinkUpdated(address indexed sink);
    event ContributorsSwept(address indexed sink, uint256 amount);

    constructor(
        address owner_,
        address avkat_,
        address growthCustody_,
        address configGate_
    ) Ownable(owner_) CurveYieldGateConfig(configGate_) {
        if (avkat_ == address(0) || growthCustody_ == address(0)) {
            revert InvalidAddress();
        }
        AVKAT = avkat_;
        growthCustody = growthCustody_;
        emit GrowthCustodyUpdated(growthCustody_);
    }

    function setGrowthCustody(address custody_) external onlyOwner {
        if (custody_ == address(0)) revert InvalidAddress();
        growthCustody = custody_;
        emit GrowthCustodyUpdated(custody_);
    }

    /// @notice Phase 4: points the contributors' share at the ContributorsRewardFuse custody.
    function setContributorsSink(address sink_) external onlyOwner {
        if (sink_ == address(0) || sink_ == address(this)) revert InvalidAddress();
        contributorsSink = sink_;
        emit ContributorsSinkUpdated(sink_);
    }

    /// @notice Pushes the held contributors' share to the configured sink. Permissionless: no discretion involved.
    function sweepContributors() external returns (uint256 amount) {
        address sink = contributorsSink;
        if (sink == address(0)) revert ContributorsSinkNotSet();
        amount = ICyErc20(AVKAT).balanceOf(address(this));
        if (amount != 0 && !ICyErc20(AVKAT).transfer(sink, amount)) revert InvalidAddress();
        emit ContributorsSwept(sink, amount);
    }

    /// @notice The four split shares (bps, sum 100%), read from the governance gate.
    function splitBps() public view returns (uint256 growth_, uint256 contributors_, uint256 vault_, uint256 rewardsManager_) {
        bytes32[] memory k = new bytes32[](4);
        (k[0], k[1], k[2], k[3]) = (K.SPLIT_GROWTH_BPS, K.SPLIT_CONTRIBUTORS_BPS, K.SPLIT_VAULT_BPS, K.SPLIT_REWARDS_MANAGER_BPS);
        uint256[] memory v = _config(k);
        return (v[0], v[1], v[2], v[3]);
    }

    function growthBps() external view returns (uint16) {
        (uint256 g,,,) = splitBps();
        return uint16(g);
    }

    function contributorsBps() external view returns (uint16) {
        (, uint256 c,,) = splitBps();
        return uint16(c);
    }

    function rewardsManagerBps() external view returns (uint16) {
        (,,, uint256 r) = splitBps();
        return uint16(r);
    }

    /// @notice Splits `amount` of profit. The vault share is the remainder, so the four parts always sum to `amount`.
    function split(uint256 amount_)
        external view returns (uint256 growth_, uint256 contributors_, uint256 vault_, uint256 rewardsManager_)
    {
        (uint256 g, uint256 c,, uint256 r) = splitBps();
        growth_ = amount_ * g / BPS;
        contributors_ = amount_ * c / BPS;
        rewardsManager_ = amount_ * r / BPS;
        vault_ = amount_ - growth_ - contributors_ - rewardsManager_;
    }

    /// @notice The split of `amount_` avKAT as transfer-fuse actions (CurveYieldErc20TransferFuse `transferFuse_`) for the
    /// executor to run in the vault: growth custody, contributors, rewards manager (the vault share stays). Also returns
    /// the rewards-manager amount (the executor then calls updateBalance on it).
    function splitLegs(uint256 amount_, address transferFuse_)
        external view returns (FuseAction[] memory legs_, uint256 toRewardsManager_)
    {
        (uint256 growth, uint256 contributors,, uint256 rewardsManager) = this.split(amount_);
        address[3] memory to = [growthCustody, this.contributorsRecipient(), REWARDS_CLAIM_MANAGER()];
        uint256[3] memory amounts = [growth, contributors, rewardsManager];
        uint256 n;
        for (uint256 i; i < 3; ++i) if (amounts[i] != 0) ++n;
        legs_ = new FuseAction[](n);
        n = 0;
        for (uint256 i; i < 3; ++i) {
            if (amounts[i] == 0) continue;
            legs_[n++] = FuseAction(transferFuse_, abi.encodeWithSignature(
                "enter((address,address,uint256))", AVKAT, to[i], amounts[i]
            ));
        }
        toRewardsManager_ = rewardsManager;
    }

    /// @notice Where the contributors' share is sent right now: the Phase 4 sink, or this contract until then.
    function contributorsRecipient() external view returns (address) {
        address sink = contributorsSink;
        return sink == address(0) ? address(this) : sink;
    }

}
