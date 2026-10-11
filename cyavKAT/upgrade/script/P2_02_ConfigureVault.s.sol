// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {CurveYieldGovernanceGate} from "../src/governance/CurveYieldGovernanceGate.sol";
import {CurveYieldConfigKeys as K, CurveYieldAddrKeys} from "../src/governance/CurveYieldGateConfig.sol";
import {CurveYieldSubstrateLib as Sub} from "../src/libraries/CurveYieldSubstrateLib.sol";

interface IPriceSourcesP22 {
    function setAssetsPriceSources(address[] calldata assets, address[] calldata sources) external;
    function getSourceOfAssetPrice(address asset) external view returns (address);
}

interface IVaultConfig {
    function getPriceOracleMiddleware() external view returns (address);
    function addFuses(address[] calldata fuses) external;
    function addBalanceFuse(uint256 marketId, address fuse) external;
    function grantMarketSubstrates(uint256 marketId, bytes32[] calldata substrates) external;
    function updateDependencyBalanceGraphs(uint256[] calldata marketIds, uint256[][] calldata dependencies) external;
    function updateCallbackHandler(address handler, address sender, bytes4 sig) external;
    function isFuseSupported(address fuse) external view returns (bool);
    function isBalanceFuseSupported(uint256 marketId, address fuse) external view returns (bool);
    function getMarketSubstrates(uint256 marketId) external view returns (bytes32[] memory);
    function getActiveMarketsInBalanceFuses() external view returns (uint256[] memory);
    function totalAssets() external view returns (uint256);
}


/// M2 (IPOR_FUSE_CONFORMANCE_SPEC §6): additive vault configuration. Safe before the cutover: every new fuse only obeys the
/// executor, which holds no vault role until the cutover.
///   - registers the Morpho flash-loan callback handler (the unwind bundles run their callback through IPOR's official
///     MorphoFlashLoanFuse);
///   - adds the official fuses and the custom ones; balance fuses for the new markets (§4.4);
///   - substrates: market 7 + vbUSDC (plain tokens only, F13); market 14 + the avKAT / vbUSDC Morpho market; market 12
///     (UTS tokens, Targets = router v2 and the tokens it approves, Slippage written by the gate); market 19 (KAT); market
///     100_001 (cyvbUSDC); the typed entries of the custom fuses in `ZERO_BALANCE_MARKET` (exception E6);
///   - dependency edges 12, 19, 100_001 -> 7 (F12: every market that changes the vault's ERC-20 holdings refreshes market 7);
///   - vbUSDC priced in the vault's oracle middleware from the SAME feed cyvbUSDC uses (F8).
/// Markets 12 and ZERO are written through the governance gate's static lists and bindings (R5): the gate registers them
/// here and this script writes exactly what `gate.previewSubstrates` returns; from P3_05 on the gate writes them itself,
/// in the transaction that changes a bound setting.
///
///   forge script script/P2_02_ConfigureVault.s.sol --root <upgrade path> --rpc-url katana     (add --broadcast ... to send)
contract P2_02_ConfigureVault is Phase2Base {
    CurveYieldGovernanceGate internal gate;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        _requireQuestSigningV2(); // Mandatory updated Quest ERC-1271 signing layer for the V2 upgrade.
        string memory d = _readDeployments();
        gate = CurveYieldGovernanceGate(_gateAddress());
        require(gate.iporAccessManager() == ACCESS_MANAGER, "V3 gate must use original IPOR access manager");
        require(gate.feeConfigRegistrationSealed(), "V4 fee registry must be sealed");
        IVaultConfig vault = IVaultConfig(VAULT);

        string[12] memory fuseKeys = [
            "transferFuse", "guardFuse", "burnHeldSharesFuse", "requestFeeSharesFuse", "swapperFuse",
            "updateMarketsBalancesFuse", "transientStorageMapperFuse", "balanceValidationFuse", "erc4626SupplyFuse",
            "flashLoanFuse", "burnRequestFeeFuse", "lendSupplyFuse"
        ];
        uint256 n;
        address[] memory toAdd = new address[](fuseKeys.length);
        for (uint256 i; i < fuseKeys.length; ++i) {
            address f = _addr(d, fuseKeys[i]);
            if (!vault.isFuseSupported(f)) toAdd[n++] = f;
        }
        assembly { mstore(toAdd, n) }

        _start();
        vault.updateCallbackHandler(
            _addr(d, "callbackHandlerMorpho"), MORPHO, bytes4(keccak256("onMorphoFlashLoan(uint256,bytes)"))
        );
        if (n != 0) vault.addFuses(toAdd);
        uint256 totalBefore = vault.totalAssets();

        _addBalance(vault, MARKET_ERC4626, _addr(d, "erc4626BalanceFuse"));
        _addBalance(vault, MARKET_FLASH, _addr(d, "zeroBalanceFlash"));
        _addBalance(vault, MARKET_ZERO, _addr(d, "zeroBalanceUtility"));

        _plainSubstrates(vault);
        _gateMarkets(d);
        _dependencies(vault);
        _oracle(vault);
        _stop();

        require(vault.totalAssets() == totalBefore, "configuration changed totalAssets");
        for (uint256 i; i < fuseKeys.length; ++i) require(vault.isFuseSupported(_addr(d, fuseKeys[i])), fuseKeys[i]);
        require(vault.isBalanceFuseSupported(MARKET_ERC4626, _addr(d, "erc4626BalanceFuse")), "balance 100001");
        console2.log("vault configured: fuses added", n);
    }

    /// @dev Markets whose substrates are plain addresses / Morpho ids (not typed, not gate-driven).
    function _plainSubstrates(IVaultConfig vault_) private {
        // market 7 (ERC20_VAULT_BALANCE): plain tokens only. vbUSDC joins KAT (the vKAT adapter leaves in M4).
        bytes32[] memory m7 = new bytes32[](1);
        m7[0] = _plain(VBUSDC_TOKEN);
        _appendSubstrates(MARKET_ERC20, m7);
        // market 14 (MORPHO): the avKAT / KAT loop and the avKAT / vbUSDC market
        bytes32[] memory subs14 = vault_.getMarketSubstrates(MARKET_LOOP);
        require(subs14.length != 0 && subs14[0] == LOOP_MARKET, "market 14 must start with the loop");
        bytes32[] memory m14 = new bytes32[](1);
        m14[0] = USDC_LOOP_MARKET;
        _appendSubstrates(MARKET_LOOP, m14);
        // market 19 (flash loan): KAT is the flash token
        bytes32[] memory m19 = new bytes32[](1);
        m19[0] = _plain(KAT);
        vault_.grantMarketSubstrates(MARKET_FLASH, m19);
        // market 100_001 (ERC4626_0001): cyvbUSDC
        bytes32[] memory m4626 = new bytes32[](1);
        m4626[0] = _plain(CYVBUSDC);
        vault_.grantMarketSubstrates(MARKET_ERC4626, m4626);
        bytes32[] memory subs41 = vault_.getMarketSubstrates(MARKET_LEND);
        require(subs41.length == 1 && subs41[0] == LEND_MARKET, "lending not in market 41 (run L1 / L9 first)");
    }

    /// @dev Markets 12 (UTS) and ZERO (typed config): static lists and bindings registered in the gate, then written to the
    /// vault exactly as `previewSubstrates` returns them.
    function _gateMarkets(string memory d_) private {
        address router = _addr(d_, "swapRouterV2");
        address exec = _addr(d_, "executor");

        // UTS (market 12): Tokens, Targets (router v2 + every token as approve target), Slippage bound to the gate
        address[4] memory tokens = [KAT, AVKAT, VBUSDC_TOKEN, VAULT];
        bytes32[] memory swapStatic = new bytes32[](tokens.length * 2 + 1);
        for (uint256 i; i < tokens.length; ++i) {
            swapStatic[i] = _utsToken(tokens[i]);
            swapStatic[tokens.length + i] = _utsTarget(tokens[i]);
        }
        swapStatic[tokens.length * 2] = _utsTarget(router);
        gate.setStaticSubstrates(MARKET_SWAP, swapStatic);
        gate.clearSubstrateBindings(MARKET_SWAP);
        gate.addSubstrateBinding(MARKET_SWAP, K.SWAP_SLIPPAGE_WAD, gate.BIND_UTS_SLIPPAGE(), bytes32(0));

        // typed config of the custom fuses (ZERO_BALANCE_MARKET, E6)
        bytes32[] memory cfg = new bytes32[](5);
        cfg[0] = Sub.encodeAddress(Sub.TRANSFER_TOKEN, AVKAT);
        cfg[1] = Sub.encodeAddress(Sub.TRANSFER_RECIPIENT, GROWTH_CUSTODY);
        cfg[2] = Sub.encodeAddress(Sub.TRANSFER_RECIPIENT, ADMIN_FEE_SAFE); // executor contributors allocation
        cfg[3] = Sub.encodeAddress(Sub.TRANSFER_RECIPIENT, RCM);
        cfg[4] = Sub.encodeAddress(Sub.TRANSFER_RECIPIENT, exec);
        gate.setStaticSubstrates(MARKET_ZERO, cfg);
        gate.clearSubstrateBindings(MARKET_ZERO);
        gate.addSubstrateBinding(MARKET_ZERO, K.TRANSFER_MAX_PER_CALL_AVKAT, gate.BIND_TRANSFER_CAP(), bytes32(uint256(uint160(AVKAT))));
        gate.addSubstrateBinding(MARKET_ZERO, K.GUARD_MAX_PPS_DROP_BPS, gate.BIND_GUARD_MAX_PPS_DROP(), bytes32(0));
        gate.addSubstrateBinding(MARKET_ZERO, K.USDC_LOOP_MAX_LTV_BPS, gate.BIND_GUARD_MAX_LTV(), USDC_LOOP_MARKET);
        gate.setSubstrateVault(VAULT);

        IVaultConfig(VAULT).grantMarketSubstrates(MARKET_SWAP, gate.previewSubstrates(MARKET_SWAP));
        IVaultConfig(VAULT).grantMarketSubstrates(MARKET_ZERO, gate.previewSubstrates(MARKET_ZERO));
    }

    /// @dev F12: after `execute`, balances are refreshed for the touched markets plus their dependency graph, so every
    /// market that changes the vault's ERC-20 holdings gets an edge to market 7 (14 and 41 already have one).
    function _dependencies(IVaultConfig vault_) private {
        uint256[] memory markets = new uint256[](3);
        (markets[0], markets[1], markets[2]) = (MARKET_SWAP, MARKET_FLASH, MARKET_ERC4626);
        uint256[][] memory deps = new uint256[][](3);
        for (uint256 i; i < 3; ++i) {
            deps[i] = new uint256[](1);
            deps[i][0] = MARKET_ERC20;
        }
        vault_.updateDependencyBalanceGraphs(markets, deps);
    }

    /// @dev F8: cyavKAT's middleware has no vbUSDC feed; use the one cyvbUSDC's middleware prices vbUSDC with.
    function _oracle(IVaultConfig vault_) private {
        IPriceSourcesP22 mw = IPriceSourcesP22(vault_.getPriceOracleMiddleware());
        if (mw.getSourceOfAssetPrice(VBUSDC_TOKEN) != address(0)) return;
        address feed = IPriceSourcesP22(IVaultConfig(CYVBUSDC).getPriceOracleMiddleware()).getSourceOfAssetPrice(VBUSDC_TOKEN);
        require(feed != address(0), "cyvbUSDC has no vbUSDC feed");
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        (assets[0], sources[0]) = (VBUSDC_TOKEN, feed);
        mw.setAssetsPriceSources(assets, sources);
    }

    function _plain(address a_) private pure returns (bytes32) {
        return bytes32(uint256(uint160(a_)));
    }

    /// @dev A market keeps ONE balance fuse: skip it when the market already has one (12 and ZERO_BALANCE are live, valued by
    /// IPOR's ZeroBalanceFuse).
    function _addBalance(IVaultConfig vault_, uint256 market_, address fuse_) private {
        uint256[] memory active = vault_.getActiveMarketsInBalanceFuses();
        for (uint256 i; i < active.length; ++i) if (active[i] == market_) return;
        vault_.addBalanceFuse(market_, fuse_);
    }
}
