// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {FuseAction, ICyStrategySet} from "../interfaces/CurveYieldPhase2Interfaces.sol";
import {CurveYieldPolPriceLib} from "./CurveYieldPolPriceLib.sol";
import {CurveYieldGateConfig, CurveYieldConfigKeys as K} from "../governance/CurveYieldGateConfig.sol";
import {CySushiRoute, IBalV3Vault, ICyPolWithdrawManager} from "./CurveYieldPolInterfaces.sol";
import {TryElseEnterData} from "../generic/CurveYieldTryElseFuse.sol";
// Fuse calls encode the fuse's ONE struct parameter (not its fields as loose top-level params: these tuples are dynamic)
import {
    BalancerLiquidityProportionalFuseEnterData,
    BalancerLiquidityProportionalFuseExitData
} from "contracts/fuses/balancer/BalancerLiquidityProportionalFuse.sol";

struct CyPolVenues {
    address pool; // CurveYield DEX Gyro E-CLP cyavKAT/avKAT pool (created manually by the operator)
    address balancerVault;
    address cyWethPool; // Sushi V3 0.3% cyavKAT/WETH: TWAP market reference (0 = no automatic trigger)
    address withdrawManager; // cyavKAT's withdraw manager (instant-withdraw fee headroom)
}

/// @notice The fuses this controller plans for (fuse standardization; all stateless, IPOR style).
struct CyPolFuses {
    address liquidity; // IPOR BalancerLiquidityProportionalFuse (market 36)
    address swap; // CurveYieldRouterSwapFuseV2 (router v2 route through the POL pool)
    address tryElse; // CurveYieldTryElseFuse
    address burn; // CurveYieldBurnHeldSharesFuse
    address transfer; // CurveYieldErc20TransferFuse (admin yield fee)
}

struct CyPolParams {
    uint16 capBps; // position A share of managed avKAT (3%), 0..1,000
    uint16 triggerBps; // buyback while market <= deposit rate x (1 - this) (300), 50..2,000
    uint16 minGainBps; // bought cyavKAT costs <= deposit rate x (1 - this) (100), 0..1,000, <= triggerBps
    uint16 maxPerRunBps; // share of the position per automatic buyback (default 10%, cap 25%)
    uint16 buybackBudgetBps; // lifetime POL buyback budget, share of net POL contributed (default 35%, cap 50%)
    uint32 cooldown; // between automatic buybacks (12 h), 1 h..7 d
    uint16 minPolProfitBps; // withdrawals funded from POL keep the vault >= this (50 = 0.5%), 0..500
    uint16 maxChargeDiscountBps; // fulfillFor with a charge may sell the cyavKAT leg down to NAV x (1 - this) (1,000)
    uint16 maxSlippageBps; // exit amounts vs expected (100), 10..500
    uint32 twapWindow; // (30 min) 5 min..24 h
    bool idleBuyback; // also buy back with vault idle avKAT (off)
    uint16 maxIdleBps; // of managed avKAT per idle buyback run (100 = 1%), 0..500
    uint16 addHaircutBps; // proportional add asks this much under the exact BPT (1 = 0.01%), 0..50
}

/// @title CurveYieldPolController (POL spec, position A) — a PLANNER
/// @notice The cyavKAT vault's own liquidity in the CurveYield DEX Gyro E-CLP cyavKAT/avKAT pool: settings, valuation,
/// triggers and plans. Every plan is a bundle of stateless fuses (IPOR's Balancer liquidity fuse + CurveYield generic
/// swap / try-else / burn / transfer fuses) with explicit amounts; the executor wraps bundles in the guard.
/// - Enter: buy cyavKAT in the pool with idle avKAT (never above the deposit rate), add proportionally,
///   burn any cyavKAT left over (PPS-neutral or better).
/// - Exit (withdrawals at `minSellBps`, cap reductions at 100%): proportional exit, then TRY selling the cyavKAT leg for
///   at least `minSellBps` of its net value, ELSE burn it; the output is avKAT. No fee.
/// - Buyback (only while cyavKAT trades `triggerBps` under the deposit rate): exit, buy cyavKAT with the avKAT leg (and
///   optionally idle avKAT) at <= deposit rate x (1 - minGain), burn everything, admin yield fee on the GUARANTEED
///   profit (the minimum bought at its net value minus the avKAT spent).
contract CurveYieldPolController is ICyStrategySet, Ownable2Step, CurveYieldGateConfig {
    uint256 private constant BPS = 10_000;

    address public immutable VAULT;
    address public immutable AVKAT;
    address public immutable FEE_MANAGER;

    CyPolVenues public venues;
    CyPolFuses public fuses;
    CySushiRoute[] private _wethToAvkat; // market reference only
    address public adminReceiver; // receives the admin yield fee (fee authority only)
    /// @notice Lifetime POL buyback budget (POL spec amendment 2026-09-29), in BPT so valuation changes never move it:
    /// net BPT contributed (entries in, non-buyback exits out) and BPT converted into buybacks.
    uint256 public netContributedBpt;
    uint256 public convertedBpt;
    uint256 public lastBpt;
    address public executor;
    uint256 public lastBuybackAt;

    event VenuesUpdated(CyPolVenues venues);
    event FusesUpdated(CyPolFuses fuses);
    event AdminReceiverUpdated(address receiver);
    event BptSynced(uint256 bpt, uint256 netContributedBpt, uint256 convertedBpt);
    event ExecutorUpdated(address executor);
    event BuybackRecorded(uint256 at);

    error BadParams();
    error OnlyExecutor(address caller);

    constructor(address owner_, address vault_, address avkat_, address feeManager_, address configGate_)
        Ownable(owner_)
        CurveYieldGateConfig(configGate_)
    {
        if (vault_ == address(0) || avkat_ == address(0) || feeManager_ == address(0)) revert BadParams();
        (VAULT, AVKAT, FEE_MANAGER) = (vault_, avkat_, feeManager_);
    }

    // ---------------------------------------------------------------- configuration

    function setVenues(CyPolVenues calldata v_) external onlyOwner {
        if (v_.pool == address(0) || v_.balancerVault == address(0) || v_.withdrawManager == address(0)) revert BadParams();
        (IERC20[] memory tokens,,,) = IBalV3Vault(v_.balancerVault).getPoolTokenInfo(v_.pool);
        if (tokens.length != 2 || !((address(tokens[0]) == VAULT && address(tokens[1]) == AVKAT) ||
            (address(tokens[0]) == AVKAT && address(tokens[1]) == VAULT))) revert BadParams();
        venues = v_;
        emit VenuesUpdated(v_);
    }

    function setFuses(CyPolFuses calldata f_) external onlyOwner {
        if (f_.liquidity == address(0) || f_.swap == address(0) || f_.tryElse == address(0) || f_.burn == address(0) ||
            f_.transfer == address(0)) revert BadParams();
        fuses = f_;
        emit FusesUpdated(f_);
    }

    function setExecutor(address executor_) external onlyOwner {
        if (executor_ == address(0)) revert BadParams();
        executor = executor_;
        emit ExecutorUpdated(executor_);
    }

    /// @notice Receiver of the admin yield fee (its bps is in the governance gate). Fee authority only (protected).
    function setAdminReceiver(address receiver_) external onlyOwner {
        if (receiver_ == address(0)) revert BadParams();
        adminReceiver = receiver_;
        emit AdminReceiverUpdated(receiver_);
    }

    function setMarketRoutes(CySushiRoute[] calldata wethToAvkat_) external onlyOwner {
        delete _wethToAvkat;
        for (uint256 i; i < wethToAvkat_.length; ++i) _wethToAvkat.push(wethToAvkat_[i]);
    }

    /// @notice The POL settings, read from the governance gate.
    function params() public view returns (CyPolParams memory p_) {
        bytes32[] memory k = new bytes32[](13);
        (k[0], k[1], k[2], k[3]) = (K.POL_CAP_BPS, K.POL_TRIGGER_BPS, K.POL_MIN_GAIN_BPS, K.POL_MAX_PER_RUN_BPS);
        (k[4], k[5], k[6], k[7]) = (K.POL_BUYBACK_BUDGET_BPS, K.POL_COOLDOWN, K.POL_MIN_POL_PROFIT_BPS, K.POL_MAX_CHARGE_DISCOUNT_BPS);
        (k[8], k[9], k[10], k[11], k[12]) = (K.POL_MAX_SLIPPAGE_BPS, K.POL_TWAP_WINDOW, K.POL_IDLE_BUYBACK, K.POL_MAX_IDLE_BPS, K.POL_ADD_HAIRCUT_BPS);
        uint256[] memory v = _config(k);
        p_.capBps = uint16(v[0]);
        p_.triggerBps = uint16(v[1]);
        p_.minGainBps = uint16(v[2]);
        p_.maxPerRunBps = uint16(v[3]);
        p_.buybackBudgetBps = uint16(v[4]);
        p_.cooldown = uint32(v[5]);
        p_.minPolProfitBps = uint16(v[6]);
        p_.maxChargeDiscountBps = uint16(v[7]);
        p_.maxSlippageBps = uint16(v[8]);
        p_.twapWindow = uint32(v[9]);
        p_.idleBuyback = v[10] != 0;
        p_.maxIdleBps = uint16(v[11]);
        p_.addHaircutBps = uint16(v[12]);
    }

    /// @notice Admin share of the REAL profit of withdrawals and buybacks (bps), from the gate (FEE class).
    function yieldFeeBps() public view returns (uint256) {
        return _config1(K.POL_YIELD_FEE_BPS);
    }

    /// @notice BPT still convertible into buybacks: budget x net contributed - converted (unsynced exits counted).
    function buybackBudgetLeftBpt() public view returns (uint256) {
        (uint256 net,) = _reconciled();
        uint256 budget = net * params().buybackBudgetBps / BPS;
        return budget > convertedBpt ? budget - convertedBpt : 0;
    }

    /// @notice Books the POL position's BPT change since the last sync (executor, after every POL bundle): a decrease
    /// is a buyback conversion when `buyback_`, otherwise an exit (net contributed down); an increase is an entry.
    function syncBpt(bool buyback_) external {
        if (msg.sender != executor) revert OnlyExecutor(msg.sender);
        uint256 current = venues.pool == address(0) ? 0 : IERC20(venues.pool).balanceOf(VAULT);
        uint256 last = lastBpt;
        if (current > last) {
            netContributedBpt += current - last;
        } else if (last > current) {
            uint256 d = last - current;
            if (buyback_) convertedBpt += d;
            else netContributedBpt = netContributedBpt > d ? netContributedBpt - d : 0;
        }
        lastBpt = current;
        emit BptSynced(current, netContributedBpt, convertedBpt);
    }

    /// @dev Net contributed as if every change since the last sync were an entry / exit (instant exits run outside the
    /// executor and are booked at the next sync).
    function _reconciled() private view returns (uint256 net_, uint256 current_) {
        current_ = venues.pool == address(0) ? 0 : IERC20(venues.pool).balanceOf(VAULT);
        net_ = netContributedBpt;
        uint256 last = lastBpt;
        if (current_ > last) net_ += current_ - last;
        else if (last > current_) net_ = net_ > last - current_ ? net_ - (last - current_) : 0;
    }

    /// @notice Starts the buyback cooldown (the executor, after a buyback bundle succeeded).
    function recordBuyback() external {
        if (msg.sender != executor) revert OnlyExecutor(msg.sender);
        lastBuybackAt = block.timestamp;
        emit BuybackRecorded(block.timestamp);
    }

    // ---------------------------------------------------------------- views

    /// @notice The vault's BPT and its proportional share of the pool's raw balances.
    function position() public view returns (uint256 bpt_, uint256 cyavkat_, uint256 avkat_, uint256 bptSupply_) {
        CyPolVenues memory v = venues;
        if (v.pool == address(0)) return (0, 0, 0, 0);
        bpt_ = IERC20(v.pool).balanceOf(VAULT);
        bptSupply_ = IERC20(v.pool).totalSupply();
        if (bpt_ == 0 || bptSupply_ == 0) return (bpt_, 0, 0, bptSupply_);
        (IERC20[] memory tokens,, uint256[] memory raw,) = IBalV3Vault(v.balancerVault).getPoolTokenInfo(v.pool);
        (uint256 c, uint256 a) = address(tokens[0]) == VAULT ? (raw[0], raw[1]) : (raw[1], raw[0]);
        (cyavkat_, avkat_) = (c * bpt_ / bptSupply_, a * bpt_ / bptSupply_);
    }

    function depositRate() public view returns (uint256) {
        return CurveYieldPolPriceLib.depositRate(VAULT, FEE_MANAGER);
    }

    function marketRate() public view returns (uint256) {
        return CurveYieldPolPriceLib.marketRate(VAULT, venues.cyWethPool, _wethToAvkat, params().twapWindow);
    }

    function buybackTriggered() public view returns (bool) {
        uint256 m = marketRate();
        return m != 0 && m * BPS <= depositRate() * (BPS - params().triggerBps);
    }

    function netValue(uint256 cyavkat_) public view returns (uint256) {
        return CurveYieldPolPriceLib.netValue(VAULT, FEE_MANAGER, cyavkat_);
    }

    /// @inheritdoc ICyStrategySet
    function managedAvkat() public view override returns (uint256) {
        (, uint256 c, uint256 a,) = position();
        return a + netValue(c);
    }

    /// @inheritdoc ICyStrategySet
    function allocationBps() external view override returns (uint256) {
        return params().capBps;
    }

    /// @notice BPT that exits about `avkat_` of value (net rate).
    function bptFor(uint256 avkat_) public view returns (uint256) {
        (uint256 bpt,,,) = position();
        uint256 value = managedAvkat();
        if (value == 0) return 0;
        uint256 out = bpt * avkat_ / value;
        return out > bpt ? bpt : out;
    }

    /// @notice Sale floor for instant withdrawals: BPS^2 / (BPS + h), h = instant fee - minPolProfit (the shortfall of a
    /// sale then stays within h of what it provides); no headroom = only at NAV.
    function instantMinSellBps() public view returns (uint256) {
        uint256 feeBps = ICyPolWithdrawManager(venues.withdrawManager).getWithdrawFee() / 1e14;
        uint256 floor = params().minPolProfitBps;
        if (feeBps <= floor) return BPS;
        return BPS * BPS / (BPS + (feeBps - floor));
    }

    // ---------------------------------------------------------------- plans (ICyStrategySet + POL)

    /// @inheritdoc ICyStrategySet
    function planDeploy(uint256 budgetAvkat_, uint256 managedTotal_)
        external view override returns (FuseAction[] memory actions_, uint256 consumedAvkat_)
    {
        if (budgetAvkat_ == 0 || fuses.liquidity == address(0) || venues.pool == address(0)) return (actions_, 0);
        uint256 target = managedTotal_ * params().capBps / BPS;
        uint256 current = managedAvkat();
        if (current >= target) return (actions_, 0);
        consumedAvkat_ = target - current;
        if (consumedAvkat_ > budgetAvkat_) consumedAvkat_ = budgetAvkat_;
        actions_ = _enterActions(consumedAvkat_);
        if (actions_.length == 0) consumedAvkat_ = 0;
    }

    /// @inheritdoc ICyStrategySet
    /// @dev Over the cap: exit the excess; the cyavKAT leg is sold only at or above its net value (else burned). No fee.
    function planReduce(uint256 managedTotal_)
        external view override returns (FuseAction[] memory actions_, uint256 releasedAvkat_)
    {
        uint256 target = managedTotal_ * params().capBps / BPS;
        uint256 current = managedAvkat();
        if (current <= target || fuses.liquidity == address(0)) return (actions_, 0);
        releasedAvkat_ = current - target;
        actions_ = _exitActions(bptFor(releasedAvkat_), BPS);
    }

    /// @inheritdoc ICyStrategySet
    /// @dev Withdrawals: the executor funds from POL through planPolWithdraw (0.5% rule); nothing through this path.
    function planWithdraw(uint256, bool) external pure override returns (FuseAction[] memory actions_, uint256) {
        return (actions_, 0);
    }

    /// @notice Exit for a withdrawal at the executor's sale floor (fee headroom, or maxChargeDiscount when charged).
    function planPolWithdraw(uint256 neededAvkat_, uint256 minSellBps_)
        external view returns (FuseAction[] memory actions_, uint256 providedAvkat_)
    {
        if (neededAvkat_ == 0 || fuses.liquidity == address(0)) return (actions_, 0);
        uint256 total = managedAvkat();
        providedAvkat_ = neededAvkat_ < total ? neededAvkat_ : total;
        if (providedAvkat_ == 0) return (actions_, 0);
        actions_ = _exitActions(bptFor(providedAvkat_), minSellBps_);
    }

    /// @notice POL-funded part of a scheduled fulfilment (POL spec 3c), planning half: the sale floor from the request
    /// fee headroom h = fee - minPolProfit (a sale at BPS^2 / (BPS + h) falls short by at most h of what it provides);
    /// a charged fulfilFor may sell down to maxChargeDiscount. Nothing when uncharged and the fee cannot cover the minimum.
    function planPolStep(uint256 neededAvkat_, uint256 requestFeeBps_, bool charged_)
        external view returns (FuseAction[] memory actions_, uint256 plannedAvkat_)
    {
        CyPolParams memory p = params();
        if (!charged_ && requestFeeBps_ < p.minPolProfitBps) return (actions_, 0);
        uint256 h = requestFeeBps_ > p.minPolProfitBps ? requestFeeBps_ - p.minPolProfitBps : 0;
        uint256 discount = charged_ && p.maxChargeDiscountBps > h ? p.maxChargeDiscountBps : h;
        return this.planPolWithdraw(neededAvkat_, BPS * BPS / (BPS + discount));
    }

    /// @notice Settlement half: from what the step provided and cost, the vault's minimum (`floor_`), what the requester
    /// must be charged to keep it (`shortAvkat_`, 0 if the fee covers it) or else the admin yield fee on the rest.
    function settlePolStep(uint256 providedAvkat_, uint256 costAvkat_, uint256 requestFeeBps_)
        external view returns (uint256 floor_, uint256 shortAvkat_, uint256 yieldFee_)
    {
        floor_ = providedAvkat_ * params().minPolProfitBps / BPS;
        uint256 feeOnPol = providedAvkat_ * requestFeeBps_ / BPS;
        uint256 needs = costAvkat_ + floor_;
        if (feeOnPol < needs) shortAvkat_ = needs - feeOnPol;
        else yieldFee_ = (feeOnPol - needs) * yieldFeeBps() / BPS;
    }

    /// @notice Instant withdrawals (through CurveYieldPlannedInstantWithdrawFuse): sells only within the fee headroom.
    function planInstantWithdraw(uint256 amount_) external view returns (FuseAction[] memory actions_) {
        if (amount_ == 0 || fuses.liquidity == address(0)) return actions_;
        uint256 total = managedAvkat();
        actions_ = _exitActions(bptFor(amount_ < total ? amount_ : total), instantMinSellBps());
    }

    /// @notice Automatic buyback (inside deployAssets): only while triggered and after the cooldown. POL BPT used is
    /// capped per run (maxPerRunBps) and by the lifetime budget (buybackBudgetLeftBpt). Idle buybacks are separate (no
    /// lifetime cap). Returns the guaranteed net gain the bundle must add to the share price (buybacks must increase PPS:
    /// the executor guards the bundle with it). The executor calls recordBuyback() and syncBpt(true) after it succeeded.
    function planBuyback() external view returns (FuseAction[] memory actions_, uint256 minGainAvkat_) {
        CyPolParams memory p = params();
        if (fuses.liquidity == address(0) || block.timestamp < lastBuybackAt + p.cooldown || !buybackTriggered()) {
            return (actions_, 0);
        }
        (uint256 bpt,,,) = position();
        uint256 lp = bpt * p.maxPerRunBps / BPS;
        uint256 left = buybackBudgetLeftBpt();
        if (lp > left) lp = left;
        uint256 idle;
        if (p.idleBuyback) {
            idle = IERC20(AVKAT).balanceOf(VAULT);
            uint256 max = (IERC20(AVKAT).balanceOf(VAULT) + managedAvkat()) * p.maxIdleBps / BPS;
            if (idle > max) idle = max;
        }
        if (lp == 0 && idle == 0) return (actions_, 0);
        (actions_, minGainAvkat_) = _buybackActions(lp, idle, p.minGainBps);
    }

    /// @notice Burn every cyavKAT the vault holds (maintenance).
    function planBurnHeld() external view returns (FuseAction[] memory actions_) {
        if (fuses.burn == address(0) || IERC20(VAULT).balanceOf(VAULT) == 0) return actions_;
        actions_ = new FuseAction[](1);
        actions_[0] = _burnAction();
    }

    /// @notice Admin yield fee on a withdrawal's real profit above the vault's minimum (executor: POL-funded part only).
    function withdrawYieldFee(uint256 profitAboveFloorAvkat_) external view returns (uint256) {
        return profitAboveFloorAvkat_ * yieldFeeBps() / BPS;
    }

    /// @notice The transfer action paying `amount_` avKAT to the admin receiver (executor).
    function yieldFeeAction(uint256 amount_) external view returns (FuseAction memory) {
        return _transferAction(amount_);
    }

    // ---------------------------------------------------------------- bundle builders

    function _enterActions(uint256 avkatIn_) private view returns (FuseAction[] memory actions_) {
        CyPolVenues memory v = venues;
        (IERC20[] memory tokens,, uint256[] memory raw,) = IBalV3Vault(v.balancerVault).getPoolTokenInfo(v.pool);
        uint256 cyIdx = address(tokens[0]) == VAULT ? 0 : 1;
        uint256 rate = depositRate();
        uint256 one = CurveYieldPolPriceLib.oneShare(VAULT);
        uint256 cyVal = raw[cyIdx] * rate / one;
        uint256 avVal = raw[1 - cyIdx];
        if (cyVal + avVal == 0) return actions_; // pool not seeded
        uint256 forCy = avkatIn_ * cyVal / (cyVal + avVal);
        uint256 minCy = forCy * one / rate; // never above NAV (no premium setting: a premium would lower PPS)
        uint256 avLeft = avkatIn_ - forCy;
        if (minCy == 0 || minCy >= raw[cyIdx] || avLeft == 0) return actions_;
        // BPT the guaranteed amounts cover at the post-swap balances (the swap removes >= minCy cyavKAT from the pool and
        // adds <= forCy avKAT), a haircut under the limiting side
        uint256 supply = IERC20(v.pool).totalSupply();
        uint256 byCy = minCy * supply / (raw[cyIdx] - minCy);
        uint256 byAv = avLeft * supply / (raw[1 - cyIdx] + forCy);
        uint256 bptOut = (byCy < byAv ? byCy : byAv) * (BPS - params().addHaircutBps) / BPS;
        if (bptOut == 0) return actions_;
        address[] memory t = new address[](2);
        (t[0], t[1]) = (address(tokens[0]), address(tokens[1]));
        uint256[] memory maxIn = new uint256[](2);
        maxIn[cyIdx] = forCy * one * 2 / rate; // generous cap: the router pulls only what the BPT needs
        maxIn[1 - cyIdx] = avLeft;
        actions_ = new FuseAction[](3);
        actions_[0] = _swapAction(AVKAT, VAULT, forCy, minCy);
        actions_[1] = FuseAction(fuses.liquidity, abi.encodeWithSignature(
            "enter((address,address[],uint256[],uint256))",
            BalancerLiquidityProportionalFuseEnterData(v.pool, t, maxIn, bptOut)
        ));
        actions_[2] = _burnAction(); // leftover cyavKAT
    }

    function _exitActions(uint256 bpt_, uint256 minSellBps_) private view returns (FuseAction[] memory actions_) {
        if (bpt_ == 0) return actions_;
        (uint256 cyExpected, uint256[] memory minOut) = _exitAmounts(bpt_);
        actions_ = new FuseAction[](3);
        actions_[0] = FuseAction(fuses.liquidity, abi.encodeWithSignature(
            "exit((address,uint256,uint256[]))", BalancerLiquidityProportionalFuseExitData(venues.pool, bpt_, minOut)
        ));
        FuseAction[] memory attempt = new FuseAction[](minSellBps_ == 0 ? 0 : 1);
        if (minSellBps_ != 0) attempt[0] = _swapAction(VAULT, AVKAT, cyExpected, netValue(cyExpected) * minSellBps_ / BPS);
        FuseAction[] memory fallbackActions = new FuseAction[](1);
        fallbackActions[0] = _burnAction();
        actions_[1] = FuseAction(fuses.tryElse, abi.encodeWithSignature(
            "enter(((address,bytes)[],(address,bytes)[]))", TryElseEnterData(attempt, fallbackActions)
        ));
        actions_[2] = _burnAction(); // any cyavKAT left (e.g. more came out than expected)
    }

    function _buybackActions(uint256 bpt_, uint256 idle_, uint256 minGainBps_)
        private view returns (FuseAction[] memory actions_, uint256 netGain_)
    {
        uint256 avIn = idle_;
        FuseAction memory exitAction;
        if (bpt_ != 0) {
            (, uint256[] memory minOut) = _exitAmounts(bpt_);
            (IERC20[] memory tokens,,,) = IBalV3Vault(venues.balancerVault).getPoolTokenInfo(venues.pool);
            avIn += minOut[address(tokens[0]) == AVKAT ? 0 : 1]; // spend the guaranteed avKAT; any extra stays idle
            exitAction = FuseAction(fuses.liquidity, abi.encodeWithSignature(
                "exit((address,uint256,uint256[]))", BalancerLiquidityProportionalFuseExitData(venues.pool, bpt_, minOut)
            ));
        }
        uint256 rate = depositRate();
        uint256 one = CurveYieldPolPriceLib.oneShare(VAULT);
        uint256 minCy = avIn * one * BPS / (rate * (BPS - minGainBps_));
        uint256 guaranteedValue = minCy * rate / one;
        uint256 fee = guaranteedValue > avIn ? (guaranteedValue - avIn) * yieldFeeBps() / BPS : 0;
        netGain_ = guaranteedValue > avIn + fee ? guaranteedValue - avIn - fee : 0;
        uint256 n = (bpt_ != 0 ? 1 : 0) + (avIn != 0 ? 1 : 0) + 1 + (fee != 0 ? 1 : 0);
        actions_ = new FuseAction[](n);
        uint256 k;
        if (bpt_ != 0) actions_[k++] = exitAction;
        if (avIn != 0) actions_[k++] = _swapAction(AVKAT, VAULT, avIn, minCy);
        actions_[k++] = _burnAction();
        if (fee != 0) actions_[k] = _transferAction(fee);
    }

    /// @dev Expected cyavKAT out and the per-token minimums (pool order) for exiting `bpt_`.
    function _exitAmounts(uint256 bpt_) private view returns (uint256 cyExpected_, uint256[] memory minOut_) {
        (IERC20[] memory tokens,, uint256[] memory raw,) = IBalV3Vault(venues.balancerVault).getPoolTokenInfo(venues.pool);
        uint256 supply = IERC20(venues.pool).totalSupply();
        minOut_ = new uint256[](2);
        for (uint256 i; i < 2; ++i) {
            uint256 expected = raw[i] * bpt_ / supply;
            if (address(tokens[i]) == VAULT) cyExpected_ = expected;
            minOut_[i] = expected * (BPS - params().maxSlippageBps) / BPS;
        }
    }

    function _swapAction(address in_, address out_, uint256 amountIn_, uint256 minOut_) private view returns (FuseAction memory) {
        return FuseAction(fuses.swap, abi.encodeWithSignature(
            "enter((address,address,uint256,uint256))", in_, out_, amountIn_, minOut_ // swap fuse v2 (router v2 route)
        ));
    }

    function _burnAction() private view returns (FuseAction memory) {
        return FuseAction(fuses.burn, abi.encodeWithSignature("enter((uint256))", uint256(0)));
    }

    function _transferAction(uint256 amount_) private view returns (FuseAction memory) {
        return FuseAction(fuses.transfer, abi.encodeWithSignature(
            "enter((address,address,uint256))", AVKAT, adminReceiver, amount_
        ));
    }

}
