// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";

interface IVaultP24 {
    function removeFuses(address[] calldata fuses) external;
    function isFuseSupported(address fuse) external view returns (bool);
    function getInstantWithdrawalFuses() external view returns (address[] memory);
}

interface IRcmP24 {
    function removeRewardFuses(address[] calldata fuses) external;
    function isRewardFuseSupported(address fuse) external view returns (bool);
}

interface IWmP24 {
    function controller() external view returns (address);
}

/// Phase 2 step 4 (#4): uninstalls fuses the Phase 2 stack no longer uses. Only after the cutover (P2_03): requires the
/// vault's withdraw manager to be WM v2. Removes (if still installed):
///   0x44D3…f36e  old BurnRequestFeeFuse (reads the pre-IL-6952 withdraw-manager slot; replaced by a fresh one)
///   0x79E8…d705  v1 Morpho strategy fuse (replaced by the Phase 2 loop fuses)
///   0xC66c…E19d  duplicate IPOR MorphoSupplyFuse(14) installed from the Terminal (unused)
///   0x1f65…f28b  duplicate IPOR MorphoSupplyFuse(41) installed from the Terminal (lending uses 0x1af8)
///   0x70a2…41Ec  CurveYieldCallerRewardFuse (cyavKAT: replaced by the withdrawal request fuse + gate keeper rewards)
///   0x1fB8…a3Ff  router swap fuse v1 (replaced by the swap fuse v2)
/// and from the rewards claim manager's reward fuses:
///   0x8c82…3470  CurveYieldMerklRewardSweepFuse, 0xb622…9704  CurveYieldMerklAutoHarvestFuse (replaced by IPOR's
///   MerklClaimFuse 0xc6d0 + the swap fuse v2 sweep)
/// Kept (used by Phase 2): collateral / borrow / flash fuses, the legacy vKAT fuse, the request-fee fuse, the market 41
/// supply fuse, the quest signature fuse, IPOR's MerklClaimFuse. Never removes an instant-withdrawal fuse.
contract P2_04_RemoveV1Fuses is Phase2Base {
    function run() external {
        require(block.chainid == 747474, "not Katana");
        IVaultP24 vault = IVaultP24(VAULT);
        address wmV2 = vm.parseJsonAddress(vm.readFile(_deploymentsPath()), ".withdrawManagerV2");
        require(IWmP24(wmV2).controller() != address(0), "run the P2_03 cutover first");
        address[6] memory candidates = [
            0x44D368e85f419C59aC01b7270D234d8BF19Df36e,
            0x79E88DD967Ef9a31046455dB94b1e487329Ed705,
            0xC66c3F5cC5e1550A0Ff960c06D630A2FBB80E19d,
            0x1f657229ec2D261be7dCD63ca82abed334d1f28b,
            0x70a2f848E21c912D660FE2263E5Be538268A41Ec,
            0x1fB8b83bAf40c90F0b450A3fd7A8b2E97Ab2a3Ff
        ];
        address[] memory instant = vault.getInstantWithdrawalFuses();
        address[] memory rm = new address[](6);
        uint256 n;
        for (uint256 i; i < 6; ++i) {
            if (!vault.isFuseSupported(candidates[i])) continue;
            for (uint256 j; j < instant.length; ++j) require(instant[j] != candidates[i], "instant fuse");
            rm[n++] = candidates[i];
        }
        assembly { mstore(rm, n) }
        address[2] memory rewardCandidates =
            [0x8c82b1ba53784F888Ea49463e2138cDF82973470, 0xb62241b19995Dac16D5905050804e1f06caC9704];
        address[] memory rrm = new address[](2);
        uint256 rn;
        for (uint256 i; i < 2; ++i) if (IRcmP24(RCM).isRewardFuseSupported(rewardCandidates[i])) rrm[rn++] = rewardCandidates[i];
        assembly { mstore(rrm, rn) }
        if (n == 0 && rn == 0) {
            console2.log("nothing to remove");
            return;
        }
        _start();
        if (n != 0) vault.removeFuses(rm);
        if (rn != 0) IRcmP24(RCM).removeRewardFuses(rrm);
        _stop();
        for (uint256 i; i < n; ++i) require(!vault.isFuseSupported(rm[i]), "still installed");
        for (uint256 i; i < rn; ++i) require(!IRcmP24(RCM).isRewardFuseSupported(rrm[i]), "reward fuse still installed");
        console2.log("removed v1 / duplicate fuses:", n);
        console2.log("removed old reward fuses:", rn);
    }
}
