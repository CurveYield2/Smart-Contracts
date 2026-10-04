// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {AragonAction} from "../src/governance/CurveYieldAragonInterfaces.sol";
import {CurveYieldGovernanceGate} from "../src/governance/CurveYieldGovernanceGate.sol";

interface IOwnableP45 {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

interface IAdminPluginP45 {
    function executeProposal(bytes calldata metadata, AragonAction[] calldata actions, uint256 allowFailureMap)
        external returns (uint256);
}

interface IAccessManagerP45 {
    function grantRole(uint64 roleId, address account, uint32 executionDelay) external;
    function renounceRole(uint64 roleId, address callerConfirmation) external;
    function hasRole(uint64 roleId, address account) external view returns (bool, uint32);
}

interface ISafeP45 {
    function execTransaction(
        address to, uint256 value, bytes calldata data, uint8 operation, uint256 safeTxGas, uint256 baseGas,
        uint256 gasPrice, address gasToken, address payable refundReceiver, bytes memory signatures
    ) external payable returns (bool);
}

/// Phase 4 step 5: governance for the Phase 4 contracts — the same model as P3_04 + P3_05 (fully reversible:
/// P3_99_Rollback's pattern applies; the fee Safe keeps FEE_AUTHORITY, the Aragon Admin plugin is never touched).
///   A. fee Safe (FEE_AUTHORITY): register the cyavKAT+ access manager (roles 7/400/500/901/902 protected) and protect
///      every Phase 4 admin-fee setter
///   B. deployer: start ownership transfers of the Phase 4 contracts to the gate; the DAO accepts in ONE Admin-plugin
///      proposal (gate.execute(target, acceptOwnership()))
///   C. cyavKAT+ roles: the gate gets 1/100/300/800/900/901/902/1000/1200, then the deployer renounces its roles
///      (the executor keeps ALPHA; router 800/1100 and booster 1100 stay)
contract P4_05_GovernPhase4 is Phase2Base {
    address internal constant FEE_SAFE = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;

    string internal p4;
    CurveYieldGovernanceGate internal gate;
    bytes internal sig;
    address[] internal owned;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        p4 = vm.readFile(vm.envOr("PHASE4_DEPLOYMENTS", string("deployments/katana-phase4.json")));
        string memory p3 = vm.readFile(vm.envOr("PHASE3_DEPLOYMENTS", string("deployments/katana-phase3.json")));
        gate = CurveYieldGovernanceGate(vm.parseJsonAddress(p3, ".governanceGate"));
        require(gate.isFeeAuthority(FEE_SAFE), "fee Safe is not the gate's fee authority");
        sig = abi.encodePacked(uint256(uint160(DEPLOYER)), uint256(0), uint8(1));
        string[9] memory keys = ["plusController", "plusExecutor", "plusDepositRouter", "plusYieldBooster", "leaderboard",
            "referrals", "specialRewards", "contributorsRewardFuse", "plusRequestFeeFuse"];
        for (uint256 i; i < keys.length; ++i) owned.push(_a(string.concat(".", keys[i])));

        _start();
        _protect();
        for (uint256 i; i < owned.length; ++i) {
            if (IOwnableP45(owned[i]).owner() == DEPLOYER) IOwnableP45(owned[i]).transferOwnership(address(gate));
        }
        AragonAction[] memory actions = new AragonAction[](owned.length);
        for (uint256 i; i < owned.length; ++i) {
            actions[i] = AragonAction(address(gate), 0, abi.encodeCall(
                CurveYieldGovernanceGate.execute, (owned[i], abi.encodeCall(IOwnableP45.acceptOwnership, ()))
            ));
        }
        IAdminPluginP45(vm.parseJsonAddress(p3, ".adminPlugin"))
            .executeProposal("Phase 4 handover: accept ownership into the governance gate", actions, 0);
        _roles();
        _stop();

        for (uint256 i; i < owned.length; ++i) require(IOwnableP45(owned[i]).owner() == address(gate), "not gate-owned");
        console2.log("Phase 4 governed by the gate", address(gate));
    }

    function _protect() internal {
        address am = _a(".plusAccessManager");
        _safe(abi.encodeCall(gate.setAccessManager, (am, true)));
        uint64[] memory roles = new uint64[](5);
        (roles[0], roles[1], roles[2], roles[3], roles[4]) = (7, 400, 500, 901, 902);
        _safe(abi.encodeCall(gate.setProtectedRoles, (am, roles, true)));
        _p(_a(".leaderboard"), "setAdminReceiver(address)");
        _p(_a(".referrals"), "setFeeReceiver(address)"); // the claim fee itself is a FEE gate key
        _p(_a(".plusController"), "setAdminReceiver(address)");
        _p(_a(".plusController"), "setProfitSplit(uint16,uint16,uint16,uint16)");
        _p(_a(".plusDepositRouter"), "setDepositFee(uint256,uint16[4])");
        _p(_a(".plusDepositRouter"), "setAdminReceiver(address)");
        _p(_a(".plusDepositRouter"), "setWhitelisted(address,bool)");
        _p(_a(".plusWithdrawManagerV2"), "updateWithdrawFee(uint256)");
        _p(_a(".plusWithdrawManagerV2"), "updateRequestFee(uint256)");
        _p(_a(".plusWithdrawManagerV2"), "setFeeSplit(address[3],uint16[3],bool)");
        _p(_a(".plusFeeManager"), "updatePerformanceFee((address,uint256)[])");
        _p(_a(".plusFeeManager"), "updateManagementFee((address,uint256)[])");
        _p(_a(".plusFeeManager"), "setDepositFee(uint256)");
        _p(_a(".plusVault"), "configurePerformanceFee(address,uint256)");
        _p(_a(".plusVault"), "configureManagementFee(address,uint256)");
        _p(_a(".specialRewards"), "setAdmin(address,uint256)");
    }

    function _roles() internal {
        IAccessManagerP45 am = IAccessManagerP45(_a(".plusAccessManager"));
        uint64[9] memory gateRoles = [uint64(1), 100, 300, 800, 900, 901, 902, 1000, 1200];
        for (uint256 i; i < gateRoles.length; ++i) am.grantRole(gateRoles[i], address(gate), 0);
        uint64[9] memory drop = [uint64(200), 300, 900, 901, 902, 1000, 1200, 100, 1];
        for (uint256 i; i < drop.length; ++i) {
            (bool has,) = am.hasRole(drop[i], DEPLOYER);
            if (has) am.renounceRole(drop[i], DEPLOYER);
        }
    }

    function _p(address target_, string memory sig_) internal {
        bytes4[] memory s = new bytes4[](1);
        s[0] = bytes4(keccak256(bytes(sig_)));
        _safe(abi.encodeCall(gate.setProtectedCalls, (target_, s, true)));
    }

    function _safe(bytes memory data_) internal {
        bool ok = ISafeP45(FEE_SAFE).execTransaction(
            address(gate), 0, data_, 0, 0, 0, 0, address(0), payable(address(0)), sig
        );
        require(ok, "Safe execTransaction failed");
    }

    function _a(string memory key_) internal view returns (address) {
        return vm.parseJsonAddress(p4, key_);
    }
}
