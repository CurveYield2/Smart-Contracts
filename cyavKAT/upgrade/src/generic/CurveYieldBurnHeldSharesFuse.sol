// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {IPlasmaVaultBase} from "contracts/interfaces/IPlasmaVaultBase.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";

/// @notice enter: burn the vault's own shares it holds.
struct CurveYieldBurnHeldSharesFuseEnterData {
    uint256 maxShares; // 0 = every share the vault holds
}

/// @title CurveYieldBurnHeldSharesFuse (custom: IPOR's BurnRequestFeeFuse burns only withdraw-manager fee shares)
/// @notice Burns the vault's OWN shares that it holds (bought back on the market, or received), through the same path
/// as IPOR's BurnRequestFeeFuse (`PlasmaVaultBase.updateInternal`): supply down, no fee, no split. Burning shares the
/// vault holds never lowers the share price (they were not counted as assets). Utility fuse: `ZERO_BALANCE_MARKET`.
contract CurveYieldBurnHeldSharesFuse is IFuseCommon {
    using Address for address;

    address public immutable VERSION;
    uint256 public immutable override MARKET_ID;

    event CurveYieldBurnHeldSharesFuseEnter(address version, uint256 shares);

    error CurveYieldBurnHeldSharesFuseInvalidMarketId();
    error CurveYieldBurnHeldSharesFuseExitNotSupported();

    constructor(uint256 marketId_) {
        if (marketId_ == 0) revert CurveYieldBurnHeldSharesFuseInvalidMarketId();
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(CurveYieldBurnHeldSharesFuseEnterData memory data_) public returns (uint256 burned_) {
        burned_ = IERC20(address(this)).balanceOf(address(this));
        if (data_.maxShares != 0 && burned_ > data_.maxShares) burned_ = data_.maxShares;
        if (burned_ == 0) return 0;
        PlasmaVaultStorageLib.getPlasmaVaultBase().functionDelegateCall(
            abi.encodeWithSelector(IPlasmaVaultBase.updateInternal.selector, address(this), address(0), burned_)
        );
        emit CurveYieldBurnHeldSharesFuseEnter(VERSION, burned_);
    }

    /// @dev Input 0: maxShares. Output 0: the shares burned.
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        uint256 burned = enter(CurveYieldBurnHeldSharesFuseEnterData({maxShares: TypeConversionLib.toUint256(inputs[0])}));
        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(burned);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    function exitTransient() external pure {
        revert CurveYieldBurnHeldSharesFuseExitNotSupported();
    }

    function exit(bytes calldata) external pure {
        revert CurveYieldBurnHeldSharesFuseExitNotSupported();
    }
}
