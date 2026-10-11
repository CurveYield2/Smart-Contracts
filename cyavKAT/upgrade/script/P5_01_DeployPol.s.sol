// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {CySets} from "../src/allocation/CurveYieldAllocationController.sol";
import {CurveYieldAllocationController} from "../src/allocation/CurveYieldAllocationController.sol";
import {CurveYieldPolController, CyPolParams, CyPolVenues, CyPolFuses} from "../src/pol/CurveYieldPolController.sol";
import {BalancerLiquidityProportionalFuse} from "contracts/fuses/balancer/BalancerLiquidityProportionalFuse.sol";
import {CurveYieldRateAwareBalancerBalanceFuse} from "../src/generic/CurveYieldRateAwareBalancerBalanceFuse.sol";
import {CurveYieldRevenueCustodyV2, CyCustodyPolVenues} from "../src/protection/CurveYieldRevenueCustodyV2.sol";
import {CySushiRoute} from "../src/pol/CurveYieldPolInterfaces.sol";

interface IVaultP51 {
    function getMarketSubstrates(uint256 marketId) external view returns (bytes32[] memory);
    function addFuses(address[] calldata fuses) external;
    function addBalanceFuse(uint256 marketId, address fuse) external;
    function grantMarketSubstrates(uint256 marketId, bytes32[] calldata substrates) external;
    function updateDependencyBalanceGraphs(uint256[] calldata marketIds, uint256[][] calldata dependencies) external;
}

interface IWmP51 {
    function setBurnOnlyFee(address account, bool enabled) external;
}

interface IProfitCustodyP51 {
    function feeRecipient() external view returns (address);
}

interface ISafeP51 {
    function execTransaction(address to, uint256 value, bytes calldata data, uint8 operation, uint256 safeTxGas,
        uint256 baseGas, uint256 gasPrice, address gasToken, address payable refundReceiver, bytes memory signatures)
        external payable returns (bool);
}

interface IGateP51 {
    function setProtectedCalls(address target, bytes4[] calldata selectors, bool isProtected) external;
    function registerAdminFeeCalls(address target, bytes4[] calldata selectors) external;
    function isFeeBearingTarget(address target) external view returns (bool);
    function isAdminFeeCall(address target, bytes4 selector) external view returns (bool);
    function isProtectedCall(address target, bytes4 selector) external view returns (bool);
    function staticSubstrates(uint256 marketId) external view returns (bytes32[] memory);
    function setStaticSubstrates(uint256 marketId, bytes32[] calldata substrates) external;
    function previewSubstrates(uint256 marketId) external view returns (bytes32[] memory);
}

/// POL (position A in the vault, position B in the revenue custody v2). Runs after P2_0x and BEFORE the governance handover
/// (P3_05), as the deployer.
///   position A (vault-owned, IPOR market 36): CurveYieldPolController (a planner) + IPOR BalancerLiquidityProportionalFuse +
///     CurveYieldRateAwareBalancerBalanceFuse (exception E2, adapted fork). Swaps go through IPOR's UniversalTokenSwapperFuse
///     (market 12) and router v2; burning held cyavKAT uses the utility fuse from P2_01. Market 36 depends on market 7 (F12).
///     No instant-withdrawal source: POL is served through withdrawal requests (B3, D6).
///   position B (off the books): held by revenue custody v2 (CurveYieldRevenueCustodyV2: the layer on top of the live loop
///     custody 0xe7D1 for everything beyond the loop) through its operator-managed POL budget.
///     Loop growth goes 100% to the ORIGINAL Profit Custody; its own configured feeRecipient payout is untouched.
///     No incoming feeder, yield feeder or external loop-profit splitter is deployed.
///   router v2: cyavKAT <-> avKAT through the POL pool, and avKAT <-> WETH Sushi routes for position B's WETH leg;
///   withdraw manager: burn-only fees for the custody.
/// Governance: existing fee authority protects POL controller admin and V2 custody owner functions.
/// No change to the live Profit Custody fee recipient or fee split is permitted in this migration.
/// Venues (created manually; optional here, set later by the owners): POL_POOL, BALANCER_VAULT, BALANCER_ROUTER, PERMIT2,
/// CY_WETH_POOL, ALPHA_VAULT. Without POL_POOL the contracts are deployed and wired but hold no venue yet.
struct CyHopP51 {
    uint8 venue;
    address tokenIn;
    address tokenOut;
    address pool;
    uint24 fee;
}

interface IRouterV2P51 {
    function owner() external view returns (address);
    function balancerVault() external view returns (address);
    function setBalancer(address vault, address router) external;
    function setRoute(address tokenIn, address tokenOut, CyHopP51[] calldata hops) external;
}

contract P5_01_DeployPol is Phase2Base {
    address internal constant FEE_SAFE = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;
    address internal constant USER_WALLET = 0x9f2B20A772246960810045905B7daccf960eE288;
    address internal constant MAIN_FEE_MANAGER = 0x11a81a7B7436CB1E8f73866AF74961cE499f5Ec6;
    address internal constant WETH = 0xEE7D8BCFb72bC1880D0Cf19822eB0A2e6577aB62;
    address internal constant USDC = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36;
    // Sushi V3 pools for the avKAT <-> WETH routes (the best-quoted route is used on every swap)
    address internal constant AVKAT_KAT_1PCT = 0x8640e1867BD563B2Ab865160E77Cb7B875243B13;
    address internal constant KAT_WETH_005 = 0xfe4E52cCf659705141E6fa5Dee01432A3e637904;
    address internal constant KAT_USDC_005 = 0x10045367E619Caae6f60CC80046c43c6cD55f629;
    address internal constant USDC_WETH_005 = 0x2A2C512beAA8eB15495726C235472D82EFFB7A6B;

    CurveYieldPolController internal controller;
    CurveYieldRateAwareBalancerBalanceFuse internal balanceFuse;
    address internal burnFuse; // CurveYieldBurnHeldSharesFuse from P2_01
    address internal liquidityFuse; // needs the CurveYield DEX router: deployed with the venues
    CurveYieldRevenueCustodyV2 internal custody;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        _requireQuestSigningV2(); // Mandatory updated Quest ERC-1271 signing layer for the V2 upgrade.
        string memory d = _readDeployments();
        CurveYieldAllocationController allocation = CurveYieldAllocationController(_addr(d, "allocation"));
        address originalFeeRecipient = IProfitCustodyP51(GROWTH_CUSTODY).feeRecipient();
        require(originalFeeRecipient != address(0), "original custody fee recipient unset");

        _start();
        address gate = _gateAddress();
        burnFuse = _addr(d, "burnHeldSharesFuse");
        controller = new CurveYieldPolController(DEPLOYER, VAULT, AVKAT, MAIN_FEE_MANAGER, gate);
        controller.setExecutor(_addr(d, "executor"));
        balanceFuse = new CurveYieldRateAwareBalancerBalanceFuse(MARKET_BALANCER);
        controller.setAdminReceiver(FEE_SAFE); // yield fee bps is in the gate (FEE class, default 10%)
        controller.setMarketRoutes(_wethToAvkat());

        address[] memory operators = new address[](3);
        (operators[0], operators[1], operators[2]) = (USER_WALLET, FEE_SAFE, vm.envOr("POL_OPERATOR", DEPLOYER));
        custody = new CurveYieldRevenueCustodyV2(
            DEPLOYER, originalFeeRecipient, VAULT, WETH, MERKL_DISTRIBUTOR, GROWTH_CUSTODY, gate, operators
        );

        _venues(d);

        // vault: the rate-aware balance fuse (market 36) and its dependency on market 7 (F12)
        IVaultP51 vault = IVaultP51(VAULT);
        vault.addBalanceFuse(MARKET_BALANCER, address(balanceFuse));
        uint256[] memory markets = new uint256[](1);
        markets[0] = MARKET_BALANCER;
        uint256[][] memory deps = new uint256[][](1);
        deps[0] = new uint256[](1);
        deps[0][0] = MARKET_ERC20;
        vault.updateDependencyBalanceGraphs(markets, deps);

        CySets memory s = allocation.sets();
        s.pol = address(controller);
        allocation.setSets(s);
        IWmP51(_addr(d, "withdrawManagerV2")).setBurnOnlyFee(address(custody), true);

        _governance(gate);
        _stop();
        require(IProfitCustodyP51(GROWTH_CUSTODY).feeRecipient() == originalFeeRecipient,
            "original Profit Custody recipient changed");
        require(IGateP51(gate).isProtectedCall(address(controller), bytes4(keccak256("setAdminReceiver(address)"))), "gate");

        console2.log("pol controller", address(controller));
        console2.log("pol balance fuse", address(balanceFuse));
        console2.log("pol liquidity fuse (0 until the venues exist)", liquidityFuse);
        console2.log("revenue custody v2 (layer over the live loop custody; holds POL position B)", address(custody));

        string memory o = "p5";
        vm.serializeAddress(o, "polController", address(controller));
        vm.serializeAddress(o, "polBalanceFuse", address(balanceFuse));
        vm.serializeAddress(o, "polLiquidityFuse", liquidityFuse);
        string memory out = vm.serializeAddress(o, "revenueCustodyV2", address(custody)); // V4 P3_05 transfers custody to the gate
        vm.writeJson(out, vm.envOr("PHASE5_DEPLOYMENTS", string("deployments/katana-phase5.json")));
    }

    /// @dev Register fee-sensitive selectors for V4 ADMIN_FEE dispatch; normal gate execution stays blocked.
    function _governance(address gate_) private {
        bytes4[] memory yieldFee = new bytes4[](1);
        yieldFee[0] = bytes4(keccak256("setAdminReceiver(address)"));
        // The POL and V2 custody contracts do not exist when P3_04 configures the
        // governance gate. Register their fee setter selectors now, using the
        // original fee-receiving Safe's self-managed ADMIN_FEE authority, before
        // P3_05's fail-closed handover checks and ownership transfers.
        _safe(gate_, abi.encodeCall(IGateP51.registerAdminFeeCalls, (address(controller), yieldFee)));
        bytes4[] memory custodyFee = new bytes4[](1);
        custodyFee[0] = custody.setFeeRecipient.selector;
        _safe(gate_, abi.encodeCall(IGateP51.registerAdminFeeCalls, (address(custody), custodyFee)));
        require(IGateP51(gate_).isFeeBearingTarget(address(controller)) &&
            IGateP51(gate_).isAdminFeeCall(address(controller), yieldFee[0]), "POL ADMIN_FEE registration");
        require(IGateP51(gate_).isFeeBearingTarget(address(custody)) &&
            IGateP51(gate_).isAdminFeeCall(address(custody), custodyFee[0]), "V2 custody ADMIN_FEE registration");
        _safe(gate_, abi.encodeCall(IGateP51.setProtectedCalls, (address(controller), yieldFee, true)));
        // every custody owner function moves funds or fee routes: fee authority only
        bytes4[] memory c = new bytes4[](9);
        c[0] = custody.setOperator.selector;
        c[1] = custody.setPolVenues.selector;
        c[2] = custody.polExitToAvkat.selector;
        c[3] = custody.setFeeRecipient.selector;
        c[4] = custody.scheduleFullUnwind.selector;
        c[5] = custody.executeFullUnwind.selector;
        c[6] = custody.setCoverer.selector;
        c[7] = custody.setCharmVaultAllowed.selector;
        c[8] = custody.transferOwnership.selector;
        _safe(gate_, abi.encodeCall(IGateP51.setProtectedCalls, (address(custody), c, true)));
    }

    function _safe(address to_, bytes memory data_) private {
        bytes memory sig = abi.encodePacked(uint256(uint160(DEPLOYER)), uint256(0), uint8(1));
        require(ISafeP51(FEE_SAFE).execTransaction(to_, 0, data_, 0, 0, 0, 0, address(0), payable(address(0)), sig), "Safe tx");
    }

    /// @dev Optional: only when the manually created venues exist.
    function _venues(string memory d_) private {
        address pool = vm.envOr("POL_POOL", address(0));
        if (pool == address(0)) return;
        address balVault = vm.envAddress("BALANCER_VAULT");
        address balRouter = vm.envAddress("BALANCER_ROUTER");
        address permit2 = vm.envOr("PERMIT2", 0x000000000022D473030F116dDEE9F6B43aC78BA3);
        address cyWeth = vm.envOr("CY_WETH_POOL", address(0));
        controller.setVenues(CyPolVenues(pool, balVault, cyWeth, _addr(d_, "withdrawManagerV2")));
        liquidityFuse = address(new BalancerLiquidityProportionalFuse(MARKET_BALANCER, balRouter, permit2));
        // POL swaps go through IPOR's UniversalTokenSwapperFuse and swap router v2 (0.1% fee, hook-oracle minimum)
        IRouterV2P51 router = IRouterV2P51(_addr(d_, "swapRouterV2"));
        // Run P5_01 before P3_05: after the handover the router belongs to the gate and these calls need the Safe through it.
        require(router.owner() == DEPLOYER, "swap router v2 already handed to the gate: run P5_01 before P3_05");
        if (router.balancerVault() == address(0)) router.setBalancer(balVault, balRouter);
        CyHopP51[] memory hops = new CyHopP51[](1);
        hops[0] = CyHopP51(2, AVKAT, VAULT, pool, 0);
        router.setRoute(AVKAT, VAULT, hops);
        hops[0] = CyHopP51(2, VAULT, AVKAT, pool, 0);
        router.setRoute(VAULT, AVKAT, hops);
        controller.setFuses(CyPolFuses({
            liquidity: liquidityFuse, swap: _addr(d_, "swapperFuse"), router: address(router),
            guard: _addr(d_, "guardFuse"), burn: burnFuse, transfer: _addr(d_, "transferFuse")
        }));
        address[] memory add = new address[](1);
        add[0] = liquidityFuse;
        IVaultP51(VAULT).addFuses(add);
        // IPOR Balancer substrates (BalancerSubstrateLib): POOL = 2, TOKEN = 3
        bytes32[] memory subs = new bytes32[](3);
        subs[0] = bytes32((uint256(2) << 160) | uint256(uint160(pool)));
        subs[1] = bytes32((uint256(3) << 160) | uint256(uint160(VAULT)));
        subs[2] = bytes32((uint256(3) << 160) | uint256(uint160(AVKAT)));
        IVaultP51(VAULT).grantMarketSubstrates(MARKET_BALANCER, subs);
        // position B's WETH leg trades through router v2 (Sushi, protected TWAP minimum)
        CyHopP51[] memory two = new CyHopP51[](2);
        two[0] = CyHopP51(1, AVKAT, KAT, AVKAT_KAT_1PCT, 10_000);
        two[1] = CyHopP51(1, KAT, WETH, KAT_WETH_005, 500);
        router.setRoute(AVKAT, WETH, two);
        two[0] = CyHopP51(1, WETH, KAT, KAT_WETH_005, 500);
        two[1] = CyHopP51(1, KAT, AVKAT, AVKAT_KAT_1PCT, 10_000);
        router.setRoute(WETH, AVKAT, two);
        address alpha = vm.envOr("ALPHA_VAULT", address(0));
        if (alpha != address(0)) {
            custody.setPolVenues(CyCustodyPolVenues(alpha, pool, balRouter, permit2, _addr(d_, "withdrawManagerV2")));
        }
    }

    function _wethToAvkat() private pure returns (CySushiRoute[] memory r_) {
        r_ = new CySushiRoute[](2);
        r_[0] = _route3(WETH, 500, KAT, 10_000, AVKAT, KAT_WETH_005, AVKAT_KAT_1PCT);
        r_[1] = _route4(WETH, USDC, KAT, AVKAT, USDC_WETH_005, KAT_USDC_005, AVKAT_KAT_1PCT);
    }

    function _route3(address a, uint24 f1, address b, uint24 f2, address c, address p1, address p2)
        private pure returns (CySushiRoute memory r_)
    {
        r_.path = abi.encodePacked(a, f1, b, f2, c);
        r_.pools = new address[](2);
        (r_.pools[0], r_.pools[1]) = (p1, p2);
        r_.tokens = new address[](3);
        (r_.tokens[0], r_.tokens[1], r_.tokens[2]) = (a, b, c);
    }

    /// @dev a -1%/0.05%- b -0.05%- c -0.05%- d ; the first hop is avKAT/KAT 1% in either direction.
    function _route4(address a, address b, address c, address e, address p1, address p2, address p3)
        private pure returns (CySushiRoute memory r_)
    {
        uint24 f1 = p1 == AVKAT_KAT_1PCT ? 10_000 : 500;
        uint24 f3 = p3 == AVKAT_KAT_1PCT ? 10_000 : 500;
        r_.path = abi.encodePacked(a, f1, b, uint24(500), c, f3, e);
        r_.pools = new address[](3);
        (r_.pools[0], r_.pools[1], r_.pools[2]) = (p1, p2, p3);
        r_.tokens = new address[](4);
        (r_.tokens[0], r_.tokens[1], r_.tokens[2], r_.tokens[3]) = (a, b, c, e);
    }
}
