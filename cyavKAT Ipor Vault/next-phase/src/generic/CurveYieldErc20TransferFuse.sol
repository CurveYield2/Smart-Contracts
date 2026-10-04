// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";

struct Erc20TransferEnterData {
    address token;
    address to;
    uint256 amount;
}

/// @title CurveYieldErc20TransferFuse (generic, IPOR style)
/// @notice Pays `amount` of `token` from the vault to `to`. Both must be granted substrates of SUBSTRATE_MARKET_ID,
/// typed so a token can never be used as a recipient or vice versa:
///   substrate = bytes32(uint256(type) << 160 | uint160(address)), type 8 = TOKEN, 3 = RECIPIENT.
/// Amounts, rates and caps are the caller's policy (e.g. an executor paying a bounded reward, a profit splitter).
contract CurveYieldErc20TransferFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    uint256 public constant TYPE_TOKEN = 8; // substrate-market type registry: see CurveYieldSubstrateTypes
    uint256 public constant TYPE_RECIPIENT = 3; // shared with the loop fuses' profit recipients

    address public immutable VERSION;
    uint256 public immutable override MARKET_ID;
    uint256 public immutable SUBSTRATE_MARKET_ID;

    event Erc20Transferred(address version, address token, address to, uint256 amount);

    error NotGranted(uint256 substrateType, address account);

    constructor(uint256 marketId_, uint256 substrateMarketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        SUBSTRATE_MARKET_ID = substrateMarketId_;
    }

    function substrate(uint256 type_, address account_) public pure returns (bytes32) {
        return bytes32((type_ << 160) | uint256(uint160(account_)));
    }

    function enter(Erc20TransferEnterData memory data_) external {
        if (data_.amount == 0) return;
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(SUBSTRATE_MARKET_ID, substrate(TYPE_TOKEN, data_.token))) {
            revert NotGranted(TYPE_TOKEN, data_.token);
        }
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(SUBSTRATE_MARKET_ID, substrate(TYPE_RECIPIENT, data_.to))) {
            revert NotGranted(TYPE_RECIPIENT, data_.to);
        }
        IERC20(data_.token).safeTransfer(data_.to, data_.amount);
        emit Erc20Transferred(VERSION, data_.token, data_.to, data_.amount);
    }
}
