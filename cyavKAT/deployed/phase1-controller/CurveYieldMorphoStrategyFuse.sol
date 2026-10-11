// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {FuseAction} from "contracts/vaults/PlasmaVault.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {
    IPlasmaVaultKatana,
    ICurveYieldWithdrawalManager,
    IRewardsClaimManagerKatana,
    IAvKatKatana,
    IVkatEscrowKatana,
    IMorphoOracleKatana,
    IERC20Katana
} from "./interfaces/CurveYieldKatanaInterfaces.sol";

/**
 * @title CurveYield System Component
 * @notice CurveYield is a decentralized NGO building optimized DeFi systems for the good of all.
 *
 * @dev CurveYield integrates specialized AMM infrastructure, tokenized yield strategies, credit
 * markets, and protocol-owned liquidity into a unified, capital-efficient liquidity stack governed
 * by an open, international DAO community.
 *
 * Protocol operations are enhanced by cross-chain bridging and messaging, MEV capture systems,
 * off-chain to on-chain automation, and peer-to-peer data networks.
 *
 * This contract is one component of the CurveYield system.
 *
 * CurveYield uses proven DeFi primitives where possible and adds targeted coordination and
 * capital-efficiency-enhancing contracts where needed. Users and integrators must review
 * CurveYield documentation before use.
 *
 * Learn more:
 * Documentation: https://docs.curveyield.com
 * dApp: https://curveyield.online
 * GitHub: https://github.com/curveyield
 *
 * Decentralized links may have limited or delayed availability during periods of high network activity:
 * https://curveyield.eth.limo
 * https://curveyield.dao
 *
 * Note: curveyield.dao may require a Brave Browser or an Unstoppable Domains browser plugin to use.
 */

struct CurveYieldMorphoStrategyDependencies {
    address withdrawManager;
    address rewardsClaimManager;
    address collateralFuse;
    address borrowFuse;
    address flashLoanFuse;
    address routerSwapFuse;
    address callerRewardFuse;
    address vkatStrategyFuse;
    address profitCustody;
}

struct CurveYieldMorphoStrategyConfig {
    uint16 allocationBps;
    uint16 requestFeeBps;
    uint16 minimumProfitBps;
    uint16 unwindLossAllowanceBps;
    uint16 baseWindupProfitBps;
    uint16 upperWindupProfitBps;
}

struct CurveYieldMorphoSnapshot {
    uint256 collateralAvkat;
    uint256 debtKat;
    uint256 collateralValueKat;
    uint256 ltvBps;
    uint256 netEquityAvkat;
}

struct CurveYieldUnwindPlan {
    uint256 requestedNetAvkat;
    uint256 repayKat;
    uint256 withdrawAvkat;
    uint256 sellAvkat;
    uint256 callerRewardAvkat;
}

struct CurveYieldMorphoLoopState {
    uint256 initialEquity;
    uint256 basis;
    uint256 excessProfit;
    uint256 rewardSourceAvkat;
}

struct CurveYieldMorphoCyclePlan {
    uint256 supplyAvkat;
    uint256 borrowKat;
    uint256 expectedAvkat;
    uint256 requiredProfitBps;
}

struct CurveYieldTargetRequestInfo {
    uint256 shares;
    uint256 endWithdrawWindowTimestamp;
    bool canWithdraw;
    uint256 withdrawWindowInSeconds;
    uint256 refundableFeeShares;
}

interface ICurveYieldMorphoStrategyConfigView {
    function CONTROLLER() external view returns (address);
    function dependencies() external view returns (CurveYieldMorphoStrategyDependencies memory);
    function strategyConfig() external view returns (CurveYieldMorphoStrategyConfig memory);
    function reserveAllocationBps() external view returns (uint16);
}

interface ICurveYieldMorphoVaultInternal {
    function executeInternal(FuseAction[] calldata calls_) external;
}

interface ICurveYieldMorphoTargetedManager {
    function activeUnreleasedShares() external view returns (uint256);
    function reservedSharesOf(address requester_) external view returns (uint256);
    function getSharesToRelease() external view returns (uint256);
    function requestInfo(address requester_) external view returns (CurveYieldTargetRequestInfo memory);
}

interface ICurveYieldMorphoSwapFuse {
    function quoteExactInput(address tokenIn_, address tokenOut_, uint256 amountIn_)
        external returns (uint256 expectedNet_, uint256 minimumNet_);
    function quoteExactInputView(address tokenIn_, address tokenOut_, uint256 amountIn_)
        external view returns (uint256 expectedNet_, uint256 minimumNet_);
    function requiredInputView(address tokenIn_, address tokenOut_, uint256 requiredNetOut_, uint256 maximumInput_)
        external view returns (uint256 amountIn_);
}

interface ICurveYieldMorphoRewardFuse {
    function quoteMorphoReward(uint8 actionId_, uint256 basisAvkat_, uint256 excessProfitAvkat_)
        external view returns (uint256 amount_);
}

interface ICurveYieldMorphoVkatStrategyFuse {
    function vkatAllocationBps() external view returns (uint16);
    function convertibleVkatAvkat() external view returns (uint256);
}

interface ICurveYieldMorphoProfitCustody {
    function revenueShareBps() external view returns (uint16);
}

interface ICurveYieldMorphoControllerAdapter {
    function releaseActiveSharesFromStrategy(uint256 timestamp_, uint256 shares_) external;
    function releaseForFromStrategy(address requester_, uint256 timestamp_, uint256 shares_) external;
    function collectContributionFromStrategy(address caller_, uint256 amount_, uint256 maximum_) external;
}

/// @notice Morpho avKAT/KAT strategy fuse; swap protection and reward policy remain in their dedicated fuses.
contract CurveYieldMorphoStrategyFuse is IFuseCommon, Ownable2Step {
    using MorphoBalancesLib for IMorpho;

    uint256 public constant MARKET_ID = 14;
    uint16 public constant MAX_MORPHO_ALLOCATION_BPS = 7_501;
    uint16 public constant MAX_COMBINED_ALLOCATION_BPS = 9_000;
    uint16 public constant TARGET_LTV_BPS = 7_500;
    uint16 public constant EMERGENCY_LTV_BPS = 7_600;
    uint8 public constant MAX_LOOP_COUNT = 8;
    uint8 private constant MAX_SEARCH_ITERATIONS = 12;
    uint16 private constant MAX_MIN_PROFIT_BPS = 1_000;
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;
    uint8 private constant ACTION_DEPLOY_ASSETS = 0;
    uint8 private constant ACTION_FULFILL_ALL = 2;
    uint8 private constant ACTION_EMERGENCY_REPAY = 3;

    address public immutable VAULT;
    address public constant AVKAT = 0x7231dbaCdFc968E07656D12389AB20De82FbfCeB;
    address public constant KAT = 0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d;
    IMorpho public constant MORPHO = IMorpho(0xD50F2DffFd62f94Ee4AEd9ca05C61d0753268aBc);
    IAvKatKatana public constant AVKAT_TOKEN = IAvKatKatana(AVKAT);
    IVkatEscrowKatana public constant ESCROW =
        IVkatEscrowKatana(0x4d6fC15Ca6258b168225D283262743C623c13Ead);
    bytes32 public constant MORPHO_MARKET_ID =
        0x80e60fe453223b0f84a567724f88190bef708420d24397157067d424429783e9;

    address public immutable VERSION;
    address public CONTROLLER;
    CurveYieldMorphoStrategyDependencies private _dependencies;
    CurveYieldMorphoStrategyConfig private _strategyConfig;

    error InvalidAddress();
    error InvalidDependencies();
    error WrongImplementationContext();
    error WrongVaultContext();
    error UnauthorizedCaller();
    error MorphoAllocationTooHigh();
    error CombinedAllocationTooHigh();
    error InvalidWithdrawalEconomics();
    error InvalidWindupEconomics();
    error NoActiveWithdrawalRequests();
    error NoProfitableFulfillment();
    error PositionNotEmergency();
    error InvalidRepayAmount();
    error InsufficientMorphoCollateral();
    error UnwindNotSafe();
    error UnwindLossTooHigh(uint256 lossAvkat_, uint256 maximumLossAvkat_);
    error CallerContributionTooHigh();

    constructor(
        address owner_,
        address controller_,
        address vault_,
        CurveYieldMorphoStrategyDependencies memory dependencies_
    ) Ownable(owner_) {
        if (owner_ == address(0) || controller_ == address(0) || vault_ == address(0)) revert InvalidAddress();
        VERSION = address(this);
        CONTROLLER = controller_;
        VAULT = vault_;
        _setDependencies(dependencies_);
        _strategyConfig = CurveYieldMorphoStrategyConfig(4_500, 390, 125, 265, 200, 450);
    }

    function setController(address controller_) external onlyOwner {
        _requireImplementation();
        if (controller_ == address(0)) revert InvalidAddress();
        CONTROLLER = controller_;
    }

    function setDependencies(CurveYieldMorphoStrategyDependencies calldata dependencies_) external onlyOwner {
        _requireImplementation();
        _setDependencies(dependencies_);
    }

    function setMorphoAllocationBps(uint16 allocationBps_) external onlyOwner {
        _requireImplementation();
        if (allocationBps_ > MAX_MORPHO_ALLOCATION_BPS) revert MorphoAllocationTooHigh();
        uint16 vkatBps = ICurveYieldMorphoVkatStrategyFuse(_dependencies.vkatStrategyFuse).vkatAllocationBps();
        if (uint256(allocationBps_) + vkatBps > MAX_COMBINED_ALLOCATION_BPS) {
            revert CombinedAllocationTooHigh();
        }
        _strategyConfig.allocationBps = allocationBps_;
    }

    function setWithdrawalEconomics(
        uint16 requestFeeBps_, uint16 minimumProfitBps_, uint16 lossAllowanceBps_
    ) external onlyOwner {
        _requireImplementation();
        if (
            requestFeeBps_ > 10_000 || minimumProfitBps_ > MAX_MIN_PROFIT_BPS ||
            lossAllowanceBps_ > 10_000 || requestFeeBps_ < minimumProfitBps_
        ) revert InvalidWithdrawalEconomics();
        _strategyConfig.requestFeeBps = requestFeeBps_;
        _strategyConfig.minimumProfitBps = minimumProfitBps_;
        _strategyConfig.unwindLossAllowanceBps = lossAllowanceBps_;
    }

    function setMorphoWindupEconomics(uint16 baseBps_, uint16 upperBps_) external onlyOwner {
        _requireImplementation();
        if (baseBps_ > upperBps_ || upperBps_ > MAX_MIN_PROFIT_BPS) {
            revert InvalidWindupEconomics();
        }
        _strategyConfig.baseWindupProfitBps = baseBps_;
        _strategyConfig.upperWindupProfitBps = upperBps_;
    }

    function dependencies() external view returns (CurveYieldMorphoStrategyDependencies memory) {
        return _dependencies;
    }

    function strategyConfig() external view returns (CurveYieldMorphoStrategyConfig memory) {
        return _strategyConfig;
    }

    function morphoAllocationBps() external view returns (uint16) {
        return _strategyConfig.allocationBps;
    }

    function reserveAllocationBps() external view returns (uint16) {
        uint16 morphoBps = _strategyConfig.allocationBps;
        uint16 vkatBps = ICurveYieldMorphoVkatStrategyFuse(_dependencies.vkatStrategyFuse).vkatAllocationBps();
        if (uint256(morphoBps) + vkatBps > MAX_COMBINED_ALLOCATION_BPS) {
            revert CombinedAllocationTooHigh();
        }
        return uint16(10_000 - morphoBps - vkatBps);
    }

    /// @notice Uses idle avKAT only when the live KAT-to-avKAT spread passes the configured threshold.
    function deployAssets() external {
        _requireActionContext();
        CurveYieldMorphoStrategyConfig memory config = _config();
        CurveYieldMorphoStrategyDependencies memory deps = _deps();
        _ensureWithdrawalRevenueAllowance(deps.withdrawManager);
        CurveYieldMorphoLoopState memory state;
        state.initialEquity = morphoSnapshot().netEquityAvkat;
        _loopTowardTarget(state, config, deps);

        uint256 reward = ICurveYieldMorphoRewardFuse(deps.callerRewardFuse).quoteMorphoReward(
            ACTION_DEPLOY_ASSETS, state.basis, state.excessProfit
        );
        uint256 managed = totalManagedAvkat();
        uint256 reserve = managed * ICurveYieldMorphoStrategyConfigView(VERSION).reserveAllocationBps() / 10_000;
        if (IERC20Katana(AVKAT).balanceOf(VAULT) < reserve + reward) revert UnwindNotSafe();
        _publishResult(ACTION_DEPLOY_ASSETS, state.basis, state.excessProfit, state.rewardSourceAvkat);
    }

    function fulfillAll() external {
        _requireActionContext();
        CurveYieldMorphoStrategyDependencies memory deps = _deps();
        ICurveYieldMorphoTargetedManager manager = ICurveYieldMorphoTargetedManager(deps.withdrawManager);
        uint256 maximumShares = manager.activeUnreleasedShares();
        if (maximumShares == 0) revert NoActiveWithdrawalRequests();

        (uint256 shares, uint256 assets,) = _findProfitableFulfillment(maximumShares, deps);
        uint256 totalNeeded = IPlasmaVaultKatana(VAULT).previewRedeem(manager.getSharesToRelease() + shares);
        CurveYieldUnwindPlan memory plan = _prepareScheduledUnwind(totalNeeded, ACTION_FULFILL_ALL, deps);
        if (!_isProfitable(plan, assets, deps.routerSwapFuse)) revert NoProfitableFulfillment();
        _performUnwind(plan, deps);
        _fundController(plan.callerRewardAvkat);
        ICurveYieldMorphoControllerAdapter(_controller()).releaseActiveSharesFromStrategy(block.timestamp - 1, shares);
        _publishResult(ACTION_FULFILL_ALL, plan.withdrawAvkat, 0, plan.callerRewardAvkat);
    }

    function fulfillFor(address caller_, address requester_, uint256 shares_, uint256 maxContributionAvkat_) external {
        _requireActionContext();
        CurveYieldMorphoStrategyDependencies memory deps = _deps();
        ICurveYieldMorphoTargetedManager manager = ICurveYieldMorphoTargetedManager(deps.withdrawManager);
        CurveYieldTargetRequestInfo memory request = manager.requestInfo(requester_);
        uint256 reserved = manager.reservedSharesOf(requester_);
        uint256 available = request.shares > reserved ? request.shares - reserved : 0;
        if (block.timestamp > request.endWithdrawWindowTimestamp || available == 0) {
            revert NoActiveWithdrawalRequests();
        }
        uint256 shares = shares_ == 0 ? available : shares_;
        if (shares > available) revert InvalidRepayAmount();

        uint256 assets = IPlasmaVaultKatana(VAULT).previewRedeem(shares);
        uint256 totalNeeded = IPlasmaVaultKatana(VAULT).previewRedeem(manager.getSharesToRelease() + shares);
        CurveYieldUnwindPlan memory plan = _prepareScheduledUnwind(totalNeeded, 0, deps);
        (, uint256 contribution) = _unwindCost(plan, assets, deps.routerSwapFuse);
        if (contribution > maxContributionAvkat_) {
            revert CallerContributionTooHigh();
        }
        if (contribution != 0) {
            ICurveYieldMorphoControllerAdapter(_controller()).collectContributionFromStrategy(
                caller_, contribution, maxContributionAvkat_
            );
        }
        _performUnwind(plan, deps);
        ICurveYieldMorphoControllerAdapter(_controller()).releaseForFromStrategy(
            requester_, block.timestamp - 1, shares
        );
    }

    function emergencyRepay(uint256 repayKat_) external {
        _requireActionContext();
        CurveYieldMorphoStrategyDependencies memory deps = _deps();
        CurveYieldMorphoSnapshot memory position = morphoSnapshot();
        if (position.ltvBps <= EMERGENCY_LTV_BPS) revert PositionNotEmergency();
        if (repayKat_ > position.debtKat) revert InvalidRepayAmount();
        bool full = repayKat_ == 0;
        CurveYieldUnwindPlan memory plan = full
            ? _planEmergencyFull(position, deps)
            : _planEmergencyPartial(position, repayKat_, deps);
        _performUnwind(plan, deps);
        _fundController(plan.callerRewardAvkat);
        _publishResult(ACTION_EMERGENCY_REPAY, plan.sellAvkat, 0, plan.callerRewardAvkat);
    }

    /// @notice Funds only the Morpho-derived share of the aggregate deploy reward.
    function fundDeployReward() external {
        _requireActionContext();
        CurveYieldMorphoStrategyDependencies memory deps = _deps();
        bytes32[] memory result = TransientStorageLib.getOutputs(VERSION);
        bytes32[] memory plan = TransientStorageLib.getInputs(deps.vkatStrategyFuse);
        if (result.length != 4 || uint256(result[0]) != ACTION_DEPLOY_ASSETS || plan.length != 4) {
            revert UnwindNotSafe();
        }
        uint256 reward = uint256(plan[1]);
        if (reward > uint256(result[3])) revert UnwindNotSafe();
        result[0] = bytes32(type(uint256).max);
        TransientStorageLib.setOutputs(VERSION, result);
        _fundController(reward);
    }

    function currentUnwindCostBps() external view returns (uint256 costBps_) {
        uint256 shares = ICurveYieldMorphoTargetedManager(_deps().withdrawManager).activeUnreleasedShares();
        (costBps_,) = _quoteUnwindForShares(shares);
    }

    function quoteUnwindForShares(uint256 shares_)
        external view returns (uint256 costBps_, uint256 extraContributionAvkat_)
    {
        return _quoteUnwindForShares(shares_);
    }

    function morphoSnapshot() public view returns (CurveYieldMorphoSnapshot memory snapshot_) {
        MarketParams memory params = MORPHO.idToMarketParams(Id.wrap(MORPHO_MARKET_ID));
        uint256 collateral = MORPHO.position(Id.wrap(MORPHO_MARKET_ID), VAULT).collateral;
        uint256 debt = MORPHO.expectedBorrowAssets(params, VAULT);
        uint256 collateralValue = Math.mulDiv(collateral, IMorphoOracleKatana(params.oracle).price(), ORACLE_PRICE_SCALE);
        uint256 debtInAvkat = debt == 0 ? 0 : AVKAT_TOKEN.previewWithdraw(debt);
        snapshot_ = CurveYieldMorphoSnapshot(
            collateral, debt, collateralValue,
            collateralValue == 0 ? 0 : debt * 10_000 / collateralValue,
            collateral > debtInAvkat ? collateral - debtInAvkat : 0
        );
    }

    function totalManagedAvkat() public view returns (uint256 total_) {
        CurveYieldMorphoStrategyDependencies memory deps = _deps();
        total_ = IERC20Katana(AVKAT).balanceOf(VAULT) + morphoSnapshot().netEquityAvkat;
        total_ += IRewardsClaimManagerKatana(deps.rewardsClaimManager).balanceOf();
        uint256[] memory tokenIds = ESCROW.ownedTokens(VAULT);
        for (uint256 i; i < tokenIds.length; ++i) {
            (uint256 lockedKat,) = ESCROW.locked(tokenIds[i]);
            total_ += AVKAT_TOKEN.convertToShares(lockedKat);
        }
    }

    function _loopTowardTarget(
        CurveYieldMorphoLoopState memory state_,
        CurveYieldMorphoStrategyConfig memory config_,
        CurveYieldMorphoStrategyDependencies memory deps_
    ) private {
        for (uint256 i; i < MAX_LOOP_COUNT; ++i) {
            (bool executable, CurveYieldMorphoCyclePlan memory plan) = _planLoopCycle(state_, config_, deps_);
            if (!executable) break;
            _executeLoopCycle(state_, plan, deps_);
        }
    }

    function _planLoopCycle(
        CurveYieldMorphoLoopState memory state_,
        CurveYieldMorphoStrategyConfig memory config_,
        CurveYieldMorphoStrategyDependencies memory deps_
    ) private returns (bool executable_, CurveYieldMorphoCyclePlan memory plan_) {
        CurveYieldMorphoSnapshot memory position = morphoSnapshot();
        uint256 managed = totalManagedAvkat();
        plan_.supplyAvkat = _plannedCycleSupply(position, managed, state_, config_, deps_.callerRewardFuse);

        MarketParams memory params = MORPHO.idToMarketParams(Id.wrap(MORPHO_MARKET_ID));
        uint256 addedValue = Math.mulDiv(
            plan_.supplyAvkat, IMorphoOracleKatana(params.oracle).price(), ORACLE_PRICE_SCALE
        );
        uint256 targetDebt = (position.collateralValueKat + addedValue) * TARGET_LTV_BPS / 10_000;
        if (targetDebt <= position.debtKat) return (false, plan_);
        plan_.borrowKat = targetDebt - position.debtKat;
        if (plan_.borrowKat == 0) return (false, plan_);
        (plan_.expectedAvkat,) = _quoteLive(deps_.routerSwapFuse, KAT, AVKAT, plan_.borrowKat);
        plan_.requiredProfitBps = _projectedRequiredWindupBps(position, plan_, managed, config_);
        (bool profitable,) = _windupProfit(plan_.borrowKat, plan_.expectedAvkat, plan_.requiredProfitBps);
        if (!profitable) return (false, plan_);
        executable_ = true;
    }

    function _plannedCycleSupply(
        CurveYieldMorphoSnapshot memory position_,
        uint256 managed_,
        CurveYieldMorphoLoopState memory state_,
        CurveYieldMorphoStrategyConfig memory config_,
        address rewardFuse_
    ) private view returns (uint256 supply_) {
        uint256 limit = managed_ * config_.allocationBps / 10_000;
        uint256 capacity = limit > position_.netEquityAvkat ? limit - position_.netEquityAvkat : 0;
        uint256 liquid = _idleAvailableAfterReserve(managed_);
        supply_ = _solveCycleSupply(liquid, capacity, state_, rewardFuse_);
    }

    function _idleAvailableAfterReserve(uint256 managed_) private view returns (uint256 available_) {
        uint256 idle = IERC20Katana(AVKAT).balanceOf(VAULT);
        uint256 reserveBps = ICurveYieldMorphoStrategyConfigView(VERSION).reserveAllocationBps();
        uint256 reserve = managed_ * reserveBps / 10_000;
        available_ = idle > reserve ? idle - reserve : 0;
    }

    function _projectedRequiredWindupBps(
        CurveYieldMorphoSnapshot memory position_,
        CurveYieldMorphoCyclePlan memory plan_,
        uint256 managed_,
        CurveYieldMorphoStrategyConfig memory config_
    ) private view returns (uint256 requiredBps_) {
        uint256 debtAfter = position_.debtKat + plan_.borrowKat;
        uint256 debtSharesAfter = AVKAT_TOKEN.previewWithdraw(debtAfter);
        uint256 debtSharesBefore = position_.debtKat == 0 ? 0 : AVKAT_TOKEN.previewWithdraw(position_.debtKat);
        uint256 debtShareIncrease = debtSharesAfter - debtSharesBefore;
        uint256 projectedEquity = position_.collateralAvkat + plan_.supplyAvkat;
        projectedEquity = projectedEquity > debtSharesAfter ? projectedEquity - debtSharesAfter : 0;
        uint256 projectedManaged = managed_;
        if (plan_.expectedAvkat >= debtShareIncrease) projectedManaged += plan_.expectedAvkat - debtShareIncrease;
        else projectedManaged -= debtShareIncrease - plan_.expectedAvkat;
        uint256 projectedLimit = projectedManaged * config_.allocationBps / 10_000;
        requiredBps_ = _requiredWindupProfitBpsForFill(
            projectedEquity, projectedLimit, config_.baseWindupProfitBps, config_.upperWindupProfitBps
        );
    }

    function _windupProfit(uint256 borrowedKat_, uint256 producedAvkat_, uint256 requiredBps_)
        private view returns (bool profitable_, uint256 excessProfit_)
    {
        uint256 direct = AVKAT_TOKEN.convertToShares(borrowedKat_);
        uint256 requiredGain = Math.mulDiv(direct, requiredBps_, 10_000, Math.Rounding.Ceil);
        uint256 gain = producedAvkat_ > direct ? producedAvkat_ - direct : 0;
        profitable_ = gain >= requiredGain;
        if (profitable_) excessProfit_ = gain - requiredGain;
    }

    function _executeLoopCycle(
        CurveYieldMorphoLoopState memory state_,
        CurveYieldMorphoCyclePlan memory plan_,
        CurveYieldMorphoStrategyDependencies memory deps_
    ) private {
        uint256 plannedReward = ICurveYieldMorphoRewardFuse(deps_.callerRewardFuse).quoteMorphoReward(
            ACTION_DEPLOY_ASSETS, state_.basis + plan_.supplyAvkat, state_.excessProfit
        );
        uint256 beforeBalance = IERC20Katana(AVKAT).balanceOf(VAULT);
        if (beforeBalance < plan_.supplyAvkat + plannedReward) revert UnwindNotSafe();
        uint256 offset = plan_.supplyAvkat == 0 ? 0 : 1;
        FuseAction[] memory actions = new FuseAction[](2 + offset);
        if (offset != 0) actions[0] = _collateralAction(deps_.collateralFuse, true, plan_.supplyAvkat);
        actions[offset] = FuseAction(
            deps_.borrowFuse,
            abi.encodeWithSignature("enter((bytes32,uint256,uint256))", MORPHO_MARKET_ID, plan_.borrowKat, 0)
        );
        actions[offset + 1] = _swapAction(deps_.routerSwapFuse, KAT, AVKAT, plan_.borrowKat, 0);
        _executeInternal(actions);

        uint256 afterBalance = IERC20Katana(AVKAT).balanceOf(VAULT);
        uint256 produced = afterBalance + plan_.supplyAvkat - beforeBalance;
        (bool profitable, uint256 excess) = _windupProfit(
            plan_.borrowKat, produced, plan_.requiredProfitBps
        );
        if (!profitable) revert UnwindNotSafe();
        state_.basis = _netEquityAdded(state_.initialEquity);
        state_.excessProfit += excess;
        uint256 reward = ICurveYieldMorphoRewardFuse(deps_.callerRewardFuse).quoteMorphoReward(
            ACTION_DEPLOY_ASSETS, state_.basis, state_.excessProfit
        );
        uint256 custodyAmount = _shareLoopProfit(
            plan_.borrowKat, produced, afterBalance, reward, deps_.profitCustody
        );
        state_.rewardSourceAvkat += produced - custodyAmount;
    }

    function _netEquityAdded(uint256 initialEquity_) private view returns (uint256 added_) {
        uint256 currentEquity = morphoSnapshot().netEquityAvkat;
        added_ = currentEquity > initialEquity_ ? currentEquity - initialEquity_ : 0;
    }

    function _shareLoopProfit(
        uint256 borrowedKat_, uint256 producedAvkat_, uint256 available_, uint256 reward_, address custody_
    ) private returns (uint256 custodyAmount_) {
        uint256 direct = AVKAT_TOKEN.convertToShares(borrowedKat_);
        uint256 gain = producedAvkat_ > direct ? producedAvkat_ - direct : 0;
        uint256 revenueShareBps = ICurveYieldMorphoProfitCustody(custody_).revenueShareBps();
        custodyAmount_ = Math.mulDiv(gain, revenueShareBps, 10_000);
        if (available_ < reward_ + custodyAmount_) revert UnwindNotSafe();
        if (custodyAmount_ != 0 && !IERC20Katana(AVKAT).transfer(custody_, custodyAmount_)) {
            revert UnwindNotSafe();
        }
    }

    function _findProfitableFulfillment(uint256 maximumShares_, CurveYieldMorphoStrategyDependencies memory deps_)
        private returns (uint256 shares_, uint256 assets_, CurveYieldUnwindPlan memory plan_)
    {
        ICurveYieldMorphoTargetedManager manager = ICurveYieldMorphoTargetedManager(deps_.withdrawManager);
        shares_ = maximumShares_;
        for (uint256 iteration; iteration < MAX_SEARCH_ITERATIONS; ++iteration) {
            assets_ = IPlasmaVaultKatana(VAULT).previewRedeem(shares_);
            uint256 totalReserved = IPlasmaVaultKatana(VAULT).previewRedeem(manager.getSharesToRelease() + shares_);
            uint256 available = IERC20Katana(AVKAT).balanceOf(VAULT) +
                ICurveYieldMorphoVkatStrategyFuse(deps_.vkatStrategyFuse).convertibleVkatAvkat();
            plan_ = _planWithdrawalUnwind(
                totalReserved > available ? totalReserved - available : 0, ACTION_FULFILL_ALL, deps_
            );
            if (_isProfitable(plan_, assets_, deps_.routerSwapFuse)) return (shares_, assets_, plan_);
            shares_ = shares_ * 3 / 4;
            if (shares_ == 0) break;
        }
        revert NoProfitableFulfillment();
    }

    function _prepareScheduledUnwind(
        uint256 totalNeeded_, uint8 rewardAction_, CurveYieldMorphoStrategyDependencies memory deps_
    ) private returns (CurveYieldUnwindPlan memory plan_) {
        uint256 idle = IERC20Katana(AVKAT).balanceOf(VAULT);
        if (totalNeeded_ > idle) {
            uint256 convertible = ICurveYieldMorphoVkatStrategyFuse(deps_.vkatStrategyFuse).convertibleVkatAvkat();
            uint256 requested = totalNeeded_ - idle;
            if (requested > convertible) requested = convertible;
            if (requested != 0) {
                _executeOne(FuseAction(
                    deps_.vkatStrategyFuse, abi.encodeWithSignature("convertNeeded(uint256)", requested)
                ));
                idle = IERC20Katana(AVKAT).balanceOf(VAULT);
            }
        }
        plan_ = _planWithdrawalUnwind(totalNeeded_ > idle ? totalNeeded_ - idle : 0, rewardAction_, deps_);
    }

    function _planWithdrawalUnwind(
        uint256 requestedNetAvkat_, uint8 rewardAction_, CurveYieldMorphoStrategyDependencies memory deps_
    ) private view returns (CurveYieldUnwindPlan memory plan_) {
        if (requestedNetAvkat_ == 0) return plan_;
        CurveYieldMorphoSnapshot memory position = morphoSnapshot();
        uint256 withdraw = requestedNetAvkat_;
        for (uint256 i; i < MAX_SEARCH_ITERATIONS; ++i) {
            uint256 repay = _repayRequiredForWithdrawal(position, withdraw, TARGET_LTV_BPS);
            uint256 sell = repay == 0 ? 0 : _requiredInput(deps_.routerSwapFuse, AVKAT, KAT, repay, position.collateralAvkat);
            uint256 reward = rewardAction_ == 0 ? 0 :
                ICurveYieldMorphoRewardFuse(deps_.callerRewardFuse).quoteMorphoReward(rewardAction_, withdraw, 0);
            uint256 next = requestedNetAvkat_ + sell + reward;
            if (next <= withdraw + 1) break;
            withdraw = next;
            if (withdraw >= position.collateralAvkat) {
                revert InsufficientMorphoCollateral();
            }
        }
        uint256 repayFinal = _repayRequiredForWithdrawal(position, withdraw, TARGET_LTV_BPS);
        uint256 sellFinal = repayFinal == 0 ? 0 :
            _requiredInput(deps_.routerSwapFuse, AVKAT, KAT, repayFinal, position.collateralAvkat);
        uint256 rewardFinal = rewardAction_ == 0 ? 0 :
            ICurveYieldMorphoRewardFuse(deps_.callerRewardFuse).quoteMorphoReward(rewardAction_, withdraw, 0);
        if (withdraw < requestedNetAvkat_ + sellFinal + rewardFinal) revert UnwindNotSafe();
        plan_ = CurveYieldUnwindPlan(requestedNetAvkat_, repayFinal, withdraw, sellFinal, rewardFinal);
    }

    function _quoteUnwindForShares(uint256 shares_)
        private view returns (uint256 costBps_, uint256 extraContributionAvkat_)
    {
        if (shares_ == 0) return (0, 0);
        CurveYieldMorphoStrategyDependencies memory deps = _deps();
        ICurveYieldMorphoTargetedManager manager = ICurveYieldMorphoTargetedManager(deps.withdrawManager);
        if (shares_ > manager.activeUnreleasedShares()) revert NoActiveWithdrawalRequests();
        uint256 releasedAssets = IPlasmaVaultKatana(VAULT).previewRedeem(shares_);
        uint256 totalNeeded = IPlasmaVaultKatana(VAULT).previewRedeem(manager.getSharesToRelease() + shares_);
        uint256 available = IERC20Katana(AVKAT).balanceOf(VAULT) +
            ICurveYieldMorphoVkatStrategyFuse(deps.vkatStrategyFuse).convertibleVkatAvkat();
        if (totalNeeded <= available) return (0, 0);
        CurveYieldUnwindPlan memory plan = _planWithdrawalUnwind(totalNeeded - available, 0, deps);
        return _unwindCost(plan, releasedAssets, deps.routerSwapFuse);
    }

    function _unwindCost(CurveYieldUnwindPlan memory plan_, uint256 releasedAssets_, address swapFuse_)
        private view returns (uint256 costBps_, uint256 extraContributionAvkat_)
    {
        if (plan_.repayKat == 0) return (0, 0);
        (, uint256 reverseAvkat) = _quote(swapFuse_, KAT, AVKAT, plan_.repayKat);
        uint256 cost = plan_.sellAvkat > reverseAvkat ? plan_.sellAvkat - reverseAvkat : 0;
        costBps_ = releasedAssets_ == 0 ? 0 : Math.mulDiv(
            cost, 10_000, releasedAssets_, Math.Rounding.Ceil
        );
        uint256 covered = releasedAssets_ * _effectiveUnwindAllowanceBps() / 10_000;
        if (cost > covered) extraContributionAvkat_ = cost - covered;
    }

    function _planEmergencyFull(CurveYieldMorphoSnapshot memory position_, CurveYieldMorphoStrategyDependencies memory deps_)
        private view returns (CurveYieldUnwindPlan memory plan_)
    {
        uint256 withdraw;
        for (uint256 i; i < MAX_SEARCH_ITERATIONS; ++i) {
            uint256 repay = _repayRequiredForWithdrawal(position_, withdraw, TARGET_LTV_BPS);
            uint256 sell = _requiredInput(deps_.routerSwapFuse, AVKAT, KAT, repay, position_.collateralAvkat);
            uint256 reward = ICurveYieldMorphoRewardFuse(deps_.callerRewardFuse).quoteMorphoReward(
                ACTION_EMERGENCY_REPAY, sell, 0
            );
            uint256 next = sell + reward;
            if (next <= withdraw + 1) break;
            withdraw = next;
            if (withdraw >= position_.collateralAvkat) revert UnwindNotSafe();
        }
        uint256 repayFinal = _repayRequiredForWithdrawal(position_, withdraw, TARGET_LTV_BPS);
        uint256 sellFinal = _requiredInput(deps_.routerSwapFuse, AVKAT, KAT, repayFinal, position_.collateralAvkat);
        uint256 rewardFinal = ICurveYieldMorphoRewardFuse(deps_.callerRewardFuse).quoteMorphoReward(
            ACTION_EMERGENCY_REPAY, sellFinal, 0
        );
        plan_ = CurveYieldUnwindPlan(0, repayFinal, sellFinal + rewardFinal, sellFinal, rewardFinal);
    }

    function _planEmergencyPartial(
        CurveYieldMorphoSnapshot memory position_, uint256 repayKat_, CurveYieldMorphoStrategyDependencies memory deps_
    ) private view returns (CurveYieldUnwindPlan memory plan_) {
        uint256 sell = _requiredInput(deps_.routerSwapFuse, AVKAT, KAT, repayKat_, position_.collateralAvkat);
        uint256 reward = ICurveYieldMorphoRewardFuse(deps_.callerRewardFuse).quoteMorphoReward(
            ACTION_EMERGENCY_REPAY, sell, 0
        );
        uint256 withdraw = sell + reward;
        if (withdraw >= position_.collateralAvkat) revert UnwindNotSafe();
        uint256 remainingValue = position_.collateralValueKat -
            Math.mulDiv(withdraw, position_.collateralValueKat, position_.collateralAvkat);
        uint256 remainingDebt = position_.debtKat - repayKat_;
        MarketParams memory params = MORPHO.idToMarketParams(Id.wrap(MORPHO_MARKET_ID));
        if (remainingDebt > Math.mulDiv(remainingValue, params.lltv, 1e18)) revert UnwindNotSafe();
        plan_ = CurveYieldUnwindPlan(0, repayKat_, withdraw, sell, reward);
    }

    function _performUnwind(CurveYieldUnwindPlan memory plan_, CurveYieldMorphoStrategyDependencies memory deps_) private {
        if (plan_.withdrawAvkat == 0) return;
        if (plan_.repayKat == 0) {
            _executeOne(_collateralAction(deps_.collateralFuse, false, plan_.withdrawAvkat));
            return;
        }
        FuseAction[] memory callback = new FuseAction[](3);
        callback[0] = FuseAction(
            deps_.borrowFuse,
            abi.encodeWithSignature("exit((bytes32,uint256,uint256))", MORPHO_MARKET_ID, plan_.repayKat, 0)
        );
        callback[1] = _collateralAction(deps_.collateralFuse, false, plan_.withdrawAvkat);
        callback[2] = _swapAction(deps_.routerSwapFuse, AVKAT, KAT, plan_.sellAvkat, plan_.repayKat);
        _executeOne(FuseAction(
            deps_.flashLoanFuse,
            abi.encodeWithSignature("enter((address,uint256,bytes))", KAT, plan_.repayKat, abi.encode(callback))
        ));
        uint256 dust = IERC20Katana(KAT).balanceOf(VAULT);
        if (dust != 0) {
            (, uint256 minimum) = _quote(deps_.routerSwapFuse, KAT, AVKAT, dust);
            if (minimum != 0) _executeOne(_swapAction(deps_.routerSwapFuse, KAT, AVKAT, dust, 0));
        }
    }

    function _isProfitable(CurveYieldUnwindPlan memory plan_, uint256 assets_, address swapFuse_)
        private view returns (bool)
    {
        if (plan_.repayKat == 0) return plan_.callerRewardAvkat * 10_000 <= assets_ * _effectiveUnwindAllowanceBps();
        (, uint256 reverse) = _quote(swapFuse_, KAT, AVKAT, plan_.repayKat);
        uint256 roundTripLoss = plan_.sellAvkat > reverse ? plan_.sellAvkat - reverse : 0;
        return (roundTripLoss + plan_.callerRewardAvkat) * 10_000 <= assets_ * _effectiveUnwindAllowanceBps();
    }

    function _repayRequiredForWithdrawal(
        CurveYieldMorphoSnapshot memory position_, uint256 withdrawAvkat_, uint256 targetLtvBps_
    ) private pure returns (uint256) {
        if (withdrawAvkat_ > position_.collateralAvkat) {
            revert InsufficientMorphoCollateral();
        }
        uint256 remainingValue = position_.collateralAvkat == 0 ? 0 : Math.mulDiv(
            position_.collateralAvkat - withdrawAvkat_, position_.collateralValueKat, position_.collateralAvkat
        );
        uint256 targetDebt = remainingValue * targetLtvBps_ / 10_000;
        return position_.debtKat > targetDebt ? position_.debtKat - targetDebt : 0;
    }

    function _requiredWindupProfitBpsForFill(
        uint256 equity_, uint256 limit_, uint16 baseBps_, uint16 upperBps_
    ) private pure returns (uint256 required_) {
        uint256 limit = limit_;
        uint256 equity = equity_;
        uint256 rampStart = limit * 6_500 / 10_000;
        if (limit == 0 || equity <= rampStart) return baseBps_;
        if (equity >= limit) return upperBps_;
        required_ = baseBps_ + Math.mulDiv(
            upperBps_ - baseBps_,
            equity - rampStart, limit - rampStart, Math.Rounding.Ceil
        );
    }

    function _solveCycleSupply(
        uint256 idle_,
        uint256 capacity_,
        CurveYieldMorphoLoopState memory state_,
        address rewardFuse_
    ) private view returns (uint256 basis_) {
        basis_ = idle_ < capacity_ ? idle_ : capacity_;
        for (uint256 i; i < 8; ++i) {
            uint256 reward = ICurveYieldMorphoRewardFuse(rewardFuse_).quoteMorphoReward(
                ACTION_DEPLOY_ASSETS, state_.basis + basis_, state_.excessProfit
            );
            uint256 working = idle_ > reward ? idle_ - reward : 0;
            uint256 next = working < capacity_ ? working : capacity_;
            if (next == basis_) break;
            basis_ = next;
        }
    }

    function _effectiveUnwindAllowanceBps() private view returns (uint256) {
        CurveYieldMorphoStrategyConfig memory config = _config();
        uint256 surplus = config.requestFeeBps - config.minimumProfitBps;
        return surplus < config.unwindLossAllowanceBps ? surplus : config.unwindLossAllowanceBps;
    }

    function _requiredInput(address swapFuse_, address in_, address out_, uint256 amount_, uint256 maximum_)
        private view returns (uint256)
    {
        return ICurveYieldMorphoSwapFuse(swapFuse_).requiredInputView(in_, out_, amount_, maximum_);
    }

    function _quote(address swapFuse_, address in_, address out_, uint256 amount_)
        private view returns (uint256 expected_, uint256 minimum_)
    {
        return ICurveYieldMorphoSwapFuse(swapFuse_).quoteExactInputView(in_, out_, amount_);
    }

    function _quoteLive(address swapFuse_, address in_, address out_, uint256 amount_)
        private returns (uint256 expected_, uint256 minimum_)
    {
        return ICurveYieldMorphoSwapFuse(swapFuse_).quoteExactInput(in_, out_, amount_);
    }

    function _collateralAction(address fuse_, bool enter_, uint256 amount_) private pure returns (FuseAction memory) {
        return FuseAction(fuse_, enter_
            ? abi.encodeWithSignature("enter((bytes32,uint256))", MORPHO_MARKET_ID, amount_)
            : abi.encodeWithSignature("exit((bytes32,uint256))", MORPHO_MARKET_ID, amount_));
    }

    function _swapAction(address fuse_, address in_, address out_, uint256 amount_, uint256 minimum_)
        private pure returns (FuseAction memory)
    {
        return FuseAction(fuse_, abi.encodeWithSignature(
            "enter((address,address,uint256,uint256))", in_, out_, amount_, minimum_
        ));
    }

    function _executeOne(FuseAction memory action_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = action_;
        _executeInternal(actions);
    }

    function _executeInternal(FuseAction[] memory actions_) private {
        ICurveYieldMorphoVaultInternal(address(this)).executeInternal(actions_);
    }

    function _ensureWithdrawalRevenueAllowance(address withdrawManager_) private {
        IERC20Katana token = IERC20Katana(AVKAT);
        if (token.allowance(VAULT, withdrawManager_) == type(uint256).max) return;
        _forceApprove(withdrawManager_, type(uint256).max);
    }

    function _forceApprove(address spender_, uint256 amount_) private {
        IERC20Katana token = IERC20Katana(AVKAT);
        uint256 current = token.allowance(VAULT, spender_);
        if (current != 0 && !token.approve(spender_, 0)) revert UnwindNotSafe();
        if (amount_ != 0 && !token.approve(spender_, amount_)) revert UnwindNotSafe();
    }

    function _fundController(uint256 amount_) private {
        if (amount_ != 0 && !IERC20Katana(AVKAT).transfer(_controller(), amount_)) revert UnwindNotSafe();
    }

    function _publishResult(uint8 action_, uint256 basis_, uint256 excess_, uint256 reward_) private {
        bytes32[] memory result = new bytes32[](4);
        result[0] = bytes32(uint256(action_));
        result[1] = bytes32(basis_);
        result[2] = bytes32(excess_);
        result[3] = bytes32(reward_);
        TransientStorageLib.setOutputs(VERSION, result);
    }

    function _setDependencies(CurveYieldMorphoStrategyDependencies memory deps_) private {
        if (
            deps_.withdrawManager == address(0) || deps_.rewardsClaimManager == address(0) ||
            deps_.collateralFuse == address(0) || deps_.borrowFuse == address(0) ||
            deps_.flashLoanFuse == address(0) || deps_.routerSwapFuse == address(0) ||
            deps_.callerRewardFuse == address(0) || deps_.vkatStrategyFuse == address(0) ||
            deps_.profitCustody == address(0)
        ) revert InvalidDependencies();
        _dependencies = deps_;
    }

    function _deps() private view returns (CurveYieldMorphoStrategyDependencies memory) {
        return ICurveYieldMorphoStrategyConfigView(VERSION).dependencies();
    }

    function _config() private view returns (CurveYieldMorphoStrategyConfig memory) {
        return ICurveYieldMorphoStrategyConfigView(VERSION).strategyConfig();
    }

    function _controller() private view returns (address) {
        return ICurveYieldMorphoStrategyConfigView(VERSION).CONTROLLER();
    }

    function _requireImplementation() private view {
        if (address(this) != VERSION) revert WrongImplementationContext();
    }

    function _requireActionContext() private view {
        if (address(this) != VAULT) revert WrongVaultContext();
        address controller = _controller();
        if (msg.sender != controller) revert UnauthorizedCaller();
        if (!PlasmaVaultLib.isExecutionStarted()) revert WrongVaultContext();
    }
}
