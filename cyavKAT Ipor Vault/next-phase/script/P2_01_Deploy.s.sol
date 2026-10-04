// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {CurveYieldAddrKeys} from "../src/governance/CurveYieldGateConfig.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {CurveYieldLoopProfitSplitter} from "../src/morpho/CurveYieldLoopProfitSplitter.sol";
import {
    CurveYieldMorphoLoopController, CyLoopFuses
} from "../src/morpho/CurveYieldMorphoLoopController.sol";
import {CyLoopEnv} from "../src/morpho/CurveYieldMorphoLoopLib.sol";
import {CurveYieldLoopCycleFuse, CurveYieldLoopUnwindFuse} from "../src/generic/CurveYieldLoopFuses.sol";
import {CurveYieldBundleGuardFuse} from "../src/generic/CurveYieldBundleGuardFuse.sol";
import {CurveYieldSwapRouterV2, CyHop} from "../src/router/CurveYieldSwapRouterV2.sol";
import {CurveYieldRouterSwapFuseV2} from "../src/router/CurveYieldRouterSwapFuseV2.sol";
import {CurveYieldWithdrawalRequestFuse} from "../src/withdraw/CurveYieldWithdrawalRequestFuse.sol";
import {MerklClaimFuse} from "contracts/rewards_fuses/merkl/MerklClaimFuse.sol";
import {CurveYieldErc20TransferFuse} from "../src/generic/CurveYieldErc20TransferFuse.sol";
import {CurveYieldPlannedInstantWithdrawFuse} from "../src/generic/CurveYieldPlannedInstantWithdrawFuse.sol";
import {CurveYieldPositionReaderBalanceFuse} from "../src/generic/CurveYieldPositionReaderBalanceFuse.sol";
import {CurveYieldLpHolderReader, CurveYieldVkatExitReader} from "../src/accounting/CurveYieldPositionReaders.sol";
import {
    CurveYieldVeLockFuse, CurveYieldVeConvertFuse, CurveYieldVeVoteFuse, CurveYieldVeExitBeginFuse,
    CurveYieldVeExitWithdrawFuse
} from "../src/generic/CurveYieldVeFuses.sol";
import {
    CurveYieldHolderOpenFuse, CurveYieldHolderIncreaseFuse, CurveYieldHolderWithdrawFuse,
    CurveYieldHolderRebalanceFuse, CurveYieldHolderDeleverageFuse
} from "../src/generic/CurveYieldHolderFuses.sol";
import {CurveYieldAllocationController, CySets} from "../src/allocation/CurveYieldAllocationController.sol";
import {CurveYieldVaultExecutor, CyExecutorDeps} from "../src/executor/CurveYieldVaultExecutor.sol";
import {CurveYieldWithdrawalManagerV2} from "../src/withdraw/CurveYieldWithdrawalManagerV2.sol";
import {
    CurveYieldVkatController, CyVkatEnv, CyVkatFuses
} from "../src/vkat/CurveYieldVkatController.sol";
import {CurveYieldAvkatLendController} from "../src/lend/CurveYieldAvkatLendController.sol";
import {CurveYieldSushiLpHolder} from "../src/lp/CurveYieldSushiLpHolder.sol";
import {CurveYieldSushiLpController, CyLpFuses} from "../src/lp/CurveYieldSushiLpController.sol";
import {BurnRequestFeeFuse} from "contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol";
import {CallbackHandlerMorpho} from "contracts/handlers/callbacks/CallbackHandlerMorpho.sol";
import {UpdateWithdrawManagerMaintenanceFuse} from "contracts/fuses/maintenance/UpdateWithdrawManagerMaintenanceFuse.sol";
import {MorphoSupplyFuse} from "contracts/fuses/morpho/MorphoSupplyFuse.sol";
import {FixedValuePriceFeed} from "contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";
import {CurveYieldUsdcSupplyLoopFuse} from "../src/morpho/CurveYieldUsdcSupplyLoopFuse.sol";

interface IWmOld {
    function getWithdrawFee() external view returns (uint256);
    function getRequestFee() external view returns (uint256);
    function getWithdrawWindow() external view returns (uint256);
}

/// Phase 2 step 1/3: deploy every Phase 2 contract and wire them to each other. Does NOT touch the vault.
/// Fuse standardization (2026-09-27): the controllers are planners over stateless generic fuses (src/generic) and IPOR
/// fuses; typed substrates go in the substrate-only market 54 (granted by P2_02).
/// Settings: every numerical setting lives in the governance gate (P0_00_DeployGateConfig, run first); the contracts
/// here take the gate's address. Vault swaps go through the swap router v2 + swap fuse v2 (SWAP_ROUTING_SPEC).
/// Writes all addresses to deployments/katana-phase2.json (PHASE2_DEPLOYMENTS overrides the path).
///
/// From C:\Users\user\Desktop\Claude (so PRIVATE_KEY / KATANA_RPC_URL load from its .env):
///   forge script script/P2_01_Deploy.s.sol --root <phase2 path> --rpc-url katana                     # dry run
///   forge script script/P2_01_Deploy.s.sol --root <phase2 path> --rpc-url katana --broadcast --slow \
///     --with-gas-price 3000000 --priority-gas-price 1000000
contract P2_01_Deploy is Phase2Base {
    // core
    CurveYieldLoopProfitSplitter internal splitter;
    CurveYieldAllocationController internal allocation;
    CurveYieldErc20TransferFuse internal transferFuse;
    CurveYieldBundleGuardFuse internal guardFuse;
    CurveYieldPlannedInstantWithdrawFuse internal plannedInstantFuse;
    CurveYieldWithdrawalManagerV2 internal wm;
    CurveYieldMorphoLoopController internal loop;
    CurveYieldVaultExecutor internal executor;
    CurveYieldSwapRouterV2 internal routerV2;
    CurveYieldRouterSwapFuseV2 internal swapFuseV2;
    CurveYieldWithdrawalRequestFuse internal requestFuse;
    MerklClaimFuse internal merklClaimFuse;
    address internal gate;
    CyLoopFuses internal loopFuses;
    // IPOR helpers
    BurnRequestFeeFuse internal burnFuse;
    CallbackHandlerMorpho internal callbackHandler;
    UpdateWithdrawManagerMaintenanceFuse internal maintenanceFuse;
    // vKAT
    CurveYieldVkatController internal vkat;
    CyVkatFuses internal vkatFuses;
    // lending
    CurveYieldAvkatLendController internal lend;
    MorphoSupplyFuse internal lendSupplyFuse;
    // LP
    CurveYieldSushiLpController internal lp;
    CurveYieldSushiLpHolder internal lpHolder;
    CyLpFuses internal lpFuses;
    // market 7 balance fuse (tokens + position readers: LP holder, exiting vKAT)
    CurveYieldPositionReaderBalanceFuse internal erc20Balance;
    CurveYieldLpHolderReader internal lpReader;
    CurveYieldVkatExitReader internal vkatExitReader;
    CurveYieldUsdcSupplyLoopFuse internal usdcLoopFuse;
    FixedValuePriceFeed internal vbUsdcPriceFeed;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        gate = vm.parseJsonAddress(vm.readFile(vm.envOr("PHASE0_DEPLOYMENTS", string("deployments/katana-gate.json"))), ".governanceGate");
        _start();
        _deployRouter();
        _deployCore();
        _deployVkat();
        _deployLend();
        _deployLp();
        _wire();
        _stop();
        _write();
    }

    function _deployCore() internal {
        _wireAddr(gate, CurveYieldAddrKeys.REWARDS_CLAIM_MANAGER, RCM);
        // the live custody (v1) until P6_01 re-points the key at custody v2 (DAO setAddr)
        _wireAddr(gate, CurveYieldAddrKeys.REVENUE_CUSTODY, GROWTH_CUSTODY);
        splitter = new CurveYieldLoopProfitSplitter(DEPLOYER, AVKAT, GROWTH_CUSTODY, gate);
        _wireAddr(gate, CurveYieldAddrKeys.LOOP_PROFIT_SPLITTER, address(splitter));
        allocation = new CurveYieldAllocationController(DEPLOYER, VAULT, AVKAT, VKAT_ESCROW, gate);
        transferFuse = new CurveYieldErc20TransferFuse(MARKET_ERC20, MARKET_SUBSTRATES);
        _wireAddr(gate, CurveYieldAddrKeys.TRANSFER_FUSE, address(transferFuse));
        guardFuse = new CurveYieldBundleGuardFuse(MARKET_ERC20);
        plannedInstantFuse = new CurveYieldPlannedInstantWithdrawFuse(MARKET_ERC20, MARKET_SUBSTRATES);
        requestFuse = new CurveYieldWithdrawalRequestFuse(MARKET_ERC20, MARKET_SUBSTRATES, gate);
        // IPOR's official Merkl reward fuse: reuse IPOR's live deployment (already a reward fuse of the RCM)
        merklClaimFuse = MerklClaimFuse(MERKL_CLAIM_FUSE);
        require(merklClaimFuse.DISTRIBUTOR() == MERKL_DISTRIBUTOR, "Merkl claim fuse distributor");

        wm = CurveYieldWithdrawalManagerV2(_createSized("CurveYieldWithdrawalManagerV2", abi.encode(ACCESS_MANAGER, WM_TEMPLATE)));
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
                collateralFuse: COLLATERAL_FUSE, borrowFuse: BORROW_FUSE, flashLoanFuse: FLASH_FUSE, swapFuse: address(swapFuseV2),
                splitter: address(splitter), withdrawManager: address(wm)
            }),
            gate
        );
        // The executor and the withdraw manager are deployed from the EIP-170 size profile (see _createSized).
        executor = CurveYieldVaultExecutor(_createSized(
            "CurveYieldVaultExecutor",
            abi.encode(
                DEPLOYER, VAULT, AVKAT,
                CyExecutorDeps({
                    allocation: address(allocation), withdrawManager: address(wm), rewardsClaimManager: RCM,
                    merklClaimFuse: address(merklClaimFuse), swapFuse: address(swapFuseV2),
                    transferFuse: address(transferFuse), kat: KAT,
                    guardFuse: address(guardFuse), requestFuse: address(requestFuse)
                }),
                gate
            )
        ));
        loopFuses = CyLoopFuses({
            cycle: address(new CurveYieldLoopCycleFuse(MARKET_LOOP, MORPHO, MARKET_SUBSTRATES)),
            unwind: address(new CurveYieldLoopUnwindFuse(MARKET_LOOP, MORPHO, MARKET_SUBSTRATES))
        });
        burnFuse = new BurnRequestFeeFuse(type(uint256).max);
        callbackHandler = new CallbackHandlerMorpho();
        maintenanceFuse = new UpdateWithdrawManagerMaintenanceFuse(0);
    }

    /// @dev Swap router v2 (owned by the deployer until P3_04 hands it to the gate) with the avKAT <-> KAT Sushi 1%
    /// routes, and the vault's swap fuse v2. The CurveYield DEX (Balancer) is wired later with setBalancer (P5).
    function _deployRouter() internal {
        routerV2 = new CurveYieldSwapRouterV2(DEPLOYER, gate, ADMIN_FEE_SAFE, SUSHI_FACTORY, SUSHI_INIT_CODE_HASH);
        _wireAddr(gate, CurveYieldAddrKeys.SWAP_ROUTER, address(routerV2));
        CyHop[] memory hops = new CyHop[](1);
        hops[0] = CyHop(1, AVKAT, KAT, POOL_1PCT, 10_000);
        routerV2.setRoute(AVKAT, KAT, hops);
        hops[0] = CyHop(1, KAT, AVKAT, POOL_1PCT, 10_000);
        routerV2.setRoute(KAT, AVKAT, hops);
        swapFuseV2 = new CurveYieldRouterSwapFuseV2(MARKET_ERC20, MARKET_SUBSTRATES, gate);
    }

    function _deployVkat() internal {
        address[] memory gauges = new address[](1);
        gauges[0] = VOTE_GAUGE;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        vkat = new CurveYieldVkatController(
            DEPLOYER,
            CyVkatEnv({
                vault: VAULT, avkat: AVKAT, nft: VKAT_NFT, escrow: VKAT_ESCROW, exitQueue: EXIT_QUEUE,
                epochClock: EPOCH_CLOCK, gaugeVoter: GAUGE_VOTER, delegationAdapter: DELEGATION, loopController: address(loop)
            }),
            gate,
            gauges, weights
        );
        _wireAddr(gate, CurveYieldAddrKeys.VKAT_CONTROLLER, address(vkat));
        vkatFuses = CyVkatFuses({
            lock: address(new CurveYieldVeLockFuse(MARKET_ERC20, MARKET_SUBSTRATES)),
            convert: address(new CurveYieldVeConvertFuse(MARKET_ERC20, MARKET_SUBSTRATES)),
            vote: address(new CurveYieldVeVoteFuse(MARKET_ERC20, MARKET_SUBSTRATES)),
            exitBegin: address(new CurveYieldVeExitBeginFuse(MARKET_ERC20, MARKET_SUBSTRATES)),
            exitWithdraw: address(new CurveYieldVeExitWithdrawFuse(MARKET_ERC20, MARKET_SUBSTRATES))
        });
    }

    function _deployLend() internal {
        lend = new CurveYieldAvkatLendController(
            DEPLOYER, VAULT, MORPHO, LEND_MARKET,
            gate
        );
        // Reuse the IPOR lending fuses if L1_InstallLendingV1 already installed them on the live vault.
        try vm.readFile(_lendingPath()) returns (string memory j) {
            lendSupplyFuse = MorphoSupplyFuse(vm.parseJsonAddress(j, ".lendSupplyFuse"));
        } catch {
            lendSupplyFuse = new MorphoSupplyFuse(MARKET_LEND, MORPHO);
        }
        // USDC_SUPPLY_LOOP_SPEC: the supply-loop fuse (market 14) and the fixed $1.00 vbUSDC price source
        usdcLoopFuse = new CurveYieldUsdcSupplyLoopFuse(MARKET_LOOP, MORPHO, gate);
        vbUsdcPriceFeed = new FixedValuePriceFeed(1e18);
    }

    function _deployLp() internal {
        lp = new CurveYieldSushiLpController(
            DEPLOYER, VAULT, AVKAT, MORPHO, LEND_MARKET, gate
        );
        _wireAddr(gate, CurveYieldAddrKeys.LP_CONTROLLER, address(lp));
        lpHolder = new CurveYieldSushiLpHolder(VAULT, gate, MORPHO, LOOP_MARKET, AVKAT, KAT, NPM, POOL_1PCT, ROUTER, QUOTER);
        lpFuses = CyLpFuses({
            open: address(new CurveYieldHolderOpenFuse(MARKET_ERC20, MARKET_SUBSTRATES)),
            increase: address(new CurveYieldHolderIncreaseFuse(MARKET_ERC20, MARKET_SUBSTRATES)),
            withdraw: address(new CurveYieldHolderWithdrawFuse(MARKET_ERC20, MARKET_SUBSTRATES)),
            rebalance: address(new CurveYieldHolderRebalanceFuse(MARKET_ERC20, MARKET_SUBSTRATES)),
            emergency: address(new CurveYieldHolderDeleverageFuse(MARKET_ERC20, MARKET_SUBSTRATES))
        });
        erc20Balance = new CurveYieldPositionReaderBalanceFuse(MARKET_ERC20, MARKET_SUBSTRATES);
        lpReader = new CurveYieldLpHolderReader(gate, AVKAT);
        vkatExitReader = new CurveYieldVkatExitReader(gate, KAT);
    }

    function _wire() internal {
        loop.setExecutor(address(executor));
        loop.setAllocation(address(allocation));
        loop.setFuses(loopFuses);
        vkat.setExecutor(address(executor));
        vkat.setFuses(vkatFuses);
        lend.setExecutor(address(executor));
        lend.setFuses(address(lendSupplyFuse));
        lp.setExecutor(address(executor));
        lp.wire(address(lpHolder), lpFuses);
        allocation.setSets(CySets({loop: address(loop), vkat: address(vkat), lend: address(lend), lp: address(lp), pol: address(0)}));
        allocation.setExecutor(address(executor));
    }

    function _write() internal {
        string memory o = "p2";
        vm.serializeAddress(o, "splitter", address(splitter));
        vm.serializeAddress(o, "usdcLoopFuse", address(usdcLoopFuse));
        vm.serializeAddress(o, "vbUsdcPriceFeed", address(vbUsdcPriceFeed));
        vm.serializeAddress(o, "allocation", address(allocation));
        vm.serializeAddress(o, "transferFuse", address(transferFuse));
        vm.serializeAddress(o, "guardFuse", address(guardFuse));
        vm.serializeAddress(o, "swapRouterV2", address(routerV2));
        vm.serializeAddress(o, "swapFuseV2", address(swapFuseV2));
        vm.serializeAddress(o, "requestFuse", address(requestFuse));
        vm.serializeAddress(o, "merklClaimFuse", address(merklClaimFuse));
        vm.serializeAddress(o, "plannedInstantFuse", address(plannedInstantFuse));
        vm.serializeAddress(o, "withdrawManagerV2", address(wm));
        vm.serializeAddress(o, "loopController", address(loop));
        vm.serializeAddress(o, "executor", address(executor));
        vm.serializeAddress(o, "loopCycleFuse", loopFuses.cycle);
        vm.serializeAddress(o, "loopUnwindFuse", loopFuses.unwind);
        vm.serializeAddress(o, "burnRequestFeeFuse", address(burnFuse));
        vm.serializeAddress(o, "callbackHandlerMorpho", address(callbackHandler));
        vm.serializeAddress(o, "withdrawManagerMaintenanceFuse", address(maintenanceFuse));
        vm.serializeAddress(o, "vkatController", address(vkat));
        vm.serializeAddress(o, "vkatLockFuse", vkatFuses.lock);
        vm.serializeAddress(o, "vkatConvertFuse", vkatFuses.convert);
        vm.serializeAddress(o, "vkatVoteFuse", vkatFuses.vote);
        vm.serializeAddress(o, "vkatExitBeginFuse", vkatFuses.exitBegin);
        vm.serializeAddress(o, "vkatExitWithdrawFuse", vkatFuses.exitWithdraw);
        vm.serializeAddress(o, "lendController", address(lend));
        vm.serializeAddress(o, "lendSupplyFuse", address(lendSupplyFuse));
        vm.serializeAddress(o, "lpController", address(lp));
        vm.serializeAddress(o, "lpHolder", address(lpHolder));
        vm.serializeAddress(o, "lpOpenFuse", lpFuses.open);
        vm.serializeAddress(o, "lpIncreaseFuse", lpFuses.increase);
        vm.serializeAddress(o, "lpWithdrawFuse", lpFuses.withdraw);
        vm.serializeAddress(o, "lpRebalanceFuse", lpFuses.rebalance);
        vm.serializeAddress(o, "lpEmergencyFuse", lpFuses.emergency);
        vm.serializeAddress(o, "lpHolderReader", address(lpReader));
        vm.serializeAddress(o, "vkatExitReader", address(vkatExitReader));
        string memory json = vm.serializeAddress(o, "erc20BalanceFuse", address(erc20Balance));
        vm.writeJson(json, _deploymentsPath());
        console2.log("Phase 2 deployed; addresses written to", _deploymentsPath());
        console2.log("executor", address(executor));
        console2.log("withdrawManagerV2", address(wm));
    }
}
