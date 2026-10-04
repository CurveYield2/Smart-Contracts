// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {AragonAction} from "../src/governance/CurveYieldAragonInterfaces.sol";

interface IOwnable2StepP35 {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

interface IAdminPluginP35 {
    function executeProposal(bytes calldata metadata, AragonAction[] calldata actions, uint256 allowFailureMap)
        external returns (uint256);
}

interface IGateP35 {
    function execute(address target, bytes calldata data) external returns (bytes memory);
}

interface IAccessManagerP35 {
    function grantRole(uint64 roleId, address account, uint32 executionDelay) external;
    function renounceRole(uint64 roleId, address callerConfirmation) external;
    function hasRole(uint64 roleId, address account) external view returns (bool, uint32);
}

interface ISafeP35 {
    function isOwner(address) external view returns (bool);
    function getThreshold() external view returns (uint256);
    function execTransaction(
        address to, uint256 value, bytes calldata data, uint8 operation, uint256 safeTxGas, uint256 baseGas,
        uint256 gasPrice, address gasToken, address payable refundReceiver, bytes memory signatures
    ) external payable returns (bool);
}

/// Phase 3 step 5/5: hands every non-public control to the DAO through the governance gate (PHASE3_DESIGN_SPEC §2).
///   A. the deployer starts ownership transfers of every CurveYield contract it owns -> gate (Ownable2Step)
///   B. the fee Safe moves the router (one-step) and the Growth Custody (two-step) -> gate
///   C. the DAO accepts every two-step transfer: ONE Admin-plugin executeProposal whose actions call
///      gate.execute(target, acceptOwnership())   (the Admin plugin is used, never touched)
///   D. IPOR roles: the gate gets OWNER, ATOMIST, FUSE_MANAGER, CLAIM_REWARDS, WHITELIST, 900, 901, 902, 1000, 1200;
///      the guardian gets GUARDIAN (2); then the deployer renounces all of them and ALPHA (the executor keeps ALPHA)
///   E. final checks: every contract is owned by the gate; the deployer holds no vault role. Allowed exceptions:
///      the deployer stays an Aragon Admin-plugin admin (HARD RULE: removed only when the user asks) and an
///      Optimization Guardian owner; the fee Safe holds FEE_AUTHORITY.
///
/// Dry-run it on a fork first; it is irreversible for the deployer.
contract P3_05_Handover is Phase2Base {
    address internal constant FEE_SAFE = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;
    address internal constant CUSTODY = 0xe7D109Ce6b34447Dd45B54e5615F4177291D5ADf;

    address internal gate;
    address[] internal twoStep; // contracts the DAO must accept

    function run() external {
        require(block.chainid == 747474, "not Katana");
        string memory p3 = vm.readFile(vm.envOr("PHASE3_DEPLOYMENTS", string("deployments/katana-phase3.json")));
        string memory p2 = vm.readFile(_deploymentsPath());
        string memory lend = vm.readFile(_lendingPath());
        gate = vm.parseJsonAddress(p3, ".governanceGate");
        address guardian = vm.parseJsonAddress(p3, ".optimizationGuardian");
        address adminPlugin = vm.parseJsonAddress(p3, ".adminPlugin");

        string[8] memory p2Keys = ["executor", "allocation", "loopController", "splitter", "vkatController", "lendController", "lpController", "swapRouterV2"];
        string[4] memory p3Keys = ["engagementToken", "engagementRewards", "voterRewards", "proposalBond"];
        for (uint256 i; i < p2Keys.length; ++i) twoStep.push(vm.parseJsonAddress(p2, string.concat(".", p2Keys[i])));
        for (uint256 i; i < p3Keys.length; ++i) twoStep.push(vm.parseJsonAddress(p3, string.concat(".", p3Keys[i])));
        twoStep.push(vm.parseJsonAddress(lend, ".wcyavkat"));
        twoStep.push(vm.parseJsonAddress(lend, ".wrapperFeeSplitter"));
        if (vm.keyExistsJson(lend, ".wrapperBurnForwarder")) twoStep.push(vm.parseJsonAddress(lend, ".wrapperBurnForwarder")); // L10
        string memory p5Path = vm.envOr("PHASE5_DEPLOYMENTS", string("deployments/katana-phase5.json"));
        address yieldFeeder;
        if (vm.exists(p5Path)) { // P5_01 (POL)
            string memory p5 = vm.readFile(p5Path);
            twoStep.push(vm.parseJsonAddress(p5, ".polController"));
            twoStep.push(vm.parseJsonAddress(p5, ".polCustody"));
            twoStep.push(vm.parseJsonAddress(p5, ".polIncomingFeeder"));
            yieldFeeder = vm.parseJsonAddress(p5, ".polYieldFeeder");
            twoStep.push(yieldFeeder);
        }
        uint256 deployerOwned = twoStep.length;
        twoStep.push(CUSTODY); // owned by the fee Safe



        _start(); // PRIVATE_KEY (must be the deployer, checked in _start) or the fork default DEPLOYER
        // A.
        for (uint256 i; i < deployerOwned; ++i) {
            IOwnable2StepP35 c = IOwnable2StepP35(twoStep[i]);
            if (c.owner() == DEPLOYER) c.transferOwnership(gate);
        }
        // B.
        bytes memory sig = abi.encodePacked(uint256(uint160(DEPLOYER)), uint256(0), uint8(1));
        _safe(ROUTER, abi.encodeCall(IOwnable2StepP35.transferOwnership, (gate)), sig);
        if (yieldFeeder != address(0)) { // POL: the profit custody's own fee share now passes through the yield feeder
            _safe(CUSTODY, abi.encodeWithSignature("setFeeRecipient(address)", yieldFeeder), sig);
        }
        _safe(CUSTODY, abi.encodeCall(IOwnable2StepP35.transferOwnership, (gate)), sig);
        // C.
        AragonAction[] memory actions = new AragonAction[](twoStep.length);
        for (uint256 i; i < twoStep.length; ++i) {
            actions[i] = AragonAction(gate, 0,
                abi.encodeCall(IGateP35.execute, (twoStep[i], abi.encodeCall(IOwnable2StepP35.acceptOwnership, ()))));
        }
        IAdminPluginP35(adminPlugin).executeProposal("Phase 3 handover: accept ownership into the governance gate", actions, 0);
        // D.
        IAccessManagerP35 am = IAccessManagerP35(ACCESS_MANAGER);
        am.grantRole(2, guardian, 0);
        uint64[10] memory gateRoles = [uint64(1), 100, 300, 600, 800, 900, 901, 902, 1000, 1200];
        for (uint256 i; i < gateRoles.length; ++i) am.grantRole(gateRoles[i], gate, 0);
        uint64[11] memory drop = [uint64(200), 300, 600, 800, 900, 901, 902, 1000, 1200, 100, 1];
        for (uint256 i; i < drop.length; ++i) {
            (bool has,) = am.hasRole(drop[i], DEPLOYER);
            if (has) am.renounceRole(drop[i], DEPLOYER);
        }
        _stop();

        // E.
        for (uint256 i; i < twoStep.length; ++i) {
            require(IOwnable2StepP35(twoStep[i]).owner() == gate, string.concat("not gate-owned: ", vm.toString(twoStep[i])));
        }
        require(IOwnable2StepP35(ROUTER).owner() == gate, "router");
        for (uint256 i; i < drop.length; ++i) {
            (bool has,) = am.hasRole(drop[i], DEPLOYER);
            require(!has, string.concat("deployer still holds role ", vm.toString(uint256(drop[i]))));
            if (drop[i] != 200) {
                (bool gateHas,) = am.hasRole(drop[i], gate);
                require(gateHas, string.concat("gate missing role ", vm.toString(uint256(drop[i]))));
            }
        }
        (bool gHas,) = am.hasRole(2, guardian);
        require(gHas, "guardian role");
        console2.log("handover complete: gate", gate);
        console2.log("allowed exceptions: deployer = Admin-plugin admin + guardian owner; fee Safe = FEE_AUTHORITY");
    }

    function _safe(address to_, bytes memory data_, bytes memory sig_) internal {
        require(ISafeP35(FEE_SAFE).isOwner(DEPLOYER) && ISafeP35(FEE_SAFE).getThreshold() == 1, "fee Safe signer");
        bool ok = ISafeP35(FEE_SAFE).execTransaction(to_, 0, data_, 0, 0, 0, 0, address(0), payable(address(0)), sig_);
        require(ok, "Safe execTransaction failed");
    }
}
