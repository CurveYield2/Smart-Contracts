// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {FuseAction} from "../interfaces/CurveYieldPhase2Interfaces.sol";

/// @notice A planner turns an instant-withdrawal amount into a bundle of fuse actions (generic fuses only).
interface ICurveYieldInstantWithdrawPlanner {
    function planInstantWithdraw(uint256 amount) external view returns (FuseAction[] memory actions);
}

interface ICurveYieldPlannedSelf {
    function executeInternal(FuseAction[] calldata calls) external;
}

/// @title CurveYieldPlannedInstantWithdrawFuse (generic, IPOR style)
/// @notice IPOR instant-withdrawal hook for positions whose exit needs planning (loops, LPs). Configured in the vault's
/// instant-withdrawal list with params = [amount (filled by IPOR), planner]. The planner must be granted as
/// `6 << 160 | planner` in SUBSTRATE_MARKET_ID. Runs the planner's bundle through the vault's `executeInternal` inside try/catch, so it never
/// reverts (IPOR does not catch instant fuses), and sets the vault's execution flag for the bundle when it is not set
/// (flash-loan callbacks, e.g. Morpho, are only accepted while it is set).
contract CurveYieldPlannedInstantWithdrawFuse is IFuseCommon {
    address public immutable VERSION;
    uint256 public constant TYPE_PLANNER = 6;

    uint256 public immutable override MARKET_ID;
    uint256 public immutable SUBSTRATE_MARKET_ID;

    event PlannedInstantWithdraw(address version, address planner, uint256 amount, bool success);

    error PlannerNotGranted(address planner);

    constructor(uint256 marketId_, uint256 substrateMarketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        SUBSTRATE_MARKET_ID = substrateMarketId_;
    }

    function instantWithdraw(bytes32[] calldata params_) external {
        if (params_.length < 2) return;
        uint256 amount = uint256(params_[0]);
        address planner = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);
        if (amount == 0) return;
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(SUBSTRATE_MARKET_ID, bytes32((TYPE_PLANNER << 160) | uint256(uint160(planner))))) {
            revert PlannerNotGranted(planner);
        }
        FuseAction[] memory actions;
        try ICurveYieldInstantWithdrawPlanner(planner).planInstantWithdraw(amount) returns (FuseAction[] memory a) {
            actions = a;
        } catch {
            emit PlannedInstantWithdraw(VERSION, planner, amount, false);
            return;
        }
        if (actions.length == 0) return;
        bool started = PlasmaVaultLib.isExecutionStarted();
        if (!started) PlasmaVaultLib.executeStarted();
        bool ok;
        try ICurveYieldPlannedSelf(address(this)).executeInternal(actions) {
            ok = true;
        } catch {}
        if (!started) PlasmaVaultLib.executeFinished();
        emit PlannedInstantWithdraw(VERSION, planner, amount, ok);
    }
}
