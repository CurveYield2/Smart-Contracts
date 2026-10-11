// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CurveYieldGateConfig, CurveYieldConfigKeys as K, CurveYieldAddrKeys} from "../governance/CurveYieldGateConfig.sol";
import {
    ICyStrategySet, ICyErc20, ICyRewardsClaimManager, FuseAction
} from "../interfaces/CurveYieldPhase2Interfaces.sol";

/// @notice Registered strategy sets, in deploy order. Zero = not built yet (skipped).
struct CySets {
    address loop; // strategic class: avKAT/KAT Morpho loop
    address usdc; // strategic class: USDC strategy (borrow vbUSDC against avKAT, deposit into cyvbUSDC)
    address lend; // reserve class
    address pol; // reserve class: protocol-owned liquidity, position A (POL spec)
}

/// @notice One managed-avKAT total for the whole vault and the idle split (#18, D3).
///
/// Buckets (all shares of `managedAvkat()`):
/// - strategic class: loop + USDC strategy targets; drawn only from reserve-class excess.
/// - reserve class: vault idle + lending + POL; target = managed - strategic targets.
/// - vault floor: `vaultFloorBps` of the reserve-class target always stays idle in the vault.
/// Lending and POL deploy only from idle above the floor, each within its own cap.
contract CurveYieldAllocationController is Ownable2Step, CurveYieldGateConfig {

    uint256 private constant BPS = 10_000;

    address public immutable VAULT;
    address public immutable AVKAT;
    /// @notice Wired in the gate (`CurveYieldAddrKeys.REWARDS_CLAIM_MANAGER`, GATE_CONFIG_SPEC §10).
    function REWARDS_CLAIM_MANAGER() public view returns (address) {
        return _addr(CurveYieldAddrKeys.REWARDS_CLAIM_MANAGER);
    }

    CySets private _sets;
    address public executor;

    // Seasoned managed avKAT (loop wind-up cap): the lowest managedAvkat over the last seasoningDays (+ today), so a
    // deposit counts for new wind-ups only after it has stayed in the vault for at least seasoningDays full days.
    uint256 public constant MAX_SEASONING_DAYS = 14;
    uint32 public firstCheckpointDay; // 0 = no history yet
    uint32 public lastCheckpointDay;
    mapping(uint256 day => uint256 low) public dailyLow;

    error InvalidAddress();

    event SetsUpdated(CySets sets);
    event ExecutorUpdated(address indexed executor);
    event Checkpointed(uint256 indexed day, uint256 managedAvkat, uint256 low);

    struct Budgets {
        uint256 managed;
        uint256 idle;
        uint256 reserveTarget;
        uint256 reserveClass;
        uint256 vaultFloor;
        uint256 strategicBudget; // what loop + USDC strategy may draw from idle
    }

    constructor(address owner_, address vault_, address avkat_, address configGate_)
        Ownable(owner_)
        CurveYieldGateConfig(configGate_)
    {
        if (vault_ == address(0) || avkat_ == address(0)) revert InvalidAddress();
        VAULT = vault_;
        AVKAT = avkat_;
    }

    // ---------------------------------------------------------------- configuration

    function setSets(CySets calldata sets_) external onlyOwner {
        _sets = sets_;
        emit SetsUpdated(sets_);
    }

    function setExecutor(address executor_) external onlyOwner {
        if (executor_ == address(0)) revert InvalidAddress();
        executor = executor_;
        emit ExecutorUpdated(executor_);
    }

    /// @notice Share of the reserve-class target kept idle in the vault (bps), from the governance gate.
    function vaultFloorBps() public view returns (uint256) {
        return _config1(K.ALLOC_VAULT_FLOOR_BPS);
    }

    /// @notice Days a deposit must stay before it counts for loop wind-ups (0 = off), from the governance gate.
    function seasoningDays() public view returns (uint256) {
        return _config1(K.ALLOC_SEASONING_DAYS);
    }

    /// @notice Records today's low of managedAvkat (permissionless; the executor calls it on every run, a bot daily).
    /// Days without a checkpoint are filled with min(last recorded low, now): a gap never lets a deposit count early.
    function checkpoint() public {
        uint256 today = block.timestamp / 1 days;
        uint256 current = managedAvkat();
        uint256 last = lastCheckpointDay;
        if (firstCheckpointDay == 0) {
            firstCheckpointDay = uint32(today); // seed: what the vault holds at start counts from day one
        } else if (today > last) {
            uint256 prev = dailyLow[last];
            uint256 fill = current < prev ? current : prev;
            uint256 from = today - last > MAX_SEASONING_DAYS + 1 ? today - MAX_SEASONING_DAYS - 1 : last + 1;
            for (uint256 d = from; d < today; ++d) dailyLow[d] = fill;
        } else if (current >= dailyLow[today]) {
            return; // today's low already recorded
        }
        dailyLow[today] = current;
        lastCheckpointDay = uint32(today);
        emit Checkpointed(today, current, current);
    }

    /// @notice managedAvkat counted for loop wind-ups: min(now, daily lows of the last seasoningDays + today).
    /// Withdrawals count immediately (the "now" term); deposits only after seasoningDays full days.
    function seasonedManagedAvkat() external view returns (uint256 low_) {
        low_ = managedAvkat();
        uint256 n = seasoningDays();
        uint256 first = firstCheckpointDay;
        if (n == 0 || first == 0) return low_;
        uint256 today = block.timestamp / 1 days;
        uint256 last = lastCheckpointDay;
        uint256 lastLow = dailyLow[last];
        uint256 start = today > n + 1 ? today - n - 1 : 0; // n full days before today, plus the partial first day
        if (start < first) start = first;
        for (uint256 d = start; d <= today; ++d) {
            uint256 v = d <= last ? dailyLow[d] : lastLow; // days since the last checkpoint: its low (conservative)
            if (v < low_) low_ = v;
        }
    }

    function sets() external view returns (CySets memory) {
        return _sets;
    }

    // ---------------------------------------------------------------- views

    /// @notice Every avKAT the vault manages: idle + rewards manager + each set.
    function managedAvkat() public view returns (uint256 total_) {
        CySets memory s = _sets;
        total_ = ICyErc20(AVKAT).balanceOf(VAULT) + ICyRewardsClaimManager(REWARDS_CLAIM_MANAGER()).balanceOf();
        if (s.loop != address(0)) total_ += ICyStrategySet(s.loop).managedAvkat();
        if (s.usdc != address(0)) total_ += ICyStrategySet(s.usdc).managedAvkat();
        if (s.lend != address(0)) total_ += ICyStrategySet(s.lend).managedAvkat();
        if (s.pol != address(0)) total_ += ICyStrategySet(s.pol).managedAvkat();
    }

    function strategicBps() public view returns (uint256 bps_) {
        CySets memory s = _sets;
        if (s.loop != address(0)) bps_ += ICyStrategySet(s.loop).allocationBps();
        if (s.usdc != address(0)) bps_ += ICyStrategySet(s.usdc).allocationBps();
        if (bps_ > BPS) bps_ = BPS;
    }

    function budgets() public view returns (Budgets memory b_) {
        CySets memory s = _sets;
        b_.managed = managedAvkat();
        b_.idle = ICyErc20(AVKAT).balanceOf(VAULT);
        b_.reserveTarget = b_.managed * (BPS - strategicBps()) / BPS;
        b_.reserveClass = b_.idle;
        if (s.lend != address(0)) b_.reserveClass += ICyStrategySet(s.lend).managedAvkat();
        if (s.pol != address(0)) b_.reserveClass += ICyStrategySet(s.pol).managedAvkat();
        b_.vaultFloor = b_.reserveTarget * vaultFloorBps() / BPS;
        if (b_.reserveClass > b_.reserveTarget) {
            uint256 excess = b_.reserveClass - b_.reserveTarget;
            b_.strategicBudget = excess < b_.idle ? excess : b_.idle;
        }
    }

    /// @notice The deploy plan (the executor only executes it): the USDC strategy from the strategic budget left after the
    /// loop, then lending, as one bundle (`main_`); the POL entry separately (`pol_`), since it runs as its own guarded
    /// step. The loop is NOT in a bundle: the executor runs its wind-up cycles one at a time (B1) with `loopBudget_`, the
    /// avKAT the loop will draw. `idle_` = vault idle before, for the caller reward basis.
    function planDeploy()
        external view returns (FuseAction[] memory main_, FuseAction[] memory pol_, uint256 idle_, uint256 loopBudget_)
    {
        CySets memory s = _sets;
        Budgets memory b = budgets();
        idle_ = b.idle;
        uint256 consumed;
        uint256 left = b.strategicBudget;
        if (s.loop != address(0) && left != 0) {
            (, loopBudget_) = ICyStrategySet(s.loop).planDeploy(left, b.managed);
            if (loopBudget_ > left) loopBudget_ = left;
            consumed = loopBudget_;
            left -= loopBudget_;
        }
        (main_, consumed, left) = _append(main_, s.usdc, left, b.managed, consumed);
        left = this.reserveBudget(b.idle, b.vaultFloor, consumed);
        (main_, consumed, left) = _append(main_, s.lend, left, b.managed, consumed);
        (pol_,,) = _append(new FuseAction[](0), s.pol, left, b.managed, consumed);
    }

    /// @notice Each set's reduce plan, in [loop, USDC, lending, POL] order (the executor runs each as its own guarded
    /// step). Empty when the set is not built or has nothing to reduce.
    function planReduces() external view returns (address[4] memory sets_, FuseAction[][4] memory plans_) {
        CySets memory s = _sets;
        sets_ = [s.loop, s.usdc, s.lend, s.pol];
        uint256 managed = managedAvkat();
        for (uint256 i; i < 4; ++i) {
            if (sets_[i] != address(0)) (plans_[i],) = ICyStrategySet(sets_[i]).planReduce(managed);
        }
    }

    /// @notice The scheduled-withdrawal source order: lending, USDC strategy, loop (built sets only).
    function withdrawSources() external view returns (address[] memory planners_) {
        CySets memory s = _sets;
        address[3] memory order = [s.lend, s.usdc, s.loop];
        uint256 n;
        for (uint256 i; i < 3; ++i) if (order[i] != address(0)) ++n;
        planners_ = new address[](n);
        n = 0;
        for (uint256 i; i < 3; ++i) if (order[i] != address(0)) planners_[n++] = order[i];
    }

    function _append(FuseAction[] memory actions_, address set_, uint256 budget_, uint256 managed_, uint256 consumed_)
        private view returns (FuseAction[] memory, uint256, uint256)
    {
        if (set_ == address(0) || budget_ == 0) return (actions_, consumed_, budget_);
        (FuseAction[] memory more, uint256 used) = ICyStrategySet(set_).planDeploy(budget_, managed_);
        if (used > budget_) used = budget_;
        if (more.length == 0) return (actions_, consumed_ + used, budget_ - used);
        FuseAction[] memory out = new FuseAction[](actions_.length + more.length);
        for (uint256 i; i < actions_.length; ++i) out[i] = actions_[i];
        for (uint256 i; i < more.length; ++i) out[actions_.length + i] = more[i];
        return (out, consumed_ + used, budget_ - used);
    }

    /// @notice Idle the reserve-class sets may use after `alreadyConsumed_` avKAT has been planned elsewhere.
    function reserveBudget(uint256 idle_, uint256 vaultFloor_, uint256 alreadyConsumed_) external pure returns (uint256) {
        if (idle_ <= alreadyConsumed_) return 0;
        uint256 left = idle_ - alreadyConsumed_;
        return left > vaultFloor_ ? left - vaultFloor_ : 0;
    }

}
