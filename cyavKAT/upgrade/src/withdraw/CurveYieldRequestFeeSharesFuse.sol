// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {IPlasmaVaultBase} from "contracts/interfaces/IPlasmaVaultBase.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";

/// @notice IPOR-compatible enter/exit data; legacy WM entrypoints are retained.
struct CurveYieldRequestFeeSharesFuseEnterData {
    address from;
    address to;
    uint256 amount;
}

struct CurveYieldRequestFeeSharesFuseExitData {
    address previousManager;
}

/// @title CurveYieldRequestFeeSharesFuse (custom: the withdraw manager v2 is an adapted IPOR fork)
/// @notice The vault-side half of the request-fee escrow of `CurveYieldWithdrawalManagerV2`, called by the vault's
/// withdraw manager through `execute` (it is the manager's `requestFeeFuse`):
///   - `moveRequestFeeShares`: moves request-fee shares between a requester and the manager (escrow in, refund out);
///   - `configureManagerAssetAllowance`: rotates the vault-asset allowance the manager's custody transfers use.
/// Nothing else: the source order, the POL sale and the settlement of a fulfilment are ordinary bundles the executor
/// builds (no gate reads, no `executeInternal`). Utility fuse: `ZERO_BALANCE_MARKET`.
contract CurveYieldRequestFeeSharesFuse is IFuseCommon {
    using SafeERC20 for IERC20;
    using Address for address;

    address public immutable VERSION;
    uint256 public immutable override MARKET_ID;

    event CurveYieldRequestFeeSharesFuseMove(address version, address indexed manager, address indexed from, address indexed to, uint256 amount);
    event CurveYieldRequestFeeSharesFuseAllowance(address version, address indexed manager, address indexed previousManager);

    error CurveYieldRequestFeeSharesFuseInvalidMarketId();
    error CurveYieldRequestFeeSharesFuseUnauthorizedCaller(address caller);
    error CurveYieldRequestFeeSharesFuseInvalidMovement(address from, address to);
    error CurveYieldRequestFeeSharesFuseInvalidTransientInputs();

    constructor(uint256 marketId_) {
        if (marketId_ == 0) revert CurveYieldRequestFeeSharesFuseInvalidMarketId();
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice IPOR fuse enter: escrow or return request-fee shares; returns realised movement.
    function enter(CurveYieldRequestFeeSharesFuseEnterData memory d_) external returns (uint256) {
        _move(d_.from, d_.to, d_.amount);
        return d_.amount;
    }

    /// @notice Retained for the existing withdrawal-manager interface.
    function moveRequestFeeShares(address from_, address to_, uint256 amount_) external {
        _move(from_, to_, amount_);
    }

    function _move(address from_, address to_, uint256 amount_) private {
        address manager = _requireManager();
        if (amount_ == 0) return;
        if (from_ != manager && to_ != manager) revert CurveYieldRequestFeeSharesFuseInvalidMovement(from_, to_);
        PlasmaVaultStorageLib.getPlasmaVaultBase().functionDelegateCall(
            abi.encodeWithSelector(IPlasmaVaultBase.updateInternal.selector, from_, to_, amount_)
        );
        emit CurveYieldRequestFeeSharesFuseMove(VERSION, manager, from_, to_, amount_);
    }

    /// @notice IPOR fuse exit: rotate the previous-manager allowance to the current WM.
    function exit(CurveYieldRequestFeeSharesFuseExitData memory d_) external {
        _configureAllowance(d_.previousManager);
    }

    /// @notice Retained for the existing withdrawal-manager interface.
    function configureManagerAssetAllowance(address previousManager_) external {
        _configureAllowance(previousManager_);
    }

    function _configureAllowance(address previousManager_) private {
        address manager = _requireManager();
        IERC20 token = IERC20(IERC4626(address(this)).asset());
        if (previousManager_ != address(0) && previousManager_ != manager) token.forceApprove(previousManager_, 0);
        token.forceApprove(manager, type(uint256).max);
        emit CurveYieldRequestFeeSharesFuseAllowance(VERSION, manager, previousManager_);
    }

    /// @notice R3: input [from, to, amount], output [realisedSharesMoved].
    function enterTransient() external {
        bytes32[] memory words = TransientStorageLib.getInputs(VERSION);
        if (words.length != 3) revert CurveYieldRequestFeeSharesFuseInvalidTransientInputs();
        address from = TypeConversionLib.toAddress(words[0]);
        address to = TypeConversionLib.toAddress(words[1]);
        uint256 amount = TypeConversionLib.toUint256(words[2]);
        _move(from, to, amount);
        bytes32[] memory out = new bytes32[](1);
        out[0] = TypeConversionLib.toBytes32(amount);
        TransientStorageLib.setOutputs(VERSION, out);
    }

    /// @notice R3: input [previousManager], no amount outputs.
    function exitTransient() external {
        bytes32[] memory words = TransientStorageLib.getInputs(VERSION);
        if (words.length != 1) revert CurveYieldRequestFeeSharesFuseInvalidTransientInputs();
        _configureAllowance(TypeConversionLib.toAddress(words[0]));
        TransientStorageLib.setOutputs(VERSION, new bytes32[](0));
    }

    function _requireManager() private view returns (address manager_) {
        manager_ = PlasmaVaultStorageLib.getWithdrawManager().manager;
        if (manager_ == address(0) || msg.sender != manager_) revert CurveYieldRequestFeeSharesFuseUnauthorizedCaller(msg.sender);
    }
}
