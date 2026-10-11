// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;
import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {CurveYieldGovernanceGate} from "../src/governance/CurveYieldGovernanceGate.sol";
interface IOwnableRollback {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function acceptOwnership() external;
}
interface ISafeRollback {
    function isOwner(address) external view returns (bool);
    function getThreshold() external view returns (uint256);
    function execTransaction(address,uint256,bytes calldata,uint8,uint256,uint256,uint256,address,address payable,bytes memory)
        external payable returns (bool);
}
/// Safe rollback of only the gate-owned OPERATIONAL Ownable contracts to the already-authorized
/// fee Safe. Never grants/deletes IPOR roles, never routes admin-fee changes through the gate,
/// and never transfers ownership to an arbitrary outsider.
contract P3_99_Rollback is Phase2Base {
    address[] private operational;
    function run() external {
        require(block.chainid == 747474, "not Katana");
        _requireQuestSigningV2();
        address gate = _gateAddress();
        require(CurveYieldGovernanceGate(gate).iporAccessManager() == ACCESS_MANAGER, "not IPOR managed");
        string memory p2 = vm.readFile(_deploymentsPath());
        string memory lend = vm.readFile(_lendingPath());
        string[5] memory keys = ["executor", "allocation", "loopController", "usdcController", "lendController"];
        for (uint256 i; i < keys.length; ++i)
            operational.push(vm.parseJsonAddress(p2, string.concat(".", keys[i])));
        // Fee-sensitive wrapper burn forwarder remains Safe-owned; never roll it through gate.
        require(ISafeRollback(ADMIN_FEE_SAFE).isOwner(DEPLOYER)
            && ISafeRollback(ADMIN_FEE_SAFE).getThreshold() == 1, "fee Safe signer");
        bytes memory sig = abi.encodePacked(uint256(uint160(DEPLOYER)), uint256(0), uint8(1));
        _start();
        for (uint256 i; i < operational.length; ++i) {
            if (IOwnableRollback(operational[i]).owner() == gate) {
                _safe(gate, abi.encodeCall(CurveYieldGovernanceGate.transferContractOwnershipToAdminSafe,
                    (operational[i])), sig);
            }
            if (IOwnableRollback(operational[i]).pendingOwner() == ADMIN_FEE_SAFE)
                _safe(operational[i], abi.encodeCall(IOwnableRollback.acceptOwnership, ()), sig);
        }
        _stop();
        for (uint256 i; i < operational.length; ++i)
            require(IOwnableRollback(operational[i]).owner() == ADMIN_FEE_SAFE, "rollback ownership incomplete");
        console2.log("operational ownership returned to existing fee Safe; IPOR roles unchanged");
    }
    function _safe(address to_, bytes memory data_, bytes memory sig_) private {
        require(ISafeRollback(ADMIN_FEE_SAFE).execTransaction(to_,0,data_,0,0,0,0,address(0),payable(address(0)),sig_),
            "fee Safe transaction failed");
    }
}
