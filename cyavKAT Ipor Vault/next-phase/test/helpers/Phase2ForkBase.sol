// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {FuseAction} from "../../src/interfaces/CurveYieldPhase2Interfaces.sol";
import {LendingForkSetup} from "./LendingForkSetup.sol";
import {P0_00_DeployGateConfig} from "../../script/P0_00_DeployGateConfig.s.sol";
import {P2_01_Deploy} from "../../script/P2_01_Deploy.s.sol";
import {P2_02_ConfigureVault} from "../../script/P2_02_ConfigureVault.s.sol";
import {P2_03_Cutover} from "../../script/P2_03_Cutover.s.sol";

interface IScriptFork {
    function setPaths(string calldata, string calldata) external;
    function run() external;
}

interface IVaultFork {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
    function redeemFromRequest(uint256 shares, address receiver, address owner) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function convertToAssets(uint256) external view returns (uint256);
    function convertToShares(uint256) external view returns (uint256);
    function previewRedeem(uint256) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function execute(FuseAction[] calldata calls) external;
    function getActiveMarketsInBalanceFuses() external view returns (uint256[] memory);
    function updateMarketsBalances(uint256[] calldata) external returns (uint256);
    function getInstantWithdrawalFuses() external view returns (address[] memory);
}

interface IErcFork {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IExecFork {
    function deployAssets() external;
    function rebalance() external;
    function fulfillAll() external;
    function fulfillFor(address requester, uint256 shares) external;
    function fulfillFor(address requester, uint256 shares, uint256 maxChargeShares) external;
    function pruneExpiredRequests() external returns (uint256, bool);
    function emergencyRepay(uint256 repayKat, uint256 maxCallerPayAvkat) external;
    function lpEmergency(uint256 maxCallerPayAvkat) external;
    function harvest(address[] calldata tokens, uint256[] calldata amounts, bytes32[][] calldata proofs) external;
    function startNativeExit() external;
    function beginNativeExits() external;
    function completeNativeExits() external;
    function completeNativeExitEarly(uint256 tokenId, uint256 maxPremiumKat) external;
    function setBackstops(address[] calldata backstops) external;
    function owner() external view returns (address);
}

interface IWmFork {
    function requestShares(uint256) external;
    function getWithdrawFee() external view returns (uint256);
    function getRequestFee() external view returns (uint256);
    function activeUnreleasedShares() external view returns (uint256);
    function committedShares() external view returns (uint256);
    function pendingOnboardingFeeShares() external view returns (uint256);
    function settleOnboardingFee() external returns (uint256);
    function setOnboardingAdmin(address) external;
    function onboardingAdmin() external view returns (address);
    function availableSharesOf(address) external view returns (uint256);
    function profitCustody() external view returns (address);
    function configGate() external view returns (address);
}

interface IGateFork {
    function setConfigs(bytes32[] calldata keys, uint256[] calldata values) external;
    function getMany(bytes32[] calldata keys) external view returns (uint256[] memory);
    function addr(bytes32 key) external view returns (address);
    function setAddr(bytes32 key, address a) external;
    function dao() external view returns (address);
    function adminReceiver() external view returns (address);
    function setAdminReceiver(address receiver) external;
    function isFeeAuthority(address a) external view returns (bool);
}

/// @notice Shared setup of the Katana fork suites (Job 2 / Job 3): forks Katana and builds the Phase 2 stack by running
/// the REAL deploy scripts P0_00, P2_01, P2_02, P2_03 as the deployer (no stack constructor is called directly, so the
/// suites keep working while src/ is refactored). Deployment files are `deployments/test-*.json` (never katana-*.json).
/// Scenarios run as isolated self-calls under a snapshot: a failure is recorded with its decoded revert, and the next
/// scenario still starts from the freshly deployed state. The final revert lists every failing scenario.
abstract contract Phase2ForkBase is LendingForkSetup {
    address internal constant VAULT = 0xEd83daf48429cfb2C650Fd721b9241e180fd4548;
    address internal constant AVKAT = 0x7231dbaCdFc968E07656D12389AB20De82FbfCeB;
    address internal constant KAT = 0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d;
    address internal constant MORPHO = 0xD50F2DffFd62f94Ee4AEd9ca05C61d0753268aBc;
    address internal constant DEPLOYER = 0x11b78837cadC8E894F1c6e13fA9f3A085a75FA35;
    address internal constant FEE_SAFE = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;
    address internal constant RCM = 0xA77470B748A8Fb50056Ca3c07375dC76Aa3A72Cb;
    address internal constant POOL_1PCT = 0x8640e1867BD563B2Ab865160E77Cb7B875243B13;
    address internal constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;
    address internal constant ACCESS_MANAGER = 0xd7f408f203c5c6a76c9c55c9f6b015929F151fAA;
    uint256 internal constant CY = 1e20; // one cyavKAT share (20 decimals)

    IVaultFork internal cy = IVaultFork(VAULT);
    IExecFork internal exec;
    IWmFork internal wm;
    IGateFork internal gate;
    string internal p0Path;
    string internal p2Path;
    string internal lendPath;
    string internal p2j;
    string internal lendj;

    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    string[] internal fails;
    uint256 internal passed;

    function _setUpFork(string memory tag_) internal {
        vm.createSelectFork(vm.envString("KATANA_RPC_URL"), vm.envUint("FORK_BLOCK"));
        vm.setEnv("PRIVATE_KEY", "0");
        p0Path = _testPath(string.concat(tag_, "-p0"));
        p2Path = _testPath(string.concat(tag_, "-p2"));
        lendPath = _testPath(string.concat(tag_, "-lend"));
        vm.setEnv("PHASE0_DEPLOYMENTS", p0Path);
        _prepareLending(lendPath, p2Path);
        IScriptFork(address(new P0_00_DeployGateConfig())).run();
        _runP2(address(new P2_01_Deploy()));
        _runP2(address(new P2_02_ConfigureVault()));
        _runP2(address(new P2_03_Cutover()));
        p2j = vm.readFile(p2Path);
        lendj = vm.readFile(lendPath);
        exec = IExecFork(_p2("executor"));
        wm = IWmFork(_p2("withdrawManagerV2"));
        gate = IGateFork(vm.parseJsonAddress(vm.readFile(p0Path), ".governanceGate"));
    }

    function _tearDownFiles() internal {
        _removeTmp(p0Path);
        _removeTmp(p2Path);
        _removeTmp(lendPath);
    }

    /// @dev `deployments/test-<tag>-<n>.json`, unique per call (parallel test contracts share the directory).
    function _testPath(string memory tag_) internal returns (string memory path_) {
        uint256 salt = uint256(keccak256(abi.encode(tag_, block.number, gasleft(), address(this))));
        for (uint256 i; i < 10_000; ++i) {
            path_ = string.concat("deployments/test-", tag_, "-", vm.toString(salt % 1e9 + i), ".json");
            if (!vm.exists(path_)) {
                vm.writeFile(path_, "{}");
                return path_;
            }
        }
        revert("no free test path");
    }

    function _runP2(address script_) internal {
        IScriptFork(script_).setPaths(p2Path, lendPath);
        IScriptFork(script_).run();
    }

    function _p2(string memory k_) internal view returns (address) {
        return vm.parseJsonAddress(p2j, string.concat(".", k_));
    }

    // ---------------------------------------------------------------- measurement helpers

    function _pps() internal view returns (uint256) {
        return cy.convertToAssets(CY);
    }

    /// @dev Share price never drops (the IPOR management fee is zero on this vault; rounding tolerance 2 wei of avKAT).
    function _ppsNotBelow(uint256 before_, string memory what_) internal view {
        uint256 now_ = _pps();
        require(now_ + 2 >= before_, string.concat("PPS DROPPED ", what_, ": ", vm.toString(before_), " -> ", vm.toString(now_)));
    }

    function _refresh() internal {
        uint256[] memory ms = cy.getActiveMarketsInBalanceFuses();
        vm.prank(DEPLOYER);
        cy.updateMarketsBalances(ms);
    }

    /// @dev Revalues every market first; the share price after interest accrued during a warp.
    function _ppsFresh() internal returns (uint256) {
        _refresh();
        return _pps();
    }

    function _depositAvkat(address who_, uint256 avkat_) internal returns (uint256 shares_) {
        deal(AVKAT, who_, IErcFork(AVKAT).balanceOf(who_) + avkat_);
        vm.startPrank(who_);
        IErcFork(AVKAT).approve(VAULT, type(uint256).max);
        shares_ = cy.deposit(avkat_, who_);
        vm.stopPrank();
    }

    function _request(address who_, uint256 shares_) internal {
        vm.prank(who_);
        wm.requestShares(shares_);
    }

    function _warpBy(uint256 dt_) internal {
        vm.warp(block.timestamp + dt_);
    }

    function _setGate(bytes32 key_, uint256 value_) internal {
        bytes32[] memory k = new bytes32[](1);
        uint256[] memory v = new uint256[](1);
        (k[0], v[0]) = (key_, value_);
        vm.prank(DEPLOYER);
        gate.setConfigs(k, v);
    }

    function _getGate(bytes32 key_) internal view returns (uint256) {
        bytes32[] memory k = new bytes32[](1);
        k[0] = key_;
        return gate.getMany(k)[0];
    }

    function _avkat(address a_) internal view returns (uint256) {
        return IErcFork(AVKAT).balanceOf(a_);
    }

    // ---------------------------------------------------------------- scenario driver

    /// @dev ONLY=<text> runs just the scenarios whose name contains the text (debugging aid; unset = all).
    function _selected(string memory name_) internal view returns (bool) {
        bytes memory needle = bytes(vm.envOr("ONLY", string("")));
        bytes memory hay = bytes(name_);
        if (needle.length == 0) return true;
        if (needle.length > hay.length) return false;
        for (uint256 i; i + needle.length <= hay.length; ++i) {
            bool ok = true;
            for (uint256 j; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    function _runS(string memory name_, bytes4 sel_) internal {
        if (!_selected(name_)) return;
        uint256 snap = vm.snapshot();
        (bool ok, bytes memory ret) = address(this).call(abi.encodeWithSelector(sel_));
        address(vm).call(abi.encodeWithSignature("stopPrank()")); // a failed scenario may leave a startPrank open
        vm.revertTo(snap);
        if (ok) {
            ++passed;
            console2.log("PASS", name_);
            return;
        }
        string memory why = _decode(ret);
        console2.log("FAIL", name_);
        console2.log("   ", why);
        fails.push(string.concat(name_, ": ", why));
    }

    function _finish() internal view {
        console2.log("scenarios passed", passed, "failed", fails.length);
        if (fails.length != 0) {
            string memory all;
            for (uint256 i; i < fails.length; ++i) all = string.concat(all, "\n  ", fails[i]);
            revert(string.concat("failed scenarios:", all));
        }
    }

    function _decode(bytes memory ret_) internal pure returns (string memory) {
        if (ret_.length == 0) return "(empty revert data)";
        bytes4 sel = bytes4(ret_);
        if (sel == 0x08c379a0) return abi.decode(_tail(ret_), (string));
        if (sel == 0x4e487b71) return string.concat("Panic(", _u(abi.decode(_tail(ret_), (uint256))), ")");
        if (sel == bytes4(keccak256("UnwindLossAboveFee(uint256,uint256)"))) {
            (uint256 a, uint256 b) = abi.decode(_tail(ret_), (uint256, uint256));
            return string.concat("UnwindLossAboveFee(loss ", _u(a), ", allowed ", _u(b), ")");
        }
        if (sel == bytes4(keccak256("CallerPayAboveMaximum(uint256,uint256)"))) {
            (uint256 a, uint256 b) = abi.decode(_tail(ret_), (uint256, uint256));
            return string.concat("CallerPayAboveMaximum(pay ", _u(a), ", max ", _u(b), ")");
        }
        if (sel == bytes4(keccak256("PpsDropped(uint256)"))) {
            return string.concat("PpsDropped(shortfall ", _u(abi.decode(_tail(ret_), (uint256))), ")");
        }
        if (sel == bytes4(keccak256("NoScheduledRequests()"))) return "NoScheduledRequests()";
        if (sel == bytes4(keccak256("NothingReleasable()"))) return "NothingReleasable()";
        if (sel == bytes4(keccak256("LaneNotCovered()"))) return "LaneNotCovered()";
        if (sel == bytes4(keccak256("NoVkatSet()"))) return "NoVkatSet()";
        if (sel == bytes4(keccak256("TooLittleOut(uint256,uint256)"))) {
            (uint256 a, uint256 b) = abi.decode(_tail(ret_), (uint256, uint256));
            return string.concat("TooLittleOut(net ", _u(a), ", minimum ", _u(b), ")");
        }
        return vm.toString(ret_);
    }

    function _u(uint256 v_) internal pure returns (string memory) {
        return vm.toString(v_);
    }

    function _tail(bytes memory b_) internal pure returns (bytes memory out_) {
        out_ = new bytes(b_.length - 4);
        for (uint256 i; i < out_.length; ++i) out_[i] = b_[i + 4];
    }

    // ---------------------------------------------------------------- log helpers

    /// @dev The decoded `WithdrawalsFulfilled(caller, requester, shares, lossAvkat, feeSharesBurned, reward)` events of the
    /// executor in the recorded logs.
    struct Fulfilled {
        address requester;
        uint256 shares;
        uint256 loss;
        uint256 feeShares;
        uint256 reward;
    }

    function _fulfilledEvents(Vm.Log[] memory logs_) internal view returns (Fulfilled[] memory out_) {
        bytes32 sig = keccak256("WithdrawalsFulfilled(address,address,uint256,uint256,uint256,uint256)");
        uint256 n;
        for (uint256 i; i < logs_.length; ++i) if (logs_[i].emitter == address(exec) && logs_[i].topics[0] == sig) ++n;
        out_ = new Fulfilled[](n);
        n = 0;
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter != address(exec) || logs_[i].topics[0] != sig) continue;
            out_[n].requester = address(uint160(uint256(logs_[i].topics[2])));
            (out_[n].shares, out_[n].loss, out_[n].feeShares, out_[n].reward) =
                abi.decode(logs_[i].data, (uint256, uint256, uint256, uint256));
            ++n;
        }
    }

    function _hasEvent(Vm.Log[] memory logs_, address emitter_, bytes32 sig_) internal pure returns (bool) {
        for (uint256 i; i < logs_.length; ++i) if (logs_[i].emitter == emitter_ && logs_[i].topics[0] == sig_) return true;
        return false;
    }
}
