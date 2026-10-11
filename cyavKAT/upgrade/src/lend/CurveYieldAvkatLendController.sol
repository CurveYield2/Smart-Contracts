// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {FuseAction, ICyStrategySet} from "../interfaces/CurveYieldPhase2Interfaces.sol";
import {CurveYieldGateConfig, CurveYieldConfigKeys as K} from "../governance/CurveYieldGateConfig.sol";

struct CyLendParams {
    uint16 capBps; // lending share of managed avKAT (D3: 20%)
    uint16 ownershipTriggerBps; // stop + decay once the vault owns more than this share of the market's supply (20%)
    uint16 decayBps; // reduce by at most this share of the vault's lent amount per interval (10%)
    uint32 decayInterval; // (12 h)
    uint16 liquidityFloorBps; // a reduction never leaves market liquidity below this share of its supply (3%)
    uint128 ownershipExemptAvkat; // the vault's first N avKAT lent ignore the ownership rule (10,000 avKAT)
}

/// @notice avKAT lending set (#13, with a first-10k ownership exemption, 2026-09-24): supplies idle avKAT to Morpho market LEND_MARKET 0xe0e5 (loan avKAT, collateral wcyavKAT; deployed with MARKET_ID from P2_01) through
/// IPOR's audited MorphoSupplyFuse in IPOR market 41 (MORPHO_LIQUIDITY_IN_MARKETS, "Lend Only"), valued by IPOR's MorphoOnlyLiquidityBalanceFuse (live since L9, 2026-09-25).
///
/// #13 rules: when the vault owns more than `ownershipTriggerBps` of the market's supply, or the market's available
/// liquidity is below the vault's own supply, it stops depositing and reduces by up to `decayBps` of its lent amount
/// per `decayInterval`, never taking market liquidity below `liquidityFloorBps`. Withdrawals for users may use all
/// available liquidity.
contract CurveYieldAvkatLendController is ICyStrategySet, Ownable2Step, CurveYieldGateConfig {
    using MorphoBalancesLib for IMorpho;

    uint256 private constant BPS = 10_000;

    address public immutable VAULT;
    IMorpho public immutable MORPHO;
    bytes32 public immutable MARKET_ID;
    address public executor;
    address public supplyFuse; // IPOR MorphoSupplyFuse (market 14)
    uint256 public lastReductionAt;

    error InvalidAddress();
    error OnlyVault(address caller);

    event ExecutorUpdated(address indexed executor);
    event FusesUpdated(address supplyFuse);
    event ReductionRecorded(uint256 amount, uint256 at);

    struct MarketState {
        uint256 vaultSupply;
        uint256 totalSupply;
        uint256 totalBorrow;
        uint256 available;
        uint256 vaultShareBps;
        bool ownershipTriggered;
        bool liquidityTriggered;
        bool triggered;
    }

    constructor(
        address owner_,
        address vault_,
        address morpho_,
        bytes32 marketId_,
        address configGate_
    ) Ownable(owner_) CurveYieldGateConfig(configGate_) {
        if (vault_ == address(0) || morpho_ == address(0) || marketId_ == bytes32(0)) revert InvalidAddress();
        VAULT = vault_;
        MORPHO = IMorpho(morpho_);
        MARKET_ID = marketId_;
    }

    // ---------------------------------------------------------------- configuration

    function setExecutor(address executor_) external onlyOwner {
        if (executor_ == address(0)) revert InvalidAddress();
        executor = executor_;
        emit ExecutorUpdated(executor_);
    }

    /// @notice IPOR MorphoSupplyFuse (market 41): supply, withdrawals and decay steps all use it directly.
    function setFuses(address supplyFuse_) external onlyOwner {
        if (supplyFuse_ == address(0)) revert InvalidAddress();
        supplyFuse = supplyFuse_;
        emit FusesUpdated(supplyFuse_);
    }

    /// @notice The lending set's settings, read from the governance gate.
    function params() public view returns (CyLendParams memory p_) {
        bytes32[] memory k = new bytes32[](6);
        (k[0], k[1], k[2]) = (K.LEND_CAP_BPS, K.LEND_OWNERSHIP_TRIGGER_BPS, K.LEND_DECAY_BPS);
        (k[3], k[4], k[5]) = (K.LEND_DECAY_INTERVAL, K.LEND_LIQUIDITY_FLOOR_BPS, K.LEND_OWNERSHIP_EXEMPT_AVKAT);
        uint256[] memory v = _config(k);
        p_ = CyLendParams(uint16(v[0]), uint16(v[1]), uint16(v[2]), uint32(v[3]), uint16(v[4]), uint128(v[5]));
    }

    /// @notice Called by the executor after a reduce bundle with the amount ACTUALLY withdrawn (lending position before
    /// minus after), so decay steps are spaced by `decayInterval`.
    function recordReduction(uint256 amount_) external {
        if (msg.sender != executor) revert OnlyVault(msg.sender);
        lastReductionAt = block.timestamp;
        emit ReductionRecorded(amount_, block.timestamp);
    }

    // ---------------------------------------------------------------- views

    function marketState() public view returns (MarketState memory m_) {
        MarketParams memory p = MORPHO.idToMarketParams(Id.wrap(MARKET_ID));
        m_.vaultSupply = MORPHO.expectedSupplyAssets(p, VAULT);
        (m_.totalSupply,, m_.totalBorrow,) = MORPHO.expectedMarketBalances(p);
        m_.available = m_.totalSupply > m_.totalBorrow ? m_.totalSupply - m_.totalBorrow : 0;
        m_.vaultShareBps = m_.totalSupply == 0 ? 0 : m_.vaultSupply * BPS / m_.totalSupply;
        m_.ownershipTriggered = m_.vaultSupply > params().ownershipExemptAvkat && m_.vaultShareBps > params().ownershipTriggerBps;
        m_.liquidityTriggered = m_.vaultSupply != 0 && m_.available < m_.vaultSupply;
        m_.triggered = m_.ownershipTriggered || m_.liquidityTriggered;
    }

    function managedAvkat() external view override returns (uint256) {
        MarketParams memory p = MORPHO.idToMarketParams(Id.wrap(MARKET_ID));
        return MORPHO.expectedSupplyAssets(p, VAULT);
    }

    function allocationBps() external view override returns (uint256) {
        return params().capBps;
    }

    // ---------------------------------------------------------------- plans

    /// @notice Supply up to the cap, never while a #13 trigger holds, and never past the ownership trigger.
    function planDeploy(uint256 budgetAvkat_, uint256 managedTotal_)
        external view override returns (FuseAction[] memory actions_, uint256 consumedAvkat_)
    {
        MarketState memory m = marketState();
        if (budgetAvkat_ == 0 || m.triggered) return (actions_, 0);
        uint256 target = managedTotal_ * params().capBps / BPS;
        if (m.vaultSupply >= target) return (actions_, 0);
        consumedAvkat_ = target - m.vaultSupply;
        if (consumedAvkat_ > budgetAvkat_) consumedAvkat_ = budgetAvkat_;
        // Stay at or below the ownership trigger after the deposit: (v + x) / (T + x) <= t.
        uint256 t = params().ownershipTriggerBps;
        if (t < BPS) {
            uint256 lhs = m.totalSupply * t;
            uint256 rhs = m.vaultSupply * BPS;
            uint256 maxDeposit = lhs > rhs ? (lhs - rhs) / (BPS - t) : 0;
            uint256 exempt = params().ownershipExemptAvkat;
            if (exempt > m.vaultSupply && exempt - m.vaultSupply > maxDeposit) maxDeposit = exempt - m.vaultSupply;
            if (consumedAvkat_ > maxDeposit) consumedAvkat_ = maxDeposit;
        }
        if (consumedAvkat_ == 0) return (actions_, 0);
        actions_ = new FuseAction[](1);
        actions_[0] = FuseAction(supplyFuse, abi.encodeWithSignature("enter((bytes32,uint256))", MARKET_ID, consumedAvkat_));
    }

    /// @notice Over cap: reduce the excess. #13 trigger: reduce up to decayBps of the lent amount once per interval.
    /// Either way market liquidity stays at or above the floor.
    function planReduce(uint256 managedTotal_)
        external view override returns (FuseAction[] memory actions_, uint256 releasedAvkat_)
    {
        MarketState memory m = marketState();
        if (m.vaultSupply == 0) return (actions_, 0);
        uint256 target = managedTotal_ * params().capBps / BPS;
        if (m.vaultSupply > target) releasedAvkat_ = m.vaultSupply - target;
        if (m.triggered && block.timestamp >= lastReductionAt + params().decayInterval) {
            uint256 decay = m.vaultSupply * params().decayBps / BPS;
            if (!m.liquidityTriggered) {
                uint256 aboveExempt = m.vaultSupply > params().ownershipExemptAvkat ? m.vaultSupply - params().ownershipExemptAvkat : 0;
                if (decay > aboveExempt) decay = aboveExempt;
            }
            if (decay > releasedAvkat_) releasedAvkat_ = decay;
        }
        // Liquidity floor: (T - x) - B >= floor * (T - x)  ->  x <= (T - B - floor*T) / (1 - floor).
        uint256 floorBps = params().liquidityFloorBps;
        uint256 free = m.available * BPS;
        uint256 kept = m.totalSupply * floorBps;
        uint256 maxOut = free > kept ? (free - kept) / (BPS - floorBps) : 0;
        if (releasedAvkat_ > maxOut) releasedAvkat_ = maxOut;
        if (releasedAvkat_ > m.vaultSupply) releasedAvkat_ = m.vaultSupply;
        if (releasedAvkat_ == 0) return (actions_, 0);
        actions_ = new FuseAction[](1);
        actions_[0] = FuseAction(supplyFuse, abi.encodeWithSignature("exit((bytes32,uint256))", MARKET_ID, releasedAvkat_));
    }

    /// @notice User withdrawals may use all available liquidity (no floor, no interval).
    function planWithdraw(uint256 neededAvkat_, bool)
        external view override returns (FuseAction[] memory actions_, uint256 providedAvkat_)
    {
        MarketState memory m = marketState();
        providedAvkat_ = neededAvkat_ < m.vaultSupply ? neededAvkat_ : m.vaultSupply;
        if (providedAvkat_ > m.available) providedAvkat_ = m.available;
        if (providedAvkat_ == 0) return (actions_, 0);
        actions_ = new FuseAction[](1);
        actions_[0] = FuseAction(supplyFuse, abi.encodeWithSignature("exit((bytes32,uint256))", MARKET_ID, providedAvkat_));
    }

}
