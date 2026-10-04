// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";

interface IGateP9 {
    function isFeeAuthority(address account) external view returns (bool);
    function feeAuthorityCount() external view returns (uint256);
    function setFeeAuthority(address account, bool granted) external;
}

/// Finalize (standalone, run once everything else is done and verified): the deployer stops being a fee authority of
/// the governance gate (it has been one since P0). Afterwards the fee Safe is the only fee authority — the only
/// account that can change admin fees, fee receivers and every other protected call, for cyavKAT and cyavKAT+ (one
/// gate). Irreversible for the deployer; the fee Safe can re-grant it.
/// Deliberately untouched: the deployer's Aragon Admin-plugin admin (removed only when the user asks) and its operator
/// role on the revenue custody v2 / custody farm (user decision 2026-09-29).
/// The deployer sends the call itself (a fee authority may remove itself; the last one cannot be removed).
///   forge script script/P9_FinalizeFeeAuthority.s.sol --root <phase2> --rpc-url katana   (dry run; --broadcast to send)
contract P9_FinalizeFeeAuthority is Phase2Base {
    address internal constant FEE_SAFE = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        IGateP9 gate = IGateP9(vm.parseJsonAddress(
            vm.readFile(vm.envOr("PHASE3_DEPLOYMENTS", string("deployments/katana-phase3.json"))), ".governanceGate"
        ));
        require(gate.isFeeAuthority(FEE_SAFE), "fee Safe is not a fee authority: removing the deployer would lock fees");
        require(gate.isFeeAuthority(DEPLOYER), "deployer is already not a fee authority");

        _start();
        gate.setFeeAuthority(DEPLOYER, false);
        _stop();

        require(!gate.isFeeAuthority(DEPLOYER), "deployer still a fee authority");
        require(gate.isFeeAuthority(FEE_SAFE) && gate.feeAuthorityCount() == 1, "fee Safe must be the only fee authority");
        console2.log("fee authorities: fee Safe only", FEE_SAFE);
    }
}
