// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {CurveYieldEngagementToken} from "../src/governance/CurveYieldEngagementToken.sol";
import {CurveYieldEngagementRewards} from "../src/governance/CurveYieldEngagementRewards.sol";
import {CurveYieldVoterRewards} from "../src/governance/CurveYieldVoterRewards.sol";
import {CurveYieldProposalBond} from "../src/governance/CurveYieldProposalBond.sol";
import {CurveYieldGovernanceGate} from "../src/governance/CurveYieldGovernanceGate.sol";
import {CurveYieldOptimizationGuardian} from "../src/governance/CurveYieldOptimizationGuardian.sol";

/// Phase 3 step 3/5 (after P3_01 tokens and P3_02 DAO + Safe):
///   - CurveYieldVoterRewards (TokenVoting, voting lock, engagement token)
///   - CurveYieldProposalBond (cyavKAT bond; Safe links / rejects; slash thirds: fee Safe / contributors / engagement rewards)
///   - CurveYieldGovernanceGate (dao, FEE_AUTHORITY = fee Safe 0x4762)
///   - CurveYieldOptimizationGuardian (gate, vault access manager, owners = deployer + fee Safe + DAO, operator BOT_OPERATOR)
///   - engagement minters = bond + voter rewards; engagement rewards pays cyavKAT
/// Gate configuration (protected list, guardian lane) is P3_04 (fee authority); ownership moves are P3_05.
/// Env: BOT_OPERATOR (the #17 bot key; may be 0 and set later), CONTRIBUTORS_RECEIVER (default the fee Safe).
contract P3_03_DeployGovernanceCore is Phase2Base {
    address internal constant FEE_SAFE = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        string memory path = vm.envOr("PHASE3_DEPLOYMENTS", string("deployments/katana-phase3.json"));
        string memory j = vm.readFile(path);
        address lock = vm.parseJsonAddress(j, ".votingLock");
        CurveYieldEngagementToken engagement = CurveYieldEngagementToken(vm.parseJsonAddress(j, ".engagementToken"));
        CurveYieldEngagementRewards rewards = CurveYieldEngagementRewards(vm.parseJsonAddress(j, ".engagementRewards"));
        address dao = vm.parseJsonAddress(j, ".dao");
        address voting = vm.parseJsonAddress(j, ".tokenVoting");
        address safe = vm.parseJsonAddress(j, ".safe");
        address contributors = vm.envOr("CONTRIBUTORS_RECEIVER", FEE_SAFE);
        address operator = vm.envOr("BOT_OPERATOR", address(0));

        CurveYieldGovernanceGate gate = CurveYieldGovernanceGate(vm.parseJsonAddress(
            vm.readFile(vm.envOr("PHASE0_DEPLOYMENTS", string("deployments/katana-gate.json"))), ".governanceGate"
        ));
        _start();
        CurveYieldVoterRewards voterRewards = new CurveYieldVoterRewards(DEPLOYER, voting, lock, address(engagement), address(gate));
        CurveYieldProposalBond bond = new CurveYieldProposalBond(
            DEPLOYER, VAULT, voting, address(engagement), safe, FEE_SAFE, contributors, address(rewards), address(gate)
        );
        address[] memory owners = new address[](3);
        (owners[0], owners[1], owners[2]) = (DEPLOYER, FEE_SAFE, dao);
        CurveYieldOptimizationGuardian guardian =
            new CurveYieldOptimizationGuardian(address(gate), ACCESS_MANAGER, VAULT, owners, operator);
        engagement.setMinter(address(bond), true);
        engagement.setMinter(address(voterRewards), true);
        rewards.setRewardToken(VAULT, true); // slashed bonds arrive as cyavKAT
        _registerGuardianActions(guardian);
        // the P0 gate goes to the DAO and the fee Safe (the deployer stays fee authority until the finalize step, so
        // P4 / P5 can add their gate rules), and its guardian lane to the Optimization Guardian
        gate.setGuardian(address(guardian));
        _guardianRanges(gate);
        gate.setFeeAuthority(FEE_SAFE, true);
        gate.setDao(dao);
        _stop();

        require(engagement.isMinter(address(bond)) && engagement.isMinter(address(voterRewards)), "minters");
        require(gate.dao() == dao && gate.isFeeAuthority(FEE_SAFE) && gate.guardian() == address(guardian), "gate");
        require(guardian.isOwner(dao) && guardian.isOwner(FEE_SAFE) && guardian.isOwner(DEPLOYER), "guardian owners");

        string memory o = "p3core";
        vm.serializeJson(o, j); // keep P3_01 / P3_02 keys
        vm.serializeAddress(o, "voterRewards", address(voterRewards));
        vm.serializeAddress(o, "proposalBond", address(bond));
        vm.serializeAddress(o, "governanceGate", address(gate));
        string memory out = vm.serializeAddress(o, "optimizationGuardian", address(guardian));
        vm.writeJson(out, path);
        console2.log("voter rewards / bond", address(voterRewards), address(bond));
        console2.log("gate / guardian", address(gate), address(guardian));
    }

    /// @dev The bot's ranges for the GUARDIAN-class keys (tighter than the keys' hard caps).
    function _guardianRanges(CurveYieldGovernanceGate gate_) internal {
        gate_.setGuardianRange(keccak256("vkat.allocationBps"), 0, 2_000);
        gate_.setGuardianRange(keccak256("loop.allocationBps"), 3_000, 8_000);
        gate_.setGuardianRange(keccak256("lend.capBps"), 0, 2_000);
        gate_.setGuardianRange(keccak256("lend.decayBps"), 0, 2_500);
        gate_.setGuardianRange(keccak256("lp.maxBps"), 200, 500);
        gate_.setGuardianRange(keccak256("alloc.vaultFloorBps"), 1_500, 4_000);
        gate_.setGuardianRange(keccak256("pol.capBps"), 0, 1_000);
    }

    /// @dev Bot action ids — MUST match curveyield-bots/config/katana.json guardianActions (0..3), then extended.
    /// Bounds are the bot's own (tighter than the controllers' bounds); owners can change them later.
    function _registerGuardianActions(CurveYieldOptimizationGuardian g_) internal {
        string memory p2 = vm.readFile(_deploymentsPath());
        address vkat = vm.parseJsonAddress(p2, ".vkatController");
        address loop = vm.parseJsonAddress(p2, ".loopController");
        address lend = vm.parseJsonAddress(p2, ".lendController");
        address lp = vm.parseJsonAddress(p2, ".lpController");
        address alloc = vm.parseJsonAddress(p2, ".allocation");
        address custody = 0xe7D109Ce6b34447Dd45B54e5615F4177291D5ADf;
        // actions 0-5 (numeric settings) moved to the gate's guardian ranges (GATE_CONFIG_SPEC G2): see _guardianRanges;
        // the bot calls guardian.setConfig(key, value) for them
        (vkat, loop, lend, lp, alloc);
        // ids are positional (setAction appends only at id == length): keep 0-5 as disabled placeholders so the bot's
        // ids 6 / 7 stay stable
        for (uint256 id; id < 6; ++id) g_.setAction(id, address(g_), bytes4(0), false, 0, 0, false);
        g_.setAction(6, custody, bytes4(keccak256("deployAll()")), false, 0, 0, true); // custody wind-up
        g_.setAction(7, custody, bytes4(keccak256("balanceLtv()")), false, 0, 0, true); // custody rebalance
    }
}
