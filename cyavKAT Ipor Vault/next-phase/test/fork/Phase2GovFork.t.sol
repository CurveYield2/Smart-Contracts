// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Test.sol";
import {Phase2ForkBase} from "../helpers/Phase2ForkBase.sol";
import {P3_01_DeployGovernanceTokens} from "../../script/P3_01_DeployGovernanceTokens.s.sol";
import {P3_02_DeployDao} from "../../script/P3_02_DeployDao.s.sol";
import {P3_03_DeployGovernanceCore} from "../../script/P3_03_DeployGovernanceCore.s.sol";
import {P3_04_ConfigureGate} from "../../script/P3_04_ConfigureGate.s.sol";
import {P3_05_Handover} from "../../script/P3_05_Handover.s.sol";
import {CurveYieldGovernanceGate} from "../../src/governance/CurveYieldGovernanceGate.sol";
import {CurveYieldOptimizationGuardian} from "../../src/governance/CurveYieldOptimizationGuardian.sol";
import {CurveYieldConfigKeys as K, CurveYieldAddrKeys} from "../../src/governance/CurveYieldGateConfig.sol";

interface IOwnableG {
    function owner() external view returns (address);
}

interface IAmG {
    function hasRole(uint64 roleId, address account) external view returns (bool, uint32);
}

interface IScriptG {
    function setPaths(string calldata, string calldata) external;
    function run() external;
}

/// @notice Job 2 item 9: gate governance after P3_03-P3_05 on top of the Phase 2 stack (P0_00, P2_01..P2_03). Router v2,
/// executor, controllers and splitter are owned by the gate; the DAO cannot reach a protected call (router v2
/// setFeeRecipient, WM fees, ownership moves, the onboarding admin); the fee authority can; the guardian is held to its
/// ranges. Scenarios are snapshot-isolated, the final revert lists every failing one.
contract Phase2GovForkTest is Phase2ForkBase {
    string p3Path;
    string p3j;
    address gateAddr;
    address daoAddr;
    address guardianAddr;
    address operator = makeAddr("operator");
    address[] gated;

    function setUp() public {
        _setUpFork("p2gov");
        p3Path = _testPath("p2gov-p3");
        vm.setEnv("PHASE3_DEPLOYMENTS", p3Path);
        vm.setEnv("SAFE_OWNER_BOT1", vm.toString(makeAddr("bot1")));
        vm.setEnv("SAFE_OWNER_BOT2", vm.toString(makeAddr("bot2")));
        vm.setEnv("BOT_OPERATOR", vm.toString(operator));
        vm.setEnv("PHASE2_DEPLOYMENTS", p2Path); // P3_03 reads the P2 file through the env, not setPaths
        IScriptG(address(new P3_01_DeployGovernanceTokens())).run();
        IScriptG(address(new P3_02_DeployDao())).run();
        IScriptG(address(new P3_03_DeployGovernanceCore())).run();
        _runP2(address(new P3_04_ConfigureGate()));
        _runP2(address(new P3_05_Handover()));
        p3j = vm.readFile(p3Path);
        gateAddr = vm.parseJsonAddress(p3j, ".governanceGate");
        daoAddr = vm.parseJsonAddress(p3j, ".dao");
        guardianAddr = vm.parseJsonAddress(p3j, ".optimizationGuardian");
        require(gateAddr == address(gate), "P3 gate is not the P0 gate");
        string[8] memory keys = ["executor", "allocation", "loopController", "splitter", "vkatController", "lendController", "lpController", "swapRouterV2"];
        for (uint256 i; i < keys.length; ++i) gated.push(_p2(keys[i]));
    }

    function _has(uint64 role_, address who_) internal view returns (bool has_) {
        (has_,) = IAmG(ACCESS_MANAGER).hasRole(role_, who_);
    }

    function _expectProtected(address target_, bytes memory data_) internal {
        vm.prank(daoAddr);
        (bool ok, bytes memory ret) = gateAddr.call(abi.encodeCall(CurveYieldGovernanceGate.execute, (target_, data_)));
        require(!ok, string.concat("the DAO reached a protected call: ", vm.toString(bytes4(data_))));
        require(
            bytes4(ret) == CurveYieldGovernanceGate.ProtectedCall.selector,
            string.concat("wrong revert for ", vm.toString(bytes4(data_)), ": ", _decode(ret))
        );
    }

    function _pad(string memory sig_) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes4(keccak256(bytes(sig_))), new bytes(128));
    }

    // ---------------------------------------------------------------- scenarios

    function g1_ownership_everyStackContractOwnedByTheGate() external view {
        for (uint256 i; i < gated.length; ++i) {
            require(IOwnableG(gated[i]).owner() == gateAddr, string.concat("not gate-owned: ", vm.toString(gated[i])));
        }
        uint64[10] memory roles = [uint64(1), 100, 300, 600, 800, 900, 901, 902, 1000, 1200];
        for (uint256 i; i < roles.length; ++i) {
            require(!_has(roles[i], DEPLOYER), string.concat("deployer still holds role ", vm.toString(uint256(roles[i]))));
            require(_has(roles[i], gateAddr), string.concat("gate missing role ", vm.toString(uint256(roles[i]))));
        }
        require(!_has(200, DEPLOYER), "deployer still holds ALPHA");
        require(_has(200, address(exec)), "the executor lost ALPHA");
        require(!_has(200, gateAddr), "the gate must not hold ALPHA");
        require(_has(2, guardianAddr), "guardian role");
        require(CurveYieldGovernanceGate(gateAddr).isFeeAuthority(FEE_SAFE), "fee Safe is not a fee authority");
        require(CurveYieldGovernanceGate(gateAddr).dao() == daoAddr, "gate DAO");
    }

    function g2_dao_cannotReachProtectedCalls() external {
        address router = _p2("swapRouterV2");
        _expectProtected(router, _pad("setFeeRecipient(address)"));
        _expectProtected(_p2("withdrawManagerV2"), _pad("updateWithdrawFee(uint256)"));
        _expectProtected(_p2("withdrawManagerV2"), _pad("updateRequestFee(uint256)"));
        _expectProtected(_p2("withdrawManagerV2"), _pad("setProfitCustody(address)"));
        _expectProtected(_p2("splitter"), _pad("setGrowthCustody(address)"));
        for (uint256 i; i < gated.length; ++i) {
            _expectProtected(gated[i], abi.encodeWithSignature("transferOwnership(address)", makeAddr("attacker")));
            _expectProtected(gated[i], abi.encodeWithSignature("renounceOwnership()"));
        }
        _expectProtected(gateAddr, abi.encodeWithSignature("setDao(address)", makeAddr("attacker")));
        _expectProtected(ACCESS_MANAGER, abi.encodeWithSignature("grantRole(uint64,address,uint32)", uint64(901), makeAddr("x"), uint32(0)));
        // the router's owner is the gate: nobody else can set routes or the fee recipient directly
        vm.prank(DEPLOYER);
        (bool ok,) = router.call(abi.encodeWithSignature("setFeeRecipient(address)", makeAddr("attacker")));
        require(!ok, "the deployer still controls the router");
        vm.prank(daoAddr);
        (ok,) = address(wm).call(abi.encodeWithSignature("setOnboardingAdmin(address)", makeAddr("attacker")));
        require(!ok, "a non-fee-authority set the onboarding admin directly");
    }

    function g3_dao_viaGateExecute_cannotSetTheOnboardingAdmin_feeAuthorityCan() external {
        // the DAO's gate.execute makes the gate the WM's msg.sender: not a fee authority, so the WM refuses
        vm.prank(daoAddr);
        (bool ok,) = gateAddr.call(abi.encodeCall(
            CurveYieldGovernanceGate.execute, (address(wm), abi.encodeCall(wm.setOnboardingAdmin, (makeAddr("attacker"))))
        ));
        require(!ok, "the DAO set the onboarding admin through the gate");
        // a fee authority (the fee Safe) sets it directly
        vm.prank(FEE_SAFE);
        wm.setOnboardingAdmin(makeAddr("admin"));
        require(wm.onboardingAdmin() == makeAddr("admin"), "fee authority could not set the onboarding admin");
    }

    function g4_feeAuthority_reachesProtectedCalls_viaExecuteProtected() external {
        address router = _p2("swapRouterV2");
        address newRx = makeAddr("newFeeRecipient");
        vm.prank(FEE_SAFE);
        CurveYieldGovernanceGate(gateAddr).executeProtected(router, abi.encodeWithSignature("setFeeRecipient(address)", newRx));
        (bool ok, bytes memory r) = router.staticcall(abi.encodeWithSignature("feeRecipient()"));
        require(ok && abi.decode(r, (address)) == newRx, "executeProtected did not set the router fee recipient");
        // and the DAO cannot use the protected path
        vm.prank(daoAddr);
        (ok,) = gateAddr.call(abi.encodeCall(CurveYieldGovernanceGate.executeProtected, (router, abi.encodeWithSignature("setFeeRecipient(address)", newRx))));
        require(!ok, "the DAO used executeProtected");
    }

    function g5_dao_normalCallsWork_andConfigWithinRanges() external {
        // an ordinary DAO setting: DAO-class gate key inside its range
        bytes32[] memory k = new bytes32[](1);
        uint256[] memory v = new uint256[](1);
        (k[0], v[0]) = (K.ALLOC_SEASONING_DAYS, 5);
        vm.prank(daoAddr);
        CurveYieldGovernanceGate(gateAddr).setConfigs(k, v);
        require(_getGate(K.ALLOC_SEASONING_DAYS) == 5, "DAO config change did not apply");
        v[0] = 15; // hard cap 14
        vm.prank(daoAddr);
        vm.expectRevert();
        CurveYieldGovernanceGate(gateAddr).setConfigs(k, v);
        // FEE-class keys: the DAO cannot, the fee authority can
        (k[0], v[0]) = (K.WM_REQUEST_FEE, 0.05e18);
        vm.prank(daoAddr);
        vm.expectRevert();
        CurveYieldGovernanceGate(gateAddr).setConfigs(k, v);
        vm.prank(FEE_SAFE);
        CurveYieldGovernanceGate(gateAddr).setConfigs(k, v);
        require(wm.getRequestFee() == 0.05e18, "the withdraw manager did not follow the gate");
    }

    function g6_guardian_heldToItsRanges() external {
        CurveYieldOptimizationGuardian g = CurveYieldOptimizationGuardian(guardianAddr);
        require(g.operator() == operator, "guardian operator");
        // loop.allocationBps: GUARDIAN class, range 3,000-8,000 set by P3_03
        vm.prank(operator);
        g.setConfig(K.LOOP_ALLOCATION_BPS, 6_000);
        require(_getGate(K.LOOP_ALLOCATION_BPS) == 6_000, "guardian in-range change did not apply");
        vm.prank(operator);
        vm.expectRevert();
        g.setConfig(K.LOOP_ALLOCATION_BPS, 2_999); // below the guardian range
        vm.prank(operator);
        vm.expectRevert();
        g.setConfig(K.LOOP_ALLOCATION_BPS, 8_001); // above the key's hard cap
        // lp.maxBps range 200-500
        vm.prank(operator);
        vm.expectRevert();
        g.setConfig(K.LP_MAX_BPS, 501);
        // a DAO-class key is not the guardian's
        vm.prank(operator);
        vm.expectRevert();
        g.setConfig(K.LOOP_TARGET_LTV_BPS, 7_000);
        // a FEE-class key is not the guardian's
        vm.prank(operator);
        vm.expectRevert();
        g.setConfig(K.SPLIT_GROWTH_BPS, 3_000);
        // only the operator or an owner
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        g.setConfig(K.LOOP_ALLOCATION_BPS, 5_000);
        // the guardian cannot call the gate's protected path, nor setConfigs
        vm.prank(guardianAddr);
        (bool ok,) = gateAddr.call(abi.encodeCall(CurveYieldGovernanceGate.setConfigs, (_k1(K.LOOP_TARGET_LTV_BPS), _v1(7_000))));
        require(!ok, "the guardian used setConfigs");
    }

    function g7_wiring_daoRepoints_feeAuthorityCannot() external {
        bytes32 key = CurveYieldAddrKeys.SWAP_ROUTER;
        address cur = gate.addr(key);
        address other = _p2("swapFuseV2"); // any contract with code
        vm.prank(FEE_SAFE);
        vm.expectRevert(CurveYieldGovernanceGate.NotDao.selector);
        gate.setAddr(key, other);
        vm.prank(daoAddr);
        gate.setAddr(key, other);
        require(gate.addr(key) == other, "DAO setAddr did not apply");
        require(gate.addr(key) != cur, "unchanged");
    }

    function _k1(bytes32 k_) internal pure returns (bytes32[] memory k) {
        k = new bytes32[](1);
        k[0] = k_;
    }

    function _v1(uint256 v_) internal pure returns (uint256[] memory v) {
        v = new uint256[](1);
        v[0] = v_;
    }

    function test_phase2Gov() public {
        _runS("g1 ownership and roles after the handover", this.g1_ownership_everyStackContractOwnedByTheGate.selector);
        _runS("g2 DAO cannot reach protected calls", this.g2_dao_cannotReachProtectedCalls.selector);
        _runS("g3 onboarding admin: fee authority only", this.g3_dao_viaGateExecute_cannotSetTheOnboardingAdmin_feeAuthorityCan.selector);
        _runS("g4 executeProtected by the fee authority only", this.g4_feeAuthority_reachesProtectedCalls_viaExecuteProtected.selector);
        _runS("g5 DAO settings inside ranges, FEE keys fee authority only", this.g5_dao_normalCallsWork_andConfigWithinRanges.selector);
        _runS("g6 guardian held to its ranges", this.g6_guardian_heldToItsRanges.selector);
        _runS("g7 wiring: DAO repoints, fee authority cannot", this.g7_wiring_daoRepoints_feeAuthorityCannot.selector);
        _finish();
    }
}
