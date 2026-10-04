// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Phase2Base} from "./Phase2Base.s.sol";
import {
    CurveYieldPlusLoopController, CyPlusEnv, CyPlusParams, CyPlusFuses
} from "../src/plus/CurveYieldPlusLoopController.sol";
import {MorphoCollateralFuse} from "contracts/fuses/morpho/MorphoCollateralFuse.sol";
import {MorphoBorrowFuse} from "contracts/fuses/morpho/MorphoBorrowFuse.sol";
import {Erc4626SupplyFuse} from "contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {CurveYieldErc20TransferFuse} from "../src/generic/CurveYieldErc20TransferFuse.sol";
import {CurveYieldPlannedInstantWithdrawFuse} from "../src/generic/CurveYieldPlannedInstantWithdrawFuse.sol";
import {CurveYieldPlusExecutor} from "../src/plus/CurveYieldPlusExecutor.sol";
import {CurveYieldPlusDepositRouter} from "../src/plus/CurveYieldPlusDepositRouter.sol";
import {CurveYieldPlusYieldBooster} from "../src/plus/CurveYieldPlusYieldBooster.sol";
import {CurveYieldWithdrawalManagerV2} from "../src/withdraw/CurveYieldWithdrawalManagerV2.sol";
import {CurveYieldCallerRewardFuse} from "../src/withdraw/CurveYieldCallerRewardFuse.sol"; // verbatim copy of controller/contracts (live 0x70a2)
import {MorphoFlashLoanFuse} from "contracts/fuses/morpho/MorphoFlashLoanFuse.sol";
import {MorphoBalanceFuse} from "contracts/fuses/morpho/MorphoBalanceFuse.sol";
import {ZeroBalanceFuse} from "contracts/fuses/ZeroBalanceFuse.sol";
import {BurnRequestFeeFuse} from "contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol";
import {UpdateWithdrawManagerMaintenanceFuse} from "contracts/fuses/maintenance/UpdateWithdrawManagerMaintenanceFuse.sol";
import {CallbackHandlerMorpho} from "contracts/handlers/callbacks/CallbackHandlerMorpho.sol";
import {ERC4626PriceFeed} from "contracts/price_oracle/price_feed/ERC4626PriceFeed.sol";
import {CurveYieldNetPpsPriceFeed} from "../src/plus/CurveYieldNetPpsPriceFeed.sol";

/// Phase 4 step 2/3: deploys the cyavKAT+ strategy stack for the vault created in P4_01 (nothing is wired yet; P4_03
/// configures). Markets used in cyavKAT+ are IPOR-registered only: 14 MORPHO (loop), 19 MORPHO_FLASH_LOAN (flash),
/// ERC4626_0001 (cyavKAT) and ERC4626_0002 (wcyavKAT) with ZeroBalanceFuse (fuse standardization: the loop runs on IPOR's
/// Morpho / ERC-4626 fuses + the generic transfer fuse, planned by the controller; typed substrates in market 54).
///   controller (70% target, 72.2% de-lever, 1% windup band, profit 40/40/10/10), step + loop fuses (market 14),
///   IPOR MorphoFlashLoanFuse(19) + ZeroBalanceFuse(19), IPOR MorphoBalanceFuse(14), CallbackHandlerMorpho,
///   WM v2 (template = the factory withdraw manager) + BurnRequestFeeFuse + request-fee fuse + maintenance fuse,
///   executor, deposit router, yield booster, ERC4626 price feeds for cyavKAT and wcyavKAT.
/// Reads deployments/katana-phase4.json (P4_01) and the lending JSON (wcyavKAT, lending market); appends to phase 4 JSON.
contract P4_02_DeployPlusStack is Phase2Base {
    uint256 internal constant MARKET_FLASH = 19; // IporFusionMarkets.MORPHO_FLASH_LOAN
    uint256 internal constant MARKET_4626_CY = 100_001; // IporFusionMarkets.ERC4626_0001: cyavKAT
    uint256 internal constant MARKET_4626_WRAP = 100_002; // IporFusionMarkets.ERC4626_0002: wcyavKAT
    address internal constant MAIN_FEE_MANAGER = 0x11a81a7B7436CB1E8f73866AF74961cE499f5Ec6;

    string internal p4Path;
    string internal p4;

    function run() external {
        require(block.chainid == 747474, "not Katana");
        p4Path = vm.envOr("PHASE4_DEPLOYMENTS", string("deployments/katana-phase4.json"));
        p4 = vm.readFile(p4Path);
        string memory lend = vm.readFile(_lendingPath());
        address plus = vm.parseJsonAddress(p4, ".plusVault");
        address wrapper = vm.parseJsonAddress(lend, ".wcyavkat");
        bytes32 market = vm.parseJsonBytes32(lend, ".lendMorphoMarket");

        _start();
        CurveYieldPlusLoopController controller = new CurveYieldPlusLoopController(
            DEPLOYER,
            CyPlusEnv({plusVault: plus, morpho: MORPHO, marketId: market, avkat: AVKAT, cyavkat: VAULT, wrapper: wrapper,
                flashLoanFuse: address(0), stepFuse: address(0)}),
            CyPlusParams({targetLtvBps: 7_000, deleverLtvBps: 7_220, windupBandBps: 100, specialRewardsBps: 4_000,
                compoundBps: 4_000, boosterBps: 1_000, adminBps: 1_000})
        );
        CyPlusFuses memory fuses = CyPlusFuses({
            flashLoan: address(new MorphoFlashLoanFuse(MARKET_FLASH, MORPHO)),
            collateral: address(new MorphoCollateralFuse(MARKET_LOOP, MORPHO)),
            borrow: address(new MorphoBorrowFuse(MARKET_LOOP, MORPHO)),
            cySupply: address(new Erc4626SupplyFuse(MARKET_4626_CY)),
            wrapSupply: address(new Erc4626SupplyFuse(MARKET_4626_WRAP)),
            transfer: address(new CurveYieldErc20TransferFuse(MARKET_LOOP, MARKET_SUBSTRATES))
        });
        controller.setFuses(fuses);

        CurveYieldWithdrawalManagerV2 wm = CurveYieldWithdrawalManagerV2(_createSized( // EIP-170 size profile
            "CurveYieldWithdrawalManagerV2",
            abi.encode(vm.parseJsonAddress(p4, ".plusAccessManager"), vm.parseJsonAddress(p4, ".plusWithdrawManager"))
        ));
        CurveYieldPlusExecutor executor = new CurveYieldPlusExecutor(DEPLOYER, plus, address(controller), address(wm));
        address plannedInstant = address(new CurveYieldPlannedInstantWithdrawFuse(MARKET_LOOP, MARKET_SUBSTRATES));
        controller.setExecutor(address(executor));

        address rcm = vm.parseJsonAddress(p4, ".plusRewardsManager");
        CurveYieldPlusDepositRouter router = new CurveYieldPlusDepositRouter(DEPLOYER, VAULT, plus);
        CurveYieldPlusYieldBooster booster = new CurveYieldPlusYieldBooster(DEPLOYER, VAULT, rcm);
        _stop();

        _deployPlumbing(plus, wrapper);
        vm.serializeAddress("p4", "plusController", address(controller));
        vm.serializeAddress("p4", "plusFlashFuse", fuses.flashLoan);
        vm.serializeAddress("p4", "plusCollateralFuse", fuses.collateral);
        vm.serializeAddress("p4", "plusBorrowFuse", fuses.borrow);
        vm.serializeAddress("p4", "plusCySupplyFuse", fuses.cySupply);
        vm.serializeAddress("p4", "plusWrapSupplyFuse", fuses.wrapSupply);
        vm.serializeAddress("p4", "plusTransferFuse", fuses.transfer);
        vm.serializeAddress("p4", "plusPlannedInstantFuse", plannedInstant);
        vm.serializeAddress("p4", "plusWithdrawManagerV2", address(wm));
        vm.serializeAddress("p4", "plusExecutor", address(executor));
        vm.serializeAddress("p4", "plusDepositRouter", address(router));
        string memory out = vm.serializeAddress("p4", "plusYieldBooster", address(booster));
        vm.writeJson(out, p4Path);
        console2.log("cyavKAT+ stack deployed; controller / executor", address(controller), address(executor));
    }

    function _deployPlumbing(address plus_, address wrapper_) internal {
        _start();
        ZeroBalanceFuse zeroFlash = new ZeroBalanceFuse(MARKET_FLASH);
        ZeroBalanceFuse zeroCy = new ZeroBalanceFuse(MARKET_4626_CY);
        ZeroBalanceFuse zeroWrap = new ZeroBalanceFuse(MARKET_4626_WRAP);
        MorphoBalanceFuse morphoBalance = new MorphoBalanceFuse(MARKET_LOOP, MORPHO);
        CallbackHandlerMorpho handler = new CallbackHandlerMorpho();
        BurnRequestFeeFuse burn = new BurnRequestFeeFuse(type(uint256).max);
        UpdateWithdrawManagerMaintenanceFuse maintenance = new UpdateWithdrawManagerMaintenanceFuse(0);
        CurveYieldCallerRewardFuse requestFee = new CurveYieldCallerRewardFuse(DEPLOYER, plus_, VAULT);
        // cyavKAT priced NET of its pending performance fee (main FeeManager 0x11a8…): crystallisation never moves PPS
        CurveYieldNetPpsPriceFeed cyFeed = new CurveYieldNetPpsPriceFeed(VAULT, MAIN_FEE_MANAGER);
        ERC4626PriceFeed wFeed = new ERC4626PriceFeed(wrapper_);
        _stop();
        vm.serializeJson("p4", p4); // keep P4_01 keys
        vm.serializeAddress("p4", "plusZeroFlashBalanceFuse", address(zeroFlash));
        vm.serializeAddress("p4", "plusZeroCyBalanceFuse", address(zeroCy));
        vm.serializeAddress("p4", "plusZeroWrapBalanceFuse", address(zeroWrap));
        vm.serializeAddress("p4", "plusMorphoBalanceFuse", address(morphoBalance));
        vm.serializeAddress("p4", "plusCallbackHandler", address(handler));
        vm.serializeAddress("p4", "plusBurnRequestFeeFuse", address(burn));
        vm.serializeAddress("p4", "plusMaintenanceFuse", address(maintenance));
        vm.serializeAddress("p4", "plusRequestFeeFuse", address(requestFee));
        vm.serializeAddress("p4", "plusCyavkatPriceFeed", address(cyFeed));
        vm.serializeAddress("p4", "plusWcyavkatPriceFeed", address(wFeed));
    }
}
