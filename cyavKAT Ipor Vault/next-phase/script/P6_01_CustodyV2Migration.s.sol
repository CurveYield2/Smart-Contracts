// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {CurveYieldAddrKeys} from "../src/governance/CurveYieldGateConfig.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {AragonAction} from "../src/governance/CurveYieldAragonInterfaces.sol";
import {CyHop} from "../src/router/CurveYieldSwapRouterV2.sol";
import {CurveYieldRevenueCustodyV2} from "../src/protection/CurveYieldRevenueCustodyV2.sol";
import {CurveYieldCustodyFarm} from "../src/protection/CurveYieldCustodyFarm.sol";
import {CurveYieldCustodyFarmPlanner} from "../src/protection/CurveYieldCustodyFarmPlanner.sol";

interface IGateP61 {
    function execute(address target, bytes calldata data) external returns (bytes memory);
    function executeProtected(address target, bytes calldata data) external returns (bytes memory);
    function isProtected(address target, bytes calldata data) external view returns (bool);
    function setProtectedCalls(address target, bytes4[] calldata selectors, bool isProtected) external;
    function setGuardianCall(address target, bytes4 selector, bool allowed) external;
}

interface IAdminPluginP61 {
    function executeProposal(bytes calldata metadata, AragonAction[] calldata actions, uint256 allowFailureMap)
        external returns (uint256);
}

interface ISafeP61 {
    function isOwner(address) external view returns (bool);
    function getThreshold() external view returns (uint256);
    function execTransaction(
        address to, uint256 value, bytes calldata data, uint8 operation, uint256 safeTxGas, uint256 baseGas,
        uint256 gasPrice, address gasToken, address payable refundReceiver, bytes memory signatures
    ) external payable returns (bool);
}

interface IOwnedP61 {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

interface ICustodyV1P61 {
    function feeRecipient() external view returns (address);
    function queuedRecipient() external view returns (address);
    function queuedExecuteAfter() external view returns (uint64);
}

interface IVaultP61 {
    function getMarketSubstrates(uint256 marketId) external view returns (bytes32[] memory);
}

interface IProfitCustodyHolderP61 {
    function profitCustody() external view returns (address);
}

interface IFeederP61 {
    function polCustody() external view returns (address);
    function destination() external view returns (address);
}

interface ILeaderboardP61 {
    function specialRewards() external view returns (address);
    function growthCustody() external view returns (address);
    function plusBooster() external view returns (address);
}

/// Phase 6 step 1/2 — revenue custody v2 + custody farm (PPS_PROTECTION_SPEC B5, CUSTODY_FARM_SPEC). Runs after P3_05
/// (everything is gate-owned): the deployer deploys and does the owner-only setup, then every other change goes
/// through the gate — protected calls by the fee Safe (gate.executeProtected), the rest in ONE Admin-plugin proposal
/// (gate.execute). The path of each call is decided by gate.isProtected, so nothing lands on the wrong path.
///   1. deploy the farm planner, custody v2 (fee recipient = the live custody's; operators as guardians) and the farm
///      (operators: your wallet, the fee Safe, the deployer; Charm vbWBTC-vbUSDC allowlisted);
///   2. owner setup (deployer): custody.setFarm(farm), custody.setCoverer(executor);
///   3. fee Safe: protected selectors of custody v2 and farm, guardian lane (custody v2 deployAll / balanceLtv);
///   4. hand custody v2 and the farm to the gate;
///   5. repoint every reference from the live custody to v2: WM v2 profit custody, POL incoming feeder destination,
///      leaderboard growth destination (when set), the vault's type-3 transfer recipient (added);
///      executor.setBackstops([custody v2]);
///   6. router v2 routes avKAT <-> vbUSDC (via KAT) and avKAT <-> vbWBTC (via KAT, vbUSDC) for the farm's tokens;
///   7. fee Safe: the live custody schedules its full unwind to custody v2 (15-day delay) — then P6_02.
///   forge script script/P6_01_CustodyV2Migration.s.sol --root <phase2> --rpc-url katana   (dry run; --broadcast to send)
contract P6_01_CustodyV2Migration is Phase2Base {
    address internal constant FEE_SAFE = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;
    address internal constant USER_WALLET = 0x9f2B20A772246960810045905B7daccf960eE288;
    address internal constant CUSTODY_V1 = GROWTH_CUSTODY;
    address internal constant SUSHI_NPM = 0x2659C6085D26144117D904C46B48B6d180393d27;
    address internal constant SUSHI_STAKER = 0xbe12e1b5C4859a3d141412748279B67458F729E9;
    address internal constant CHARM_WBTC_USDC = 0xBC2AE38CE7127854b08eC5956F8A31547f6390ff;
    address internal constant VBUSDC = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36;
    address internal constant VBWBTC = 0x0913DA6Da4b42f538B445599b46Bb4622342Cf52;
    address internal constant POOL_KAT_USDC_005 = 0x10045367E619Caae6f60CC80046c43c6cD55f629; // KAT / vbUSDC 0.05%
    address internal constant POOL_USDC_WBTC_005 = 0x744676B3CeD942D78F9b8e9cd22246Db5c32395c; // vbUSDC / vbWBTC 0.05%

    IGateP61 internal gate;
    AragonAction[] internal daoActions;
    bytes internal sig;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        string memory p3 = vm.readFile(vm.envOr("PHASE3_DEPLOYMENTS", string("deployments/katana-phase3.json")));
        string memory p2 = _readDeployments();
        gate = IGateP61(vm.parseJsonAddress(p3, ".governanceGate"));
        address adminPlugin = vm.parseJsonAddress(p3, ".adminPlugin");
        address executor = _addr(p2, "executor");
        address routerV2 = _addr(p2, "swapRouterV2");
        address wm = _addr(p2, "withdrawManagerV2");
        require(IOwnedP61(executor).owner() == address(gate), "run P3_05 first: executor not gate-owned");
        require(IOwnedP61(CUSTODY_V1).owner() == address(gate), "run P3_05 first: live custody not gate-owned");
        require(ICustodyV1P61(CUSTODY_V1).queuedRecipient() == address(0), "a full unwind is already queued");
        sig = abi.encodePacked(uint256(uint160(DEPLOYER)), uint256(0), uint8(1));

        _start();
        // 1. deploy
        address[] memory operators = new address[](3);
        (operators[0], operators[1], operators[2]) = (USER_WALLET, FEE_SAFE, DEPLOYER);
        CurveYieldCustodyFarmPlanner planner = new CurveYieldCustodyFarmPlanner();
        CurveYieldRevenueCustodyV2 custody = new CurveYieldRevenueCustodyV2(
            DEPLOYER, ICustodyV1P61(CUSTODY_V1).feeRecipient(), VAULT, address(gate), operators
        );
        // re-point the wiring key from custody v1 (P2_01) to v2: DAO-only setAddr, through the admin plugin batch
        daoActions.push(AragonAction(address(gate), 0, abi.encodeWithSignature(
            "setAddr(bytes32,address)", CurveYieldAddrKeys.REVENUE_CUSTODY, address(custody)
        )));
        CurveYieldCustodyFarm farm = new CurveYieldCustodyFarm(
            DEPLOYER, AVKAT, KAT, SUSHI_NPM, SUSHI_STAKER, MERKL_DISTRIBUTOR,
            address(planner), address(gate), operators
        );
        // 2. owner-only setup while the deployer still owns them
        farm.setCharmVaultAllowed(CHARM_WBTC_USDC, true);
        custody.setFarm(address(farm));
        custody.setCoverer(executor, true);

        // 3. protections and guardian lane (fee Safe)
        bytes4[] memory cSel = new bytes4[](6);
        cSel[0] = custody.setFeeRecipient.selector;
        cSel[1] = custody.scheduleFullUnwind.selector;
        cSel[2] = custody.executeFullUnwind.selector;
        cSel[3] = custody.setCoverer.selector;
        cSel[4] = custody.setGuardian.selector;
        cSel[5] = custody.setFarm.selector;
        _safe(address(gate), abi.encodeCall(IGateP61.setProtectedCalls, (address(custody), cSel, true)));
        bytes4[] memory fSel = new bytes4[](3);
        fSel[0] = farm.setOperator.selector;
        fSel[1] = farm.setPoolAllowed.selector;
        fSel[2] = farm.setCharmVaultAllowed.selector;
        _safe(address(gate), abi.encodeCall(IGateP61.setProtectedCalls, (address(farm), fSel, true)));
        _safe(address(gate), abi.encodeCall(IGateP61.setGuardianCall, (address(custody), custody.deployAll.selector, true)));
        _safe(address(gate), abi.encodeCall(IGateP61.setGuardianCall, (address(custody), custody.balanceLtv.selector, true)));

        // 4. hand both to the gate (accepted in the DAO proposal below)
        custody.transferOwnership(address(gate));
        farm.transferOwnership(address(gate));
        _gateCall(address(custody), abi.encodeCall(IOwnedP61.acceptOwnership, ()));
        _gateCall(address(farm), abi.encodeCall(IOwnedP61.acceptOwnership, ()));

        // 5. repoint every reference to the live custody
        if (IProfitCustodyHolderP61(wm).profitCustody() == CUSTODY_V1) {
            _gateCall(wm, abi.encodeWithSignature("setProfitCustody(address)", address(custody)));
        }
        string memory p5Path = vm.envOr("PHASE5_DEPLOYMENTS", string("deployments/katana-phase5.json"));
        if (vm.exists(p5Path)) {
            address feeder = vm.parseJsonAddress(vm.readFile(p5Path), ".polIncomingFeeder");
            if (IFeederP61(feeder).destination() == CUSTODY_V1) {
                _gateCall(feeder, abi.encodeWithSignature(
                    "setConfig(address,address)", IFeederP61(feeder).polCustody(), address(custody)
                ));
            }
        }
        string memory p4Path = vm.envOr("PHASE4_DEPLOYMENTS", string("deployments/katana-phase4.json"));
        if (vm.exists(p4Path) && vm.keyExistsJson(vm.readFile(p4Path), ".leaderboard")) {
            ILeaderboardP61 lb = ILeaderboardP61(vm.parseJsonAddress(vm.readFile(p4Path), ".leaderboard"));
            if (lb.growthCustody() == CUSTODY_V1) {
                _gateCall(address(lb), abi.encodeWithSignature(
                    "setBuyDestinations(address,address,address)", lb.specialRewards(), address(custody), lb.plusBooster()
                ));
            }
        }
        bytes32[] memory subs = IVaultP61(VAULT).getMarketSubstrates(MARKET_SUBSTRATES);
        bytes32[] memory withV2 = new bytes32[](subs.length + 1);
        for (uint256 i; i < subs.length; ++i) withV2[i] = subs[i];
        withV2[subs.length] = bytes32((uint256(3) << 160) | uint256(uint160(address(custody))));
        _gateCall(VAULT, abi.encodeWithSignature("grantMarketSubstrates(uint256,bytes32[])", MARKET_SUBSTRATES, withV2));
        address[] memory backstops = new address[](1);
        backstops[0] = address(custody);
        _gateCall(executor, abi.encodeWithSignature("setBackstops(address[])", backstops));

        // 6. router v2 routes for the farm's tokens
        CyHop[] memory toUsdc = new CyHop[](2);
        toUsdc[0] = CyHop(1, AVKAT, KAT, POOL_1PCT, 10_000);
        toUsdc[1] = CyHop(1, KAT, VBUSDC, POOL_KAT_USDC_005, 500);
        _route(routerV2, AVKAT, VBUSDC, toUsdc);
        CyHop[] memory fromUsdc = new CyHop[](2);
        fromUsdc[0] = CyHop(1, VBUSDC, KAT, POOL_KAT_USDC_005, 500);
        fromUsdc[1] = CyHop(1, KAT, AVKAT, POOL_1PCT, 10_000);
        _route(routerV2, VBUSDC, AVKAT, fromUsdc);
        CyHop[] memory toWbtc = new CyHop[](3);
        (toWbtc[0], toWbtc[1]) = (toUsdc[0], toUsdc[1]);
        toWbtc[2] = CyHop(1, VBUSDC, VBWBTC, POOL_USDC_WBTC_005, 500);
        _route(routerV2, AVKAT, VBWBTC, toWbtc);
        CyHop[] memory fromWbtc = new CyHop[](3);
        fromWbtc[0] = CyHop(1, VBWBTC, VBUSDC, POOL_USDC_WBTC_005, 500);
        (fromWbtc[1], fromWbtc[2]) = (fromUsdc[0], fromUsdc[1]);
        _route(routerV2, VBWBTC, AVKAT, fromWbtc);
        CyHop[] memory usdcToWbtc = new CyHop[](1);
        usdcToWbtc[0] = toWbtc[2];
        _route(routerV2, VBUSDC, VBWBTC, usdcToWbtc);
        CyHop[] memory wbtcToUsdc = new CyHop[](1);
        wbtcToUsdc[0] = fromWbtc[0];
        _route(routerV2, VBWBTC, VBUSDC, wbtcToUsdc);

        IAdminPluginP61(adminPlugin).executeProposal("Phase 6: revenue custody v2 + custody farm", daoActions, 0);

        // 7. the live custody starts its full unwind to v2 (protected; executes after 15 days in P6_02)
        _gateCall(CUSTODY_V1, abi.encodeWithSignature("scheduleFullUnwind(address)", address(custody)));
        _stop();

        // post-conditions
        require(IOwnedP61(address(custody)).owner() == address(gate) && IOwnedP61(address(farm)).owner() == address(gate),
            "custody v2 / farm not gate-owned");
        require(custody.farm() == address(farm) && custody.isCoverer(executor), "custody wiring");
        require(IProfitCustodyHolderP61(wm).profitCustody() == address(custody), "WM profit custody");
        require(ICustodyV1P61(CUSTODY_V1).queuedRecipient() == address(custody), "full unwind not queued");
        require(farm.isCharmVaultAllowed(CHARM_WBTC_USDC), "Charm vault");
        console2.log("custody v2", address(custody));
        console2.log("farm      ", address(farm));
        console2.log("planner   ", address(planner));
        console2.log("full unwind executable after", ICustodyV1P61(CUSTODY_V1).queuedExecuteAfter());
        string memory o = "p6";
        vm.serializeAddress(o, "revenueCustodyV2", address(custody));
        vm.serializeAddress(o, "custodyFarm", address(farm));
        vm.writeJson(vm.serializeAddress(o, "custodyFarmPlanner", address(planner)),
            vm.envOr("PHASE6_DEPLOYMENTS", string("deployments/katana-phase6.json")));
    }

    function _route(address router_, address tokenIn_, address tokenOut_, CyHop[] memory hops_) internal {
        _gateCall(router_, abi.encodeWithSignature(
            "setRoute(address,address,(uint8,address,address,address,uint24)[])", tokenIn_, tokenOut_, hops_
        ));
    }

    /// @dev Protected calls go through the fee Safe now; everything else joins the single DAO proposal.
    function _gateCall(address target_, bytes memory data_) internal {
        if (gate.isProtected(target_, data_)) {
            _safe(address(gate), abi.encodeCall(IGateP61.executeProtected, (target_, data_)));
        } else {
            daoActions.push(AragonAction(address(gate), 0, abi.encodeCall(IGateP61.execute, (target_, data_))));
        }
    }

    function _safe(address to_, bytes memory data_) internal {
        require(ISafeP61(FEE_SAFE).isOwner(DEPLOYER) && ISafeP61(FEE_SAFE).getThreshold() == 1, "fee Safe signer");
        bool ok = ISafeP61(FEE_SAFE).execTransaction(to_, 0, data_, 0, 0, 0, 0, address(0), payable(address(0)), sig);
        require(ok, "Safe execTransaction failed");
    }
}
