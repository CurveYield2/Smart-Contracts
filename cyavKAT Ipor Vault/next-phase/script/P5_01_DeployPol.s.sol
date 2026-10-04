// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {CySets} from "../src/allocation/CurveYieldAllocationController.sol";
import {CurveYieldAllocationController} from "../src/allocation/CurveYieldAllocationController.sol";
import {CurveYieldPolController, CyPolParams, CyPolVenues, CyPolFuses} from "../src/pol/CurveYieldPolController.sol";
import {BalancerLiquidityProportionalFuse} from "contracts/fuses/balancer/BalancerLiquidityProportionalFuse.sol";
import {CurveYieldTryElseFuse} from "../src/generic/CurveYieldTryElseFuse.sol";
import {CurveYieldBurnHeldSharesFuse} from "../src/generic/CurveYieldBurnHeldSharesFuse.sol";
import {CurveYieldRateAwareBalancerBalanceFuse} from "../src/generic/CurveYieldRateAwareBalancerBalanceFuse.sol";
import {CurveYieldPolCustody, CyPolCustodyParams, CyPolCustodyVenues} from "../src/pol/CurveYieldPolCustody.sol";
import {CurveYieldPolFeeder} from "../src/pol/CurveYieldPolFeeder.sol";
import {CySushiRoute} from "../src/pol/CurveYieldPolInterfaces.sol";

struct InstantWithdrawalFusesParamsP51 {
    address fuse;
    bytes32[] params;
}

interface IVaultP51 {
    function getMarketSubstrates(uint256 marketId) external view returns (bytes32[] memory);
    function addFuses(address[] calldata fuses) external;
    function addBalanceFuse(uint256 marketId, address fuse) external;
    function grantMarketSubstrates(uint256 marketId, bytes32[] calldata substrates) external;
    function configureInstantWithdrawalFuses(InstantWithdrawalFusesParamsP51[] calldata fuses) external;
}

interface IWmP51 {
    function setBurnOnlyFee(address account, bool enabled) external;
}

interface ISplitterP51 {
    function setGrowthCustody(address custody) external;
    function growthCustody() external view returns (address);
}

interface ISafeP51 {
    function execTransaction(address to, uint256 value, bytes calldata data, uint8 operation, uint256 safeTxGas,
        uint256 baseGas, uint256 gasPrice, address gasToken, address payable refundReceiver, bytes memory signatures)
        external payable returns (bool);
}

interface IGateP51 {
    function setProtectedCalls(address target, bytes4[] calldata selectors, bool isProtected) external;
    function setGuardianCall(address target, bytes4 selector, bool allowed) external;
    function isProtectedCall(address target, bytes4 selector) external view returns (bool);
}

interface IProfitCustodyP51 {
    function feeRecipient() external view returns (address);
}

/// POL spec (#25 revised): protocol-owned liquidity. Runs after P4_04 and BEFORE the handover (P3_05), as the deployer.
///   position A (vault-owned, IPOR market 36): CurveYieldPolController + CurveYieldPolFuse + CurveYieldPolBalanceFuse;
///     added to the vault, the allocation sets (reserve class) and the instant-withdrawal list (after lend, vKAT, LP)
///   position B (off the books): CurveYieldPolCustody (Alpha Vault cyavKAT/WETH) + two CurveYieldPolFeeders:
///     incoming  splitter.growthCustody -> feeder (20% to POL) -> profit custody 0xe7D1
///     yield     profit custody feeRecipient -> feeder (15% to POL) -> previous recipient (the fee Safe re-points it)
///   withdraw manager: burn-only fees for the POL custody
/// Governance: fee-authority protections (POL controller setAdminReceiver, yield feeder setConfig, every POL custody
/// owner function) are set here through the fee Safe, since P3_04 ran before (POL numbers are gate keys; the guardian
/// sets pol.capBps inside its gate range); the
/// ownerships stay with the deployer and move to the gate in P3_05 (which also re-points the profit custody fee recipient).
/// Venues (created manually; optional here, set later by the owners): POL_POOL, BALANCER_VAULT, BALANCER_ROUTER,
/// PERMIT2, CY_WETH_POOL, ALPHA_VAULT. Without POL_POOL the contracts are deployed and wired but hold no venue yet.
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
    address internal constant MAIN_FEE_MANAGER = 0x11a81a7B7436CB1E8f73866AF74961cE499f5Ec6;
    address internal constant WETH = 0xEE7D8BCFb72bC1880D0Cf19822eB0A2e6577aB62;
    address internal constant USDC = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36;
    address internal constant SUSHI_ROUTER = 0x4e1d81A3E627b9294532e990109e4c21d217376C;
    // Sushi V3 pools for the avKAT <-> WETH routes (the best-quoted route is used on every swap)
    address internal constant AVKAT_KAT_1PCT = 0x8640e1867BD563B2Ab865160E77Cb7B875243B13;
    address internal constant KAT_WETH_005 = 0xfe4E52cCf659705141E6fa5Dee01432A3e637904;
    address internal constant KAT_USDC_005 = 0x10045367E619Caae6f60CC80046c43c6cD55f629;
    address internal constant USDC_WETH_005 = 0x2A2C512beAA8eB15495726C235472D82EFFB7A6B;
    uint256 internal constant MARKET_BALANCER = 36; // IporFusionMarkets.BALANCER

    CurveYieldPolController internal controller;
    CurveYieldRateAwareBalancerBalanceFuse internal balanceFuse;
    address internal tryElseFuse;
    address internal burnFuse;
    address internal liquidityFuse; // needs the CurveYield DEX router: deployed with the venues
    address internal swapFuse; // idem
    CurveYieldPolCustody internal custody;
    CurveYieldPolFeeder internal incomingFeeder;
    CurveYieldPolFeeder internal yieldFeeder;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        string memory d = _readDeployments();
        CurveYieldAllocationController allocation = CurveYieldAllocationController(_addr(d, "allocation"));
        ISplitterP51 splitter = ISplitterP51(_addr(d, "splitter"));
        require(splitter.growthCustody() == GROWTH_CUSTODY, "splitter growth custody moved");
        address prevFeeRecipient = IProfitCustodyP51(GROWTH_CUSTODY).feeRecipient();

        _start();
        address gate = vm.parseJsonAddress(vm.readFile(vm.envOr("PHASE0_DEPLOYMENTS", string("deployments/katana-gate.json"))), ".governanceGate");
        controller = new CurveYieldPolController(DEPLOYER, VAULT, AVKAT, MAIN_FEE_MANAGER, gate);
        controller.setExecutor(_addr(d, "executor"));
        balanceFuse = new CurveYieldRateAwareBalancerBalanceFuse(MARKET_BALANCER);
        tryElseFuse = address(new CurveYieldTryElseFuse(MARKET_BALANCER));
        burnFuse = address(new CurveYieldBurnHeldSharesFuse(MARKET_BALANCER));
        controller.setAdminReceiver(FEE_SAFE); // yield fee bps is in the gate (FEE class, default 10%)
        controller.setMarketRoutes(_wethToAvkat());

        custody = new CurveYieldPolCustody(DEPLOYER, VAULT, AVKAT, WETH, MAIN_FEE_MANAGER, gate);
        custody.setRoutes(_avkatToWeth(), _wethToAvkat());
        custody.setOperator(vm.envOr("POL_OPERATOR", DEPLOYER), true);
        incomingFeeder = new CurveYieldPolFeeder(
            DEPLOYER, AVKAT, address(custody), GROWTH_CUSTODY, keccak256("polFeeder.incomingBps"), gate
        );
        yieldFeeder = new CurveYieldPolFeeder(
            DEPLOYER, AVKAT, address(custody), prevFeeRecipient, keccak256("polFeeder.yieldBps"), gate
        );

        _venues();

        // vault: generic fuses + rate-aware balance fuse (market 36) + instant withdrawals (lend, vKAT, LP, POL)
        IVaultP51 vault = IVaultP51(VAULT);
        address[] memory add = new address[](2);
        (add[0], add[1]) = (tryElseFuse, burnFuse);
        vault.addFuses(add);
        vault.addBalanceFuse(MARKET_BALANCER, address(balanceFuse));
        InstantWithdrawalFusesParamsP51[] memory iw = new InstantWithdrawalFusesParamsP51[](4);
        bytes32[] memory lendParams = new bytes32[](2);
        lendParams[1] = LEND_MARKET;
        address planned = _addr(d, "plannedInstantFuse");
        iw[0] = InstantWithdrawalFusesParamsP51(_addr(d, "lendSupplyFuse"), lendParams);
        iw[1] = InstantWithdrawalFusesParamsP51(planned, _plannerParams(_addr(d, "vkatController")));
        iw[2] = InstantWithdrawalFusesParamsP51(planned, _plannerParams(_addr(d, "lpController")));
        iw[3] = InstantWithdrawalFusesParamsP51(planned, _plannerParams(address(controller)));
        vault.configureInstantWithdrawalFuses(iw);
        bytes32[] memory typed = new bytes32[](3);
        typed[0] = bytes32((uint256(6) << 160) | uint256(uint160(address(controller)))); // instant planner
        typed[1] = bytes32((uint256(3) << 160) | uint256(uint160(FEE_SAFE))); // yield-fee recipient
        typed[2] = bytes32((uint256(3) << 160) | uint256(uint160(address(incomingFeeder)))); // splitter growth leg
        _appendSubstrates(MARKET_SUBSTRATES, typed);

        CySets memory s = allocation.sets();
        s.pol = address(controller);
        allocation.setSets(s);
        IWmP51(_addr(d, "withdrawManagerV2")).setBurnOnlyFee(address(custody), true);
        splitter.setGrowthCustody(address(incomingFeeder));

        _governance();
        _stop();
        require(IGateP51(_gate()).isProtectedCall(address(controller), bytes4(keccak256("setAdminReceiver(address)"))), "gate");

        console2.log("pol controller", address(controller));
        console2.log("pol balance fuse / try-else / burn", address(balanceFuse), tryElseFuse, burnFuse);
        console2.log("pol liquidity / swap fuse (0 until the venues exist)", liquidityFuse, swapFuse);
        console2.log("pol custody", address(custody));
        console2.log("feeders incoming / yield", address(incomingFeeder), address(yieldFeeder));

        string memory o = "p5";
        vm.serializeAddress(o, "polController", address(controller));
        vm.serializeAddress(o, "polBalanceFuse", address(balanceFuse));
        vm.serializeAddress(o, "polTryElseFuse", tryElseFuse);
        vm.serializeAddress(o, "polBurnFuse", burnFuse);
        vm.serializeAddress(o, "polLiquidityFuse", liquidityFuse);
        vm.serializeAddress(o, "polSwapFuse", swapFuse);
        vm.serializeAddress(o, "polCustody", address(custody));
        vm.serializeAddress(o, "polIncomingFeeder", address(incomingFeeder));
        string memory out = vm.serializeAddress(o, "polYieldFeeder", address(yieldFeeder));
        vm.writeJson(out, vm.envOr("PHASE5_DEPLOYMENTS", string("deployments/katana-phase5.json")));
    }

    function _gate() private view returns (address) {
        return vm.parseJsonAddress(vm.readFile(vm.envOr("PHASE3_DEPLOYMENTS", string("deployments/katana-phase3.json"))), ".governanceGate");
    }

    /// @dev Admin-fee paths are fee-authority only (gate); the cap joins the guardian lane.
    function _governance() private {
        address gate = _gate();
        bytes4[] memory yieldFee = new bytes4[](1);
        yieldFee[0] = bytes4(keccak256("setAdminReceiver(address)"));
        _safe(gate, abi.encodeCall(IGateP51.setProtectedCalls, (address(controller), yieldFee, true)));
        bytes4[] memory feeder = new bytes4[](1);
        feeder[0] = bytes4(keccak256("setConfig(address,address)")); // admin fee route (the rate itself is a FEE gate key)
        _safe(gate, abi.encodeCall(IGateP51.setProtectedCalls, (address(yieldFeeder), feeder, true)));
        bytes4[] memory c = new bytes4[](6);
        c[0] = bytes4(keccak256("setOperator(address,bool)"));
        c[1] = bytes4(keccak256("setVenues((address,address,address,address,address,address,address,address))"));
        c[2] = bytes4(keccak256("setRoutes((bytes,address[],address[])[],(bytes,address[],address[])[])"));
        c[3] = bytes4(keccak256("exitToAvkat(uint256,address)"));
        c[4] = bytes4(keccak256("sweep(address,address,uint256)"));
        c[5] = bytes4(keccak256("migrate(address)"));
        _safe(gate, abi.encodeCall(IGateP51.setProtectedCalls, (address(custody), c, true)));
    }

    function _safe(address to_, bytes memory data_) private {
        bytes memory sig = abi.encodePacked(uint256(uint160(DEPLOYER)), uint256(0), uint8(1));
        require(ISafeP51(FEE_SAFE).execTransaction(to_, 0, data_, 0, 0, 0, 0, address(0), payable(address(0)), sig), "Safe tx");
    }

    /// @dev Optional: only when the manually created venues exist.
    function _venues() private {
        address pool = vm.envOr("POL_POOL", address(0));
        if (pool == address(0)) return;
        address balVault = vm.envAddress("BALANCER_VAULT");
        address balRouter = vm.envAddress("BALANCER_ROUTER");
        address permit2 = vm.envOr("PERMIT2", 0x000000000022D473030F116dDEE9F6B43aC78BA3);
        address cyWeth = vm.envOr("CY_WETH_POOL", address(0));
        string memory d = _readDeployments();
        controller.setVenues(CyPolVenues(pool, balVault, cyWeth, _addr(d, "withdrawManagerV2")));
        liquidityFuse = address(new BalancerLiquidityProportionalFuse(MARKET_BALANCER, balRouter, permit2));
        // POL swaps go through the swap router v2 (0.1% fee, hook-oracle minimum) and the vault's swap fuse v2
        swapFuse = _addr(d, "swapFuseV2");
        IRouterV2P51 router = IRouterV2P51(_addr(d, "swapRouterV2"));
        // Run P5_01 before P3_05: after the handover the router belongs to the gate and these calls need a DAO proposal.
        require(router.owner() == DEPLOYER, "swap router v2 already handed to the gate: run P5_01 before P3_05");
        if (router.balancerVault() == address(0)) router.setBalancer(balVault, balRouter);
        CyHopP51[] memory hops = new CyHopP51[](1);
        hops[0] = CyHopP51(2, AVKAT, VAULT, pool, 0);
        router.setRoute(AVKAT, VAULT, hops);
        hops[0] = CyHopP51(2, VAULT, AVKAT, pool, 0);
        router.setRoute(VAULT, AVKAT, hops);
        controller.setFuses(CyPolFuses(liquidityFuse, swapFuse, tryElseFuse, burnFuse, _addr(d, "transferFuse")));
        address[] memory add = new address[](1);
        add[0] = liquidityFuse;
        IVaultP51(VAULT).addFuses(add);
        // IPOR Balancer substrates (BalancerSubstrateLib): POOL = 2, TOKEN = 3
        bytes32[] memory subs = new bytes32[](3);
        subs[0] = bytes32((uint256(2) << 160) | uint256(uint160(pool)));
        subs[1] = bytes32((uint256(3) << 160) | uint256(uint160(VAULT)));
        subs[2] = bytes32((uint256(3) << 160) | uint256(uint160(AVKAT)));
        IVaultP51(VAULT).grantMarketSubstrates(MARKET_BALANCER, subs);
        address alpha = vm.envOr("ALPHA_VAULT", address(0));
        if (alpha != address(0)) {
            custody.setVenues(CyPolCustodyVenues(
                alpha, cyWeth, pool, balRouter, permit2, SUSHI_ROUTER, QUOTER, _addr(_readDeployments(), "withdrawManagerV2")
            ));
        }
    }

    function _plannerParams(address planner_) private pure returns (bytes32[] memory p_) {
        p_ = new bytes32[](2); // [amount (filled by IPOR), planner]
        p_[1] = bytes32(uint256(uint160(planner_)));
    }

    function _avkatToWeth() private pure returns (CySushiRoute[] memory r_) {
        r_ = new CySushiRoute[](2);
        r_[0] = _route3(AVKAT, 10_000, KAT, 500, WETH, AVKAT_KAT_1PCT, KAT_WETH_005);
        r_[1] = _route4(AVKAT, KAT, USDC, WETH, AVKAT_KAT_1PCT, KAT_USDC_005, USDC_WETH_005);
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
