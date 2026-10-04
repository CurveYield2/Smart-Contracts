// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

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

abstract contract Phase2Base is Script {
    // Live Katana system
    address internal constant VAULT = 0xEd83daf48429cfb2C650Fd721b9241e180fd4548;
    address internal constant ACCESS_MANAGER = 0xd7f408f203c5c6a76c9c55c9f6b015929F151fAA;
    address internal constant RCM = 0xA77470B748A8Fb50056Ca3c07375dC76Aa3A72Cb;
    address internal constant WM_OLD = 0x59B340EAb30AFE0cecD51C609d3190e8C75C40AE;
    address internal constant WM_TEMPLATE = 0x7a0928c0E99e50b2D51C8db7DC400123982687CF;
    address internal constant CONTROLLER_V2 = 0xbFdf2d2653859B66A8A15e1C85F6d6cdEe89698f;
    address internal constant GROWTH_CUSTODY = 0xe7D109Ce6b34447Dd45B54e5615F4177291D5ADf;
    address internal constant LEGACY_VKAT_FUSE = 0x987C05943855B22552898F032c1AEa7930E340da;
    address internal constant CALLER_REWARD_FUSE = 0x70a2f848E21c912D660FE2263E5Be538268A41Ec;
    address internal constant SWAP_FUSE = 0x1fB8b83bAf40c90F0b450A3fd7A8b2E97Ab2a3Ff;
    /// IPOR's own deployment of the official MerklClaimFuse, already a reward fuse of the rewards claim manager.
    address internal constant MERKL_CLAIM_FUSE = 0xc6d024E53204CADa27a3c60C77dA4de2e7eb5166;
    address internal constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae; // verified 2026-09-29: live tree root; same as the live MerklAutoHarvest fuse
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
    address internal constant VKAT_NFT = 0x106F7D67Ea25Cb9eFf5064CF604ebf6259Ff296d;
    address internal constant VKAT_ESCROW = 0x4d6fC15Ca6258b168225D283262743C623c13Ead;
    address internal constant EXIT_QUEUE = 0x6dE9cAAb658C744aD337Ca5d92D084c97ffF578d;
    address internal constant EPOCH_CLOCK = 0x17049d374A2bcdA70F8939C21ad92bcF6B2A95ab;
    address internal constant GAUGE_VOTER = 0x5e755A3C5dc81A79DE7a7cEF192FFA60964c9352;
    address internal constant DELEGATION = 0xB67Ac05e2C1d8592692a90BF61712274b988f25A;
    address internal constant VOTE_GAUGE = 0x744676B3CeD942D78F9b8e9cd22246Db5c32395c;
    address internal constant NPM = 0x2659C6085D26144117D904C46B48B6d180393d27;
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
    uint256 internal constant MARKET_LOOP = 14; // MORPHO: the loop 0x80e6 only
    uint256 internal constant MARKET_ERC20 = 7; // ERC20_VAULT_BALANCE: tokens + LP holder + exiting avKAT
    uint256 internal constant MARKET_SUBSTRATES = 54; // substrate-only list (live: vKAT set); typed CurveYield entries
    uint256 internal constant MARKET_LEND = 41; // MORPHO_LIQUIDITY_IN_MARKETS ("Lend Only"): supply-only, loan token valued
    // by IPOR's MorphoOnlyLiquidityBalanceFuse (never prices collateral). Live since L9 (2026-09-25).

    // Roles (IPOR access manager)
    uint64 internal constant ROLE_ALPHA = 200;
    uint64 internal constant ROLE_CLAIM_REWARDS = 600;
    uint64 internal constant ROLE_UPDATE_MARKETS_BALANCES = 1000;

    bytes32 internal constant WITHDRAW_MANAGER_SLOT = 0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100;

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

    /// @dev Deploys a contract built by the EIP-170 size profile (foundry.toml [profile.size]) with its constructor
    /// arguments. Build first: FOUNDRY_PROFILE=size forge build src/executor/CurveYieldVaultExecutor.sol
    /// src/withdraw/CurveYieldWithdrawalManagerV2.sol (this forge-std has vm.getCode, not deployCode).
    function _createSized(string memory name_, bytes memory args_) internal returns (address deployed_) {
        bytes memory code = abi.encodePacked(vm.getCode(string.concat("out-size/", name_, ".sol/", name_, ".json")), args_);
        assembly {
            deployed_ := create(0, add(code, 0x20), mload(code))
        }
        require(deployed_ != address(0), string.concat(name_, " deploy failed"));
    }

    /// @dev Registers a wiring address in the gate once (deployer = DAO or fee authority). A re-run with the same
    /// address is a no-op; a different address must go through the DAO's setAddr (single-contract redeploy).
    function _wireAddr(address gate_, bytes32 key_, address addr_) internal {
        address current = IGateAddrRegistry(gate_).addrOrZero(key_);
        if (current == address(0)) IGateAddrRegistry(gate_).registerAddr(key_, addr_);
        else require(current == addr_, "wiring key already set: replace it with the DAO's setAddr");
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

    function _addr(string memory json_, string memory key_) internal pure returns (address) {
        return vm.parseJsonAddress(json_, string.concat(".", key_));
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

    function _typed(uint256 type_, address account_) internal pure returns (bytes32) {
        return bytes32((type_ << 160) | uint256(uint160(account_)));
    }

    function _readDeployments() internal view returns (string memory) {
        return vm.readFile(_deploymentsPath());
    }
}
