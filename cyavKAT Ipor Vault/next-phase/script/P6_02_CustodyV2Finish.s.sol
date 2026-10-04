// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";

interface IGateP62 {
    function executeProtected(address target, bytes calldata data) external returns (bytes memory);
}

interface ISafeP62 {
    function isOwner(address) external view returns (bool);
    function getThreshold() external view returns (uint256);
    function execTransaction(
        address to, uint256 value, bytes calldata data, uint8 operation, uint256 safeTxGas, uint256 baseGas,
        uint256 gasPrice, address gasToken, address payable refundReceiver, bytes memory signatures
    ) external payable returns (bool);
}

interface ICustodyV1P62 {
    function queuedRecipient() external view returns (address);
    function queuedExecuteAfter() external view returns (uint64);
    function positionSnapshot() external view returns (uint256 collateral, uint256 debt, uint256 value, uint256 ltv);
}

interface ICustodyV2P62 {
    function deployAll() external;
    function loopEquityAvkat() external view returns (uint256);
    function loopTargetBps() external view returns (uint256);
}

interface IErc20P62 {
    function balanceOf(address) external view returns (uint256);
}

/// Phase 6 step 2/2 — after the live custody's 15-day delay: the fee Safe executes its full unwind (protected), which
/// sends all its avKAT and KAT to custody v2; then custody v2 deploys (operator = the deployer): the loop fills up to
/// custody.loopTargetBps (60%), the rest stays idle for the farm (no farm positions yet).
///   forge script script/P6_02_CustodyV2Finish.s.sol --root <phase2> --rpc-url katana   (dry run; --broadcast to send)
contract P6_02_CustodyV2Finish is Phase2Base {
    address internal constant FEE_SAFE = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;
    address internal constant CUSTODY_V1 = GROWTH_CUSTODY;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        address gate = vm.parseJsonAddress(
            vm.readFile(vm.envOr("PHASE3_DEPLOYMENTS", string("deployments/katana-phase3.json"))), ".governanceGate"
        );
        address custody = vm.parseJsonAddress(
            vm.readFile(vm.envOr("PHASE6_DEPLOYMENTS", string("deployments/katana-phase6.json"))), ".revenueCustodyV2"
        );
        ICustodyV1P62 v1 = ICustodyV1P62(CUSTODY_V1);
        require(v1.queuedRecipient() == custody, "full unwind not queued to custody v2 (run P6_01)");
        require(block.timestamp >= v1.queuedExecuteAfter(), "15-day delay still running");
        require(ISafeP62(FEE_SAFE).isOwner(DEPLOYER) && ISafeP62(FEE_SAFE).getThreshold() == 1, "fee Safe signer");
        uint256 avkatBefore = IErc20P62(AVKAT).balanceOf(custody);

        _start();
        bytes memory sig = abi.encodePacked(uint256(uint160(DEPLOYER)), uint256(0), uint8(1));
        bool ok = ISafeP62(FEE_SAFE).execTransaction(
            gate, 0, abi.encodeCall(IGateP62.executeProtected, (CUSTODY_V1, abi.encodeWithSignature("executeFullUnwind()"))),
            0, 0, 0, 0, address(0), payable(address(0)), sig
        );
        require(ok, "Safe execTransaction failed");
        uint256 received = IErc20P62(AVKAT).balanceOf(custody) - avkatBefore;
        ICustodyV2P62(custody).deployAll();
        _stop();

        (uint256 collateral,,,) = v1.positionSnapshot();
        require(collateral == 0, "live custody still holds collateral");
        console2.log("avKAT moved to custody v2", received);
        console2.log("loop equity (avKAT)", ICustodyV2P62(custody).loopEquityAvkat());
        console2.log("idle avKAT left for the farm", IErc20P62(AVKAT).balanceOf(custody));
        console2.log("loop target (bps)", ICustodyV2P62(custody).loopTargetBps());
    }
}
