// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title CurveYieldSubstrateTypes
/// @notice One registry for the typed entries of the substrate-only market (the cyavKAT vault: 54) shared by every
/// CurveYield generic fuse: `bytes32(type << 160 | address)`. Types are unique across fuses so an entry granted for one
/// purpose can never be read as another (e.g. a transfer token as a position reader). Type 0 = plain addresses
/// (IPOR convention; the vKAT fuses' escrow / NFT / gauges).
library CurveYieldSubstrateTypes {
    uint256 internal constant READER = 1; // CurveYieldPositionReaderBalanceFuse
    uint256 internal constant COMPONENT = 2; // CurveYieldLoop*Fuse: collateral / borrow / flash / swap fuses
    uint256 internal constant RECIPIENT = 3; // CurveYieldLoopCycleFuse profit legs, CurveYieldErc20TransferFuse
    uint256 internal constant HOLDER = 4; // CurveYieldHolder*Fuse
    uint256 internal constant HOOK = 5; // CurveYieldHolder*Fuse checkpoint / rebalance check
    uint256 internal constant PLANNER = 6; // CurveYieldPlannedInstantWithdrawFuse
    uint256 internal constant BASE_1271 = 7; // CurveYieldErc1271SignerFuse
    uint256 internal constant TRANSFER_TOKEN = 8; // CurveYieldErc20TransferFuse

    function encode(uint256 type_, address account_) internal pure returns (bytes32) {
        return bytes32((type_ << 160) | uint256(uint160(account_)));
    }
}
