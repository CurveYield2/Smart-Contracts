// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {CurveYieldAddrKeys} from "../src/governance/CurveYieldGateConfig.sol";
import {Phase2Base, IVaultConfigAppend} from "./Phase2Base.s.sol";
import {CurveYieldReferrals} from "../src/leaderboard/CurveYieldReferrals.sol";
import {CurveYieldLeaderboard} from "../src/leaderboard/CurveYieldLeaderboard.sol";
import {CurveYieldSpecialRewards} from "../src/plus/CurveYieldSpecialRewards.sol";
import {CurveYieldContributorsRewardFuse} from "../src/plus/CurveYieldContributorsRewardFuse.sol";
import {CurveYieldPlusLoopController} from "../src/plus/CurveYieldPlusLoopController.sol";
import {CurveYieldPlusDepositRouter} from "../src/plus/CurveYieldPlusDepositRouter.sol";
import {CurveYieldEngagementRewards} from "../src/governance/CurveYieldEngagementRewards.sol";

interface IContributorsSinksP44 {
    function setContributorsSink(address sink) external; // loop profit splitter
    function setDestinations(address contributors, address second) external; // wrapper fee splitter / proposal bond
}

interface IWmSplitP44 {
    function setFeeSplit(address[3] calldata recipients, uint16[3] calldata bps, bool splitRequestFee) external;
}

/// Phase 4 step 4: the reward layer (#24 referrals + leaderboard, #22 special rewards, #23 contributors reward fuse) and
/// its wiring. Run after P3_01..P3_04 and P4_01..P4_03, BEFORE the P3_05 handover (which then moves these too).
///   - special rewards becomes the destination everywhere the fee Safe stood in (cyavKAT+ controller / router / WM v2
///     split, leaderboard point purchases)
///   - the contributors fuse is whitelisted in the cyavKAT+ router (no deposit fee); point the contributors sinks
///     (loop splitter, wrapper splitter, bond) at it afterwards (they are gate-protected / owner setters)
///   - cyavKAT+ is whitelisted as a reward token in the engagement rewards contract (governance distributions)
///   - leaderboard points allocator = POINTS_ALLOCATOR (the off-chain partner workflow key; may be 0 until set)
interface IGateRulesP44 {
    function addRule(uint8 kind, uint256 bound, bytes32[] calldata keys, address lockTarget, bytes4 lockSelector)
        external returns (uint256);
}

contract P4_04_DeployRewards is Phase2Base {
    address internal constant FEE_SAFE = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;

    function _appendPlus(address plusVault_, bytes32[] memory add_) internal {
        bytes32[] memory cur = IVaultConfigAppend(plusVault_).getMarketSubstrates(MARKET_SUBSTRATES);
        bytes32[] memory out = new bytes32[](cur.length + add_.length);
        uint256 n;
        for (uint256 i; i < cur.length; ++i) out[n++] = cur[i];
        for (uint256 i; i < add_.length; ++i) {
            bool dup;
            for (uint256 j; j < n; ++j) if (out[j] == add_[i]) dup = true;
            if (!dup) out[n++] = add_[i];
        }
        assembly { mstore(out, n) }
        IVaultConfigAppend(plusVault_).grantMarketSubstrates(MARKET_SUBSTRATES, out);
    }

    function run() external {
        require(block.chainid == 747474, "not Katana");
        string memory p4Path = vm.envOr("PHASE4_DEPLOYMENTS", string("deployments/katana-phase4.json"));
        string memory p4 = vm.readFile(p4Path);
        string memory p3 = vm.readFile(vm.envOr("PHASE3_DEPLOYMENTS", string("deployments/katana-phase3.json")));
        address plus = vm.parseJsonAddress(p4, ".plusVault");
        address booster = vm.parseJsonAddress(p4, ".plusYieldBooster");

        address gate = vm.parseJsonAddress(vm.readFile(vm.envOr("PHASE0_DEPLOYMENTS", string("deployments/katana-gate.json"))), ".governanceGate");
        _start();
        CurveYieldReferrals referrals = new CurveYieldReferrals(DEPLOYER, VAULT, FEE_SAFE, gate);
        _wireAddr(gate, CurveYieldAddrKeys.REFERRALS, address(referrals));
        _wireAddr(gate, CurveYieldAddrKeys.PLUS_CONTROLLER, vm.parseJsonAddress(p4, ".plusController"));
        _wireAddr(gate, CurveYieldAddrKeys.PLUS_DEPOSIT_ROUTER, vm.parseJsonAddress(p4, ".plusDepositRouter"));
        CurveYieldLeaderboard leaderboard = new CurveYieldLeaderboard(DEPLOYER, VAULT, gate);
        _wireAddr(gate, CurveYieldAddrKeys.LEADERBOARD, address(leaderboard));
        {
            // GATE_CONFIG_SPEC: the point-purchase split may not change while a season is active
            bytes32[] memory splitKeys = new bytes32[](4);
            (splitKeys[0], splitKeys[1], splitKeys[2], splitKeys[3]) = (
                keccak256("leaderboard.buySplit0"), keccak256("leaderboard.buySplit1"),
                keccak256("leaderboard.buySplit2"), keccak256("leaderboard.buySplit3")
            );
            IGateRulesP44(gate).addRule(6, 0, splitKeys, address(leaderboard), bytes4(keccak256("seasonActive()")));
        }
        CurveYieldSpecialRewards special = new CurveYieldSpecialRewards(
            DEPLOYER, VAULT, plus, gate, vm.parseJsonAddress(p3, ".engagementToken"), FEE_SAFE
        );
        CurveYieldContributorsRewardFuse contributors = new CurveYieldContributorsRewardFuse(
            DEPLOYER, AVKAT, VAULT, plus, gate, vm.parseJsonAddress(p3, ".engagementRewards")
        );

        // leaderboard point purchases: admin / special rewards / cyavKAT growth custody / cyavKAT+ booster
        leaderboard.setAdminReceiver(FEE_SAFE);
        leaderboard.setBuyDestinations(address(special), GROWTH_CUSTODY, booster);
        leaderboard.setPointsAllocator(vm.envOr("POINTS_ALLOCATOR", address(0)));
        // special rewards replaces the fee-Safe placeholder
        CurveYieldPlusLoopController(vm.parseJsonAddress(p4, ".plusController")).setDestinations(address(special), booster);
        CurveYieldPlusDepositRouter router = CurveYieldPlusDepositRouter(vm.parseJsonAddress(p4, ".plusDepositRouter"));
        router.setDestinations(vm.parseJsonAddress(p4, ".plusRewardsManager"), address(special), booster);
        router.setWhitelisted(address(contributors), true);
        IWmSplitP44(vm.parseJsonAddress(p4, ".plusWithdrawManagerV2")).setFeeSplit(
            [FEE_SAFE, address(special), booster], [uint16(2_000), 2_500, 3_000], true
        );
        CurveYieldEngagementRewards(vm.parseJsonAddress(p3, ".engagementRewards")).setRewardToken(plus, true);
        // every contributors share now lands in the contributors fuse
        string memory p2 = vm.readFile(_deploymentsPath());
        string memory lend = vm.readFile(_lendingPath());
        IContributorsSinksP44(vm.parseJsonAddress(p2, ".splitter")).setContributorsSink(address(contributors));
        // fuse standardization: the executor's split legs pay the contributors fuse through the transfer fuse
        bytes32[] memory mainRecipients = new bytes32[](1);
        mainRecipients[0] = _typed(3, address(contributors));
        _appendSubstrates(MARKET_SUBSTRATES, mainRecipients);
        // cyavKAT+ profit legs now also pay special rewards (its own market 54)
        bytes32[] memory plusRecipients = new bytes32[](1);
        plusRecipients[0] = _typed(3, address(special));
        _appendPlus(plus, plusRecipients);
        // wrapper fees 40 / 40 / 20: with the L10 forwarder the splitter's burn leg goes through it (2/3 burned, 1/3 contributors)
        address wmV2 = vm.parseJsonAddress(p2, ".withdrawManagerV2");
        if (vm.keyExistsJson(lend, ".wrapperBurnForwarder")) {
            address fwd = vm.parseJsonAddress(lend, ".wrapperBurnForwarder");
            IContributorsSinksP44(vm.parseJsonAddress(lend, ".wrapperFeeSplitter")).setDestinations(address(contributors), fwd);
            IContributorsSinksP44(fwd).setDestinations(address(contributors), wmV2);
        } else {
            IContributorsSinksP44(vm.parseJsonAddress(lend, ".wrapperFeeSplitter")).setDestinations(address(contributors), wmV2);
        }
        IContributorsSinksP44(vm.parseJsonAddress(p3, ".proposalBond"))
            .setDestinations(address(contributors), vm.parseJsonAddress(p3, ".engagementRewards"));
        _stop();

        vm.serializeJson("p4r", p4);
        vm.serializeAddress("p4r", "referrals", address(referrals));
        vm.serializeAddress("p4r", "leaderboard", address(leaderboard));
        vm.serializeAddress("p4r", "specialRewards", address(special));
        string memory out = vm.serializeAddress("p4r", "contributorsRewardFuse", address(contributors));
        vm.writeJson(out, p4Path);
        console2.log("rewards deployed; leaderboard / special / contributors", address(leaderboard), address(special), address(contributors));
    }
}
