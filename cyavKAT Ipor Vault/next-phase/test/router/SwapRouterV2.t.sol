// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CurveYieldSwapRouterV2, CyHop} from "../../src/router/CurveYieldSwapRouterV2.sol";
import {CurveYieldConfigKeys as K} from "../../src/governance/CurveYieldGateConfig.sol";
import {MockErc20, MockConfigGate, MockBalVault, MockPoolHook, MockPermit2, MockBalRouter} from "./SwapRouterMocks.sol";

/// @notice Unit tests of the pure / Balancer-venue parts of CurveYieldSwapRouterV2 (SWAP_ROUTING_SPEC), with mock pools:
/// the flat 0.1% fee, the protected minimum (gate-read protection bps, chained hop by hop), route set/remove, and owner
/// gating. The Sushi V3 venue (CREATE2 pool-address prediction against the live factory) is exercised on the fork suite,
/// not here: the router's own `_sushiPoolFor` must match the real factory's `getPool`, which only a real deployment can
/// satisfy meaningfully.
contract SwapRouterV2Test is Test {
    uint256 constant BPS = 10_000;
    uint8 constant BALANCER = 2;

    CurveYieldSwapRouterV2 router;
    MockConfigGate gate;
    MockErc20 tokenIn;
    MockErc20 tokenOut;
    MockBalVault balVault;
    MockPoolHook hook;
    MockPermit2 permit2;
    MockBalRouter balRouter;
    address pool = address(0xBEEF);
    address owner = makeAddr("owner");
    address feeRecipient = makeAddr("feeRecipient");
    address sushiFactory = makeAddr("sushiFactory");
    address user = makeAddr("user");
    address recipient = makeAddr("recipient");

    function setUp() public {
        gate = new MockConfigGate();
        gate.set(K.ROUTER_PROTECTION_BPS, 100); // 1%
        gate.set(K.ROUTER_TWAP_WINDOW, 1800);
        router = new CurveYieldSwapRouterV2(owner, address(gate), feeRecipient, sushiFactory, bytes32(uint256(1)));

        tokenIn = new MockErc20("IN");
        tokenOut = new MockErc20("OUT");
        balVault = new MockBalVault();
        hook = new MockPoolHook();
        permit2 = new MockPermit2();
        balRouter = new MockBalRouter(permit2);
        balVault.setHook(pool, address(hook));

        vm.startPrank(owner);
        router.setBalancer(address(balVault), address(balRouter));
        CyHop[] memory hops = new CyHop[](1);
        hops[0] = CyHop({venue: BALANCER, tokenIn: address(tokenIn), tokenOut: address(tokenOut), pool: pool, fee: 0});
        router.setRoute(address(tokenIn), address(tokenOut), hops);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- construction

    function test_constructor_setsFeeRecipientAndSushiFactory_rejectsZero() public {
        assertEq(router.feeRecipient(), feeRecipient);
        assertEq(router.SUSHI_FACTORY(), sushiFactory);
        vm.expectRevert(CurveYieldSwapRouterV2.BadRoute.selector);
        new CurveYieldSwapRouterV2(owner, address(gate), address(0), sushiFactory, bytes32(0));
        vm.expectRevert(CurveYieldSwapRouterV2.BadRoute.selector);
        new CurveYieldSwapRouterV2(owner, address(gate), feeRecipient, address(0), bytes32(0));
    }

    // ---------------------------------------------------------------- owner gating

    function test_setFeeRecipient_onlyOwner_rejectsZero() public {
        vm.prank(user);
        vm.expectRevert();
        router.setFeeRecipient(user);
        vm.startPrank(owner);
        vm.expectRevert(CurveYieldSwapRouterV2.BadRecipient.selector);
        router.setFeeRecipient(address(0));
        router.setFeeRecipient(user);
        vm.stopPrank();
        assertEq(router.feeRecipient(), user);
    }

    function test_setBalancer_onlyOwner_onceOnly_rejectsZero() public {
        vm.prank(user);
        vm.expectRevert();
        router.setBalancer(address(1), address(2));
        vm.startPrank(owner);
        vm.expectRevert(CurveYieldSwapRouterV2.BadRoute.selector); // already set in setUp
        router.setBalancer(address(1), address(2));
        vm.stopPrank();

        CurveYieldSwapRouterV2 fresh = new CurveYieldSwapRouterV2(owner, address(gate), feeRecipient, sushiFactory, bytes32(0));
        vm.startPrank(owner);
        vm.expectRevert(CurveYieldSwapRouterV2.BadRoute.selector);
        fresh.setBalancer(address(0), address(2));
        vm.expectRevert(CurveYieldSwapRouterV2.BadRoute.selector);
        fresh.setBalancer(address(1), address(0));
        vm.stopPrank();
    }

    function test_setRoute_onlyOwner() public {
        CyHop[] memory hops = new CyHop[](1);
        hops[0] = CyHop({venue: BALANCER, tokenIn: address(tokenIn), tokenOut: address(tokenOut), pool: pool, fee: 0});
        vm.prank(user);
        vm.expectRevert();
        router.setRoute(address(tokenIn), address(tokenOut), hops);
        vm.prank(user);
        vm.expectRevert();
        router.removeRoute(address(tokenIn), address(tokenOut));
    }

    // ---------------------------------------------------------------- route validation

    function test_setRoute_rejectsBadChaining_selfRoute_emptyHops_unhookedBalancerPool() public {
        MockErc20 mid = new MockErc20("MID");
        CyHop[] memory hops = new CyHop[](2);
        hops[0] = CyHop({venue: BALANCER, tokenIn: address(tokenIn), tokenOut: address(mid), pool: pool, fee: 0});
        hops[1] = CyHop({venue: BALANCER, tokenIn: address(tokenOut), tokenOut: address(mid), pool: pool, fee: 0}); // wrong tokenIn
        vm.startPrank(owner);
        vm.expectRevert(CurveYieldSwapRouterV2.BadRoute.selector);
        router.setRoute(address(tokenIn), address(mid), hops);

        vm.expectRevert(CurveYieldSwapRouterV2.BadRoute.selector);
        router.setRoute(address(tokenIn), address(tokenIn), new CyHop[](1)); // tokenIn == tokenOut

        vm.expectRevert(CurveYieldSwapRouterV2.BadRoute.selector);
        router.setRoute(address(tokenIn), address(mid), new CyHop[](0)); // no hops

        CyHop[] memory unhooked = new CyHop[](1);
        unhooked[0] = CyHop({venue: BALANCER, tokenIn: address(tokenIn), tokenOut: address(mid), pool: address(0x1234), fee: 0});
        vm.expectRevert(CurveYieldSwapRouterV2.BadRoute.selector);
        router.setRoute(address(tokenIn), address(mid), unhooked); // pool has no registered hook

        CyHop[] memory badVenue = new CyHop[](1);
        badVenue[0] = CyHop({venue: 0, tokenIn: address(tokenIn), tokenOut: address(mid), pool: pool, fee: 0});
        vm.expectRevert(CurveYieldSwapRouterV2.BadRoute.selector);
        router.setRoute(address(tokenIn), address(mid), badVenue);
        vm.stopPrank();
    }

    function test_removeRoute_andRouteHops() public {
        CyHop[] memory got = router.routeHops(address(tokenIn), address(tokenOut));
        assertEq(got.length, 1);
        assertEq(got[0].pool, pool);
        vm.prank(owner);
        router.removeRoute(address(tokenIn), address(tokenOut));
        assertEq(router.routeHops(address(tokenIn), address(tokenOut)).length, 0);
    }

    // ---------------------------------------------------------------- protection() / quotes

    function test_protection_readsBpsAndWindowFromTheGate() public {
        (uint256 bps, uint32 window) = router.protection();
        assertEq(bps, 100);
        assertEq(window, 1800);
        gate.set(K.ROUTER_PROTECTION_BPS, 250);
        gate.set(K.ROUTER_TWAP_WINDOW, 60);
        (bps, window) = router.protection();
        assertEq(bps, 250);
        assertEq(window, 60);
    }

    function test_protectedQuote_feeThenProtection_chainedHopByHop() public {
        hook.setExpectedOut(1_000_000);
        (uint256 expectedNet, uint256 minimumNet) = router.protectedQuote(address(tokenIn), address(tokenOut), 500);
        uint256 wantExpected = 1_000_000 * (BPS - 10) / BPS; // 0.1% fee
        uint256 wantMin = wantExpected * (BPS - 100) / BPS; // 1% protection (gate)
        assertEq(expectedNet, wantExpected);
        assertEq(minimumNet, wantMin);
        assertEq(router.twapMinimumOut(address(tokenIn), address(tokenOut), 500), wantMin);
    }

    function test_protectedQuote_missingRoute_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(CurveYieldSwapRouterV2.RouteMissing.selector, address(tokenOut), address(tokenIn)));
        router.protectedQuote(address(tokenOut), address(tokenIn), 1);
    }

    // ---------------------------------------------------------------- swap

    function _fundUser(uint256 amount) internal {
        tokenIn.mint(user, amount);
        vm.prank(user);
        tokenIn.approve(address(router), amount);
    }

    function test_swapExactInput_flatFeeToFeeRecipient_restToRecipient() public {
        hook.setExpectedOut(1_000_000);
        balRouter.setNextOut(1_000_000); // the mock venue pays exactly the hook's "expected" amount
        _fundUser(500);

        vm.prank(user);
        uint256 netOut = router.swapExactInput(address(tokenIn), address(tokenOut), 500, 0, recipient, block.timestamp);

        uint256 fee = 1_000_000 * 10 / BPS;
        assertEq(netOut, 1_000_000 - fee);
        assertEq(tokenOut.balanceOf(feeRecipient), fee);
        assertEq(tokenOut.balanceOf(recipient), 1_000_000 - fee);
        assertEq(tokenIn.balanceOf(address(router)), 0, "input left stuck in the router");
        assertEq(tokenIn.balanceOf(address(balRouter)), 500);
    }

    function test_swapExactInput_minOut_isMaxOfProtectedAndCallerMinimum() public {
        hook.setExpectedOut(1_000_000);
        balRouter.setNextOut(1_000_000);
        _fundUser(500);
        uint256 fee = 1_000_000 * 10 / BPS;
        uint256 net = 1_000_000 - fee;
        (, uint256 protectedMin) = router.protectedQuote(address(tokenIn), address(tokenOut), 500);
        assertLt(protectedMin, net, "test setup: protected min should be below the actual net for this case");

        // caller minimum ABOVE the protected minimum but still <= actual net: must pass, using the caller's minimum
        vm.prank(user);
        router.swapExactInput(address(tokenIn), address(tokenOut), 500, protectedMin + 1, recipient, block.timestamp);

        // caller minimum ABOVE the actual net output: must revert TooLittleOut even though the protected min was fine
        _fundUser(500);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldSwapRouterV2.TooLittleOut.selector, net, net + 1));
        router.swapExactInput(address(tokenIn), address(tokenOut), 500, net + 1, recipient, block.timestamp);
    }

    function test_swapExactInput_belowProtectedMinimum_reverts() public {
        hook.setExpectedOut(1_000_000);
        balRouter.setNextOut(1); // the venue actually pays far less than the TWAP-expected amount (manipulated pool)
        _fundUser(500);
        (, uint256 protectedMin) = router.protectedQuote(address(tokenIn), address(tokenOut), 500);
        uint256 actualNet = 1 - 1 * 10 / BPS;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldSwapRouterV2.TooLittleOut.selector, actualNet, protectedMin));
        router.swapExactInput(address(tokenIn), address(tokenOut), 500, 0, recipient, block.timestamp);
    }

    function test_swapExactInput_expiredDeadline_reverts() public {
        _fundUser(500);
        vm.warp(1000);
        vm.prank(user);
        vm.expectRevert(CurveYieldSwapRouterV2.Expired.selector);
        router.swapExactInput(address(tokenIn), address(tokenOut), 500, 0, recipient, 999);
    }

    function test_swapExactInput_zeroAmount_reverts() public {
        vm.prank(user);
        vm.expectRevert(CurveYieldSwapRouterV2.ZeroAmount.selector);
        router.swapExactInput(address(tokenIn), address(tokenOut), 0, 0, recipient, block.timestamp);
    }

    function test_swapExactInput_badRecipient_reverts() public {
        _fundUser(500);
        vm.startPrank(user);
        vm.expectRevert(CurveYieldSwapRouterV2.BadRecipient.selector);
        router.swapExactInput(address(tokenIn), address(tokenOut), 500, 0, address(0), block.timestamp);
        vm.expectRevert(CurveYieldSwapRouterV2.BadRecipient.selector);
        router.swapExactInput(address(tokenIn), address(tokenOut), 500, 0, address(router), block.timestamp);
        vm.stopPrank();
    }

    function test_swapExactInput_missingRoute_reverts() public {
        _fundUser(500);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(CurveYieldSwapRouterV2.RouteMissing.selector, address(tokenOut), address(tokenIn)));
        router.swapExactInput(address(tokenOut), address(tokenIn), 500, 0, recipient, block.timestamp);
    }

    function test_swapExactInput_feeZero_skipsTransferButStillPaysNet() public {
        hook.setExpectedOut(1); // amount so small the 0.1% fee floors to 0
        balRouter.setNextOut(1);
        _fundUser(500);
        vm.prank(user);
        uint256 netOut = router.swapExactInput(address(tokenIn), address(tokenOut), 500, 0, recipient, block.timestamp);
        assertEq(netOut, 1);
        assertEq(tokenOut.balanceOf(feeRecipient), 0);
        assertEq(tokenOut.balanceOf(recipient), 1);
    }
}
