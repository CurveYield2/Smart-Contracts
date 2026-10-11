// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {CurveYieldAddrKeys} from "../src/governance/CurveYieldGateConfig.sol";
import {CurveYieldGovernanceGate} from "../src/governance/CurveYieldGovernanceGate.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {CurveYieldMorphoLoopController} from "../src/morpho/CurveYieldMorphoLoopController.sol";
import {CurveYieldUsdcStrategyController, CyUsdcEnv} from "../src/morpho/CurveYieldUsdcStrategyController.sol";
import {CyLoopEnv} from "../src/morpho/CurveYieldMorphoLoopLib.sol";
import {CurveYieldBundleGuardFuse} from "../src/generic/CurveYieldBundleGuardFuse.sol";
import {CurveYieldErc20TransferFuse} from "../src/generic/CurveYieldErc20TransferFuse.sol";
import {CurveYieldBurnHeldSharesFuse} from "../src/generic/CurveYieldBurnHeldSharesFuse.sol";
import {CurveYieldSwapRouterV2, CyHop} from "../src/router/CurveYieldSwapRouterV2.sol";
import {CurveYieldRequestFeeSharesFuse} from "../src/withdraw/CurveYieldRequestFeeSharesFuse.sol";
import {CurveYieldAllocationController, CySets} from "../src/allocation/CurveYieldAllocationController.sol";
import {CurveYieldVaultExecutor, CyExecutorDeps} from "../src/executor/CurveYieldVaultExecutor.sol";
import {CurveYieldWithdrawalManagerV2} from "../src/withdraw/CurveYieldWithdrawalManagerV2.sol";
import {CurveYieldAvkatLendController} from "../src/lend/CurveYieldAvkatLendController.sol";
import {UniversalTokenSwapperFuse} from "contracts/fuses/universal_token_swapper/UniversalTokenSwapperFuse.sol";
import {UpdateMarketsBalancesFuse} from "contracts/fuses/update_balances/UpdateMarketsBalancesFuse.sol";
import {TransientStorageMapperFuse} from "contracts/fuses/transient_storage/TransientStorageMapperFuse.sol";
import {PlasmaVaultBalanceAssetsValidationFuse} from "contracts/fuses/PlasmaVaultBalanceAssetsValidationFuse.sol";
import {Erc4626SupplyFuse} from "contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {Erc4626BalanceFuse} from "contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {MorphoFlashLoanFuse} from "contracts/fuses/morpho/MorphoFlashLoanFuse.sol";
import {ZeroBalanceFuse} from "contracts/fuses/ZeroBalanceFuse.sol";
import {BurnRequestFeeFuse} from "contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol";
import {CallbackHandlerMorpho} from "contracts/handlers/callbacks/CallbackHandlerMorpho.sol";
import {UpdateWithdrawManagerMaintenanceFuse} from "contracts/fuses/maintenance/UpdateWithdrawManagerMaintenanceFuse.sol";
import {MorphoSupplyFuse} from "contracts/fuses/morpho/MorphoSupplyFuse.sol";

interface IWmOld {
    function getWithdrawFee() external view returns (uint256);
    function getRequestFee() external view returns (uint256);
    function getWithdrawWindow() external view returns (uint256);
}

interface IV3FactoryP21 {
    function getPool(address a, address b, uint24 fee) external view returns (address);
}

/// M1 (IPOR_FUSE_CONFORMANCE_SPEC §6): deploy every contract of the new stack and wire them to each other. Does NOT touch
/// the vault. Everything is compiled against the IPOR version the live vault runs (`a1f79d6`, F2) with the default
/// profile: the executor and the withdraw manager fit EIP-170 without a special build.
///   - official IPOR fuses: UniversalTokenSwapperFuse (12), Erc4626Supply / Balance (100_001), UpdateMarketsBalances,
///     TransientStorageMapper, PlasmaVaultBalanceAssetsValidation, the UNMODIFIED MorphoFlashLoanFuse (19), BurnRequestFee;
///   - the custom fuses that remain (§4.2): bundle guard, ERC-20 transfer, burn held shares, request-fee shares;
///   - swap router v2 (the only router Target of the swapper), planners (loop, USDC strategy, lending), allocation,
///     withdraw manager v2 and the executor.
/// Settings: every numerical setting lives in the governance gate (P0_00, run first). Writes the deployment record
/// (PHASE2_DEPLOYMENTS) with the addresses just deployed: the next-phase record is overwritten key by key, never trusted
/// without code (Phase2Base._addr).
///   forge script script/P2_01_Deploy.s.sol --root <upgrade path> --rpc-url katana                     # dry run
///   forge script script/P2_01_Deploy.s.sol --root <upgrade path> --rpc-url katana --broadcast --slow \
///     --with-gas-price 3000000 --priority-gas-price 1000000
contract P2_01_Deploy is Phase2Base {
    address internal gate;
    // core
    CurveYieldAllocationController internal allocation;
    CurveYieldWithdrawalManagerV2 internal wm;
    CurveYieldMorphoLoopController internal loop;
    CurveYieldUsdcStrategyController internal usdc;
    CurveYieldVaultExecutor internal executor;
    CurveYieldSwapRouterV2 internal routerV2;
    CurveYieldAvkatLendController internal lend;
    // custom fuses
    CurveYieldBundleGuardFuse internal guardFuse;
    CurveYieldErc20TransferFuse internal transferFuse;
    CurveYieldBurnHeldSharesFuse internal burnHeldFuse;
    CurveYieldRequestFeeSharesFuse internal requestFeeFuse;
    // official IPOR fuses
    UniversalTokenSwapperFuse internal swapperFuse;
    UpdateMarketsBalancesFuse internal updateBalancesFuse;
    TransientStorageMapperFuse internal mapperFuse;
    PlasmaVaultBalanceAssetsValidationFuse internal validationFuse;
    Erc4626SupplyFuse internal erc4626SupplyFuse;
    Erc4626BalanceFuse internal erc4626BalanceFuse;
    MorphoFlashLoanFuse internal flashFuse;
    ZeroBalanceFuse internal zeroBalance19;
    ZeroBalanceFuse internal zeroBalanceUtility;
    BurnRequestFeeFuse internal burnFuse;
    CallbackHandlerMorpho internal callbackHandler;
    UpdateWithdrawManagerMaintenanceFuse internal maintenanceFuse;
    MorphoSupplyFuse internal lendSupplyFuse;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        _requireQuestSigningV2(); // Mandatory updated Quest ERC-1271 signing layer for the V2 upgrade.
        gate = _gateAddress();
        require(CurveYieldGovernanceGate(gate).iporAccessManager() == ACCESS_MANAGER, "V4 gate must use original IPOR access manager");
        require(CurveYieldGovernanceGate(gate).feeConfigRegistrationSealed(), "V4 fee registry must be sealed");
        require(CurveYieldGovernanceGate(gate).adminFeeRoleHolder() == ADMIN_FEE_SAFE, "V4 ADMIN_FEE initial role holder");
        _start();
        _deployFuses();
        _deployRouter();
        _deployCore();
        _deployLend();
        _wire();
        _stop();
        _write();
    }

    function _deployFuses() internal {
        guardFuse = new CurveYieldBundleGuardFuse(MARKET_ZERO, MORPHO);
        transferFuse = new CurveYieldErc20TransferFuse(MARKET_ERC20);
        burnHeldFuse = new CurveYieldBurnHeldSharesFuse(MARKET_ZERO);
        requestFeeFuse = new CurveYieldRequestFeeSharesFuse(MARKET_ZERO);
        swapperFuse = new UniversalTokenSwapperFuse(MARKET_SWAP);
        updateBalancesFuse = new UpdateMarketsBalancesFuse();
        mapperFuse = new TransientStorageMapperFuse();
        validationFuse = new PlasmaVaultBalanceAssetsValidationFuse(MARKET_ZERO);
        erc4626SupplyFuse = new Erc4626SupplyFuse(MARKET_ERC4626);
        erc4626BalanceFuse = new Erc4626BalanceFuse(MARKET_ERC4626);
        flashFuse = new MorphoFlashLoanFuse(MARKET_FLASH, MORPHO);
        zeroBalance19 = new ZeroBalanceFuse(MARKET_FLASH);
        // Reuse the already deployed, market-max ZeroBalanceFuse; validated on Katana fork (run 38144542830).
        zeroBalanceUtility = ZeroBalanceFuse(0xE3E28F04499470bAc1dAc842aEe424a185d14D42);
        burnFuse = new BurnRequestFeeFuse(type(uint256).max);
        callbackHandler = new CallbackHandlerMorpho();
        maintenanceFuse = new UpdateWithdrawManagerMaintenanceFuse(0);
    }

    /// @dev Swap router v2 (owned by the deployer until P3_04 hands it to the gate) with the Sushi routes the stack uses.
    /// The CurveYield DEX (Balancer) is wired later with setBalancer (P5).
    function _deployRouter() internal {
        routerV2 = new CurveYieldSwapRouterV2(DEPLOYER, gate, ADMIN_FEE_SAFE, SUSHI_FACTORY, SUSHI_INIT_CODE_HASH);
        _wireAddr(gate, CurveYieldAddrKeys.SWAP_ROUTER, address(routerV2));
        CyHop[] memory hops = new CyHop[](1);
        hops[0] = CyHop(1, AVKAT, KAT, POOL_1PCT, 10_000);
        routerV2.setRoute(AVKAT, KAT, hops);
        hops[0] = CyHop(1, KAT, AVKAT, POOL_1PCT, 10_000);
        routerV2.setRoute(KAT, AVKAT, hops);
        // avKAT <-> vbUSDC (USDC strategy: buys a cyvbUSDC shortfall before a repay) when the 0.3% pool exists
        address p3000 = IV3FactoryP21(SUSHI_FACTORY).getPool(AVKAT, VBUSDC_TOKEN, 3_000);
        if (p3000 != address(0)) {
            hops[0] = CyHop(1, AVKAT, VBUSDC_TOKEN, p3000, 3_000);
            routerV2.setRoute(AVKAT, VBUSDC_TOKEN, hops);
            hops[0] = CyHop(1, VBUSDC_TOKEN, AVKAT, p3000, 3_000);
            routerV2.setRoute(VBUSDC_TOKEN, AVKAT, hops);
        }
    }

    function _deployCore() internal {
        _wireAddr(gate, CurveYieldAddrKeys.REWARDS_CLAIM_MANAGER, RCM);
        // Initial bootstrapping only: growth is repointed ONCE to V2 custody in P6 after it is deployed.
        _wireAddr(gate, CurveYieldAddrKeys.REVENUE_CUSTODY, GROWTH_CUSTODY);
        _wireAddr(gate, CurveYieldAddrKeys.LOOP_GROWTH_RECIPIENT, GROWTH_CUSTODY);
        _wireAddr(gate, CurveYieldAddrKeys.LOOP_CONTRIBUTORS_RECIPIENT, ADMIN_FEE_SAFE);
        _wireAddr(gate, CurveYieldAddrKeys.TRANSFER_FUSE, address(transferFuse));
        allocation = new CurveYieldAllocationController(DEPLOYER, VAULT, AVKAT, gate);

        wm = new CurveYieldWithdrawalManagerV2(ACCESS_MANAGER, WM_TEMPLATE);
        _wireAddr(gate, CurveYieldAddrKeys.WITHDRAW_MANAGER, address(wm));
        wm.updatePlasmaVaultAddress(VAULT);
        wm.updateWithdrawWindow(IWmOld(WM_OLD).getWithdrawWindow());
        wm.setConfigGate(gate); // fees and split bps from the gate (registered from the live manager's values)
        wm.setOnboardingAdmin(ADMIN_FEE_SAFE); // ONBOARDING_FEE_SPEC: 30% of the onboarding fee (deployer = fee authority)
        wm.setProfitCustody(GROWTH_CUSTODY);

        loop = new CurveYieldMorphoLoopController(
            DEPLOYER,
            CyLoopEnv({
                vault: VAULT, morpho: MORPHO, marketId: LOOP_MARKET, avkat: AVKAT, kat: KAT,
                collateralFuse: COLLATERAL_FUSE, borrowFuse: BORROW_FUSE, flashLoanFuse: address(flashFuse),
                swapFuse: address(swapperFuse), router: address(routerV2), guardFuse: address(guardFuse),
                withdrawManager: address(wm)
            }),
            gate
        );
        usdc = new CurveYieldUsdcStrategyController(
            DEPLOYER,
            CyUsdcEnv({
                vault: VAULT, morpho: MORPHO, marketId: USDC_LOOP_MARKET, avkat: AVKAT, usdc: VBUSDC_TOKEN,
                supplyVault: CYVBUSDC, collateralFuse: COLLATERAL_FUSE, borrowFuse: BORROW_FUSE,
                supplyFuse: address(erc4626SupplyFuse), swapFuse: address(swapperFuse), router: address(routerV2),
                guardFuse: address(guardFuse), withdrawManager: address(wm)
            }),
            gate
        );
        executor = new CurveYieldVaultExecutor(
            DEPLOYER, VAULT, AVKAT,
            CyExecutorDeps({
                allocation: address(allocation), withdrawManager: address(wm), rewardsClaimManager: RCM,
                transferFuse: address(transferFuse), guardFuse: address(guardFuse)
            }),
            gate
        );
    }

    function _deployLend() internal {
        lend = new CurveYieldAvkatLendController(DEPLOYER, VAULT, MORPHO, LEND_MARKET, gate);
        // Reuse the IPOR lending fuse if L1_InstallLendingV1 already installed it on the live vault.
        try vm.readFile(_lendingPath()) returns (string memory j) {
            lendSupplyFuse = MorphoSupplyFuse(vm.parseJsonAddress(j, ".lendSupplyFuse"));
        } catch {
            lendSupplyFuse = new MorphoSupplyFuse(MARKET_LEND, MORPHO);
        }
    }

    function _wire() internal {
        loop.setExecutor(address(executor));
        loop.setAllocation(address(allocation));
        usdc.setExecutor(address(executor));
        lend.setExecutor(address(executor));
        lend.setFuses(address(lendSupplyFuse));
        allocation.setSets(CySets({loop: address(loop), usdc: address(usdc), lend: address(lend), pol: address(0)}));
        allocation.setExecutor(address(executor));
    }

    function _write() internal {
        string memory o = "p2";
        vm.serializeAddress(o, "allocation", address(allocation));
        vm.serializeAddress(o, "transferFuse", address(transferFuse));
        vm.serializeAddress(o, "guardFuse", address(guardFuse));
        vm.serializeAddress(o, "burnHeldSharesFuse", address(burnHeldFuse));
        vm.serializeAddress(o, "requestFeeSharesFuse", address(requestFeeFuse));
        vm.serializeAddress(o, "swapperFuse", address(swapperFuse));
        vm.serializeAddress(o, "swapExecutor", swapperFuse.EXECUTOR());
        vm.serializeAddress(o, "updateMarketsBalancesFuse", address(updateBalancesFuse));
        vm.serializeAddress(o, "transientStorageMapperFuse", address(mapperFuse));
        vm.serializeAddress(o, "balanceValidationFuse", address(validationFuse));
        vm.serializeAddress(o, "erc4626SupplyFuse", address(erc4626SupplyFuse));
        vm.serializeAddress(o, "erc4626BalanceFuse", address(erc4626BalanceFuse));
        vm.serializeAddress(o, "flashLoanFuse", address(flashFuse));
        vm.serializeAddress(o, "zeroBalanceFlash", address(zeroBalance19));
        vm.serializeAddress(o, "zeroBalanceUtility", address(zeroBalanceUtility));
        vm.serializeAddress(o, "swapRouterV2", address(routerV2));
        vm.serializeAddress(o, "withdrawManagerV2", address(wm));
        vm.serializeAddress(o, "loopController", address(loop));
        vm.serializeAddress(o, "usdcController", address(usdc));
        vm.serializeAddress(o, "executor", address(executor));
        vm.serializeAddress(o, "burnRequestFeeFuse", address(burnFuse));
        vm.serializeAddress(o, "callbackHandlerMorpho", address(callbackHandler));
        vm.serializeAddress(o, "withdrawManagerMaintenanceFuse", address(maintenanceFuse));
        vm.serializeAddress(o, "lendController", address(lend));
        string memory json = vm.serializeAddress(o, "lendSupplyFuse", address(lendSupplyFuse));
        vm.writeJson(json, _deploymentsPath());
        console2.log("deployed; addresses written to", _deploymentsPath());
        console2.log("executor", address(executor));
        console2.log("withdrawManagerV2", address(wm));
    }
}
