// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionMarkets} from "contracts/libraries/IporFusionMarkets.sol";

/// @title CurveYieldSubstrateLib
/// @notice Typed substrates of the CurveYield custom fuses (IPOR_FUSE_CONFORMANCE_SPEC §1.1 rule 5, R4). The type is the
/// top byte, the payload the lower 248 bits (`type << 248 | payload`), the layout of IPOR's UniversalTokenSwapper
/// substrates. Type codes are unique across our fuses, so an entry granted for one purpose can never be read as another.
/// Until IPOR assigns market ids, the entries live in `ZERO_BALANCE_MARKET` (exception E6): the market is valued by
/// IPOR's `ZeroBalanceFuse` and no official fuse reads its substrates. Market 7 can never hold typed entries (F13).
library CurveYieldSubstrateLib {
    /// @dev CurveYieldErc20TransferFuse: payload = token
    uint256 internal constant TRANSFER_TOKEN = 0x10;
    /// @dev CurveYieldErc20TransferFuse: payload = recipient
    uint256 internal constant TRANSFER_RECIPIENT = 0x11;
    /// @dev CurveYieldErc20TransferFuse: payload = cap (88 bits, token base units) << 160 | token
    uint256 internal constant TRANSFER_CAP = 0x12;
    /// @dev CurveYieldBundleGuardFuse: payload = ceiling of the share-price drop / bounded loss, bps
    uint256 internal constant GUARD_MAX_PPS_DROP = 0x20;
    /// @dev CurveYieldBundleGuardFuse: payload = ceiling LTV bps (16 bits) << 160 | low 160 bits of the Morpho market id
    uint256 internal constant GUARD_MAX_LTV = 0x21;
    /// @dev CurveYieldErc1271InstallFuse: payload = ERC-1271 base
    uint256 internal constant BASE_1271 = 0x30;

    /// @notice The market that holds the typed entries until IPOR assigns ids (E6).
    uint256 internal constant CONFIG_MARKET = IporFusionMarkets.ZERO_BALANCE_MARKET;

    uint256 private constant PAYLOAD_MASK = type(uint248).max;

    error CurveYieldSubstratePayloadTooLarge(uint256 payload);

    function encode(uint256 type_, uint256 payload_) internal pure returns (bytes32) {
        if (payload_ > PAYLOAD_MASK) revert CurveYieldSubstratePayloadTooLarge(payload_);
        return bytes32((type_ << 248) | payload_);
    }

    function encodeAddress(uint256 type_, address account_) internal pure returns (bytes32) {
        return bytes32((type_ << 248) | uint256(uint160(account_)));
    }

    /// @dev payload = cap << 160 | token, cap < 2^88
    function encodeCap(address token_, uint256 cap_) internal pure returns (bytes32) {
        if (cap_ >= (1 << 88)) revert CurveYieldSubstratePayloadTooLarge(cap_);
        return bytes32((TRANSFER_CAP << 248) | (cap_ << 160) | uint256(uint160(token_)));
    }

    /// @dev payload = ltvBps << 160 | low 160 bits of the market id
    function encodeMaxLtv(bytes32 morphoMarketId_, uint256 ltvBps_) internal pure returns (bytes32) {
        return bytes32((GUARD_MAX_LTV << 248) | (ltvBps_ << 160) | (uint256(morphoMarketId_) & type(uint160).max));
    }

    function typeOf(bytes32 substrate_) internal pure returns (uint256) {
        return uint256(substrate_) >> 248;
    }

    function payloadOf(bytes32 substrate_) internal pure returns (uint256) {
        return uint256(substrate_) & PAYLOAD_MASK;
    }

    function isGranted(uint256 type_, address account_) internal view returns (bool) {
        return PlasmaVaultConfigLib.isMarketSubstrateGranted(CONFIG_MARKET, encodeAddress(type_, account_));
    }

    /// @dev The per-call cap granted for `token_` (0 = none).
    function capOf(address token_) internal view returns (uint256 cap_) {
        bytes32[] memory subs = PlasmaVaultConfigLib.getMarketSubstrates(CONFIG_MARKET);
        for (uint256 i; i < subs.length; ++i) {
            if (typeOf(subs[i]) != TRANSFER_CAP) continue;
            uint256 p = payloadOf(subs[i]);
            if (address(uint160(p)) == token_) cap_ = p >> 160;
        }
    }

    /// @dev The share-price drop ceiling in bps (0 = none granted).
    function maxPpsDropBps() internal view returns (uint256 bps_) {
        bytes32[] memory subs = PlasmaVaultConfigLib.getMarketSubstrates(CONFIG_MARKET);
        for (uint256 i; i < subs.length; ++i) {
            if (typeOf(subs[i]) == GUARD_MAX_PPS_DROP) bps_ = payloadOf(subs[i]);
        }
    }

    /// @dev The ceiling LTV (bps) granted for a Morpho market (0 = none).
    function maxLtvBps(bytes32 morphoMarketId_) internal view returns (uint256 bps_) {
        bytes32[] memory subs = PlasmaVaultConfigLib.getMarketSubstrates(CONFIG_MARKET);
        for (uint256 i; i < subs.length; ++i) {
            if (typeOf(subs[i]) != GUARD_MAX_LTV) continue;
            uint256 p = payloadOf(subs[i]);
            if ((p & type(uint160).max) == (uint256(morphoMarketId_) & type(uint160).max)) bps_ = p >> 160;
        }
    }
}
