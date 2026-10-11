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

/// V4: make all known fee setters exclusively callable via gate.executeAdminFee by the
/// self-administered ADMIN_FEE role (initial holder: existing admin-fee receiver Safe).
/// All other roles remain in the factory IPOR Access Manager.
contract P3_04_ConfigureGate is Phase2Base {
    address internal constant FEE_SAFE = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;
    address internal constant FEE_MANAGER = 0x11a81a7B7436CB1E8f73866AF74961cE499f5Ec6;
    address internal constant CUSTODY = 0xe7D109Ce6b34447Dd45B54e5615F4177291D5ADf;

    CurveYieldGovernanceGate internal gate;
    bytes internal sig;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        _requireQuestSigningV2(); // Mandatory updated Quest ERC-1271 signing layer for the V2 upgrade.
        string memory p2 = vm.readFile(_deploymentsPath());
        string memory lend = vm.readFile(_lendingPath());
        gate = CurveYieldGovernanceGate(_gateAddress());
        require(gate.iporAccessManager() == ACCESS_MANAGER, "gate must use IPOR roles");
        require(gate.adminFeeRoleHolder() == FEE_SAFE, "ADMIN_FEE role not held by original fee receiver");
        (bool safeOwner,) = IIporRoleP34(ACCESS_MANAGER).hasRole(1, FEE_SAFE);
        require(safeOwner, "fee Safe requires existing IPOR OWNER role");

        address self = DEPLOYER;
        require(ISafeP34(FEE_SAFE).isOwner(self) && ISafeP34(FEE_SAFE).getThreshold() == 1, "signer / threshold");
        sig = abi.encodePacked(uint256(uint160(self)), uint256(0), uint8(1));

        _start(); // PRIVATE_KEY (must be the deployer, checked in _start) or the fork default DEPLOYER
        _fee(FEE_MANAGER, _sels5(
            "updatePerformanceFee((address,uint256)[])", "updateManagementFee((address,uint256)[])", "setDepositFee(uint256)",
            "updateHighWaterMarkPerformanceFee()", "updateIntervalHighWaterMarkPerformanceFee(uint32)"));
        // Do not register direct vault technical fee setters: factory roles
        // 400/500 remain on FeeManager, while the gate uses FeeManager's
        // authorized role-100 operations via its ADMIN_FEE execution lane.
        _protect(VAULT, _sels1("grantMarketSubstrates(uint256,bytes32[])"));
        _fee(CUSTODY, _sels3(
            "setRevenueShareBps(uint16)", "setWindupDistributionBps(uint16,uint16)", "setFeeRecipient(address)"));
        _protect(CUSTODY, _sels2("scheduleFullUnwind(address)", "executeFullUnwind()"));
        bytes4[] memory router = _sels5(
            "setFeeRecipient(address)", "setFeeBps(uint16)", "setRouteFeeBps(address,address,uint16)",
            "clearRouteFee(address,address)", "transferOwnership(address)"); // (ownership is also code-protected)
        _fee(ROUTER, _sels3("setFeeRecipient(address)", "setFeeBps(uint16)",
            "setRouteFeeBps(address,address,uint16)"));
        _fee(ROUTER, _sels1("clearRouteFee(address,address)"));
        _protect(ROUTER, _sels1("transferOwnership(address)"));
        _fee(vm.parseJsonAddress(p2, ".swapRouterV2"), _sels1("setFeeRecipient(address)"));
        bytes4[] memory wmFees = _sels2("updateWithdrawFee(uint256)", "updateRequestFee(uint256)");
        _fee(vm.parseJsonAddress(p2, ".withdrawManagerV2"), wmFees);
        _fee(vm.parseJsonAddress(p2, ".withdrawManagerV2"), _sels1("setProfitCustody(address)"));
        _fee(vm.parseJsonAddress(p2, ".withdrawManagerV2"),
            _sels1("setFeeSplit(address[3],uint16[3],bool)"));
        _fee(vm.parseJsonAddress(p2, ".withdrawManagerV2"), _sels2(
            "setOnboardingAdmin(address)", "setBurnOnlyFee(address,bool)"));
        _fee(WM_OLD, wmFees);
        _fee(WM_OLD, _sels1("setProfitCustody(address)"));
        _fee(vm.parseJsonAddress(lend, ".wcyavkat"), _sels1("setFees(uint256,uint256)"));
        _fee(vm.parseJsonAddress(lend, ".wrapperFeeSplitter"), _sels2(
            "setAdminReceiver(address)", "setDestinations(address,address)"));
        if (vm.exists(vm.envOr("PHASE5_DEPLOYMENTS", string("deployments/katana-phase5.json")))) {
            string memory p5 = vm.readFile(vm.envOr("PHASE5_DEPLOYMENTS", string("deployments/katana-phase5.json")));
            _fee(vm.parseJsonAddress(p5, ".polController"), _sels1("setAdminReceiver(address)"));
            _fee(vm.parseJsonAddress(p5, ".revenueCustodyV2"), _sels1("setFeeRecipient(address)"));
        }
        _stop();

        require(gate.iporAccessManager() == ACCESS_MANAGER, "IPOR access manager");
        require(gate.isProtectedCall(FEE_MANAGER, bytes4(keccak256("updatePerformanceFee((address,uint256)[])"))), "fee manager");
        require(gate.isProtectedCall(CUSTODY, bytes4(keccak256("executeFullUnwind()"))), "custody");
        require(gate.isProtectedCall(VAULT, bytes4(keccak256("grantMarketSubstrates(uint256,bytes32[])"))), "substrate grants");
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

    function _fee(address target_, bytes4[] memory sels_) internal {
        _safe(abi.encodeCall(gate.registerAdminFeeCalls, (target_, sels_)));
    }

    function _protect(address target_, bytes4[] memory sels_) internal {
        _safe(abi.encodeCall(gate.setProtectedCalls, (target_, sels_, true)));
    }

    function _sels1(string memory a) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = bytes4(keccak256(bytes(a)));
    }

    function _sels2(string memory a, string memory b) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        (s[0], s[1]) = (bytes4(keccak256(bytes(a))), bytes4(keccak256(bytes(b))));
    }

    function _sels3(string memory a, string memory b, string memory c) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        (s[0], s[1], s[2]) = (bytes4(keccak256(bytes(a))), bytes4(keccak256(bytes(b))), bytes4(keccak256(bytes(c))));
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

interface IIporRoleP34 { function hasRole(uint64 roleId, address account) external view returns (bool, uint32); }
