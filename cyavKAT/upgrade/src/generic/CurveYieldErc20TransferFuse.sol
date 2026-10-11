// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {CurveYieldSubstrateLib as Sub} from "../libraries/CurveYieldSubstrateLib.sol";

/// @notice enter: pay `amount` of `token` from the vault to `to`.
struct CurveYieldErc20TransferFuseEnterData {
    address token;
    address to;
    uint256 amount;
}

/// @title CurveYieldErc20TransferFuse (custom: IPOR has no outbound transfer fuse; exception E1)
/// @notice Pays a token out of the vault. The boundary is the granted substrates, checked on every call: the token and
/// the recipient (typed, so a token can never be a recipient or the reverse) and a per-call cap for the token. The
/// amount is capped to the vault balance and to the cap's absolute ceiling; zero returns 0. Market 7 (it moves
/// accountable assets, §1.1 rule 3); its typed entries live in `ZERO_BALANCE_MARKET` (E6).
contract CurveYieldErc20TransferFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    /// @dev Absolute per-call ceiling in token base units, whatever the granted cap (R5): 1,000,000 tokens at 18 decimals.
    uint256 public constant ABSOLUTE_MAX_PER_CALL = 1_000_000e18;

    address public immutable VERSION;
    uint256 public immutable override MARKET_ID;

    event CurveYieldErc20TransferFuseEnter(address version, address token, address to, uint256 amount);

    error CurveYieldErc20TransferFuseInvalidMarketId();
    error CurveYieldErc20TransferFuseTokenNotGranted(address token);
    error CurveYieldErc20TransferFuseRecipientNotGranted(address recipient);
    error CurveYieldErc20TransferFuseCapNotGranted(address token);
    error CurveYieldErc20TransferFuseAboveCap(uint256 amount, uint256 cap);
    error CurveYieldErc20TransferFuseExitNotSupported();

    constructor(uint256 marketId_) {
        if (marketId_ == 0) revert CurveYieldErc20TransferFuseInvalidMarketId();
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(CurveYieldErc20TransferFuseEnterData memory data_) public returns (uint256 sent_) {
        if (data_.amount == 0) return 0;
        if (!Sub.isGranted(Sub.TRANSFER_TOKEN, data_.token)) revert CurveYieldErc20TransferFuseTokenNotGranted(data_.token);
        if (!Sub.isGranted(Sub.TRANSFER_RECIPIENT, data_.to)) revert CurveYieldErc20TransferFuseRecipientNotGranted(data_.to);
        uint256 cap = Sub.capOf(data_.token);
        if (cap == 0) revert CurveYieldErc20TransferFuseCapNotGranted(data_.token);
        if (cap > ABSOLUTE_MAX_PER_CALL) cap = ABSOLUTE_MAX_PER_CALL;
        if (data_.amount > cap) revert CurveYieldErc20TransferFuseAboveCap(data_.amount, cap);
        sent_ = IERC20(data_.token).balanceOf(address(this));
        if (sent_ > data_.amount) sent_ = data_.amount;
        if (sent_ == 0) return 0;
        IERC20(data_.token).safeTransfer(data_.to, sent_);
        emit CurveYieldErc20TransferFuseEnter(VERSION, data_.token, data_.to, sent_);
    }

    /// @dev Inputs: 0 token, 1 recipient, 2 amount. Output 0: the amount sent.
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        uint256 sent = enter(CurveYieldErc20TransferFuseEnterData({
            token: TypeConversionLib.toAddress(inputs[0]),
            to: TypeConversionLib.toAddress(inputs[1]),
            amount: TypeConversionLib.toUint256(inputs[2])
        }));
        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(sent);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    function exitTransient() external pure {
        revert CurveYieldErc20TransferFuseExitNotSupported();
    }

    function exit(bytes calldata) external pure {
        revert CurveYieldErc20TransferFuseExitNotSupported();
    }
}
