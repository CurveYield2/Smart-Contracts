// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {L1_InstallLendingV1} from "../../script/L1_InstallLendingV1.s.sol";

interface IVaultLS {
    function isFuseSupported(address fuse) external view returns (bool);
    function getMarketSubstrates(uint256 marketId) external view returns (bytes32[] memory);
    function totalAssets() external view returns (uint256);
    function totalAssetsInMarket(uint256 marketId) external view returns (uint256);
    function getActiveMarketsInBalanceFuses() external view returns (uint256[] memory);
    function getInstantWithdrawalFuses() external view returns (address[] memory);
}

interface IScriptPathsLS {
    function setPaths(string calldata, string calldata) external;
    function run() external;
}

/// @notice State-aware lending setup for the fork tests. The live vault lends through IPOR market 41 ("Lend Only", supply
/// fuse 0x1af8…, substrate = the wcyavKAT / avKAT market). This makes sure a fork has that:
///   - market 41 already has its substrate -> nothing to do
///   - market 41 is empty (an older fork block) -> run L1, which installs lending fresh into market 41
/// Works on a temp copy of deployments/katana-lending-v1.json, so the real file is never written.
abstract contract LendingForkSetup is Test {
    enum LendingState {
        NotInstalled,
        Installed
    }

    address internal constant LS_VAULT = 0xEd83daf48429cfb2C650Fd721b9241e180fd4548;
    bytes32 internal constant LS_LOOP_MARKET = 0x80e60fe453223b0f84a567724f88190bef708420d24397157067d424429783e9;
    bytes32 internal constant LS_LEND_MARKET = 0xe0e57a9a96ef56292b1400db02b19995147b1f39ff9dc1673b4618beba1cb159;

    /// @dev A unique temp path per call: tests of one contract run in parallel and each rewrites its own lending JSON.
    function _tmpPath(string memory tag_) internal returns (string memory path_) {
        (bool ok, bytes memory r) = address(vm).call(abi.encodeWithSignature("unixTime()"));
        uint256 salt = ok && r.length == 32 ? abi.decode(r, (uint256)) : uint256(keccak256(abi.encode(tag_, gasleft())));
        for (uint256 i; i < 10_000; ++i) {
            path_ = string.concat("deployments/tmp-", tag_, "-", vm.toString(salt + i), ".json");
            if (!vm.exists(path_)) {
                vm.writeFile(path_, "{}");
                return path_;
            }
        }
        revert("no free temp path");
    }

    /// @return state_ what the fork looked like before, supplyFuse_ the market 14 supply fuse now installed (0 if unknown)
    function _prepareLending(string memory lendPath_, string memory p2Path_)
        internal
        returns (LendingState state_, address supplyFuse_)
    {
        vm.setEnv("PRIVATE_KEY", "0");
        try vm.readFile("deployments/katana-lending-v1.json") returns (string memory j) {
            vm.writeFile(lendPath_, j);
        } catch {}
        IVaultLS vault = IVaultLS(LS_VAULT);
        bytes32[] memory subs = vault.getMarketSubstrates(41);
        if (subs.length == 1 && subs[0] == LS_LEND_MARKET) {
            state_ = LendingState.Installed;
        } else {
            state_ = LendingState.NotInstalled;
            _runScript(address(new L1_InstallLendingV1()), p2Path_, lendPath_);
        }
        try vm.readFile(lendPath_) returns (string memory j2) {
            supplyFuse_ = vm.parseJsonAddress(j2, ".lendSupplyFuse");
        } catch {}
    }

    function _runScript(address script_, string memory p2Path_, string memory lendPath_) internal {
        IScriptPathsLS(script_).setPaths(p2Path_, lendPath_);
        IScriptPathsLS(script_).run();
    }

    function _removeTmp(string memory path_) internal {
        try vm.removeFile(path_) {} catch {}
    }
}
