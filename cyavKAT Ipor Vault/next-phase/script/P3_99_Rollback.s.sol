// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";

interface IOwnableP99 {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

interface IGateP99 {
    function executeProtected(address target, bytes calldata data) external returns (bytes memory);
}

interface IAccessManagerP99 {
    function grantRole(uint64 roleId, address account, uint32 executionDelay) external;
    function hasRole(uint64 roleId, address account) external view returns (bool, uint32);
}

interface ISafeP99 {
    function execTransaction(
        address to, uint256 value, bytes calldata data, uint8 operation, uint256 safeTxGas, uint256 baseGas,
        uint256 gasPrice, address gasToken, address payable refundReceiver, bytes memory signatures
    ) external payable returns (bool);
}

/// Undo of P3_05: everything back under the deployer (reversibility until the stack is final).
/// The fee Safe (the gate's FEE_AUTHORITY; the deployer signs as its owner) calls gate.executeProtected to:
///   1. re-grant the deployer its vault roles (the gate holds OWNER / ATOMIST, the admins of those roles)
///   2. start ownership transfers of every gated contract back to the deployer (the router / custody go back to the
///      fee Safe, their pre-handover owner)
/// then the deployer (and the fee Safe for the custody) accept. The gate's roles stay until revoked separately.
contract P3_99_Rollback is Phase2Base {
    address internal constant FEE_SAFE = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;
    address internal constant CUSTODY = 0xe7D109Ce6b34447Dd45B54e5615F4177291D5ADf;

    address internal gate;
    bytes internal sig;
    address[] internal toDeployer;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        string memory p3 = vm.readFile(vm.envOr("PHASE3_DEPLOYMENTS", string("deployments/katana-phase3.json")));
        string memory p2 = vm.readFile(_deploymentsPath());
        string memory lend = vm.readFile(_lendingPath());
        gate = vm.parseJsonAddress(p3, ".governanceGate");
        string[8] memory p2Keys = ["executor", "allocation", "loopController", "splitter", "vkatController", "lendController", "lpController", "swapRouterV2"];
        string[4] memory p3Keys = ["engagementToken", "engagementRewards", "voterRewards", "proposalBond"];
        for (uint256 i; i < p2Keys.length; ++i) toDeployer.push(vm.parseJsonAddress(p2, string.concat(".", p2Keys[i])));
        for (uint256 i; i < p3Keys.length; ++i) toDeployer.push(vm.parseJsonAddress(p3, string.concat(".", p3Keys[i])));
        toDeployer.push(vm.parseJsonAddress(lend, ".wcyavkat"));
        toDeployer.push(vm.parseJsonAddress(lend, ".wrapperFeeSplitter"));
        if (vm.keyExistsJson(lend, ".wrapperBurnForwarder")) toDeployer.push(vm.parseJsonAddress(lend, ".wrapperBurnForwarder")); // L10
        string memory p5Path = vm.envOr("PHASE5_DEPLOYMENTS", string("deployments/katana-phase5.json"));
        if (vm.exists(p5Path)) { // P5_01 (POL)
            string memory p5 = vm.readFile(p5Path);
            toDeployer.push(vm.parseJsonAddress(p5, ".polController"));
            toDeployer.push(vm.parseJsonAddress(p5, ".polCustody"));
            toDeployer.push(vm.parseJsonAddress(p5, ".polIncomingFeeder"));
            toDeployer.push(vm.parseJsonAddress(p5, ".polYieldFeeder"));
        }



        sig = abi.encodePacked(uint256(uint160(DEPLOYER)), uint256(0), uint8(1));
        _start(); // PRIVATE_KEY (must be the deployer, checked in _start) or the fork default DEPLOYER
        // 1. roles back to the deployer
        uint64[11] memory roles = [uint64(1), 100, 200, 300, 600, 800, 900, 901, 902, 1000, 1200];
        for (uint256 i; i < roles.length; ++i) {
            (bool has,) = IAccessManagerP99(ACCESS_MANAGER).hasRole(roles[i], DEPLOYER);
            if (!has) _protected(ACCESS_MANAGER, abi.encodeCall(IAccessManagerP99.grantRole, (roles[i], DEPLOYER, 0)));
        }
        // 2. ownership back
        for (uint256 i; i < toDeployer.length; ++i) {
            if (IOwnableP99(toDeployer[i]).owner() == gate) {
                _protected(toDeployer[i], abi.encodeCall(IOwnableP99.transferOwnership, (DEPLOYER)));
                IOwnableP99(toDeployer[i]).acceptOwnership();
            }
        }
        if (IOwnableP99(ROUTER).owner() == gate) _protected(ROUTER, abi.encodeCall(IOwnableP99.transferOwnership, (FEE_SAFE)));
        if (IOwnableP99(CUSTODY).owner() == gate) {
            _protected(CUSTODY, abi.encodeCall(IOwnableP99.transferOwnership, (FEE_SAFE)));
            _safe(CUSTODY, abi.encodeCall(IOwnableP99.acceptOwnership, ()));
        }
        _stop();

        for (uint256 i; i < toDeployer.length; ++i) require(IOwnableP99(toDeployer[i]).owner() == DEPLOYER, "owner");
        require(IOwnableP99(ROUTER).owner() == FEE_SAFE && IOwnableP99(CUSTODY).owner() == FEE_SAFE, "Safe-owned");
        (bool owner1,) = IAccessManagerP99(ACCESS_MANAGER).hasRole(1, DEPLOYER);
        require(owner1, "deployer OWNER role");
        console2.log("rolled back: deployer owns everything again; gate", gate);
    }

    function _protected(address target_, bytes memory data_) internal {
        _safe(gate, abi.encodeCall(IGateP99.executeProtected, (target_, data_)));
    }

    function _safe(address to_, bytes memory data_) internal {
        bool ok = ISafeP99(FEE_SAFE).execTransaction(to_, 0, data_, 0, 0, 0, 0, address(0), payable(address(0)), sig);
        require(ok, "Safe execTransaction failed");
    }
}
