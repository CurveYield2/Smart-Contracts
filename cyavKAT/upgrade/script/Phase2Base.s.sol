// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {CurveYieldQuestSignerConfigFuse} from "../src/katana/CurveYieldQuestSignerConfigFuse.sol";
import {CurveYieldVaultBase1271} from "../src/katana/CurveYieldVaultBase1271.sol";
import {CurveYieldSignatureFuse} from "../src/katana/CurveYieldSignatureFuse.sol";

/// @notice Shared constants, broadcaster selection and the deployment-address file for the Phase 2 migration.
/// Live broadcast: PRIVATE_KEY in the environment (run from C:\Users\user\Desktop\Claude so its .env is loaded).
/// Fork tests: no PRIVATE_KEY -> calls are made as DEPLOYER.
/// @dev The gate's wiring registry (GATE_CONFIG_SPEC §10).
interface IGateAddrRegistry {
    function addrOrZero(bytes32 key) external view returns (address);
    function registerAddr(bytes32 key, address addr) external;
}

interface IVaultConfigAppend {
    function getMarketSubstrates(uint256 marketId) external view returns (bytes32[] memory);
    function grantMarketSubstrates(uint256 marketId, bytes32[] calldata substrates) external;
}

interface IQuestSigningVaultGate {
    function PLASMA_VAULT_BASE() external view returns (address);
    function isFuseSupported(address fuse) external view returns (bool);
    function isQuestSigner(address signer) external view returns (bool);
    function questSignPrefix() external view returns (bytes memory);
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

abstract contract Phase2Base is Script {
    // Live Katana system
    address internal constant VAULT = 0xEd83daf48429cfb2C650Fd721b9241e180fd4548;
    address internal constant ACCESS_MANAGER = 0xd7f408f203c5c6a76c9c55c9f6b015929F151fAA;
    address internal constant RCM = 0xA77470B748A8Fb50056Ca3c07375dC76Aa3A72Cb;
    address internal constant WM_OLD = 0x59B340EAb30AFE0cecD51C609d3190e8C75C40AE;
    address internal constant WM_TEMPLATE = 0x7a0928c0E99e50b2D51C8db7DC400123982687CF;
    address internal constant CONTROLLER_V2 = 0xbFdf2d2653859B66A8A15e1C85F6d6cdEe89698f;
    address internal constant GROWTH_CUSTODY = 0xe7D109Ce6b34447Dd45B54e5615F4177291D5ADf;
    /// @dev history: used only by the L* scripts (already broadcast); M4 removes the fuse from the vault.
    address internal constant LEGACY_VKAT_FUSE = 0x987C05943855B22552898F032c1AEa7930E340da;
    address internal constant CALLER_REWARD_FUSE = 0x70a2f848E21c912D660FE2263E5Be538268A41Ec;
    address internal constant SWAP_FUSE = 0x1fB8b83bAf40c90F0b450A3fd7A8b2E97Ab2a3Ff;
    /// IPOR official MerklClaimFuse and the two custom reward fuses of the rewards claim manager: all three are removed
    /// from it by M4 (Merkl claiming leaves the cyavKAT vault, D11; nothing accrues to the vault, F15).
    /// @dev Merkl distributor: claimed by custody v2 for its Charm positions (not a vault claim, D11).
    address internal constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;
    address internal constant MERKL_CLAIM_FUSE = 0xc6d024E53204CADa27a3c60C77dA4de2e7eb5166;
    address internal constant MERKL_SWEEP_FUSE = 0x8c82b1ba53784F888Ea49463e2138cDF82973470;
    address internal constant MERKL_AUTO_HARVEST = 0xb62241b19995Dac16D5905050804e1f06caC9704;
    address internal constant COLLATERAL_FUSE = 0xda9a20690a185DAA3b0fD198C6232234835B6929;
    address internal constant BORROW_FUSE = 0x08095Aef82A5B33b5B478d254052618A5366cd78;
    address internal constant FLASH_FUSE = 0x84927bFf2a35a543ed94A7d96D5ccd162a167947;
    address internal constant AVKAT = 0x7231dbaCdFc968E07656D12389AB20De82FbfCeB;
    address internal constant KAT = 0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d;
    address internal constant MORPHO = 0xD50F2DffFd62f94Ee4AEd9ca05C61d0753268aBc;
    bytes32 internal constant LOOP_MARKET = 0x80e60fe453223b0f84a567724f88190bef708420d24397157067d424429783e9;
    // avKAT lending market: loan avKAT, collateral wcyavKAT (0x10dF…4692), 12% haircut oracle 0x2926…5137, LLTV 86%.
    // Replaced 0x5c60 (cyavKAT collateral, 5% haircut) via L5/L5b on 2026-09-25.
    bytes32 internal constant LEND_MARKET = 0xe0e57a9a96ef56292b1400db02b19995147b1f39ff9dc1673b4618beba1cb159;
    bytes32 internal constant OLD_LEND_MARKET = 0x5c60efbfb29c57b5a6917cc4af1c3b07fb238b2a4b1884d739bf6a79080fd014;
    address internal constant VKAT_NFT = 0x106F7D67Ea25Cb9eFf5064CF604ebf6259Ff296d; // read-only: F5 asserts the vault holds none
    address internal constant VKAT_ADAPTER = 0xD3d3fd4fe4c09d9BB826A37D368Cf8033e512507; // "Vault vKAT Accounting Position", a market-7 substrate
    address internal constant POOL_1PCT = 0x8640e1867BD563B2Ab865160E77Cb7B875243B13;
    address internal constant ROUTER = 0x01F9894f92ea9224fECc8C35482E20a05De13582;
    address internal constant QUOTER = 0x92dea23ED1C683940fF1a2f8fE23FE98C5d3041c;
    address internal constant DEPLOYER = 0x11b78837cadC8E894F1c6e13fA9f3A085a75FA35;
    address internal constant ADMIN_FEE_SAFE = 0x47623C62f281807D615eeb4A2CEee9d97F9D3C49; // fee Safe (fee authority)
    address internal constant SUSHI_FACTORY = 0x203e8740894c8955cB8950759876d7E7E45E04c1; // Katana Sushi V3
    bytes32 internal constant SUSHI_INIT_CODE_HASH = 0xe040f12c7cee3904b78f24f8fc395629c2e69525c2815da7a659f7483e378ecb;

    // Vault market ids used by Phase 2: IPOR-registered markets ONLY (IporFusionMarkets.sol)
    /// @dev USDC_SUPPLY_LOOP_SPEC: avKAT / vbUSDC (LLTV 62.5%), the second market-14 substrate
    bytes32 internal constant USDC_LOOP_MARKET = 0xbd48214a2f12e951da20ad0b8fd83b611c693b5bbaa280b68ba4075678f2a138;
    address internal constant VBUSDC_TOKEN = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36;
    uint256 internal constant MARKET_LOOP = 14; // MORPHO: the avKAT/KAT loop 0x80e6 + the avKAT/vbUSDC market 0xbd48
    uint256 internal constant MARKET_ERC20 = 7; // ERC20_VAULT_BALANCE: plain tokens only (F13: no typed entries)
    uint256 internal constant MARKET_SWAP = 12; // UNIVERSAL_TOKEN_SWAPPER: tokens, Targets (router v2), Slippage
    uint256 internal constant MARKET_FLASH = 19; // MORPHO_FLASH_LOAN
    uint256 internal constant MARKET_BALANCER = 36; // BALANCER (POL position A)
    uint256 internal constant MARKET_ERC4626 = 100_001; // ERC4626_0001: cyvbUSDC
    uint256 internal constant MARKET_ZERO = type(uint256).max; // ZERO_BALANCE_MARKET: custom utility fuses + typed config (E6)
    uint256 internal constant MARKET_VKAT_RETIRED = 54; // substrate-only vKAT list: emptied and retired by M4
    address internal constant CYVBUSDC = 0xDf9CbCB8b57A031e91CAe673a6A5786d85Ce2eC5; // "CurveYield USDC" IPOR vault (F7)
    address internal constant MARKETS_LIB = 0x6475d2c6b2e2Dc3de7F26226D08651F7F85ACf08; // IPOR PlasmaVaultMarketsLib the vault runs (F2)
    uint256 internal constant MARKET_LEND = 41; // MORPHO_LIQUIDITY_IN_MARKETS ("Lend Only"): supply-only, loan token valued
    // by IPOR's MorphoOnlyLiquidityBalanceFuse (never prices collateral). Live since L9 (2026-09-25).

    // Roles (IPOR access manager)
    uint64 internal constant ROLE_ALPHA = 200;
    uint64 internal constant ROLE_CLAIM_REWARDS = 600;
    uint64 internal constant ROLE_UPDATE_MARKETS_BALANCES = 1000;

    bytes32 internal constant WITHDRAW_MANAGER_SLOT = 0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100;

    /// @notice REQUIRED V2 upgrade gate: the new dedicated signer-config fuse must be on chain,
    /// the one-time legacy installer must be unregistered, and the original factory base must still
    /// be the wrapper's delegation target. The check reads LIVE state; the JSON alone never passes it.
    /// @dev The v2 config fuse version method was added to the revised implementation, not the old installer
    /// or the older standalone configuration fuse. DO NOT weaken this gate to read only JSON.
    function _requireQuestSigningV2() internal view {
        string memory path = vm.envOr("QUEST_DEPLOYMENTS", string("deployments/katana-quests.json"));
        string memory q = vm.readFile(path);
        address original = vm.parseJsonAddress(q, ".originalBase");
        address wrapper = vm.parseJsonAddress(q, ".base1271");
        address installer = vm.parseJsonAddress(q, ".signatureFuse");
        address config = vm.parseJsonAddress(q, ".configFuse");
        address recordedSigner = vm.parseJsonAddress(q, ".signer");
        address requiredSigner = vm.envOr("QUEST_REQUIRED_SIGNER", recordedSigner);

        require(original != address(0) && original.code.length != 0, "QUEST V2: original factory base missing");
        require(wrapper != address(0) && wrapper.code.length != 0, "QUEST V2: signing wrapper missing");
        require(installer != address(0) && installer.code.length != 0, "QUEST V2: installer record invalid");
        require(CurveYieldSignatureFuse(installer).VAULT() == VAULT, "QUEST V2: old installer vault mismatch");
        require(CurveYieldSignatureFuse(installer).BASE_1271() == wrapper, "QUEST V2: old installer wrapper mismatch");
        require(CurveYieldSignatureFuse(installer).ORIGINAL_BASE() == original,
            "QUEST V2: old installer original base mismatch");
        require(config != address(0) && config.code.length != 0 && config != installer, "QUEST V2: revised config fuse absent");
        require(CurveYieldQuestSignerConfigFuse(config).QUEST_SIGNING_LAYER_VERSION() == 2,
            "QUEST V2: outdated signer-config implementation");
        require(CurveYieldQuestSignerConfigFuse(config).VAULT() == VAULT, "QUEST V2: config vault mismatch");
        require(CurveYieldQuestSignerConfigFuse(config).BASE_1271() == wrapper, "QUEST V2: config wrapper mismatch");
        require(CurveYieldQuestSignerConfigFuse(config).ORIGINAL_BASE() == original,
            "QUEST V2: config factory base mismatch");
        require(CurveYieldQuestSignerConfigFuse(config).MARKET_ID() == MARKET_ERC20,
            "QUEST V2: config market mismatch");
        require(CurveYieldVaultBase1271(wrapper).ORIGINAL_BASE() == original,
            "QUEST V2: original factory base no longer delegated to");

        IQuestSigningVaultGate v = IQuestSigningVaultGate(VAULT);
        require(v.PLASMA_VAULT_BASE() == wrapper, "QUEST V2: ERC1271 wrapper no longer active");
        require(v.isFuseSupported(config), "QUEST V2: revised config fuse not registered");
        require(!v.isFuseSupported(installer), "QUEST V2: legacy installation fuse still registered");
        require(requiredSigner != address(0) && v.isQuestSigner(requiredSigner),
            "QUEST V2: no verified authorized signer");
        bytes memory activePrefix = v.questSignPrefix();
        require(activePrefix.length != 0, "QUEST V2: signing prefix empty");
        // Check that the vault exposes the ERC-1271 selector and rejects an invalid signature.
        require(v.isValidSignature(bytes32(0), abi.encode(bytes("invalid"), new bytes(65))) == 0xffffffff,
            "QUEST V2: invalid signature was accepted");
    }

    // Per-instance path overrides (tests run in parallel and share environment variables, so they set these instead).
    string internal _p2PathOverride;
    string internal _lendPathOverride;

    function setPaths(string calldata phase2Path_, string calldata lendingPath_) external {
        _p2PathOverride = phase2Path_;
        _lendPathOverride = lendingPath_;
    }

    function _deploymentsPath() internal view returns (string memory) {
        if (bytes(_p2PathOverride).length != 0) return _p2PathOverride;
        return vm.envOr("PHASE2_DEPLOYMENTS", string("deployments/katana-phase2.json"));
    }

    function _lendingPath() internal view returns (string memory) {
        if (bytes(_lendPathOverride).length != 0) return _lendPathOverride;
        return vm.envOr("LENDING_DEPLOYMENTS", string("deployments/katana-lending-v1.json"));
    }

    /// @dev Registers an address once using IPOR roles. A same-address re-run is a no-op;
    /// fee-sensitive revenue destinations and contributors custody are permanently ADMIN_FEE-controlled.
    function _wireAddr(address gate_, bytes32 key_, address addr_) internal {
        address current = IGateAddrRegistry(gate_).addrOrZero(key_);
        if (current == address(0)) IGateAddrRegistry(gate_).registerAddr(key_, addr_);
        else require(current == addr_, "wiring key already set: IPOR operational repoint requires V4 gate permissions; fee-sensitive keys require ADMIN_FEE");
    }

    function _start() internal {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) {
            require(vm.addr(pk) == DEPLOYER, "PRIVATE_KEY is not the deployer");
            vm.startBroadcast(pk);
        } else {
            vm.startBroadcast(DEPLOYER);
        }
    }

    function _stop() internal {
        vm.stopBroadcast();
    }

    /// @dev An address from the deployment record, which must hold code: the record is a next-phase file and some of its
    /// entries collide with live contracts on Katana (IPOR_FUSE_CONFORMANCE_SPEC §2.6).
    function _addr(string memory json_, string memory key_) internal view returns (address a_) {
        a_ = vm.parseJsonAddress(json_, string.concat(".", key_));
        require(a_.code.length != 0, string.concat("no code at recorded address: ", key_));
    }

    /// @dev grantMarketSubstrates REPLACES a market's list: append to what is there (skipping duplicates).
    function _appendSubstrates(uint256 market_, bytes32[] memory add_) internal {
        bytes32[] memory cur = IVaultConfigAppend(VAULT).getMarketSubstrates(market_);
        bytes32[] memory out = new bytes32[](cur.length + add_.length);
        uint256 n;
        for (uint256 i; i < cur.length; ++i) out[n++] = cur[i];
        for (uint256 i; i < add_.length; ++i) {
            bool dup;
            for (uint256 j; j < n; ++j) if (out[j] == add_[i]) dup = true;
            if (!dup) out[n++] = add_[i];
        }
        assembly { mstore(out, n) }
        IVaultConfigAppend(VAULT).grantMarketSubstrates(market_, out);
    }

    /// @dev Typed CurveYield substrate: type in the top byte (CurveYieldSubstrateLib), payload below.
    function _typed(uint256 type_, address account_) internal pure returns (bytes32) {
        return bytes32((type_ << 248) | uint256(uint160(account_)));
    }

    /// @dev IPOR UniversalTokenSwapper substrates: 1 Token, 2 Target (top byte), 3 Slippage (WAD).
    function _utsToken(address a_) internal pure returns (bytes32) { return _typed(1, a_); }
    function _utsTarget(address a_) internal pure returns (bytes32) { return _typed(2, a_); }
    function _utsSlippage(uint256 wad_) internal pure returns (bytes32) { return bytes32((uint256(3) << 248) | wad_); }

    /// @dev The governance gate (deployed by P0_00; PHASE0_DEPLOYMENTS overrides the record path).
    function _gateAddress() internal view returns (address) {
        return vm.parseJsonAddress(
            vm.readFile(vm.envOr("PHASE0_DEPLOYMENTS", string("deployments/katana-gate-v4.json"))), ".governanceGate"
        );
    }

    function _readDeployments() internal view returns (string memory) {
        return vm.readFile(_deploymentsPath());
    }
}
