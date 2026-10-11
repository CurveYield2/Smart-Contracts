// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";

interface IVaultP24 {
    function removeFuses(address[] calldata fuses) external;
    function removeBalanceFuse(uint256 marketId, address fuse) external;
    function grantMarketSubstrates(uint256 marketId, bytes32[] calldata substrates) external;
    function isFuseSupported(address fuse) external view returns (bool);
    function isBalanceFuseSupported(uint256 marketId, address fuse) external view returns (bool);
    function getInstantWithdrawalFuses() external view returns (address[] memory);
    function getMarketSubstrates(uint256 marketId) external view returns (bytes32[] memory);
    function getActiveMarketsInBalanceFuses() external view returns (uint256[] memory);
    function totalAssets() external view returns (uint256);
}

interface IRcmP24 {
    function removeRewardFuses(address[] calldata fuses) external;
    function isRewardFuseSupported(address fuse) external view returns (bool);
    function balanceOf() external view returns (uint256);
}

interface IWmP24 {
    function controller() external view returns (address);
}

interface IErc721P24 {
    function balanceOf(address owner) external view returns (uint256);
}

/// M4b (IPOR_FUSE_CONFORMANCE_SPEC §2.2, §2.3, §6): removals. Only after the cutover (P2_03): requires the vault's withdraw
/// manager to be WM v2. Asserts first that the vault holds no vKAT lock and that market 54 and the adapter are empty (F5), then:
///   - market 7: revokes the vKAT accounting adapter (a market-7 substrate would be mis-valued, F13) FIRST;
///   - retires market 54: removes its balance fuse (the adapter itself) and empties its substrates;
///   - removes from the vault (if still installed):
///       0x44D3…f36e  old BurnRequestFeeFuse (reads the pre-IL-6952 withdraw-manager slot; replaced by a fresh one)
///       0x79E8…d705  v1 Morpho strategy fuse
///       0x987C…40da  CurveYieldVkatStrategyFuse (also leaves the instant list in P2_03)
///       0xC66c…E19d / 0x1f65…f28b  duplicate IPOR MorphoSupplyFuse(14 / 41) installed from the Terminal (unused)
///       0x70a2…41Ec  CurveYieldCallerRewardFuse (the executor + gate keeper rewards replace it)
///       0x1fB8…a3Ff  router swap fuse v1 (UniversalTokenSwapperFuse + router v2 replace it; the Sushi router 0x01F9 itself
///                    STAYS live: cyvbUSDC's reward swap fuse and the live custody use it, F15 / F16)
///       0x8492…7947  the CurveYield MorphoFlashLoanFuse subclass (the unmodified IPOR fuse replaces it, market 19)
///   - the rewards claim manager: removeRewardFuses x3 (IPOR MerklClaimFuse 0xc6d0, 0x8c82 sweep, 0xb622 auto-harvest). The
///     manager stays and keeps vesting its avKAT (F6).
/// Kept: collateral / borrow fuses, market-41 supply fuse, active Quest ERC-1271 wrapper and the new persistent
/// Quest signer-config fuse. The legacy Quest installer must already have been detached in mandatory step K1.
/// Never removes an instant-withdrawal fuse.
contract P2_04_RemoveV1Fuses is Phase2Base {
    // Read-only migration invariant: no direct Sushi V3 LP NFT survives on the vault.
    // The old Sushi fee router stays live; do NOT revoke or replace it.
    address internal constant SUSHI_V3_POSITION_MANAGER = 0x2659C6085D26144117D904C46B48B6d180393d27;
    address internal constant OLD_BURN_FUSE = 0x44D368e85f419C59aC01b7270D234d8BF19Df36e;
    address internal constant V1_MORPHO_STRATEGY = 0x79E88DD967Ef9a31046455dB94b1e487329Ed705;
    address internal constant VKAT_STRATEGY_FUSE = 0x987C05943855B22552898F032c1AEa7930E340da;
    address internal constant DUP_SUPPLY_14 = 0xC66c3F5cC5e1550A0Ff960c06D630A2FBB80E19d;
    address internal constant DUP_SUPPLY_41 = 0x1f657229ec2D261be7dCD63ca82abed334d1f28b;

    /// @dev The operator produces this receipt using scripts/merkl_preflight_v6.py immediately
    /// before the removal broadcast. Anchor it to a canonical recent Katana block hash to
    /// reject stale API responses or accidental re-use after a reorg.
    function _requireMerklM3() internal view {
        string memory path = vm.envString("MERKL_PREFLIGHT_RECEIPT_PATH");
        string memory record = vm.readFile(path);
        require(vm.parseJsonUint(record, ".chainId") == block.chainid, "M3: wrong Merkl chain");
        require(vm.parseJsonAddress(record, ".vault") == VAULT, "M3: wrong vault");
        require(vm.parseJsonAddress(record, ".rewardsManager") == RCM, "M3: wrong rewards manager");
        require(vm.parseJsonUint(record, ".claimableTotalRawVault") == 0, "M3: vault has Merkl rewards");
        require(vm.parseJsonUint(record, ".claimableTotalRawRewardsManager") == 0, "M3: RCM has Merkl rewards");
        require(vm.parseJsonUint(record, ".unclaimablePendingTotalRaw") == 0 ||
            vm.envOr("MERKL_ACK_PENDING", false), "M3: pending Merkl rewards require acknowledgement");
        uint256 checkedBlock = vm.parseJsonUint(record, ".checkedBlockNumber");
        require(checkedBlock < block.number && block.number - checkedBlock <= 200,
            "M3: Merkl preflight stale/future; rerun immediately before M4");
        bytes32 expectedBlockHash = vm.parseJsonBytes32(record, ".checkedBlockHash");
        require(expectedBlockHash != bytes32(0) && blockhash(checkedBlock) == expectedBlockHash,
            "M3: Merkl preflight is not anchored to this Katana fork");
    }

    function run() external {
        require(block.chainid == 747474, "not Katana");
        _requireQuestSigningV2(); // Mandatory updated Quest ERC-1271 signing layer for the V2 upgrade.
        IVaultP24 vault = IVaultP24(VAULT);
        address wmV2 = vm.parseJsonAddress(vm.readFile(_deploymentsPath()), ".withdrawManagerV2");
        require(IWmP24(wmV2).controller() != address(0), "run the P2_03 cutover first");
        require(IErc721P24(VKAT_NFT).balanceOf(VAULT) == 0, "F5: the vault still holds vKAT locks");
        require(IErc721P24(SUSHI_V3_POSITION_MANAGER).balanceOf(VAULT) == 0,
            "M3: direct Sushi V3 LP NFT still held by vault");

        address[8] memory candidates = [
            OLD_BURN_FUSE, V1_MORPHO_STRATEGY, VKAT_STRATEGY_FUSE, DUP_SUPPLY_14, DUP_SUPPLY_41, CALLER_REWARD_FUSE, SWAP_FUSE,
            FLASH_FUSE
        ];
        address[] memory instant = vault.getInstantWithdrawalFuses();
        address[] memory rm = new address[](8);
        uint256 n;
        for (uint256 i; i < 8; ++i) {
            if (!vault.isFuseSupported(candidates[i])) continue;
            for (uint256 j; j < instant.length; ++j) require(instant[j] != candidates[i], "instant fuse");
            rm[n++] = candidates[i];
        }
        assembly { mstore(rm, n) }
        address[3] memory rewardCandidates = [MERKL_CLAIM_FUSE, MERKL_SWEEP_FUSE, MERKL_AUTO_HARVEST];
        address[] memory rrm = new address[](3);
        uint256 rn;
        for (uint256 i; i < 3; ++i) if (IRcmP24(RCM).isRewardFuseSupported(rewardCandidates[i])) rrm[rn++] = rewardCandidates[i];
        assembly { mstore(rrm, rn) }

        // M3: a current Merkl preflight is mandatory before removing the cyavKAT reward fuses.
        // The preflight checks BOTH the vault and its rewards manager; pending (unclaimable)
        // rewards do not count as immediately claimable. Do not change this to a warning.
        if (rn != 0) _requireMerklM3();

        uint256 totalBefore = vault.totalAssets();
        _start();
        // market 7 first: the adapter is a substrate there (F13); it holds no value (F5)
        bytes32[] memory subs7 = vault.getMarketSubstrates(MARKET_ERC20);
        bytes32[] memory keep = new bytes32[](subs7.length);
        uint256 k;
        for (uint256 i; i < subs7.length; ++i) if (subs7[i] != bytes32(uint256(uint160(VKAT_ADAPTER)))) keep[k++] = subs7[i];
        if (k != subs7.length) {
            assembly { mstore(keep, k) }
            vault.grantMarketSubstrates(MARKET_ERC20, keep);
        }
        // retire market 54: its balance fuse is the adapter itself; empty its substrates
        if (vault.isBalanceFuseSupported(MARKET_VKAT_RETIRED, VKAT_ADAPTER)) vault.removeBalanceFuse(MARKET_VKAT_RETIRED, VKAT_ADAPTER);
        if (vault.getMarketSubstrates(MARKET_VKAT_RETIRED).length != 0) {
            vault.grantMarketSubstrates(MARKET_VKAT_RETIRED, new bytes32[](0));
        }
        if (n != 0) vault.removeFuses(rm);
        if (rn != 0) IRcmP24(RCM).removeRewardFuses(rrm);
        _stop();

        for (uint256 i; i < n; ++i) require(!vault.isFuseSupported(rm[i]), "still installed");
        for (uint256 i; i < 3; ++i) require(!IRcmP24(RCM).isRewardFuseSupported(rewardCandidates[i]), "reward fuse still installed");
        uint256[] memory active = vault.getActiveMarketsInBalanceFuses();
        for (uint256 i; i < active.length; ++i) require(active[i] != MARKET_VKAT_RETIRED, "market 54 still active");
        require(vault.totalAssets() == totalBefore, "removals changed totalAssets");
        console2.log("removed fuses:", n);
        console2.log("removed reward fuses:", rn);
    }
}
