// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {Test} from "forge-std/Test.sol";
import {Id} from "@morpho-blue/interfaces/IMorpho.sol";
import {YearnMorphoMarketChild_v2} from "../contracts/YearnMorphoMarketChild_v2.sol";

interface ILiveFeeRouterKatanaV2 {
    function routeFor(address tokenIn, address tokenOut) external view returns (bytes memory);
    function routeTwapGuard(address tokenIn, address tokenOut)
        external view returns (uint32 window, uint16 maxDeviationBps, bool configured);
}

interface IERC20LiveForkV2 {
    function balanceOf(address) external view returns (uint256);
}

/// @notice Exercises the actual SAME cyavKAT fee-router contract and real
///         Morpho Blue market on an isolated funded Katana fork.
///         No IPOR vault writes; no Katana production transaction broadcast.
contract YearnMorphoRouterKatanaFork_v2 is Test {
    address constant ROUTER = 0x01F9894f92ea9224fECc8C35482E20a05De13582;
    address constant KAT = 0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d;
    address constant VBUSDC = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36;
    address constant MORPHO = 0xD50F2DffFd62f94Ee4AEd9ca05C61d0753268aBc;
    address constant MERKL = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;
    Id internal constant MARKET = Id.wrap(0xbd48214a2f12e951da20ad0b8fd83b611c693b5bbaa280b68ba4075678f2a138);
    uint256 constant KAT_AMOUNT = 1 ether;

    function setUp() public {
        vm.createSelectFork(vm.envString("KATANA_RPC_URL"));
    }

    function testLiveCyavKatRouterRouteAndGuard() public view {
        ILiveFeeRouterKatanaV2 router = ILiveFeeRouterKatanaV2(ROUTER);
        assertGt(router.routeFor(KAT, VBUSDC).length, 0, "missing live KAT-vbUSDC route");
        (uint32 window, uint16 deviation, bool configured) = router.routeTwapGuard(KAT, VBUSDC);
        assertTrue(configured, "TWAP guard must be set on live router");
        assertGt(window, 0);
        assertLe(deviation, 2000);
    }

    function testLiveRouterSwapCompoundsNetVbusdcIntoMorpho() public {
        YearnMorphoMarketChild_v2 child = new YearnMorphoMarketChild_v2(
            VBUSDC, "Yearn live router integration child", MORPHO, MARKET,
            address(this), KAT, ROUTER, MERKL
        );
        // Model a successful Merkl payout. No fake price/route/oracle: the
        // actual deployed router pulls KAT and trades on real forked pools.
        deal(KAT, address(child), KAT_AMOUNT, true);
        assertEq(IERC20LiveForkV2(KAT).balanceOf(address(child)), KAT_AMOUNT);
        uint256 totalBefore = child.suppliedAssets();

        address[] memory users = new address[](0);
        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        bytes32[][] memory proofs = new bytes32[][](0);

        uint256 received = child.claimAndCompound(
            users, tokens, amounts, proofs, 1, block.timestamp + 300
        );

        assertGt(received, 0, "router did not deliver vbUSDC");
        assertEq(IERC20LiveForkV2(KAT).balanceOf(address(child)), 0, "KAT unswapped");
        assertEq(IERC20LiveForkV2(VBUSDC).balanceOf(address(child)), 0, "vbUSDC not compounded");
        assertGe(child.suppliedAssets(), totalBefore + received, "Morpho position not increased");
    }
}
