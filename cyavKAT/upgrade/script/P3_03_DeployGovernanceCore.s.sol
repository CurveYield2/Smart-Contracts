// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {CurveYieldGovernanceGate} from "../src/governance/CurveYieldGovernanceGate.sol";

/// Governance phase: verify original IPOR operating roles plus the isolated, self-managed
/// gate ADMIN_FEE role (initial holder is the current fee recipient).
contract P3_03_DeployGovernanceCore is Phase2Base {
    function run() external {
        require(block.chainid == 747474, "not Katana");
        _requireQuestSigningV2();
        CurveYieldGovernanceGate gate = CurveYieldGovernanceGate(_gateAddress());
        require(gate.iporAccessManager() == ACCESS_MANAGER, "gate is not IPOR-managed");
        require(gate.adminReceiver() == ADMIN_FEE_SAFE, "initial fee receiver mismatch");
        require(gate.adminFeeRoleHolder() == ADMIN_FEE_SAFE, "ADMIN_FEE initial holder mismatch");
        require(gate.feeConfigRegistrationSealed(), "unsealed fee config registry");
        IAccessManagerP303 am = IAccessManagerP303(ACCESS_MANAGER);
        (bool safeOwner,) = am.hasRole(1, ADMIN_FEE_SAFE);
        (bool safeOperator,) = am.hasRole(100, ADMIN_FEE_SAFE);
        if (!safeOwner || !safeOperator) {
            (bool deployerOwner,) = am.hasRole(1, DEPLOYER);
            require(deployerOwner, "deployer requires IPOR OWNER to delegate control");
            _start();
            if (!safeOwner) am.grantRole(1, ADMIN_FEE_SAFE, 0);
            if (!safeOperator) am.grantRole(100, ADMIN_FEE_SAFE, 0);
            _stop();
        }
        uint32 ownerDelay;
        uint32 operatorDelay;
        (safeOwner, ownerDelay) = am.hasRole(1, ADMIN_FEE_SAFE);
        (safeOperator, operatorDelay) = am.hasRole(100, ADMIN_FEE_SAFE);
        require(safeOwner && safeOperator && ownerDelay == 0 && operatorDelay == 0,
            "fee Safe needs immediate IPOR OWNER and ATOMIST; inspect role delay");
        console2.log("IPOR-role-backed operational gate", address(gate));
    }
}

interface IAccessManagerP303 {
    function hasRole(uint64 roleId, address account) external view returns (bool, uint32);
    function grantRole(uint64 roleId, address account, uint32 executionDelay) external;
}
