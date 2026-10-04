// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {CurveYieldVotingLock} from "../src/governance/CurveYieldVotingLock.sol";
import {CurveYieldEngagementToken} from "../src/governance/CurveYieldEngagementToken.sol";
import {CurveYieldEngagementRewards} from "../src/governance/CurveYieldEngagementRewards.sol";

/// Phase 3 step 1/5: the contracts the DAO depends on. The voting lock is the TokenVoting token, so it must exist
/// before the DAO (P3_02). Owners start as the deployer and move to the governance gate in P3_05.
///   - CurveYieldVotingLock(cyavKAT, 60-day ramp)  (ownerless)
///   - CurveYieldEngagementToken                   (minters wired in P3_03)
///   - CurveYieldEngagementRewards                 (set as the engagement token's distributor)
/// Writes deployments/katana-phase3.json (PHASE3_DEPLOYMENTS env overrides).
///
///   forge script "$P2/script/P3_01_DeployGovernanceTokens.s.sol" --root $P2 --rpc-url katana --skip test --skip "*/test/**"
contract P3_01_DeployGovernanceTokens is Phase2Base {
    function run() external {
        require(block.chainid == 747474, "not Katana");
        _start();
        CurveYieldVotingLock lock = new CurveYieldVotingLock(VAULT, 60 days, "Locked cyavKAT (votes)", "vcyavKAT");
        CurveYieldEngagementToken engagement = new CurveYieldEngagementToken(DEPLOYER);
        address gate = vm.parseJsonAddress(vm.readFile(vm.envOr("PHASE0_DEPLOYMENTS", string("deployments/katana-gate.json"))), ".governanceGate");
        CurveYieldEngagementRewards rewards = new CurveYieldEngagementRewards(DEPLOYER, address(engagement), gate);
        engagement.setDistributor(address(rewards));
        _stop();

        require(address(lock.TOKEN()) == VAULT && lock.RAMP() == 60 days, "lock");
        require(engagement.distributor() == address(rewards), "distributor");
        string memory o = "p3";
        vm.serializeAddress(o, "votingLock", address(lock));
        vm.serializeAddress(o, "engagementToken", address(engagement));
        string memory json = vm.serializeAddress(o, "engagementRewards", address(rewards));
        vm.writeJson(json, _phase3Path());
        console2.log("voting lock", address(lock));
        console2.log("engagement token / rewards", address(engagement), address(rewards));
    }

    function _phase3Path() internal view returns (string memory) {
        return vm.envOr("PHASE3_DEPLOYMENTS", string("deployments/katana-phase3.json"));
    }
}
