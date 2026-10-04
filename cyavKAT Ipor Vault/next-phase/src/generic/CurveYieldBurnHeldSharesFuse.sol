// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {IPlasmaVaultBase} from "contracts/interfaces/IPlasmaVaultBase.sol";

struct BurnHeldSharesEnterData {
    uint256 maxShares; // 0 = every share the vault holds
}

/// @title CurveYieldBurnHeldSharesFuse (generic, IPOR style)
/// @notice Burns the vault's OWN shares that it holds (bought back on the market, or received), through the same path
/// as IPOR's BurnRequestFeeFuse (PlasmaVaultBase.updateInternal): supply down, no fee, no split. Burning shares the
/// vault holds never lowers the share price (they were not counted as assets).
contract CurveYieldBurnHeldSharesFuse is IFuseCommon {
    using Address for address;

    address public immutable VERSION;
    uint256 public immutable override MARKET_ID;

    event HeldSharesBurned(address version, uint256 shares);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(BurnHeldSharesEnterData memory data_) external returns (uint256 burned_) {
        burned_ = IERC20(address(this)).balanceOf(address(this));
        if (data_.maxShares != 0 && burned_ > data_.maxShares) burned_ = data_.maxShares;
        if (burned_ == 0) return 0;
        PlasmaVaultStorageLib.getPlasmaVaultBase().functionDelegateCall(
            abi.encodeWithSelector(IPlasmaVaultBase.updateInternal.selector, address(this), address(0), burned_)
        );
        emit HeldSharesBurned(VERSION, burned_);
    }
}
