// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";

interface ICurveYieldSushiRouterCyvbETHV1 {
    function owner() external view returns (address);
    function routeFor(address tokenIn, address tokenOut) external view returns (bytes memory);
    function routeTwapGuard(address tokenIn, address tokenOut)
        external
        view
        returns (uint32 window, uint16 maxDeviationBps, bool configured);
    function setRoute(address tokenIn, address tokenOut, bytes calldata path) external;
    function setRouteFeeBps(address tokenIn, address tokenOut, uint16 feeBps) external;
    function setRouteTwapGuard(address tokenIn, address tokenOut, uint32 window, uint16 maxDeviationBps) external;
}

interface ISafeCyvbETHV1 {
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

/// @title ConfigureCyvbEthRoutes_v1
/// @notice Installs the CurveYield-router routes required by cyvbETH on Katana.
/// @dev Reuses the live cyvbWBTC fxUSD/vbUSDC route and adds only the verified ETH-side Sushi V3 routes.
contract ConfigureCyvbEthRoutes_v1 is Script {
    uint256 internal constant KATANA_CHAIN_ID = 747474;

    ICurveYieldSushiRouterCyvbETHV1 internal constant ROUTER =
        ICurveYieldSushiRouterCyvbETHV1(0x01F9894f92ea9224fECc8C35482E20a05De13582);
    ISafeCyvbETHV1 internal constant SAFE =
        ISafeCyvbETHV1(0x47623C62f281807D615eeb4A2CEee9d97F9D3C49);

    address internal constant FXUSD = 0x4c03ff0f44A55e7098a09016E02a01d3cdC2FDF9;
    address internal constant VBUSDC = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36;
    address internal constant VBETH = 0xEE7D8BCFb72bC1880D0Cf19822eB0A2e6577aB62;
    address internal constant WEETH = 0x9893989433e7a383Cb313953e4c2365107dc19a7;

    uint32 internal constant TWAP_WINDOW = 15 minutes;
    uint16 internal constant MAX_TWAP_DEVIATION_BPS = 200;

    // Sushi V3 fxUSD/vbUSDC 0.01% pool:
    // 0x2d43e7931329dbb709f33d7049c937c6794bae10
    bytes internal constant FXUSD_TO_VBUSDC =
        hex"4c03ff0f44a55e7098a09016e02a01d3cdc2fdf9000064203a662b0bd271a6ed5a60edfbd04bfce608fd36";
    bytes internal constant VBUSDC_TO_FXUSD =
        hex"203a662b0bd271a6ed5a60edfbd04bfce608fd360000644c03ff0f44a55e7098a09016e02a01d3cdc2fdf9";

    // Sushi V3 vbUSDC/vbETH 0.05% pool:
    // 0x2A2C512beAA8eB15495726C235472D82EFFB7A6B
    bytes internal constant VBUSDC_TO_VBETH =
        hex"203a662b0bd271a6ed5a60edfbd04bfce608fd360001f4ee7d8bcfb72bc1880d0cf19822eb0a2e6577ab62";

    // Sushi V3 vbETH/weETH 0.05% pool:
    // 0xdfc0ba24be7f93bf1a9401635815ece4cc579282
    bytes internal constant VBETH_TO_WEETH =
        hex"ee7d8bcfb72bc1880d0cf19822eb0a2e6577ab620001f49893989433e7a383cb313953e4c2365107dc19a7";
    bytes internal constant WEETH_TO_VBETH =
        hex"9893989433e7a383cb313953e4c2365107dc19a70001f4ee7d8bcfb72bc1880d0cf19822eb0a2e6577ab62";

    function run() external {
        require(block.chainid == KATANA_CHAIN_ID, "not Katana");
        require(ROUTER.owner() == address(SAFE), "wrong router owner");
        require(SAFE.getThreshold() == 1, "Safe threshold != 1");

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(privateKey);
        require(SAFE.isOwner(signer), "signer not Safe owner");

        bytes memory prevalidatedSignature =
            abi.encodePacked(uint256(uint160(signer)), uint256(0), uint8(1));

        vm.startBroadcast(privateKey);

        _configure(FXUSD, VBUSDC, FXUSD_TO_VBUSDC, prevalidatedSignature);
        _configure(VBUSDC, FXUSD, VBUSDC_TO_FXUSD, prevalidatedSignature);
        _configure(VBUSDC, VBETH, VBUSDC_TO_VBETH, prevalidatedSignature);
        _configure(VBETH, WEETH, VBETH_TO_WEETH, prevalidatedSignature);
        _configure(WEETH, VBETH, WEETH_TO_VBETH, prevalidatedSignature);

        vm.stopBroadcast();

        _verify(FXUSD, VBUSDC, FXUSD_TO_VBUSDC);
        _verify(VBUSDC, FXUSD, VBUSDC_TO_FXUSD);
        _verify(VBUSDC, VBETH, VBUSDC_TO_VBETH);
        _verify(VBETH, WEETH, VBETH_TO_WEETH);
        _verify(WEETH, VBETH, WEETH_TO_VBETH);
    }

    function _configure(
        address tokenIn_,
        address tokenOut_,
        bytes memory path_,
        bytes memory signature_
    ) private {
        _safeExec(
            abi.encodeCall(ICurveYieldSushiRouterCyvbETHV1.setRoute, (tokenIn_, tokenOut_, path_)),
            signature_
        );
        _safeExec(
            abi.encodeCall(ICurveYieldSushiRouterCyvbETHV1.setRouteFeeBps, (tokenIn_, tokenOut_, uint16(0))),
            signature_
        );
        _safeExec(
            abi.encodeCall(
                ICurveYieldSushiRouterCyvbETHV1.setRouteTwapGuard,
                (tokenIn_, tokenOut_, TWAP_WINDOW, MAX_TWAP_DEVIATION_BPS)
            ),
            signature_
        );
    }

    function _verify(address tokenIn_, address tokenOut_, bytes memory expected_) private view {
        require(
            keccak256(ROUTER.routeFor(tokenIn_, tokenOut_)) == keccak256(expected_),
            "route mismatch"
        );
        (uint32 window, uint16 deviation, bool configured) = ROUTER.routeTwapGuard(tokenIn_, tokenOut_);
        require(configured, "TWAP guard missing");
        require(window == TWAP_WINDOW, "TWAP window wrong");
        require(deviation == MAX_TWAP_DEVIATION_BPS, "TWAP deviation wrong");
    }

    function _safeExec(bytes memory data_, bytes memory signature_) private {
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
        require(ok, "Safe exec failed");
    }
}
