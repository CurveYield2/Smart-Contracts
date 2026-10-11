// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";

/// @notice Mandatory, read-only V2 prerequisite. Run after K1_QuestSigning migration and
/// before P2_01. P2_01 through P2_04, governance handover, and later upgrade steps
/// re-run this SAME invariant internally and revert if signing is missing or outdated.
/// @dev No --broadcast is needed: this script performs no state changes.
contract P2_00_VerifyQuestSigning is Phase2Base {
    function run() external view {
        require(block.chainid == 747474, "not Katana");
        _requireQuestSigningV2();
        console2.log("V2 REQUIRED Quest signing layer: active, revised, installer detached");
    }
}
