// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {CurveYieldGovernanceGate} from "../src/governance/CurveYieldGovernanceGate.sol";

interface ISafeP34 {
    function isOwner(address) external view returns (bool);
    function getThreshold() external view returns (uint256);
    function execTransaction(
        address to, uint256 value, bytes calldata data, uint8 operation, uint256 safeTxGas, uint256 baseGas,
        uint256 gasPrice, address gasToken, address payable refundReceiver, bytes memory signatures
    ) external payable returns (bool);
}

/// Phase 3 step 4/5: the governance gate's protections, set by its FEE_AUTHORITY (fee Safe 0x4762, threshold 1; the
/// deployer signs as a Safe owner with the "caller is owner" signature, v = 1).
///
/// Protected (fee authority only; the DAO can never call them) — every admin-fee receiver / percentage, plus custody
/// drains:
///   IPOR FeeManager   updatePerformanceFee, updateManagementFee, setDepositFee, updateHighWaterMarkPerformanceFee,
///                     updateIntervalHighWaterMarkPerformanceFee
///   Vault             configurePerformanceFee, configureManagementFee
///   Access manager    roles 7 (TECH_FEE_MANAGER), 400, 500 (fee tech roles), 901 / 902 (request / withdraw fee)
///                     + every setTargetFunctionRole
///   Growth Custody    setRevenueShareBps, setWindupDistributionBps, setFeeRecipient, scheduleFullUnwind, executeFullUnwind
///   Fee router        setFeeRecipient, setFeeBps, setRouteFeeBps, clearRouteFee
///   Swap router v2    setFeeRecipient (its 0.1% admin fee receiver; the fee itself is hard-coded)
///   Loop splitter     setGrowthCustody (the split itself is a FEE-class gate key)
///   WM v2 + live WM   updateWithdrawFee, updateRequestFee (+ WM v2 setProfitCustody)
///   wcyavKAT          setFees        wrapper splitter / proposal bond   setAdminReceiver
///   (transferOwnership / renounceOwnership and the gate itself are always protected by the gate's code)
/// Guardian lane (bot actions): custody deployAll / balanceLtv. Numeric settings (allocations, caps, decay, LP max,
/// vault floor) are gate keys the guardian sets inside its per-key ranges (P3_03, GATE_CONFIG_SPEC).
contract P3_04_ConfigureGate is Phase2Base {
    address internal constant FEE_SAFE = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;
    address internal constant FEE_MANAGER = 0x11a81a7B7436CB1E8f73866AF74961cE499f5Ec6;
    address internal constant CUSTODY = 0xe7D109Ce6b34447Dd45B54e5615F4177291D5ADf;

    CurveYieldGovernanceGate internal gate;
    bytes internal sig;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        string memory p3 = vm.readFile(vm.envOr("PHASE3_DEPLOYMENTS", string("deployments/katana-phase3.json")));
        string memory p2 = vm.readFile(_deploymentsPath());
        string memory lend = vm.readFile(_lendingPath());
        gate = CurveYieldGovernanceGate(vm.parseJsonAddress(p3, ".governanceGate"));
        require(gate.isFeeAuthority(FEE_SAFE), "fee Safe is not the gate's fee authority");


        address self = DEPLOYER;
        require(ISafeP34(FEE_SAFE).isOwner(self) && ISafeP34(FEE_SAFE).getThreshold() == 1, "signer / threshold");
        sig = abi.encodePacked(uint256(uint160(self)), uint256(0), uint8(1));

        _start(); // PRIVATE_KEY (must be the deployer, checked in _start) or the fork default DEPLOYER
        _safe(abi.encodeCall(gate.setAccessManager, (ACCESS_MANAGER, true)));
        uint64[] memory roles = new uint64[](5);
        (roles[0], roles[1], roles[2], roles[3], roles[4]) = (7, 400, 500, 901, 902);
        _safe(abi.encodeCall(gate.setProtectedRoles, (ACCESS_MANAGER, roles, true)));

        _protect(FEE_MANAGER, _sels5(
            "updatePerformanceFee((address,uint256)[])", "updateManagementFee((address,uint256)[])", "setDepositFee(uint256)",
            "updateHighWaterMarkPerformanceFee()", "updateIntervalHighWaterMarkPerformanceFee(uint32)"));
        _protect(VAULT, _sels2("configurePerformanceFee(address,uint256)", "configureManagementFee(address,uint256)"));
        _protect(CUSTODY, _sels5(
            "setRevenueShareBps(uint16)", "setWindupDistributionBps(uint16,uint16)", "setFeeRecipient(address)",
            "scheduleFullUnwind(address)", "executeFullUnwind()"));
        bytes4[] memory router = _sels5(
            "setFeeRecipient(address)", "setFeeBps(uint16)", "setRouteFeeBps(address,address,uint16)",
            "clearRouteFee(address,address)", "transferOwnership(address)"); // (ownership is also code-protected)
        _protect(ROUTER, router);
        _protect(vm.parseJsonAddress(p2, ".splitter"), _sels1("setGrowthCustody(address)"));
        _protect(vm.parseJsonAddress(p2, ".swapRouterV2"), _sels1("setFeeRecipient(address)"));
        bytes4[] memory wmFees = _sels2("updateWithdrawFee(uint256)", "updateRequestFee(uint256)");
        _protect(vm.parseJsonAddress(p2, ".withdrawManagerV2"), wmFees);
        _protect(vm.parseJsonAddress(p2, ".withdrawManagerV2"), _sels1("setProfitCustody(address)"));
        _protect(WM_OLD, wmFees);
        _protect(vm.parseJsonAddress(lend, ".wcyavkat"), _sels1("setFees(uint256,uint256)"));
        _protect(vm.parseJsonAddress(lend, ".wrapperFeeSplitter"), _sels1("setAdminReceiver(address)"));
        _protect(vm.parseJsonAddress(p3, ".proposalBond"), _sels1("setAdminReceiver(address)"));

        // guardian lane
        _safe(abi.encodeCall(gate.setGuardian, (vm.parseJsonAddress(p3, ".optimizationGuardian"))));
        _allow(CUSTODY, "deployAll()");
        _allow(CUSTODY, "balanceLtv()");
        _stop();

        require(gate.isAccessManager(ACCESS_MANAGER) && gate.isProtectedRole(ACCESS_MANAGER, 400), "roles");
        require(gate.isProtectedCall(FEE_MANAGER, bytes4(keccak256("updatePerformanceFee((address,uint256)[])"))), "fee manager");
        require(gate.isProtectedCall(CUSTODY, bytes4(keccak256("executeFullUnwind()"))), "custody");
        require(gate.guardian() == vm.parseJsonAddress(p3, ".optimizationGuardian"), "guardian");
        require(gate.isProtectedCall(vm.parseJsonAddress(p2, ".swapRouterV2"), bytes4(keccak256("setFeeRecipient(address)"))),
            "router v2 fee recipient");
        console2.log("gate configured", address(gate));
    }

    function _safe(bytes memory data_) internal {
        bool ok = ISafeP34(FEE_SAFE).execTransaction(
            address(gate), 0, data_, 0, 0, 0, 0, address(0), payable(address(0)), sig
        );
        require(ok, "Safe execTransaction failed");
    }

    function _protect(address target_, bytes4[] memory sels_) internal {
        _safe(abi.encodeCall(gate.setProtectedCalls, (target_, sels_, true)));
    }

    function _allow(address target_, string memory sig_) internal {
        _safe(abi.encodeCall(gate.setGuardianCall, (target_, bytes4(keccak256(bytes(sig_))), true)));
    }

    function _sels1(string memory a) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = bytes4(keccak256(bytes(a)));
    }

    function _sels2(string memory a, string memory b) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        (s[0], s[1]) = (bytes4(keccak256(bytes(a))), bytes4(keccak256(bytes(b))));
    }

    function _sels5(string memory a, string memory b, string memory c, string memory d, string memory e)
        internal pure returns (bytes4[] memory s)
    {
        s = new bytes4[](5);
        s[0] = bytes4(keccak256(bytes(a)));
        s[1] = bytes4(keccak256(bytes(b)));
        s[2] = bytes4(keccak256(bytes(c)));
        s[3] = bytes4(keccak256(bytes(d)));
        s[4] = bytes4(keccak256(bytes(e)));
    }
}
