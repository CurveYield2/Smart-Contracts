# PPS protection — spec, APPROVED 2026-09-29 (D1–D3 decided); IMPLEMENTED in phase2 (custody v2 `cover`, executor `emergencyRepay`/`lpEmergency` + `_coverLoss`, loop `planCollateralTopUp`, WM v2 `emergencyFeeExempt`) — UNTESTED as of 2026-10-03

Rule (user, 2026-09-29): **the only accepted reduction of vault PPS is the IPOR management fee** (0.5%/yr today).
Applies to cyavKAT and cyavKAT+. This spec closes every other path found in the 2026-09-29 review:
Part A = the four "should fix" items (approved to fix), Part B = review item 5 (emergency de-leverage); items 6, 8, 9 dropped for now. Item 10 (POL instant floor) is not a PPS item; see Appendix.

Live fees used throughout (read on Katana 2026-09-29): instant withdraw 1.25%, request 8.75%.

All decisions are recorded at the end.

---

## Shared building block: PPS backstop (new)

The backstop is the **revenue custody** (CurveYieldProfitCustody `0xe7D1…5ADf`, user decision 2026-09-29): its
**entire** balance is available to cover the cost of emergency de-leverage. The live custody keeps its capital in its
own avKAT/KAT Morpho position and has no pay-on-demand function (only an owner-run, scheduled full unwind), so:
- **Revenue custody v2**: same behaviour as today plus `cover(uint256 lossAvkat) returns (uint256 paid)`, callable only
  by the executor, paying avKAT to the vault in the same transaction (from idle first, then a partial flash-loan
  unwind of its own position). Destination fixed to the vault. Migration: the fee Safe runs the existing
  `scheduleFullUnwind(v2)` / `executeFullUnwind()`; the POL feeder's "rest" output is re-pointed to v2.
- **[D2] decided: no.** If the custody cannot cover an emergency's cost, the emergency does not run. More sources to pull
  from will be added later (user, 2026-09-29).
- Admin fees are never used.

---

## Part A — approved fixes

### A1. Native-exit lane: cost paid by the requests it serves, in the same transaction
Problem: `startNativeExit` / `beginNativeExits` are public, book the 2.5% queue fee immediately (exit reader values
exiting KAT net of it), and charge it back only at completion; request fees stay refundable until release, so a
request can trigger the cost and then be replaced/expire for a full refund. Completions whose loss share exceeds the
fee headroom release nothing and the loss is dropped. The sizing also over-exits the vKAT position source 4.3×.

Changes:
1. **Per-source sizing.** Released avKAT per avKAT exited: from the vKAT position `(1 - fee) / targetLtv`
   (≈ 1.30); from loop headroom `(1 - fee) / targetLtv - 1` (≈ 0.30). The executor sizes each source separately
   (position first). Cost per avKAT released: ≈ 1.9% (position) vs ≈ 8.3% (headroom).
2. **Loss-matched fee earning (WM v2).** New `earnRequestFees(uint256 feeShares) onlyController returns (uint256)`:
   walks active unreleased requests oldest first and marks escrowed, unearned fee shares as earned (non-refundable:
   the existing replace/expiry refund is `total - earned`), then burns them in the same call. New view
   `escrowedFeeHeadroomShares()` = Σ unearned fee shares minus what each request must still earn at release to keep
   `minUnwindProfitBps` of its value.
3. **Sizing cap.** A lane step (start or begin) is sized down so its booked loss ≤ the escrowed fee headroom. If
   nothing fits, it does nothing (no revert for keepers; explicit callers get `LaneNotCovered`).
4. **Same-transaction settlement.** start / begin: snapshot assets-per-share → execute the lane bundle → measure the
   loss → `earnRequestFees(sharesFor(loss) + 1)` → require assets-per-share ≥ snapshot, else revert.
   Result: no PPS drop at start or begin, and nothing left to recover later.
5. **Remove `laneBookedLoss` / `_consumeLaneLoss`.** `completeNativeExits` fulfils with no pre-loss (already paid).
   `completeNativeExitEarly` keeps measuring its own loss (the caller's premium covers the fee above 2.5%) but now
   reverts if that loss exceeds the fee headroom instead of returning silently.
6. Requests cancelled between start and begin: `begin` then finds less headroom and sizes down; prepared lane NFTs
   that are not begun stay vault-owned locks (valued at conversion, no loss) and are merged back into the voting
   position or converted in the next free window by the existing reduce path.

Tests (fork): trigger-then-replace attack leaves PPS ≥ before and the attacker's fee burned; per-source sizing;
start/begin revert-free size-down; completion with cancelled requests; no double-earn at release.

### A2. `deployAssets` caller reward only from the bundle's gain
- Snapshot `_refreshedTotalAssets()` and supply before the deploy bundle; after it, gain
  `G = totalAssets × supplyBefore / supplyAfter - totalBefore` (0 if negative).
- `reward = min(rewardBps × deployed, rewardCapAvkat, G)`; unchanged `MAX_PAY_AVKAT`. No gain → no reward.
- Same rule for any other reward the executor pays outside fulfilments (fulfilments already cap at profit).
Tests: deploy with no gain pays 0; reward never exceeds G; PPS after reward ≥ before.

### A3. Every reduce / rebalance step guarded, one step at a time
- New executor helper `_tryGuarded(address set, FuseAction[] actions)`: runs `executeSelf(_guarded(actions, 0))`
  in try/catch, emits `StepSkipped(set, reason)` on failure (same pattern as POL maintenance).
- `deployAssets`: the reduce plans leave the deploy bundle; after the (guarded) deploy bundle, each set's reduce plan
  runs through `_tryGuarded`. The POL deploy leg also runs as its own `_tryGuarded` step (see B9: entries can be
  blocked by the guard when the pool is off peg, and must not revert the whole deploy).
- `rebalance()`: the LTV re-lever and each reduce plan run through `_tryGuarded`. Nothing in rebalance can lower PPS.
- Loop `reduceLossBps` bound set to (0, 0) in P2_01 (a guarded reduce can never realize a loss anyway).
Tests: over-target set with a lossy reduce is skipped without blocking the deploy; rebalance never lowers PPS.

### A4. `emergencyRepay` repays only what the emergency needs
- Loop unwind fuse, mode 2 (PARTIAL): `amount` is clamped to the KAT that brings LTV down to `emergencyTargetLtvBps`,
  computed in the same call as `(D - t·Cv) / (1 - t·k)` with `k` = oracle value per avKAT / the swap fuse's
  TWAP-floor value per avKAT (the worst price the swap may execute at). Mode 1 is unchanged.
- The cost of the (clamped) emergency is handled by B5.
Tests: oversized `repayKat` is clamped; the result lands at or just below the emergency target.

---

## Part B — "by design" items that are no longer accepted

### B5. Emergency de-leverage (loop; cyavKAT+)
Goal: emergencies should practically never need a swap, and when one does, the backstop pays for it.

1. **Free de-leverage first (loop), inside every `deployAssets` / `rebalance`:** when loop LTV > target + tolerance,
   before any deploy budget: (a) repay debt with idle KAT the vault holds (harvested rewards); (b) supply idle avKAT
   as extra collateral with no new borrow, just enough to return to target. Both are PPS-neutral (no swap). New
   controller plan `planCollateralTopUp()` (not in today's design: the cycle fuse only supplies idle together with a
   borrow and stops when LTV is already above target). **Capped so loop equity never exceeds its allocation cap**
   (the seasoned wind-up limit): amount = min(needed to reach target LTV, idle, cap - loop equity); at the cap it does
   nothing and step 2 applies. The allocation controller counts the extra collateral as loop equity.
2. **Swap-based emergency** (mode 1 / clamped mode 2) only if the LTV is still above the emergency trigger. Its
   measured loss is paid by `backstop.cover(loss)` in the same transaction, so PPS does not drop while the backstop
   has funds.
3. **Settlement, same transaction** (loop `emergencyRepay`, and the LP holder's `lpEmergency`): snapshot assets per share
   → run the emergency bundle → measure the loss → `custody.cover(loss)` → if the custody paid less, the **caller pays the
   difference** in avKAT (`transferFrom`, up to the caller's `maxCallerPayAvkat_` argument) → require assets per share ≥
   snapshot. If custody + caller cannot cover it, the whole transaction reverts and the emergency does not run (D2 = no;
   more sources later). New signatures: `emergencyRepay(uint256 repayKat_, uint256 maxCallerPayAvkat_)`,
   `lpEmergency(uint256 maxCallerPayAvkat_)`.
4. **cyavKAT+ emergency de-lever (D3 decided: exemption for emergency de-leverage only):** its de-lever and unwinds redeem cyavKAT instantly from the main vault and pay the main
   vault's instant fee (1.25% live) — that fee is the loss. Main WM v2 `emergencyFeeExempt[account]` (same permission as
   `setBurnOnlyFee`, fee authority), set for the cyavKAT+ vault, used only through a transient arm: the first action of
   cyavKAT+'s `planDeleverActions` bundle is a small arm fuse that checks cyavKAT+ LTV > `deleverLtvBps` in the same
   call and arms a zero fee for the next instant withdrawal. User-driven unwinds (`planUnwindActions`, fulfilments,
   instant withdrawals) never arm it and pay the normal fee. Safe for the main vault: cyavKAT+ only draws the main
   vault's idle (`mainLiquidAvkat`), never its markets, so there is no unwind loss to cover. cyavKAT+ also tops up its
   own collateral from idle cyavKAT first (already done in its wind-up; add it to `delever()`).

### Dropped (user, 2026-09-29)
- **B6** Sushi avKAT/KAT LP holder valuation — dropped for now.
- **B8** Lending (market 41) bad debt — dropped.
- **B9** POL pool price drift — dropped for now.

---

## Appendix — review item 10 (not a PPS item)
`instantMinSellBps` sizes the POL sale floor from the full instant fee (1.25% live), but the vault keeps only the fee
minus the profit-custody cut (up to 35%). PPS still rises; only the POL spec's "vault keeps ≥ 0.5%" promise is missed
(≈ 0.07% at a 35% cut). D6: left as is (user, 2026-09-29).

## Decisions
- **D1** ~~Backstop~~ — decided: the whole revenue custody (v2 with executor-only `cover`).
- **D2** ~~Emergency without cover~~ — decided: no; more sources later.
- **D3** ~~cyavKAT+ fee exemption~~ — decided: emergency de-leverage only.
- **D4 / D5 / D7** — dropped with B6, B8, B9.
- **D6** ~~POL instant floor~~ — leave as is.

## Result when implemented
PPS can fall only through the management fee, plus the dropped items B6 / B8 / B9 (to revisit), and an emergency the
custody and the caller together cannot cover (it then does not run; more sources later).
