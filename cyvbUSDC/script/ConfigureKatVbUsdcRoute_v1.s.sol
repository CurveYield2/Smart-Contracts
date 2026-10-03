// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";

interface ICurveYieldSushiV3FeeRouterRouteV1 {
    function owner() external view returns (address);
    function routeFor(address tokenIn, address tokenOut) external view returns (bytes memory);
    function routeTwapGuard(address tokenIn, address tokenOut)
        external view returns (uint32 window, uint16 maxDeviationBps, bool configured);

    function setRoute(address tokenIn, address tokenOut, bytes calldata path) external;
    function setRouteFeeBps(address tokenIn, address tokenOut, uint16 feeBps) external;
    function setRouteTwapGuard(address tokenIn, address tokenOut, uint32 window, uint16 maxDeviationBps) external;
}

interface ISafeRouteV1 {
    function isOwner(address account) external view returns (bool);
    function getThreshold() external view returns (uint256);

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);
}

/// @title ConfigureKatVbUsdcRoute_v1
/// @notice Adds the direct Sushi V3 KAT -> vbUSDC 0.05% route to the existing
///         CurveYieldSushiV3FeeRouter used by the reference Katana vault.
/// @dev Router ownership is the CurveYield Safe. This follows the same prevalidated
///      threshold-1 Safe execution pattern already used by the reference-vault scripts.
///
///      Route encoding is standard Uniswap/Sushi V3:
///      tokenIn (20 bytes) | fee (3 bytes) | tokenOut (20 bytes)
///
///      fee=500 = 0.05% = 0x0001f4.
contract ConfigureKatVbUsdcRoute_v1 is Script {
    uint256 internal constant KATANA_CHAIN_ID = 747474;

    ICurveYieldSushiV3FeeRouterRouteV1 internal constant ROUTER =
        ICurveYieldSushiV3FeeRouterRouteV1(0x01F9894f92ea9224fECc8C35482E20a05De13582);

    ISafeRouteV1 internal constant SAFE =
        ISafeRouteV1(0x47623C62f281807D615eeb4A2CEee9d97F9D3C49);

    address internal constant KAT = 0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d;
    address internal constant VB_USDC = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36;

    uint32 internal constant TWAP_WINDOW = 15 minutes;
    uint16 internal constant MAX_TWAP_DEVIATION_BPS = 200;

    // Direct Sushi V3 KAT/vbUSDC 0.05% path.
    bytes internal constant KAT_TO_VBUSDC_PATH =
        hex"7f1f4b4b29f5058fa32cc7a97141b8d7e5abdc2d0001f4203a662b0bd271a6ed5a60edfbd04bfce608fd36";

    function run() external {
        require(block.chainid == KATANA_CHAIN_ID, "not Katana");
        require(ROUTER.owner() == address(SAFE), "router owner != CurveYield Safe");
        require(SAFE.getThreshold() == 1, "Safe threshold != 1");

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(privateKey);
        require(SAFE.isOwner(signer), "signer is not Safe owner");

        bytes memory prevalidatedSignature =
            abi.encodePacked(uint256(uint160(signer)), uint256(0), uint8(1));

        vm.startBroadcast(privateKey);

        _safeExec(
            abi.encodeCall(
                ICurveYieldSushiV3FeeRouterRouteV1.setRoute,
                (KAT, VB_USDC, KAT_TO_VBUSDC_PATH)
            ),
            prevalidatedSignature
        );

        // The 70/30 reward split should be the only CurveYield split applied to this route.
        // Explicit 0-bps route override prevents the router's global fee from taking an
        // additional cut before the reward fuse performs the 70/30 split.
        _safeExec(
            abi.encodeCall(
                ICurveYieldSushiV3FeeRouterRouteV1.setRouteFeeBps,
                (KAT, VB_USDC, uint16(0))
            ),
            prevalidatedSignature
        );

        // Match the tightened reference-vault router protection: 15-minute TWAP, 2% deviation.
        _safeExec(
            abi.encodeCall(
                ICurveYieldSushiV3FeeRouterRouteV1.setRouteTwapGuard,
                (KAT, VB_USDC, TWAP_WINDOW, MAX_TWAP_DEVIATION_BPS)
            ),
            prevalidatedSignature
        );

        vm.stopBroadcast();

        bytes memory installedRoute = ROUTER.routeFor(KAT, VB_USDC);
        require(
            keccak256(installedRoute) == keccak256(KAT_TO_VBUSDC_PATH),
            "route mismatch"
        );

        (uint32 window, uint16 deviation, bool configured) = ROUTER.routeTwapGuard(KAT, VB_USDC);
        require(configured, "TWAP guard missing");
        require(window == TWAP_WINDOW, "TWAP window mismatch");
        require(deviation == MAX_TWAP_DEVIATION_BPS, "TWAP deviation mismatch");
    }

    function _safeExec(bytes memory data_, bytes memory signature_) internal {
        bool ok = SAFE.execTransaction(
            address(ROUTER),
            0,
            data_,
            0,
            0,
            0,
            0,
            address(0),
            payable(address(0)),
            signature_
        );
        require(ok, "Safe execTransaction failed");
    }
}
