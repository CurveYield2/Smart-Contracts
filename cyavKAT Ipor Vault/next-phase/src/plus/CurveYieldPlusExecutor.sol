// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FuseAction} from "../interfaces/CurveYieldPhase2Interfaces.sol";
import {CurveYieldPlusLoopController} from "./CurveYieldPlusLoopController.sol";

interface ICyPlusExecVault {
    function execute(FuseAction[] calldata calls) external;
    function convertToShares(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function asset() external view returns (address);
}

interface ICyPlusWm {
    function activeUnreleasedShares() external view returns (uint256);
    function getSharesToRelease() external view returns (uint256);
    function getRequestFee() external view returns (uint256);
    function feeSplit() external view returns (address[3] memory, uint16[3] memory);
    function splitRequestFee() external view returns (bool);
    function releaseActiveShares(uint256 timestamp, uint256 shares) external returns (uint256);
    function settleSplit() external returns (uint256);
}

/// @title CurveYieldPlusExecutor (#20)
/// @notice Public keeper entry points for cyavKAT+ (the maintenance bot calls them; anyone may). Holds ALPHA on the
/// cyavKAT+ vault and is the controller of its withdraw manager (our WM v2 with the 20/25/30 fee split).
/// Every action is a bundle of standard fuses planned by the controller (fuse standardization).
///   windup()  — back to target LTV, profit share out, idle cyavKAT supplied
///   delever() — above 72.2% LTV, back to 70%
///   fulfill() — scheduled requests, oldest first: unwinds only what the main vault can supply instantly now, then
///               releases what idle cyavKAT covers INCLUDING the request-fee split payout (so every released holder
///               can redeem). Anything left waits for the next call.
contract CurveYieldPlusExecutor is Ownable2Step, ReentrancyGuard {
    uint256 public constant BPS = 10_000;

    ICyPlusExecVault public immutable VAULT;
    CurveYieldPlusLoopController public immutable CONTROLLER;
    ICyPlusWm public withdrawManager;

    event Fulfilled(uint256 unwoundCy, uint256 releasedShares);

    error NothingToFulfil();

    constructor(address owner_, address vault_, address controller_, address withdrawManager_) Ownable(owner_) {
        VAULT = ICyPlusExecVault(vault_);
        CONTROLLER = CurveYieldPlusLoopController(controller_);
        withdrawManager = ICyPlusWm(withdrawManager_);
    }

    function setWithdrawManager(address withdrawManager_) external onlyOwner {
        withdrawManager = ICyPlusWm(withdrawManager_);
    }

    function windup() external nonReentrant {
        withdrawManager.settleSplit();
        _run(CONTROLLER.planWindupActions(address(withdrawManager)));
        CONTROLLER.recordCheckpoint();
    }

    function delever() external nonReentrant {
        withdrawManager.settleSplit();
        _run(CONTROLLER.planDeleverActions());
    }

    function fulfill() external nonReentrant returns (uint256 releasedShares_) {
        ICyPlusWm wm = withdrawManager;
        wm.settleSplit();
        uint256 active = wm.activeUnreleasedShares();
        if (active == 0) revert NothingToFulfil();
        IERC20 cy = IERC20(VAULT.asset());
        uint256 splitBps = _splitBpsForRequests(wm);
        uint256 feeRate = wm.getRequestFee(); // WAD

        // cyavKAT the release needs: already-released (still unredeemed) + the new release + its fee-split payout
        // released shares redeem via redeemFromRequest (no instant fee): value them at convertToAssets
        uint256 reserved = VAULT.convertToAssets(wm.getSharesToRelease());
        uint256 wantAssets = VAULT.convertToAssets(active);
        // the request fee is charged on GROSS (net = gross * (1 - f)): fee assets = net * f / (1 - f)
        uint256 splitAssets = feeRate >= 1e18 ? 0 : wantAssets * feeRate / (1e18 - feeRate) * splitBps / BPS;
        uint256 idle = cy.balanceOf(address(VAULT));
        uint256 needed = reserved + wantAssets + splitAssets;
        uint256 unwound;
        if (needed > idle) {
            uint256 gap = needed - idle;
            uint256 maxOut = CONTROLLER.maxInstantOut();
            unwound = gap < maxOut ? gap : maxOut;
            if (unwound != 0) _run(CONTROLLER.planUnwindActions(unwound));
            idle = cy.balanceOf(address(VAULT));
        }
        if (idle <= reserved) revert NothingToFulfil();
        // largest release whose assets + split payout fit in idle after the reserve
        uint256 room = idle - reserved;
        // cost per unit of released value = 1 + f * split / ((1 - f) * BPS)
        uint256 coverAssets = feeRate >= 1e18
            ? 0
            : room * ((1e18 - feeRate) * BPS) / ((1e18 - feeRate) * BPS + feeRate * splitBps);
        releasedShares_ = VAULT.convertToShares(coverAssets);
        if (releasedShares_ > active) releasedShares_ = active;
        if (releasedShares_ == 0) revert NothingToFulfil();
        wm.releaseActiveShares(block.timestamp - 1, releasedShares_);
        emit Fulfilled(unwound, releasedShares_);
    }

    function _splitBpsForRequests(ICyPlusWm wm_) private view returns (uint256) {
        if (!wm_.splitRequestFee()) return 0;
        (, uint16[3] memory bps) = wm_.feeSplit();
        return uint256(bps[0]) + bps[1] + bps[2];
    }

    function _run(FuseAction[] memory actions_) private {
        if (actions_.length != 0) VAULT.execute(actions_);
    }
}
