// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";

interface IOwnableP499 {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

interface IGateP499 {
    function executeProtected(address target, bytes calldata data) external returns (bytes memory);
}

interface IAccessManagerP499 {
    function grantRole(uint64 roleId, address account, uint32 executionDelay) external;
    function hasRole(uint64 roleId, address account) external view returns (bool, uint32);
}

interface ISafeP499 {
    function execTransaction(
        address to, uint256 value, bytes calldata data, uint8 operation, uint256 safeTxGas, uint256 baseGas,
        uint256 gasPrice, address gasToken, address payable refundReceiver, bytes memory signatures
    ) external payable returns (bool);
}

/// Undo of P4_05: the Phase 4 contracts and the cyavKAT+ vault roles back under the deployer (reversibility until the
/// stack is final). The fee Safe (FEE_AUTHORITY) drives gate.executeProtected; the deployer accepts.
contract P4_99_RollbackPhase4 is Phase2Base {
    address internal constant FEE_SAFE = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;

    address internal gate;
    bytes internal sig;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        string memory p4 = vm.readFile(vm.envOr("PHASE4_DEPLOYMENTS", string("deployments/katana-phase4.json")));
        string memory p3 = vm.readFile(vm.envOr("PHASE3_DEPLOYMENTS", string("deployments/katana-phase3.json")));
        gate = vm.parseJsonAddress(p3, ".governanceGate");
        sig = abi.encodePacked(uint256(uint160(DEPLOYER)), uint256(0), uint8(1));
        string[9] memory keys = ["plusController", "plusExecutor", "plusDepositRouter", "plusYieldBooster", "leaderboard",
            "referrals", "specialRewards", "contributorsRewardFuse", "plusRequestFeeFuse"];
        address am = vm.parseJsonAddress(p4, ".plusAccessManager");

        _start();
        uint64[8] memory roles = [uint64(1), 100, 300, 900, 901, 902, 1000, 1200];
        for (uint256 i; i < roles.length; ++i) {
            (bool has,) = IAccessManagerP499(am).hasRole(roles[i], DEPLOYER);
            if (!has) _protected(am, abi.encodeCall(IAccessManagerP499.grantRole, (roles[i], DEPLOYER, 0)));
        }
        for (uint256 i; i < keys.length; ++i) {
            address c = vm.parseJsonAddress(p4, string.concat(".", keys[i]));
            if (IOwnableP499(c).owner() == gate) {
                _protected(c, abi.encodeCall(IOwnableP499.transferOwnership, (DEPLOYER)));
                IOwnableP499(c).acceptOwnership();
            }
        }
        _stop();

        for (uint256 i; i < keys.length; ++i) {
            require(IOwnableP499(vm.parseJsonAddress(p4, string.concat(".", keys[i]))).owner() == DEPLOYER, "owner");
        }
        console2.log("Phase 4 rolled back to the deployer");
    }

    function _protected(address target_, bytes memory data_) internal {
        bool ok = ISafeP499(FEE_SAFE).execTransaction(
            gate, 0, abi.encodeCall(IGateP499.executeProtected, (target_, data_)), 0, 0, 0, 0, address(0),
            payable(address(0)), sig
        );
        require(ok, "Safe execTransaction failed");
    }
}
