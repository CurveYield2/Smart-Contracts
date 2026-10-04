// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {CurveYieldAddrKeys, ICurveYieldConfigGate} from "../governance/CurveYieldGateConfig.sol";

interface ICyPlusLtvView {
    function snapshot() external view returns (CyPlusLtvSnapshot memory);
    function params() external view returns (CyPlusLtvParams memory);
}

/// @dev Mirrors of CurveYieldPlusLoopController's CyPlusSnapshot / CyPlusParams (same ABI).
struct CyPlusLtvSnapshot {
    uint256 collateralWrapped;
    uint256 collateralCy;
    uint256 collateralValue;
    uint256 debt;
    uint256 idleCy;
    uint256 ltvBps;
    uint256 equityCy;
}

struct CyPlusLtvParams {
    uint16 targetLtvBps;
    uint16 deleverLtvBps;
    uint16 windupBandBps;
    uint16 specialRewardsBps;
    uint16 compoundBps;
    uint16 boosterBps;
    uint16 adminBps;
}

interface ICyMainWmEmergency {
    function armEmergencyFeeExempt() external;
    function disarmEmergencyFeeExempt() external;
}

/// @title CurveYieldEmergencyFeeArmFuse (PPS spec B5, D3)
/// @notice First and last action of cyavKAT+'s EMERGENCY de-leverage bundle. `enter(true)` checks, in the same call,
/// that cyavKAT+ is above its de-lever LTV and arms a zero instant fee on the main vault's withdraw manager for the
/// bundle's own redemption; `enter(false)` clears it if unused. Normal unwinds and user withdrawals never use it.
contract CurveYieldEmergencyFeeArmFuse is IFuseCommon {
    address public immutable VERSION;
    uint256 public immutable override MARKET_ID;
    /// @notice Wired in the gate (`CurveYieldAddrKeys.PLUS_CONTROLLER`, GATE_CONFIG_SPEC §10).
    function PLUS_CONTROLLER() public view returns (ICyPlusLtvView) {
        return ICyPlusLtvView(ICurveYieldConfigGate(GATE).addr(CurveYieldAddrKeys.PLUS_CONTROLLER));
    }
    /// @notice Wired in the gate (`CurveYieldAddrKeys.WITHDRAW_MANAGER`, GATE_CONFIG_SPEC §10).
    function MAIN_WITHDRAW_MANAGER() public view returns (ICyMainWmEmergency) {
        return ICyMainWmEmergency(ICurveYieldConfigGate(GATE).addr(CurveYieldAddrKeys.WITHDRAW_MANAGER));
    }

    error NotAboveDeleverLtv(uint256 ltvBps, uint256 deleverLtvBps);
    /// @notice The governance gate (wiring anchor, GATE_CONFIG_SPEC §10).
    address public immutable GATE;

    constructor(uint256 marketId_, address gate_) {
        VERSION = address(this);
        GATE = gate_;
        MARKET_ID = marketId_;
    }

    function enter(bool arm_) external {
        if (!arm_) {
            MAIN_WITHDRAW_MANAGER().disarmEmergencyFeeExempt();
            return;
        }
        uint256 ltv = PLUS_CONTROLLER().snapshot().ltvBps;
        uint256 trigger = PLUS_CONTROLLER().params().deleverLtvBps;
        if (ltv <= trigger) revert NotAboveDeleverLtv(ltv, trigger);
        MAIN_WITHDRAW_MANAGER().armEmergencyFeeExempt();
    }
}
