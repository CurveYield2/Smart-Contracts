// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {CurveYieldGovernanceGate} from "../src/governance/CurveYieldGovernanceGate.sol";

interface IL10Splitter {
    function owner() external view returns (address);
    function adminReceiver() external view returns (address);
    function contributorsReceiver() external view returns (address);
    function burnWithdrawManager() external view returns (address);
    function setDestinations(address contributors_, address withdrawManager_) external;
}
interface IL10Custody {
    function VAULT() external view returns (address);
    function LOOP_CUSTODY() external view returns (address);
}
interface IL10Safe {
    function isOwner(address) external view returns (bool);
    function getThreshold() external view returns (uint256);
    function execTransaction(
        address to, uint256 value, bytes calldata data, uint8 operation, uint256 safeTxGas, uint256 baseGas,
        uint256 gasPrice, address gasToken, address payable refundReceiver, bytes memory signatures
    ) external payable returns (bool);
}
interface IL10VaultWM { function balanceOf(address holder) external view returns (uint256); }

/// @notice Route the EXISTING wcyavKAT fee splitter directly to the Phase-5 RevenueCustodyV2 and Phase-2 WM V2.
/// Only AFTER P2_03 (WM cutover), P5_01 (custody deployed), P3_04 (gate configured), and P3_05 (handover).
/// No new wrapper, splitter, burn forwarder or Morpho market is deployed. The live 40/30/30 ratio is unmodified.
/// ADMIN_FEE holder is the fee-receiving Safe, so this executes through gate.executeAdminFee via Safe signatures.
/// NOTE: P5_01 must be deployed BEFORE P3_05 so the new custody is included in the ownership handover.
contract L10_RouteWrapperFeesToCustodyV2 is Phase2Base {
    function run() external {
        require(block.chainid == 747474, "not Katana");
        _requireQuestSigningV2();
        string memory lend = vm.readFile(_lendingPath());
        string memory p2 = _readDeployments();
        string memory p5Path = vm.envOr("PHASE5_DEPLOYMENTS", string("deployments/katana-phase5.json"));
        require(vm.exists(p5Path), "P5_01 custody deployment is missing");
        string memory p5 = vm.readFile(p5Path);
        IL10Splitter splitter = IL10Splitter(_addr(lend, "wrapperFeeSplitter"));
        address wmV2 = _addr(p2, "withdrawManagerV2");
        address custodyV2 = _addr(p5, "revenueCustodyV2");
        address gateAddress = _gateAddress();
        CurveYieldGovernanceGate gate = CurveYieldGovernanceGate(gateAddress);

        require(custodyV2 != address(splitter) && custodyV2 != wmV2 && custodyV2 != ADMIN_FEE_SAFE,
            "invalid custody routing");
        require(IL10Custody(custodyV2).VAULT() == VAULT &&
            IL10Custody(custodyV2).LOOP_CUSTODY() == GROWTH_CUSTODY, "wrong V2 custody");
        require(address(uint160(uint256(vm.load(VAULT, WITHDRAW_MANAGER_SLOT)))) == wmV2,
            "WM V2 cutover not completed");
        require(splitter.owner() == gateAddress && gate.isFeeBearingTarget(address(splitter)),
            "splitter not handed to ADMIN_FEE gate");
        require(gate.adminFeeRoleHolder() == ADMIN_FEE_SAFE &&
            gate.isAdminFeeCall(address(splitter), IL10Splitter.setDestinations.selector), "ADMIN_FEE route absent");
        // A secondary burn forwarder in live state must be reviewed/removed outside this deployment script.
        address priorBurn = splitter.burnWithdrawManager();
        require(priorBurn == WM_OLD || priorBurn == wmV2, "unexpected splitter burn destination");
        address originalAdmin = splitter.adminReceiver();
        if (splitter.contributorsReceiver() == custodyV2 && priorBurn == wmV2) {
            console2.log("wrapper fee destinations already configured");
            return;
        }
        IL10Safe safe = IL10Safe(ADMIN_FEE_SAFE);
        require(safe.isOwner(DEPLOYER) && safe.getThreshold() == 1, "Safe signer or threshold differs");
        bytes memory signatures = abi.encodePacked(uint256(uint160(DEPLOYER)), uint256(0), uint8(1));
        bytes memory data = abi.encodeCall(IL10Splitter.setDestinations, (custodyV2, wmV2));

        _start();
        bool ok = safe.execTransaction(
            gateAddress, 0, abi.encodeCall(gate.executeAdminFee, (address(splitter), data)),
            0, 0, 0, 0, address(0), payable(address(0)), signatures
        );
        require(ok, "Safe ADMIN_FEE execution failed");
        _stop();

        require(splitter.contributorsReceiver() == custodyV2, "custody recipient not applied");
        require(splitter.burnWithdrawManager() == wmV2, "burn destination not applied");
        require(splitter.adminReceiver() == originalAdmin, "admin fee receiver changed");
        console2.log("Existing splitter contributors -> RevenueCustodyV2", custodyV2);
        console2.log("Existing splitter burn -> WM V2", wmV2);
        console2.log("Fixed allocation unchanged: 40% admin, 30% V2 custody, 30% WM V2");
    }
}
