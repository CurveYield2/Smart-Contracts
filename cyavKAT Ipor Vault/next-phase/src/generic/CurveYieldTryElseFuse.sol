// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {FuseAction} from "../interfaces/CurveYieldPhase2Interfaces.sol";

interface ICurveYieldTryElseSelf {
    function executeInternal(FuseAction[] calldata calls) external;
}

struct TryElseEnterData {
    FuseAction[] attempt; // e.g. a swap with its minimum output
    FuseAction[] fallbackActions; // run only if `attempt` reverts (e.g. burn the held shares instead of selling them)
}

/// @title CurveYieldTryElseFuse (generic, IPOR style)
/// @notice Runs `attempt` through the vault's own executeInternal (so every fuse in it must be supported by the vault)
/// and, if any action in it reverts, rolls it back and runs `fallbackActions` instead. For choices that depend on a
/// result only known on-chain, e.g. "sell at no less than X, otherwise burn". The fallback is not caught: if it fails,
/// the whole bundle fails.
contract CurveYieldTryElseFuse is IFuseCommon {
    address public immutable VERSION;
    uint256 public immutable override MARKET_ID;

    event TryElse(address version, bool attemptSucceeded);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(TryElseEnterData memory d_) external returns (bool attemptSucceeded_) {
        if (d_.attempt.length != 0) {
            try ICurveYieldTryElseSelf(address(this)).executeInternal(d_.attempt) {
                attemptSucceeded_ = true;
            } catch {}
        }
        if (!attemptSucceeded_ && d_.fallbackActions.length != 0) {
            ICurveYieldTryElseSelf(address(this)).executeInternal(d_.fallbackActions);
        }
        emit TryElse(VERSION, attemptSucceeded_);
    }
}
