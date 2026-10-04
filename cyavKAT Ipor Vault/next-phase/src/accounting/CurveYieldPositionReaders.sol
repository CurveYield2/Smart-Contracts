// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICurveYieldPositionReader} from "../generic/CurveYieldPositionReaderBalanceFuse.sol";
import {CurveYieldAddrKeys, ICurveYieldConfigGate} from "../governance/CurveYieldGateConfig.sol";

interface ICyLpNetView {
    function managedAvkat() external view returns (uint256);
    function AVKAT() external view returns (address);
}

interface ICyVkatExitView {
    function exitingKat() external view returns (uint256);
    function exitMinFeeBps() external view returns (uint256);
}

/// @notice Sushi LP holder, net of its KAT debt, in avKAT on the conversion basis (the LP controller's managedAvkat,
/// the same figure the allocation controller uses; never negative).
contract CurveYieldLpHolderReader is ICurveYieldPositionReader {
    /// @notice Wired in the gate (`CurveYieldAddrKeys.LP_CONTROLLER`, GATE_CONFIG_SPEC §10).
    function LP_CONTROLLER() public view returns (ICyLpNetView) {
        return ICyLpNetView(ICurveYieldConfigGate(GATE).addr(CurveYieldAddrKeys.LP_CONTROLLER));
    }
    address public immutable AVKAT;
    /// @notice The governance gate (wiring anchor, GATE_CONFIG_SPEC §10).
    address public immutable GATE;

    constructor(address gate_, address avkat_) {
        GATE = gate_;
        AVKAT = avkat_;
    }

    function positionValue(address) external view returns (address, uint256) {
        return (AVKAT, LP_CONTROLLER().managedAvkat());
    }
}

/// @notice KAT in the vKAT exit queue, valued net of the queue's minimum fee (as the Phase 2 market-7 fuse did).
contract CurveYieldVkatExitReader is ICurveYieldPositionReader {
    /// @notice Wired in the gate (`CurveYieldAddrKeys.VKAT_CONTROLLER`, GATE_CONFIG_SPEC §10).
    function VKAT_CONTROLLER() public view returns (ICyVkatExitView) {
        return ICyVkatExitView(ICurveYieldConfigGate(GATE).addr(CurveYieldAddrKeys.VKAT_CONTROLLER));
    }
    address public immutable KAT;
    /// @notice The governance gate (wiring anchor, GATE_CONFIG_SPEC §10).
    address public immutable GATE;

    constructor(address gate_, address kat_) {
        GATE = gate_;
        KAT = kat_;
    }

    function positionValue(address) external view returns (address, uint256) {
        uint256 exiting = VKAT_CONTROLLER().exitingKat();
        if (exiting == 0) return (KAT, 0);
        return (KAT, exiting * (10_000 - VKAT_CONTROLLER().exitMinFeeBps()) / 10_000);
    }
}
