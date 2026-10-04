// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {CurveYieldWrapperBurnForwarder} from "../src/wrapper/CurveYieldWrapperBurnForwarder.sol";

interface ISplitterL10 {
    function contributorsReceiver() external view returns (address);
    function burnWithdrawManager() external view returns (address);
    function adminReceiver() external view returns (address);
    function setDestinations(address contributors, address withdrawManager) external;
    function owner() external view returns (address);
}

/// Wrapper fee split 40 / 30 / 30 (live, fixed in the splitter) -> the approved 40 admin / 40 contributors / 20 burned.
/// Deploys CurveYieldWrapperBurnForwarder with the splitter's current destinations and makes it the splitter's burn
/// destination: the splitter's 30% burn leg is forwarded 2/3 to the withdraw manager (burned) and 1/3 to contributors.
/// Admin receiver untouched. Reversible: splitter.setDestinations(contributors, withdrawManager).
/// Writes `wrapperBurnForwarder` into deployments/katana-lending-v1.json (P4_04 re-points both at the cutover).
///
/// From C:\Users\user\Desktop\Claude:
///   forge script "$P2/script/L10_WrapperSplit404020.s.sol" --root $P2 --rpc-url katana --skip test --skip "*/test/**"
contract L10_WrapperSplit404020 is Phase2Base {
    function run() external {
        require(block.chainid == 747474, "not Katana");
        string memory json = vm.readFile(_lendingPath());
        ISplitterL10 splitter = ISplitterL10(vm.parseJsonAddress(json, ".wrapperFeeSplitter"));
        require(splitter.owner() == DEPLOYER, "splitter owner");
        address contributors = splitter.contributorsReceiver();
        address wm = splitter.burnWithdrawManager();
        address admin = splitter.adminReceiver();

        _start();
        CurveYieldWrapperBurnForwarder fwd =
            new CurveYieldWrapperBurnForwarder(DEPLOYER, IERC20(VAULT), address(splitter), contributors, wm);
        splitter.setDestinations(contributors, address(fwd));
        fwd.distribute(); // proves the path end to end (a no-op when nothing has accrued)
        _stop();

        require(splitter.burnWithdrawManager() == address(fwd) && splitter.adminReceiver() == admin, "splitter");
        require(fwd.burnWithdrawManager() == wm && fwd.contributorsReceiver() == contributors, "forwarder");
        console2.log("burn forwarder", address(fwd));
        console2.log("contributors / burn WM", contributors, wm);

        vm.serializeJson("lend", json);
        string memory out = vm.serializeAddress("lend", "wrapperBurnForwarder", address(fwd));
        vm.writeJson(out, _lendingPath());
    }
}
