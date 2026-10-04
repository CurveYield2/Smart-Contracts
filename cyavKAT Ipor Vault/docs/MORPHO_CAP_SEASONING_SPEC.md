# Morpho loop cap: 7-day seasoned avKAT (APPROVED 2026-09-27: wind-up only, managedAvkat; IMPLEMENTED)

## Request (2026-09-26)
"Only calculate avKAT that has been deposited for at least 7 days. Fresh deposits won't trigger a wind-up until a
week later, and then only if the total amount of avKAT in the vault remains at a higher amount."

## Today
Loop wind-up cap = `allocationBps × managedAvkat()` (allocation controller: idle avKAT + loop equity + lending + LP +
vKAT). Used by `CurveYieldMorphoLoopController.planDeploy` and `CurveYieldMorphoWindupLib.run`. A deposit raises the
cap immediately.

## Change
**Seasoned avKAT** = the lowest `managedAvkat` seen over the last 7 days, including right now:

    seasoned = min(managedAvkat now, daily lows of the last 7 days)
    wind-up cap = allocationBps × seasoned

- A deposit on day D only raises the cap from day D+7, and only by the amount that stayed in the vault the whole week
  (any dip in between counts).
- Withdrawals lower the cap immediately (the "now" term), exactly as today.
- Only the wind-up (new deploys) uses the seasoned amount. Reduce / delever / withdrawals keep using the current total,
  so nothing is ever forced to unwind because of a deposit.

## Mechanism (allocation controller)
- 8 daily slots (ring buffer): `day → lowest managedAvkat seen that day`.
- `checkpoint()`: permissionless, cheap; writes today's slot = min(slot, current). Days with no checkpoint are
  filled with min(last recorded low, current) — so a gap can never let a deposit count early.
- Called automatically at the start of every executor run, plus once a day by the existing bot (a no-op if already
  recorded).
- Seeded at deployment with the current total, so avKAT already in the vault counts from day one.
- `seasonedManagedAvkat()` view, used by the loop's planDeploy and the wind-up library (replaces `managedAvkat()`
  there only).
- `seasoningDays`: owner-configurable 0..14 (default 7; 0 = today's behaviour). Reversible like every other param.

## Scope questions
1. Loop wind-up only (my reading of "trigger a wind-up"), or also the lending cap (20%, also Morpho)?
2. Measure `managedAvkat` (everything the vault manages, as the cap does today) — or only idle avKAT deposits?
   Recommended: `managedAvkat`, so profits and moves between strategies don't count as "fresh".

## Files
`src/allocation/CurveYieldAllocationController.sol` (slots, checkpoint, view, param), `src/morpho/CurveYieldMorphoLoopController.sol`
(planDeploy), `src/morpho/CurveYieldMorphoWindupLib.sol` (limit), executor run start (checkpoint call),
`curveyield-bots` (daily checkpoint). Deploys with Phase 2 (P2_01); no extra script.

## Implemented (2026-09-27)
- Allocation controller: `seasoningDays` (default 7, 0..14, owner), `checkpoint()`, `seasonedManagedAvkat()`,
  `dailyLow`, `firstCheckpointDay`, `lastCheckpointDay`. Window = the last `seasoningDays` + 1 full days plus today, so a
  deposit counts after at least 7 full days (7–8 days depending on the time of day).
- Loop `planDeploy` and `CurveYieldMorphoWindupLib.run` use `seasonedManagedAvkat()`; reduce / withdraw unchanged.
- Executor: `checkpoint()` at the start of `deployAssets()` and `rebalance()`.
- Bots: maintenance step 0 calls `allocation.checkpoint()` once a day.
- Answers: wind-up only (lending cap unchanged); measured on `managedAvkat` (everything the vault manages).
