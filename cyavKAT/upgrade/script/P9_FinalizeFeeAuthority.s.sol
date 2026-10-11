// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;
import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {CurveYieldGovernanceGate} from "../src/governance/CurveYieldGovernanceGate.sol";
interface IP9Owned { function owner() external view returns (address); }
interface IP9RoleCheck {
    function hasRole(uint64,address) external view returns (bool,uint32);
    function canCall(address,address,bytes4) external view returns (bool,uint32);
    function getTargetFunctionRole(address,bytes4) external view returns (uint64);
}
/// Final V5 ADMIN_FEE lane and preserved fee Safe IPOR OWNER role verification.
contract P9_FinalizeFeeAuthority is Phase2Base {
    function run() external {
        require(block.chainid == 747474, "not Katana");
        _requireQuestSigningV2();
        address g = _gateAddress();
        CurveYieldGovernanceGate gate = CurveYieldGovernanceGate(g);
        require(gate.iporAccessManager() == ACCESS_MANAGER, "not IPOR managed");
        require(gate.adminReceiver() == ADMIN_FEE_SAFE, "initial admin fee receiver mismatch");
        require(gate.adminFeeRoleHolder() != address(0), "ADMIN_FEE has no holder");
        require(gate.feeConfigRegistrationSealed(), "fee config registration must be sealed");
        require(gate.feeHandoverComplete(), "fee-sensitive substrate writers not sealed");
        IP9RoleCheck am = IP9RoleCheck(ACCESS_MANAGER);
        (bool safeOwner, uint32 safeOwnerDelay) = am.hasRole(1, ADMIN_FEE_SAFE);
        require(safeOwner && safeOwnerDelay == 0,
            "fee Safe lost immediate IPOR OWNER authority");
        uint64[3] memory technical = [uint64(7), 400, 500];
        for (uint256 i; i < technical.length; ++i) {
            (bool has,) = am.hasRole(technical[i], g);
            require(!has, "technical fee role improperly assigned to gate");
        }
        (bool gateRequest, uint32 requestDelay) = am.hasRole(901, g);
        (bool gateWithdraw, uint32 withdrawDelay) = am.hasRole(902, g);
        require(gateRequest && gateWithdraw && requestDelay == 0 && withdrawDelay == 0,
            "gate must have both fee roles without delay");
        (bool safeRequest,) = am.hasRole(901, ADMIN_FEE_SAFE);
        (bool safeWithdraw,) = am.hasRole(902, ADMIN_FEE_SAFE);
        require(!safeRequest && !safeWithdraw, "fee Safe bypass still has IPOR fee roles");
        // V5: report, do NOT block, existing direct fee permissions of the fee Safe.
        // Keeping IPOR OWNER can confer direct factory access outside the Gate;
        // ADMIN_FEE exclusivity therefore applies to gate-owned contracts and calls
        // submitted through the gate, not necessarily the unchanged factory contracts.
        bytes4[2] memory vaultFee = [
            bytes4(keccak256("configurePerformanceFee(address,uint256)")),
            bytes4(keccak256("configureManagementFee(address,uint256)"))
        ];
        address fm = 0x11a81a7B7436CB1E8f73866AF74961cE499f5Ec6;
        // IPOR factory uses role 400 (performance) / 500 (management) for
        // direct PlasmaVault setters. Those roles MUST remain on FeeManager,
        // not on the gate. The ADMIN_FEE Safe calls the gate, which invokes
        // FeeManager's role-100 setters, and FeeManager forwards to the vault.
        uint64[2] memory vaultTechnicalRoles = [uint64(400), 500];
        for (uint256 i; i < vaultFee.length; ++i) {
            require(am.getTargetFunctionRole(VAULT, vaultFee[i]) == vaultTechnicalRoles[i],
                "unexpected vault technical fee role");
            (bool feeManagerRole, uint32 feeManagerRoleDelay) = am.hasRole(vaultTechnicalRoles[i], fm);
            (bool feeManagerCan, uint32 feeManagerDelay) = am.canCall(fm, VAULT, vaultFee[i]);
            require(feeManagerRole && feeManagerRoleDelay == 0 && feeManagerCan && feeManagerDelay == 0,
                "IPOR FeeManager cannot configure vault fees");
            (bool gateCan, uint32 gateDelay) = am.canCall(g, VAULT, vaultFee[i]);
            require(!gateCan && gateDelay == 0, "gate has forbidden direct vault technical role");
            (bool safeCan, uint32 safeDelay) = am.canCall(ADMIN_FEE_SAFE, VAULT, vaultFee[i]);
            if (safeCan || safeDelay != 0)
                console2.log("NOTICE: IPOR OWNER Safe has direct factory Vault fee permissions");
        }
        bytes4[3] memory managerFee = [
            bytes4(keccak256("updatePerformanceFee((address,uint256)[])")),
            bytes4(keccak256("updateManagementFee((address,uint256)[])")),
            bytes4(keccak256("setDepositFee(uint256)"))
        ];
        for (uint256 i; i < managerFee.length; ++i) {
            (bool safeCan, uint32 safeDelay) = am.canCall(ADMIN_FEE_SAFE, fm, managerFee[i]);
            (bool gateCan, uint32 gateDelay) = am.canCall(g, fm, managerFee[i]);
            if (safeCan || safeDelay != 0)
                console2.log("NOTICE: IPOR OWNER Safe has direct factory FeeManager fee permissions");
            require(gateCan && gateDelay == 0, "gate cannot execute factory fee manager setter");
        }
        // Confirm the new custom fee-bearing ownership topology, not only the roles.
        string memory p2 = _readDeployments();
        string memory lending = vm.readFile(_lendingPath());
        address[3] memory owned = [
            vm.parseJsonAddress(p2, ".swapRouterV2"),
            vm.parseJsonAddress(lending, ".wcyavkat"),
            vm.parseJsonAddress(lending, ".wrapperFeeSplitter")
        ];
        for (uint256 i; i < owned.length; ++i) {
            require(IP9Owned(owned[i]).owner() == g, "fee module not gate-owned");
            require(gate.isFeeBearingTarget(owned[i]), "fee module has no ADMIN_FEE entry");
        }
        require(IP9Owned(ROUTER).owner() == g && IP9Owned(GROWTH_CUSTODY).owner() == g,
            "live fee-bearing modules not gate-owned");
        console2.log("PASS: fee Safe retains IPOR OWNER; gate owns custom fee modules", g);
        console2.log("NOTE: factory direct fee permission notices above are informational");
    }
}
