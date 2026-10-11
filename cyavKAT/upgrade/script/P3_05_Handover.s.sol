// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {CurveYieldGovernanceGate} from "../src/governance/CurveYieldGovernanceGate.sol";

interface IOwnable2StepP35 {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

interface IAccessManagerP35 {
    function grantRole(uint64 roleId, address account, uint32 executionDelay) external;
    function revokeRole(uint64 roleId, address account) external;
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

/// V5 governance handover: custom Ownable targets move to the gate; IPOR fee roles
/// 901/902 move to the gate, while the admin-fee Safe retains IPOR OWNER role 1.
/// The fee Safe also holds the gate's isolated, self-managed ADMIN_FEE role initially.
/// Quest signing V2 remains mandatory; no original IPOR source is modified.
contract P3_05_Handover is Phase2Base {
    address internal constant FEE_SAFE = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;
    address internal constant CUSTODY = 0xe7D109Ce6b34447Dd45B54e5615F4177291D5ADf;

    address internal gate;
    address[] internal twoStep; // operational modules transferred to gate
    address[] internal feeOwned; // fee-bearing modules ALSO transferred to gate; never left directly Safe-owned

    function run() external {
        require(block.chainid == 747474, "not Katana");
        _requireQuestSigningV2(); // Mandatory updated Quest ERC-1271 signing layer for the V2 upgrade.
        string memory p2 = vm.readFile(_deploymentsPath());
        string memory lend = vm.readFile(_lendingPath());
        gate = _gateAddress();

        // ALL admin-fee-enabled Ownable contracts must be gate-owned for fee-lane exclusivity.
        string[5] memory operational = ["executor", "allocation", "loopController", "usdcController", "lendController"];
        for (uint256 i; i < operational.length; ++i)
            twoStep.push(vm.parseJsonAddress(p2, string.concat(".", operational[i])));
        // Fee-bearing modules must transfer to gate; their setters have separate ADMIN_FEE lane.
        string[1] memory feeP2 = ["swapRouterV2"];
        for (uint256 i; i < feeP2.length; ++i)
            feeOwned.push(vm.parseJsonAddress(p2, string.concat(".", feeP2[i])));
        feeOwned.push(vm.parseJsonAddress(lend, ".wcyavkat"));
        feeOwned.push(vm.parseJsonAddress(lend, ".wrapperFeeSplitter"));
        string memory p5Path = vm.envOr("PHASE5_DEPLOYMENTS", string("deployments/katana-phase5.json"));
        if (vm.exists(p5Path)) {
            string memory p5 = vm.readFile(p5Path);
            feeOwned.push(vm.parseJsonAddress(p5, ".polController"));
            feeOwned.push(vm.parseJsonAddress(p5, ".revenueCustodyV2"));
        }
        // Previously Safe-owned live router and custody must also be brought under the gate.
        feeOwned.push(ROUTER);
        feeOwned.push(CUSTODY);
        // Fail closed: every fee-bearing module must have a configured ADMIN_FEE lane
        // before transferring its ownership to the gate.
        CurveYieldGovernanceGate targetGate = CurveYieldGovernanceGate(gate);
        for (uint256 i; i < feeOwned.length; ++i)
            require(targetGate.isFeeBearingTarget(feeOwned[i]), "unregistered fee-bearing module");
        IAccessManagerP35 am = IAccessManagerP35(ACCESS_MANAGER);
        require(CurveYieldGovernanceGate(gate).adminFeeRoleHolder() == FEE_SAFE,
            "ADMIN_FEE must start at live admin fee receiver");
        // V5: Do not block an upgrade because the fee-receiving Safe still has direct
        // factory permissions. Its existing IPOR OWNER role must be preserved.
        // Factory Access Manager permissions are independent of the gate's ADMIN_FEE lane.
        (bool deployerOwner,) = am.hasRole(1, DEPLOYER);
        require(deployerOwner, "IPOR OWNER required for delegation");
        _start(); // PRIVATE_KEY (must be the deployer, checked in _start) or the fork default DEPLOYER
        // Delegate through the EXISTING IPOR Access Manager; no private gate roles.
        (bool safeHasOwner,) = am.hasRole(1, FEE_SAFE);
        if (!safeHasOwner) am.grantRole(1, FEE_SAFE, 0);
        (bool safeHasAtomist,) = am.hasRole(100, FEE_SAFE);
        if (!safeHasAtomist) am.grantRole(100, FEE_SAFE, 0);
        // Safe remains an IPOR OWNER even though all custom Ownable modules move
        // into the gate. Never revoke or renounce this Safe's native OWNER role.
        (bool safeOwnerAfterGrant, uint32 safeOwnerDelay) = am.hasRole(1, FEE_SAFE);
        require(safeOwnerAfterGrant && safeOwnerDelay == 0,
            "fee Safe must retain immediate IPOR OWNER authority");
        // Move dedicated vault fee-setting roles to the gate: never retain a second direct caller.
        (bool safeRequestFee,) = am.hasRole(901, FEE_SAFE);
        (bool safeWithdrawFee,) = am.hasRole(902, FEE_SAFE);
        (bool gateRequestFee,) = am.hasRole(901, gate);
        (bool gateWithdrawFee,) = am.hasRole(902, gate);
        if (!gateRequestFee) am.grantRole(901, gate, 0);
        if (!gateWithdrawFee) am.grantRole(902, gate, 0);
        if (safeRequestFee) am.revokeRole(901, FEE_SAFE);
        if (safeWithdrawFee) am.revokeRole(902, FEE_SAFE);
        // A. every Ownable module -> gate, including all fee-capable ones.
        for (uint256 i; i < twoStep.length; ++i) {
            IOwnable2StepP35 c = IOwnable2StepP35(twoStep[i]);
            if (c.owner() == DEPLOYER) c.transferOwnership(gate);
        }
        for (uint256 i; i < feeOwned.length; ++i) {
            IOwnable2StepP35 c = IOwnable2StepP35(feeOwned[i]);
            if (c.owner() == DEPLOYER) c.transferOwnership(gate);
            else if (c.owner() == FEE_SAFE)
                _safe(feeOwned[i], abi.encodeCall(IOwnable2StepP35.transferOwnership, (gate)),
                    abi.encodePacked(uint256(uint160(DEPLOYER)), uint256(0), uint8(1)));
        }
        // B. Safe executes acceptance via IPOR OWNER role; ownership moves to gate.
        bytes memory sig = abi.encodePacked(uint256(uint160(DEPLOYER)), uint256(0), uint8(1));
        // C. exact, non-general-purpose ownership acceptance on the operational gate.
        for (uint256 i; i < twoStep.length; ++i)
            _safe(gate, abi.encodeCall(CurveYieldGovernanceGate.acceptContractOwnership, (twoStep[i])), sig);
        // Live CurveYield router/custody versions may use one-step Ownable,
        // whereas the newly deployed modules use Ownable2Step. A completed
        // immediate transfer already makes the gate the owner, so never call
        // acceptOwnership() on those contracts (they lack that method).
        for (uint256 i; i < feeOwned.length; ++i) {
            IOwnable2StepP35 target = IOwnable2StepP35(feeOwned[i]);
            if (target.owner() == gate) continue;
            require(target.pendingOwner() == gate, "fee module not pending gate ownership");
            _safe(gate, abi.encodeCall(CurveYieldGovernanceGate.acceptContractOwnership, (feeOwned[i])), sig);
        }
        // D. Gate owns operating roles and the IPOR fee roles 901/902 for forwarding fee requests.
        uint64[11] memory gateRoles = [uint64(1), 100, 300, 600, 800, 900, 901, 902, 1000, 1100, 1200];
        for (uint256 i; i < gateRoles.length; ++i) am.grantRole(gateRoles[i], gate, 0);
        // Deployer drops only roles transferred into IPOR ownership (Safe + gate). No gate-local role migration.
        uint64[11] memory drop = [uint64(200), 300, 600, 800, 900, 901, 902, 1000, 1200, 100, 1];
        for (uint256 i; i < drop.length; ++i) {
            (bool has,) = am.hasRole(drop[i], DEPLOYER);
            if (has) am.renounceRole(drop[i], DEPLOYER);
        }
        _safe(gate, abi.encodeCall(CurveYieldGovernanceGate.activateFeeHandover, ()),
            abi.encodePacked(uint256(uint160(DEPLOYER)), uint256(0), uint8(1)));
        _stop();

        // E. enforce only the gate owns fee-capable modules and retains direct vault fee roles.
        for (uint256 i; i < twoStep.length; ++i)
            require(IOwnable2StepP35(twoStep[i]).owner() == gate, "operational ownership");
        for (uint256 i; i < feeOwned.length; ++i)
            require(IOwnable2StepP35(feeOwned[i]).owner() == gate, "fee module must be gate-owned");
        require(IOwnable2StepP35(ROUTER).owner() == gate, "router must be gate-owned");
        (bool hasRequestFee, uint32 requestDelay) = am.hasRole(901, gate);
        (bool hasWithdrawFee, uint32 withdrawDelay) = am.hasRole(902, gate);
        require(hasRequestFee && hasWithdrawFee && requestDelay == 0 && withdrawDelay == 0,
            "IPOR fee roles must be gate-exclusive and immediate");
        (hasRequestFee,) = am.hasRole(901, FEE_SAFE);
        (hasWithdrawFee,) = am.hasRole(902, FEE_SAFE);
        require(!hasRequestFee && !hasWithdrawFee, "Safe retains direct IPOR fee role");
        require(IOwnable2StepP35(CUSTODY).owner() == gate, "custody must be gate-owned");
        (bool safeRetainsOwner, uint32 ownerDelay) = am.hasRole(1, FEE_SAFE);
        require(safeRetainsOwner && ownerDelay == 0,
            "handover removed fee Safe IPOR OWNER role");
        require(CurveYieldGovernanceGate(gate).adminFeeRoleHolder() == FEE_SAFE,
            "ADMIN_FEE role unexpectedly reassigned during handover");
        for (uint256 i; i < drop.length; ++i) {
            (bool has,) = am.hasRole(drop[i], DEPLOYER);
            require(!has, "deployer still has an IPOR role");
        }
        for (uint256 i; i < gateRoles.length; ++i) {
            (bool has, uint32 delay) = am.hasRole(gateRoles[i], gate);
            require(has && delay == 0, "missing/improper gate operational IPOR role");
        }
        uint64[3] memory forbidden = [uint64(7), 400, 500];
        for (uint256 i; i < forbidden.length; ++i) {
            (bool has,) = am.hasRole(forbidden[i], gate);
            require(!has, "gate must not hold fee-role");
        }
        // Close bootstrapping. After this point IPOR OWNER cannot rewrite fee-sensitive
        // substrate recipient lists or first-time fee wiring without ADMIN_FEE.
        require(CurveYieldGovernanceGate(gate).feeHandoverComplete(), "fee handover not activated");
        // R5: the gate now writes the fuses' substrates itself; a sync must change nothing
        CurveYieldGovernanceGate g = CurveYieldGovernanceGate(gate);
        uint256[2] memory synced = [MARKET_SWAP, MARKET_ZERO];
        for (uint256 i; i < synced.length; ++i) {
            bytes32[] memory want = g.previewSubstrates(synced[i]);
            bytes32[] memory have = IVaultSubstrates(VAULT).getMarketSubstrates(synced[i]);
            require(keccak256(abi.encode(want)) == keccak256(abi.encode(have)), "gate substrates differ from the vault's");
        }
        console2.log("handover complete: gate", gate);
        console2.log("V5: fee Safe retains IPOR OWNER role; custom contracts owned by gate");
        console2.log("gate ADMIN_FEE lane: self-managed; factory IPOR permissions remain independent");
    }

    function _safe(address to_, bytes memory data_, bytes memory sig_) internal {
        require(ISafeP35(FEE_SAFE).isOwner(DEPLOYER) && ISafeP35(FEE_SAFE).getThreshold() == 1, "fee Safe signer");
        bool ok = ISafeP35(FEE_SAFE).execTransaction(to_, 0, data_, 0, 0, 0, 0, address(0), payable(address(0)), sig_);
        require(ok, "Safe execTransaction failed");
    }
}

interface IVaultSubstrates {
    function getMarketSubstrates(uint256 marketId) external view returns (bytes32[] memory);
}
