// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {CurveYieldAddrKeys} from "../src/governance/CurveYieldGateConfig.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {CyHop} from "../src/router/CurveYieldSwapRouterV2.sol";
import {CurveYieldRevenueCustodyV2} from "../src/protection/CurveYieldRevenueCustodyV2.sol";

interface IGateP61 {
    function execute(address target, bytes calldata data) external returns (bytes memory);
    function executeAdminFee(address target, bytes calldata data) external returns (bytes memory);
    function executeRestricted(address target, bytes calldata data) external returns (bytes memory);
    function isAdminFeeCall(address target, bytes4 selector) external view returns (bool);
    function isProtected(address target, bytes calldata data) external view returns (bool);
    function setProtectedCalls(address target, bytes4[] calldata selectors, bool isProtected) external;
    function staticSubstrates(uint256 marketId) external view returns (bytes32[] memory);
    function setStaticSubstrates(uint256 marketId, bytes32[] calldata substrates) external;
    function syncSubstrates(uint256 marketId) external;
    function addr(bytes32 key) external view returns (address);
    function setAddr(bytes32 key, address recipient) external;
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
    function isGuardian(address account) external view returns (bool);
}

interface IProfitCustodyHolderP61 {
    function profitCustody() external view returns (address);
}


/// Phase 6 — revenue custody v2 goes live as the layer on top of the live loop custody 0xe7D1 (PPS_PROTECTION_SPEC B5,
/// CUSTODY_FARM_SPEC). The live custody keeps the Morpho loop unchanged; v2 holds everything beyond it (allocation,
/// Charm farm, POL position B, Merkl, the cover backstop). Custody v2 was deployed by P5_01 and transferred to the gate by V4 P3_05.
/// Admin fee setters are exclusively forwarded via the self-administered ADMIN_FEE gate lane;
/// non-fee calls continue to use the original IPOR Access Manager roles.
///   1-2. (P5_01) custody v2 exists, gate-owned; here: coverer = executor, Charm vbWBTC-vbUSDC allowlisted;
///   4. (P3_05) custody v2 transferred to the gate;
///   5. WM v2 custody and wrapper-fee receipts flow to V2; repoint the executor's vault-loop growth
///      once to V2 via ADMIN_FEE (with the transfer recipient allowlisted first). The ORIGINAL custody's
///      feeRecipient and its internal distribution are UNCHANGED. executor.setBackstops([custody v2]);
///      V2 becomes a guardian of the live custody for its own allocation into the original loop;
///   6. router v2 routes avKAT <-> vbUSDC (via KAT) and avKAT <-> vbWBTC (via KAT, vbUSDC) for the farm's tokens;
///   (no step 7: the live custody is kept; its loop is never unwound into v2).
///   forge script script/P6_01_CustodyV2Migration.s.sol --root <phase2> --rpc-url katana   (dry run; --broadcast to send)
contract P6_01_CustodyV2Migration is Phase2Base {
    address internal constant FEE_SAFE = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49;
    address internal constant USER_WALLET = 0x9f2B20A772246960810045905B7daccf960eE288;
    address internal constant CUSTODY_V1 = GROWTH_CUSTODY;
    address internal constant CHARM_WBTC_USDC = 0xBC2AE38CE7127854b08eC5956F8A31547f6390ff;
    address internal constant VBUSDC = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36;
    address internal constant VBWBTC = 0x0913DA6Da4b42f538B445599b46Bb4622342Cf52;
    address internal constant POOL_KAT_USDC_005 = 0x10045367E619Caae6f60CC80046c43c6cD55f629; // KAT / vbUSDC 0.05%
    address internal constant POOL_USDC_WBTC_005 = 0x744676B3CeD942D78F9b8e9cd22246Db5c32395c; // vbUSDC / vbWBTC 0.05%

    IGateP61 internal gate;
    bytes internal sig;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        _requireQuestSigningV2(); // Mandatory updated Quest ERC-1271 signing layer for the V2 upgrade.
        string memory p2 = _readDeployments();
        gate = IGateP61(_gateAddress());
        address executor = _addr(p2, "executor");
        address routerV2 = _addr(p2, "swapRouterV2");
        address wm = _addr(p2, "withdrawManagerV2");
        require(IOwnedP61(executor).owner() == address(gate), "run P3_05 first: executor not gate-owned");
        require(IOwnedP61(CUSTODY_V1).owner() == address(gate), "live custody must be gate-owned in V4");
        require(ICustodyV1P61(CUSTODY_V1).queuedRecipient() == address(0), "a full unwind is already queued");
        sig = abi.encodePacked(uint256(uint160(DEPLOYER)), uint256(0), uint8(1));

        _start();
        // 1. deploy
        CurveYieldRevenueCustodyV2 custody = CurveYieldRevenueCustodyV2(vm.parseJsonAddress(
            vm.readFile(vm.envOr("PHASE5_DEPLOYMENTS", string("deployments/katana-phase5.json"))), ".revenueCustodyV2"
        ));
        require(IOwnedP61(address(custody)).owner() == address(gate),
            "custody v2 must be gate-owned (run V4 P3_05)");
        // Protect the live Profit Custody's independent, configurable Morpho wind-up fee distribution.
        address originalFee = ICustodyV1P61(CUSTODY_V1).feeRecipient();
        require(originalFee != address(0) && originalFee != address(custody), "invalid original fee recipient");
        // 2. owner setup through the gate's IPOR-restricted maintenance lane
        _gateCall(address(custody), abi.encodeCall(custody.setCharmVaultAllowed, (CHARM_WBTC_USDC, true)));
        _gateCall(address(custody), abi.encodeCall(custody.setCoverer, (executor, true)));

        // 5. The single fee-routing change is made here, not in P2. Existing ADMIN_FEE Safe authority
        // changes only the executor's growth destination; its four-way percentages remain untouched.
        _grantRecipient(address(custody)); // prerequisite: the vault transfer fuse must permit V2 custody
        address growthBefore = gate.addr(CurveYieldAddrKeys.LOOP_GROWTH_RECIPIENT);
        require(growthBefore == CUSTODY_V1 || growthBefore == address(custody), "unexpected growth recipient");
        if (growthBefore != address(custody)) {
            _safe(address(gate), abi.encodeCall(IGateP61.setAddr,
                (CurveYieldAddrKeys.LOOP_GROWTH_RECIPIENT, address(custody))));
        }
        // WM v2 routes its own custody revenues to V2, separately from the executor's growth allocation.
        if (IProfitCustodyHolderP61(wm).profitCustody() == CUSTODY_V1) {
            _gateCall(wm, abi.encodeWithSignature("setProfitCustody(address)", address(custody)));
        }
        // NO feeRecipient change or replacement split on the original Profit Custody.
        address[] memory backstops = new address[](1);
        backstops[0] = address(custody);
        _gateCall(executor, abi.encodeWithSignature("setBackstops(address[])", backstops));

        // 6. router v2 routes for the farm's Charm tokens
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

        // v2 may run the live custody's deployAll (its allocation feeds the loop)
        _gateCall(CUSTODY_V1, abi.encodeWithSignature("setGuardian(address,bool)", address(custody), true));

        _stop();

        // post-conditions
        require(custody.isCoverer(executor), "custody wiring");
        require(ICustodyV1P61(CUSTODY_V1).feeRecipient() == originalFee, "original Profit Custody recipient changed");
        require(gate.addr(CurveYieldAddrKeys.LOOP_GROWTH_RECIPIENT) == address(custody),
            "executor vault-loop growth not routed to V2 custody");
        require(gate.addr(CurveYieldAddrKeys.LOOP_CONTRIBUTORS_RECIPIENT) == ADMIN_FEE_SAFE,
            "executor contributors allocation not routed to admin fee receiver");
        require(IProfitCustodyHolderP61(wm).profitCustody() == address(custody), "WM profit custody");
        require(ICustodyV1P61(CUSTODY_V1).isGuardian(address(custody)), "v2 is not a guardian of the live custody");
        require(custody.isCharmVaultAllowed(CHARM_WBTC_USDC), "Charm vault");
        console2.log("custody v2", address(custody));
        string memory o = "p6";
        vm.writeJson(vm.serializeAddress(o, "revenueCustodyV2", address(custody)),
            vm.envOr("PHASE6_DEPLOYMENTS", string("deployments/katana-phase6.json")));
    }

    /// @dev Adds `recipient_` to the gate's static transfer recipients and syncs (the gate holds the FUSE_MANAGER role after P3_05).
    function _grantRecipient(address recipient_) internal {
        bytes32 entry = bytes32((uint256(0x11) << 248) | uint256(uint160(recipient_))); // CurveYieldSubstrateLib.TRANSFER_RECIPIENT
        bytes32[] memory cur = gate.staticSubstrates(MARKET_ZERO);
        for (uint256 i; i < cur.length; ++i) if (cur[i] == entry) return;
        bytes32[] memory next = new bytes32[](cur.length + 1);
        for (uint256 i; i < cur.length; ++i) next[i] = cur[i];
        next[cur.length] = entry;
        _safe(address(gate), abi.encodeCall(IGateP61.setStaticSubstrates, (MARKET_ZERO, next)));
        gate.syncSubstrates(MARKET_ZERO);
    }

    function _route(address router_, address tokenIn_, address tokenOut_, CyHop[] memory hops_) internal {
        _gateCall(router_, abi.encodeWithSignature(
            "setRoute(address,address,(uint8,address,address,address,uint24)[])", tokenIn_, tokenOut_, hops_
        ));
    }

    /// @dev All owner-only dispatch is routed through the gate. Fee-sensitive selectors
    /// exclusively require ADMIN_FEE; protected non-fee maintenance requires IPOR OWNER.
    function _gateCall(address target_, bytes memory data_) internal {
        (bool hasOwner, bytes memory ownerData) = target_.staticcall(abi.encodeWithSignature("owner()"));
        if (hasOwner && ownerData.length >= 32)
            require(abi.decode(ownerData, (address)) == address(gate), "target must be gate-owned");
        bytes4 selector;
        assembly { selector := mload(add(data_, 32)) }
        if (gate.isAdminFeeCall(target_, selector)) {
            _safe(address(gate), abi.encodeCall(IGateP61.executeAdminFee, (target_, data_)));
        } else if (gate.isProtected(target_, data_)) {
            _safe(address(gate), abi.encodeCall(IGateP61.executeRestricted, (target_, data_)));
        } else {
            _safe(address(gate), abi.encodeCall(IGateP61.execute, (target_, data_)));
        }
    }

    function _safe(address to_, bytes memory data_) internal {
        require(ISafeP61(FEE_SAFE).isOwner(DEPLOYER) && ISafeP61(FEE_SAFE).getThreshold() == 1, "fee Safe signer");
        bool ok = ISafeP61(FEE_SAFE).execTransaction(to_, 0, data_, 0, 0, 0, 0, address(0), payable(address(0)), sig);
        require(ok, "Safe execTransaction failed");
    }
}
