// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";

interface ICurveYieldSushiRouterCyvbWBTCV1 {
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

interface ISafeCyvbWBTCV1 {
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

/// @title ConfigureCyvbWbtcRoutes_v1
/// @notice Installs the three existing-pool routes required by cyvbWBTC on the existing CurveYield router.
contract ConfigureCyvbWbtcRoutes_v1 is Script {
    uint256 internal constant KATANA_CHAIN_ID = 747474;

    ICurveYieldSushiRouterCyvbWBTCV1 internal constant ROUTER =
        ICurveYieldSushiRouterCyvbWBTCV1(0x01F9894f92ea9224fECc8C35482E20a05De13582);
    ISafeCyvbWBTCV1 internal constant SAFE =
        ISafeCyvbWBTCV1(0x47623C62f281807D615eeb4A2CEee9d97F9D3C49);

    address internal constant FXUSD = 0x1364b238C668A2dec1294174e4798E8c09979f86;
    address internal constant VBUSDC = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36;
    address internal constant VBWBTC = 0x0913DA6Da4b42f538B445599b46Bb4622342Cf52;

    uint32 internal constant TWAP_WINDOW = 15 minutes;
    uint16 internal constant MAX_TWAP_DEVIATION_BPS = 200;

    // Sushi V3 fxUSD/vbUSDC 0.01% pool:
    // 0xe1578cEF06331d77bC99273d5f1aF48eC2de92db
    bytes internal constant FXUSD_TO_VBUSDC =
        hex"1364b238c668a2dec1294174e4798e8c09979f86000064203a662b0bd271a6ed5a60edfbd04bfce608fd36";
    bytes internal constant VBUSDC_TO_FXUSD =
        hex"203a662b0bd271a6ed5a60edfbd04bfce608fd360000641364b238c668a2dec1294174e4798e8c09979f86";

    // Deepest observed direct Sushi V3 vbUSDC/vbWBTC pool is the 0.05% tier:
    // 0x744676B3CeD942D78F9b8e9cd22246Db5c32395c
    bytes internal constant VBUSDC_TO_VBWBTC =
        hex"203a662b0bd271a6ed5a60edfbd04bfce608fd360001f40913da6da4b42f538b445599b46bb4622342cf52";

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
        _configure(VBUSDC, VBWBTC, VBUSDC_TO_VBWBTC, prevalidatedSignature);

        vm.stopBroadcast();

        _verify(FXUSD, VBUSDC, FXUSD_TO_VBUSDC);
        _verify(VBUSDC, FXUSD, VBUSDC_TO_FXUSD);
        _verify(VBUSDC, VBWBTC, VBUSDC_TO_VBWBTC);
    }

    function _configure(
        address tokenIn_,
        address tokenOut_,
        bytes memory path_,
        bytes memory signature_
    ) private {
        _safeExec(
            abi.encodeCall(ICurveYieldSushiRouterCyvbWBTCV1.setRoute, (tokenIn_, tokenOut_, path_)),
            signature_
        );
        _safeExec(
            abi.encodeCall(ICurveYieldSushiRouterCyvbWBTCV1.setRouteFeeBps, (tokenIn_, tokenOut_, uint16(0))),
            signature_
        );
        _safeExec(
            abi.encodeCall(
                ICurveYieldSushiRouterCyvbWBTCV1.setRouteTwapGuard,
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
