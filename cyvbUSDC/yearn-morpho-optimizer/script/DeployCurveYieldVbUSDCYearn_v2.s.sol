// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import {Script} from "forge-std/Script.sol";
import {Id, IMorpho, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {YearnMorphoRankedMaster_v2} from "../contracts/YearnMorphoRankedMaster_v2.sol";
import {YearnMorphoMarketChild_v2} from "../contracts/YearnMorphoMarketChild_v2.sol";

interface IYearnVaultFactoryKatanaV2 {
    function apiVersion() external view returns (string memory);
    function deploy_new_vault(
        address underlying, string calldata name, string calldata symbol,
        address roleManager, uint256 profitMaxUnlockTime
    ) external returns (address);
}

interface IYearnVaultKatanaV2 {
    function asset() external view returns (address);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function role_manager() external view returns (address);
    function set_role(address account, uint256 roles) external;
    function set_auto_allocate(bool enabled) external;
    function set_deposit_limit(uint256 limit) external;
    function add_strategy(address strategy) external;
    function update_max_debt_for_strategy(address strategy, uint256 maxDebt) external;
    function transfer_role_manager(address newRoleManager) external;
    function deposit(uint256 assets, address receiver) external returns (uint256);
}

interface IIPORMorphoSubstratesV2 {
    function getMarketSubstrates(uint256 iporMarketId) external view returns (bytes32[] memory);
}
interface IIPORMorphoSupplyFuseV2 {
    function MORPHO() external view returns (address);
}
interface IERC20ApproveV2 {
    function approve(address spender,uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

/// @dev Exact same router interface as the active cyavKAT IPOR router
///      at 0x01F9894f92ea9224fECc8C35482E20a05De13582.
interface ICurveYieldSushiFeeRouterKatanaV2 {
    function routeFor(address tokenIn, address tokenOut) external view returns (bytes memory);
    function routeTwapGuard(address tokenIn, address tokenOut)
        external view returns (uint32 window, uint16 maxDeviationBps, bool configured);
}

/// @title CurveYield vbUSDC Yearn V3 vault + 4 dedicated direct-market child strategies.
/// @notice **No private key stored in source.**  Broadcast ONLY after successful fork
///         preflight and security review. In GitHub CI the key is a dummy fork signer.
/// @dev Uses Yearn official V3.1.0 factory, not the IPOR factory.
///      Source markets inherited from cyvbUSDC/script/DeployCyvbUSDC_v4.s.sol.
contract DeployCurveYieldVbUSDCYearn_v2 is Script {
    uint256 internal constant KATANA = 747474;
    uint256 internal constant IPOR_MORPHO_MARKET = 41;
    uint256 internal constant FOUR_CHILD_SEED = 400_000; // 4 x 0.1 vbUSDC
    uint256 internal constant ROLE_ALL = 16_383;

    address internal constant VBUSDC = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36;
    address internal constant KAT = 0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d;
    address internal constant IPOR_VAULT = 0xDf9CbCB8b57A031e91CAe673a6A5786d85Ce2eC5;
    address internal constant IPOR_MORPHO_FUSE = 0x1f657229ec2D261be7dCD63ca82abed334d1f28b;
    address internal constant CURVEYIELD_ROUTER = 0x01F9894f92ea9224fECc8C35482E20a05De13582;
    address internal constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;
    address internal constant YEARN_FACTORY = 0x310aC28ACF5E514abDbFF9Ab25e21f1bfe22bcAC;
    address internal constant YEARN_TOKENIZED_STRATEGY = 0x310f5Db015E9d6E542fd41bd4542640790791e76;
    address internal constant DEFAULT_OWNER = 0x11b78837cadC8E894F1c6e13fA9f3A085a75FA35;

    bytes32 internal constant AVKAT = 0xbd48214a2f12e951da20ad0b8fd83b611c693b5bbaa280b68ba4075678f2a138;
    bytes32 internal constant SIUSD = 0xf7fc5cc82200ddf8f23188ddbd6727eda2c8bc41863e91fb767bbc6e4f71890e;
    bytes32 internal constant WEETH = 0x76e311d4b0e2e6ae88ad9bab18063452a6d39837d7104c430ff62457b91cb2cb;
    bytes32 internal constant YVAUSD = 0xcfac40b9f06194a33d9526f73642f6849b908c2b6d8669ad9d2d4a3e7dcb017a;

    event CurveYieldYearnDeployment(
        address indexed vault, address indexed master, address indexed owner,
        address[4] children, bytes32[4] marketIds, uint256 initialSeed
    );

    /// @dev Read the live IPOR market allowlist and verify each Morpho market's
    ///      loan token. This rejects changed or incompatible substrates.
    function checkedMarkets() public view returns (address morphoAddress, bytes32[4] memory ids) {
        require(block.chainid == KATANA, "not Katana");
        require(IPOR_VAULT.code.length > 0, "IPOR vault missing");
        require(IPOR_MORPHO_FUSE.code.length > 0, "IPOR Morpho fuse missing");
        require(YEARN_FACTORY.code.length > 0, "Yearn factory missing");
        require(YEARN_TOKENIZED_STRATEGY.code.length > 0, "Yearn strategy impl missing");
        require(VBUSDC.code.length > 0 && KAT.code.length > 0, "asset/reward missing");
        require(CURVEYIELD_ROUTER.code.length > 0, "reward swap router missing");
        require(MERKL_DISTRIBUTOR.code.length > 0, "Merkl distributor missing");
        // cyavKAT uses this very same deployed Sushi V3 fee router.
        // The child uses its unchanged v1-compatible swapExactInput ABI.
        bytes memory rewardRoute =
            ICurveYieldSushiFeeRouterKatanaV2(CURVEYIELD_ROUTER).routeFor(KAT, VBUSDC);
        require(rewardRoute.length != 0, "cyavKAT router KAT->vbUSDC route missing");
        (uint32 twapWindow, uint16 deviationBps, bool enabled) =
            ICurveYieldSushiFeeRouterKatanaV2(CURVEYIELD_ROUTER).routeTwapGuard(KAT, VBUSDC);
        require(enabled && twapWindow != 0 && deviationBps <= 2000, "router TWAP guard inactive");
        require(
            keccak256(bytes(IYearnVaultFactoryKatanaV2(YEARN_FACTORY).apiVersion())) ==
                keccak256(bytes("3.1.0")),
            "wrong Yearn V3 factory release"
        );

        ids = [AVKAT, SIUSD, WEETH, YVAUSD];
        bytes32[] memory ipor = IIPORMorphoSubstratesV2(IPOR_VAULT).getMarketSubstrates(IPOR_MORPHO_MARKET);
        // The live IPOR vault currently returns zero Morpho substrates for
        // market 41 (verified 2026-10-13). Source the original three immutable
        // IDs from its checked-in DeployCyvbUSDC_v4.s.sol when that happens.
        // If a live allowlist exists, it MUST contain precisely the same three
        // IDs; never silently accept an altered live deployment.
        if (ipor.length != 0) {
            require(ipor.length == 3, "IPOR Morpho allowlist changed");
            for (uint256 i; i < 3; ++i) {
                uint256 matches;
                for (uint256 j; j < 3; ++j) {
                    if (ids[i] == ipor[j]) matches++;
                }
                require(matches == 1, "IPOR Morpho market mismatch");
            }
        }
        morphoAddress = IIPORMorphoSupplyFuseV2(IPOR_MORPHO_FUSE).MORPHO();
        require(morphoAddress.code.length > 0, "Morpho Blue missing");
        for (uint256 i; i < 4; ++i) {
            MarketParams memory params = IMorpho(morphoAddress).idToMarketParams(Id.wrap(ids[i]));
            require(params.loanToken == VBUSDC, "market loan token not vbUSDC");
            require(params.collateralToken != address(0), "uninitialized market");
        }
    }

    /// @notice Deploy exactly four child strategies and one Yearn V3 allocator
    ///         vault. All protocol configuration and handoff in one transaction
    ///         on Katana. Safe/owner later accepts 2-step vault role transfer.
    function run() external returns (address vaultAddress, address masterAddress) {
        (address morphoAddress, bytes32[4] memory marketIds) = checkedMarkets();
        uint256 key = vm.envUint("DEPLOYER_FX");
        address deployer = vm.addr(key);
        address owner = vm.envOr("FINAL_OWNER", DEFAULT_OWNER);
        address keeper = vm.envOr("STRATEGY_KEEPER", deployer);
        uint256 seed = vm.envOr("INITIAL_SEED_VBUSDC", uint256(0));
        require(owner != address(0) && keeper != address(0), "invalid owner/keeper");
        // If seeding, enough must reach all 4 child positions to establish PPS.
        require(seed == 0 || seed >= FOUR_CHILD_SEED, "seed below four-child minimum");
        if (seed != 0) {
            require(IERC20ApproveV2(VBUSDC).balanceOf(deployer) >= seed, "deployer lacks seed");
        }

        vm.startBroadcast(key);
        YearnMorphoRankedMaster_v2 master = new YearnMorphoRankedMaster_v2(
            VBUSDC, "CurveYield vbUSDC Master Strategy"
        );
        masterAddress = address(master);
        ITokenizedStrategy(masterAddress).setKeeper(keeper);
        ITokenizedStrategy(masterAddress).setProfitMaxUnlockTime(0);
        ITokenizedStrategy(masterAddress).setPerformanceFee(0);
        require(master.minimumChildDeposit() == 100_000, "minimum != 0.1 vbUSDC");

        address[4] memory created;
        for (uint256 i; i < 4; ++i) {
            created[i] = _deployChild(morphoAddress, marketIds[i], masterAddress, i);
            master.addChild(created[i]);
        }
        require(master.childCount() == 4, "child registration failed");

        // Yearn vault factory takes role_manager = caller, allowing initial
        // permission setup before future transfer to multisig owner.
        vaultAddress = IYearnVaultFactoryKatanaV2(YEARN_FACTORY).deploy_new_vault(
            VBUSDC, "CurveYield vbUSDC", "cyvbUSDC", deployer, 1 days
        );
        IYearnVaultKatanaV2 vault = IYearnVaultKatanaV2(vaultAddress);
        require(vault.asset() == VBUSDC, "wrong vault asset");
        require(keccak256(bytes(vault.name())) == keccak256(bytes("CurveYield vbUSDC")), "wrong name");
        require(keccak256(bytes(vault.symbol())) == keccak256(bytes("cyvbUSDC")), "wrong symbol");
        require(vault.role_manager() == deployer, "wrong role manager");

        // Yearn v3 Roles.ALL = 16383. Configuration is done by current role manager.
        vault.set_role(deployer, ROLE_ALL);
        vault.add_strategy(masterAddress);
        vault.update_max_debt_for_strategy(masterAddress, type(uint256).max);
        vault.set_deposit_limit(type(uint256).max);
        vault.set_auto_allocate(true); // deposit/mint automatically enters master
        if (seed != 0) {
            require(IERC20ApproveV2(VBUSDC).approve(vaultAddress, seed), "seed approve failed");
            vault.deposit(seed, owner); // actual first deposit establishes all four PPS positions
            require(ITokenizedStrategy(masterAddress).balanceOf(vaultAddress) != 0, "master not funded");
            for (uint256 i; i < 4; ++i) {
                uint256 ownedShares = ITokenizedStrategy(created[i]).balanceOf(masterAddress);
                require(ownedShares != 0, "child missing seeded shares");
                uint256 childAssets = ITokenizedStrategy(created[i]).convertToAssets(ownedShares);
                // Tolerate up to two base units of ERC4626 virtual share rounding.
                require(childAssets + 2 >= master.minimumChildDeposit(), "child below minimum seed");
            }
        }

        // Governance handoff: keeper stays independent; the owner receives
        // strategy management after 2-step acceptance. This also makes future
        // rank weights and minimumChildDeposit owner-configurable.
        ITokenizedStrategy(masterAddress).setPendingManagement(owner);
        for (uint256 i; i < 4; ++i) ITokenizedStrategy(created[i]).setPendingManagement(owner);
        vault.set_role(owner, ROLE_ALL);
        if (owner != deployer) {
            vault.set_role(deployer, 0);
            vault.transfer_role_manager(owner);
        }

        emit CurveYieldYearnDeployment(vaultAddress, masterAddress, owner, created, marketIds, seed);
        vm.stopBroadcast();
    }
    function _deployChild(address morpho, bytes32 id, address master, uint256 index)
        internal returns (address childAddress)
    {
        string memory name;
        if (index == 0) name = "CurveYield vbUSDC - avKAT Morpho";
        else if (index == 1) name = "CurveYield vbUSDC - siUSD Morpho";
        else if (index == 2) name = "CurveYield vbUSDC - weETH Morpho";
        else name = "CurveYield vbUSDC - yvAUSD Morpho";

        YearnMorphoMarketChild_v2 child = new YearnMorphoMarketChild_v2(
            VBUSDC, name, morpho, Id.wrap(id), master,
            KAT, CURVEYIELD_ROUTER, MERKL_DISTRIBUTOR
        );
        childAddress = address(child);
        ITokenizedStrategy(childAddress).setKeeper(master);
        ITokenizedStrategy(childAddress).setProfitMaxUnlockTime(0);
        ITokenizedStrategy(childAddress).setPerformanceFee(0);
    }

}
