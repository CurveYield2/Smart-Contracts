# Generic loop fuses (fuse standardization, hard cases) — APPROVED 2026-09-27

Two generic, IPOR-style fuses that replace the four Morpho loop fuses (wind-up, LTV re-lever, unwind, emergency) with
**identical behaviour**: the same math is moved, unchanged, from `CurveYieldMorphoLoopLib` / `CurveYieldMorphoWindupLib`
into a generic library; only where its inputs come from changes (call data + substrates instead of our controller).

## Pattern they generalise
A Morpho Blue loop where the **collateral is an ERC-4626 whose asset is the loan token** (avKAT over KAT): borrow the
loan token, swap it for more collateral, supply, repeat. Any IPOR vault with such a pair can use them.

## Shared: what the fuses may touch (substrates of the MORPHO market, 14)
| Substrate | Encoding |
|---|---|
| Morpho market id | IPOR's standard Morpho substrate (the market id), as MorphoCollateral/Borrow fuses use |
| collateral fuse, borrow fuse, flash-loan fuse, swap fuse | typed `bytes32(2 << 160 \| fuse)` ("component") — the fuses also must be supported by the vault (executeInternal checks) |
| profit recipients | typed `bytes32(3 << 160 \| recipient)` |
The swap fuse must implement the quoting interface our live swap fuse already has: `quoteExactInput(in, out, amount)
→ (quoted, minimum)` (TWAP-guarded minimum), `quoteExactInputView`, `requiredInput(in, out, amountOut, maxIn)`, and
`enter((in, out, amountIn, minOut))`.

## 1. CurveYieldLoopCycleFuse — wind-up and LTV re-lever (replaces WindupFuse + LtvRebalanceFuse)
`enter(LoopCycleData)`:
```
LoopCycleData {
  bytes32 morphoMarketId; address collateralFuse, borrowFuse, swapFuse;
  uint256 idleBudget;        // collateral token to add as new collateral (0 = pure re-lever)
  bool    leaveProducedIdle; // re-lever while withdrawals wait: keep bought collateral idle
  uint256 minBorrow;         // stop when the next borrow is below this
  uint8   maxCycles;
  uint16  targetLtvBps;
  // required profit per cycle (bps of the conversion value of what is borrowed), ramp as in #14:
  uint256 limit;             // the planner's cap (e.g. allocation x SEASONED managed avKAT)
  uint16  rampZoneBps, baseProfitBps, rampStartProfitBps, rampEndProfitBps;
  SplitLeg[] profitSplit;    // {recipient, bps}: each cycle's gain is split like CurveYieldProfitSplitLib today
}
```
Per cycle, exactly as `CurveYieldMorphoWindupLib.run` today: snapshot → target debt at `targetLtvBps` (with the
supply of this cycle) → stop if the borrow is ≤ debt + minBorrow → quote (live, TWAP-guarded minimum) → required
profit from the ramp at the current equity → stop if the quote cannot clear it → supply + borrow + swap (IPOR
collateral / borrow fuses + the swap fuse, via executeInternal) → measure what was produced → **revert** if the
realised gain is under the requirement (same as today) → split the gain to the recipients (transfer; if a recipient is
the vault's IPOR rewards-claim manager, `updateBalance()` is called, as today) → carry the rest into the next cycle.
Returns the same result struct (cycles, borrowed, produced, profit, split out).

## 2. CurveYieldLoopUnwindFuse — unwind, de-leverage, partial repay (replaces UnwindFuse + EmergencyFuse)
`enter(LoopUnwindData)`:
```
LoopUnwindData {
  bytes32 morphoMarketId; address collateralFuse, borrowFuse, flashLoanFuse, swapFuse;
  uint8   mode;              // 0 UNWIND (free `amount` collateral at targetLtv), 1 DELEVERAGE (to targetLtv),
                             // 2 PARTIAL (repay `amount` loan token, stay under LLTV)
  uint256 amount;
  uint16  targetLtvBps;
  uint16  maxLossBps;        // UNWIND: booked loss (conversion basis, D1) <= amount x this, else revert
  uint16  minLtvBpsToAct;    // DELEVERAGE / PARTIAL: only if LTV is above this (the emergency trigger); 0 = always
}
```
Same code as today: `planUnwind` (secant search, second point at 5x the gap, tolerance amount/1000 + 1, 12 iterations,
revert if it cannot close), `planDeleverage` (fixed-point with the c·a/(1−c·b) start, 0.01% stop, 12 iterations),
`planPartialRepay` (LLTV check), `enforceLoss`, then the flash-loan unwind through IPOR `MorphoFlashLoanFuse` with
the callback [borrow exit, collateral exit, swap] encoded as ONE tuple (the fix already in Phase 2), and the KAT
dust sweep.

## What moves where
| Today | After |
|---|---|
| env + params read from the loop controller inside the fuse | passed in LoopCycleData / LoopUnwindData by the planner (the loop controller), checked against substrates |
| `requiredWindupProfitBps` in the controller | same formula inside the cycle fuse, parameters in the call data |
| splitter read inside the lib | split legs in the call data (the executor reads the splitter when planning) |
| emergency trigger check in the fuse | `minLtvBpsToAct` in the call data (planner passes emergencyLtvBps) |
| loss allowance check vs config in the fuse | planner passes maxLossBps within the controller's bounds (the executor's allowed-loss rule is unchanged) |
| `msg.sender == executor` check | removed (IPOR model: only ALPHA can call execute; our ALPHA holders are the executor / guardian paths) |

## Behaviour changes
None intended. One structural: the fuses no longer check the caller is the executor — any ALPHA-role holder could
run them with its own parameters (bounded only by substrates). Today only the executor holds ALPHA on cyavKAT, so
this is the IPOR norm; noted for the audit.

## Decision needed
Approve this spec (both fuses, identical math, planner-supplied parameters, ALPHA-only as the gate).
