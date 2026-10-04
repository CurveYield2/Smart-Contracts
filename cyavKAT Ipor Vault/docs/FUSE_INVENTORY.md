# Fuse inventory — exact function-by-function mapping (2026-09-27)

Step 1 of the fuse-standardization refactor (see `FUSE_STANDARDIZATION_SPEC.md`, approved architecture). This is a
read-only inventory: no code was changed to produce it.

Scope read: every file under `phase2/src/{accounting,executor,katana,lend,lp,morpho,plus,pol,vkat}` that implements
`IFuseCommon` / `IMarketBalanceFuse`, plus the live swap fuse `CurveYieldRouterSwapFuse` (0x1fB8…, source in
`merkl/contracts/fuses/CurveYieldRouterSwapFuse.sol`) and its router `router/contracts/CurveYieldSushiV3FeeRouter.sol`.
IPOR counterparts read in full: `IFuseCommon`, `IMarketBalanceFuse`, `IFuseInstantWithdraw`,
`morpho/{MorphoFlashLoanFuse,MorphoCollateralFuse,MorphoBorrowFuse,MorphoSupplyFuse}`,
`uniswap/{UniswapV3NewPositionFuse,UniswapV3ModifyPositionFuse,UniswapV3CollectFuse,UniswapV3Balance}`,
`balancer/{BalancerLiquidityProportionalFuse,BalancerBalanceFuse}`, `erc20/Erc20BalanceFuse`,
`erc4626/Erc4626SupplyFuse`, `universal_token_swapper/UniversalTokenSwapperFuse`,
`burn_request_fee/BurnRequestFeeFuse`, `maintenance/ConfigureInstantWithdrawalFuse`,
`PlasmaVaultBalanceAssetsValidationFuse`, `transient_storage/TransientStorageChainReaderFuse`.

**Honest count**: 9 current contracts/files hold **~34 distinct external "vault action" entry points** (enter / exit /
named actions / `instantWithdraw`), plus 4 balance-fuse `balanceOf()` views, plus the live swap fuse's ~10 functions
(1 vault action + 4 quote/search views + 5 admin). Of the 34 vault actions: **14 map directly onto an existing IPOR
fuse call** (no new code), **11 need a small new generic fuse** (listed once each, reused by several call sites),
and **9 keep genuinely on-chain, non-view decisions that cannot move into a planner as pure math** — those either get
a bespoke generic fuse that repeats the live decision inside the fuse (loop wind-up, unwind search, POL
sell-or-burn, LP holder pattern) or stay as multi-call bundles the planner assembles from smaller generic pieces.
Nothing here is "1 fuse in, 1 fuse out" — most current contracts split into 2–3 standard pieces (a generic fuse for
the mechanical step + the guard for the safety check that used to be inline).

---

## 1. accounting/CurveYieldErc20BalanceFuse.sol (market 7)

| current contract.function | what it does | on-chain decisions at execution time | replacement | behaviour change? |
|---|---|---|---|---|
| `CurveYieldErc20BalanceFuse.balanceOf()` | Sums (1) every market-7 substrate token balance x oracle price (2) Sushi LP holder's avKAT+KAT net of debt (3) exiting-avKAT net of the queue's minimum fee | None — pure view, reads live balances/oracle at call time (a balance fuse is always "as of now", never a plan) | **New generic `PositionReaderBalanceFuse`**: IPOR's `ERC20BalanceFuse` logic (part 1, unchanged) + a list of substrate "position reader" addresses implementing `positionValue(vault) returns (address asset, uint256 amount)`; the LP holder and the vKAT exit-queue view (`exitingKat`/`exitMinFeeBps`) each get a thin reader adapter registered as a substrate | **None if the reader adapters replicate the exact math.** Behaviour risk: today this is one audited contract computing plus/minus and clamping at 0 in one place; splitting into N independent readers means the guard/vault must re-do the "clamp combined result at 0" step, or each reader must clamp itself — decide which. |

## 2. executor/CurveYieldExecutorFuses.sol (market 0 — not a real market; these run through the vault but move avKAT the fuse already holds/vault holds)

| current contract.function | what it does | on-chain decisions | replacement | behaviour change? |
|---|---|---|---|---|
| `CurveYieldExecutorPayFuse.enter(amount)` | Pays the executor its caller reward in avKAT, capped at `MAX_PAY_AVKAT` | None (pure transfer + cap check) | **New generic `Erc20TransferFuse`** (token + allow-listed recipients as substrates, amount from call data); the immutable per-call ceiling becomes a planner-computed amount (planner already knows the configured rate/cap) | None functionally; the hard-coded `MAX_PAY_AVKAT` ceiling moves from the fuse's immutable to the planner's logic — same number, different enforcement point (spec explicitly allows this: protections live in planners, not fuses) |
| `CurveYieldProfitSplitFuse.enter(profitAvkat)` | Splits unwind profit through `CurveYieldProfitSplitLib.distribute` (splitter #16) | None (deterministic split by configured bps) | **Same `Erc20TransferFuse`** cannot express "split into N shares by bps" as a single generic — either (a) planner precomputes the N transfer amounts and issues N `Erc20TransferFuse` calls, or (b) keep `CurveYieldProfitSplitLib.distribute` itself as a tiny generic "distribute by registered splitter" fuse (splitter address is the substrate) | If (a): none (same amounts, more calls in the bundle). If (b): none, just re-packaged as a generic fuse instead of one bespoke to the executor. |

## 3. katana/CurveYieldSignatureFuse.sol (LIVE, market 7 only because IPOR needs a market)

| current contract.function | what it does | on-chain decisions | replacement | behaviour change? |
|---|---|---|---|---|
| `install()` | Swaps `PlasmaVaultBase` to the ERC-1271-wrapping implementation | None | Stays a bespoke fuse (nothing IPOR-generic does this); spec's only change: **drop the `VAULT` immutable**, read vault context from the delegatecall itself (`address(this)`) so the same fuse could be installed on any vault | None — already generic enough per spec; only the immutable-vs-context detail changes |
| `uninstall()` | Reverts `PlasmaVaultBase` back to original | None | same | None |
| `setSigner(signer, enabled)` | Authorizes/revokes a login-signing wallet | None | same, generic once VAULT immutable dropped | None |
| `setPrefix(bytes)` | Sets the required signed-message prefix | None | same | None |
| **Decision**: spec says the live copy stays deployed as-is; the generic rewrite (`Erc1271SignerFuse`) is for future vaults only, not a live migration. | | | | |

## 4. lend/CurveYieldAvkatLendReduceFuse.sol (market → IPOR lending market 41)

| current contract.function | what it does | on-chain decisions | replacement | behaviour change? |
|---|---|---|---|---|
| `enter(amount)` | Withdraws avKAT from IPOR's Morpho-market-41 lending position via **IPOR's own `MorphoSupplyFuse.exit`** (already delegated!), then records the decay-step timestamp on the controller | None — the fuse itself does no math; it wraps one `exit` call plus a controller bookkeeping call | **IPOR `MorphoSupplyFuse.exit((bytes32 marketId, uint256 amount))` directly** from the planner. `recordReduction(amount)` (the interval bookkeeping) has to move: either the controller's `planReduce` records the intended reduction optimistically (risk: fuse call could partially fail today it can't — `MorphoSupplyFuse.exit` doesn't try/catch here) or a tiny wrapper fuse keeps `recordReduction` as its only job, called right after `MorphoSupplyFuse.exit` in the same bundle | **This whole fuse can be deleted** exactly as the spec says. Behaviour change: none in the withdrawal itself (same IPOR call it already makes); the only wrinkle is where `recordReduction` lives — if it's called unconditionally after `exit` in the bundle (not gated on `exit`'s actual output), a `MorphoSupplyFuse.exit` that returns less than requested (e.g. `amountsMax` clamp) would record the *requested* amount instead of the *actual* one, unless the planner reads the actual output via `executeInternal`'s return value / a follow-up read. **Needs owner decision on how bookkeeping precision is preserved.** |

## 5. lp/CurveYieldSushiLpFuses.sol + lp/CurveYieldSushiLpHolder.sol (market 19 — Sushi LP; **LP holder kept**, per 2026-09-27 decision)

The holder is *not* removed, so none of IPOR's Uniswap-V3 fuses apply directly (they assume the vault itself holds the
NFT, tracked in `FuseStorageLib.UniswapV3TokenIds` — a shared, vault-wide token-id list, not a per-controller
position). Every current LP fuse becomes a thin wrapper calling the **same holder contract**, restated as a generic
"holder" fuse pattern (holder address = substrate).

| current contract.function | what it does | on-chain decisions at execution time | replacement | behaviour change? |
|---|---|---|---|---|
| `CurveYieldSushiLpOpenFuse.enter(amount, lower, upper)` | Sends avKAT to the holder, calls `holder.open()`, records a checkpoint | `holder.open` internally computes the Morpho-collateral/LP split ratio from the *current* pool price and Morpho oracle price (`_deploy`) — genuinely a live on-chain computation, not something a planner view can precompute exactly (price can move between the planner's view call and execution) | **New generic `CurveYieldPositionHolderOpenFuse`** (or a shared "HolderFuse" with an action enum): holder address is the substrate; amount/lower/upper come in the call; the actual split math stays inside the holder (kept as-is, unaudited change = none since holder logic doesn't move) | None if the holder's internal math is untouched — the fuse wrapper is pure pass-through already |
| `CurveYieldSushiLpIncreaseFuse.enter(amount)` | Checkpoint, send avKAT, `holder.increase()` | Same live split math as open | Same generic holder-fuse pattern, different action id | None |
| `CurveYieldSushiLpWithdrawFuse.enter(bps, maxLossBps)` | `holder.withdraw(bps)`, then **reverts if realized loss > maxLossBps** (the gate is INSIDE the fuse today) | `holder._unwind` sells LP avKAT for KAT at the live quoted price to repay debt — genuine execution-time price discovery; the loss gate is a live check against that discovered price | Generic holder-fuse for the mechanical `withdraw` call; **the loss gate moves to the guard fuse** (post-condition check on realized avKAT out vs. basis, exactly what `CurveYieldBundleGuardFuse` is for) — this is a clean split, not a hack | **None in outcome**, but it changes *where* the revert happens (guard fuse at bundle end instead of inline) — timing-neutral within one transaction, no owner-visible behaviour change |
| `CurveYieldSushiLpWithdrawFuse.enterWithLoss(bps)` | Same withdraw, no gate (owner/executor only) | Same live price discovery, no gate | Generic holder-fuse `withdraw` call with the guard's maxLossBps parameter set to 100% (BPS) for this bundle | None |
| `CurveYieldSushiLpWithdrawFuse.instantWithdraw(params)` | IPOR instant-withdraw hook; computes `bps` from `params[0]`, pre-checks the 1% gate against an *estimate*, then try/catches the real `holder.withdraw` | Two live decisions: (a) the estimate uses `closeValueAvkat()` (a view, but a *snapshot* of live pool state) (b) the try/catch on the real call, because the real outcome can differ from the estimate | **New generic `CurveYieldPlannedInstantWithdrawFuse`** (per spec): its substrate is a planner address; it asks the planner for `FuseAction[]` sized to the requested amount and runs them via `executeInternal` in a try/catch, never reverting. The LP controller implements `planInstantWithdraw(amount) returns (FuseAction[])` which reproduces today's `bps`/estimate logic as a view | **None in economics** (same 1% gate, same never-revert contract), but the estimate-vs-actual gap is now the planner's problem to size, same as today — genuinely equivalent, not a downgrade, because the underlying try/catch survives |
| `CurveYieldSushiLpRebalanceFuse.enter(lower, upper)` | Collects fees, **re-checks `needsRebalance()` live** (off-optimal + profitable), calls `holder.rebalance` | The live re-check is exactly the kind of "on-chain decision a view planner can't know in advance" the spec calls out — pool price/fee state between the planner's view and execution can flip the profitability call | Generic holder-fuse for the mechanical rebalance; the live re-check either (a) **stays inside the fuse** as a guard clause (this is not a "protection", it's correctness — a bad rebalance should not execute) or (b) becomes part of the end-of-bundle guard fuse checking "no rebalance happened if it wasn't supposed to" — (a) is simpler and closer to current behaviour | If (a): **none**. If (b): the failure mode moves from "silent no-op" to "guard revert", which is a visible behaviour change (a bundle that used to succeed with a no-op now reverts) — **recommend (a), keep the live re-check inside the fuse, call this out as a case where the fuse legitimately keeps a decision** |
| `CurveYieldSushiLpEmergencyFuse.enter()` | Reverts unless `ltv > emergencyLtvBps`; calls `holder.deleverage(target)` | The revert-if-not-emergency check is a live state read (Morpho LTV can change every block); `holder.deleverage` runs an on-chain fixed-point iterative solver (16 iterations) against live Morpho + pool state — cannot be precomputed by any view planner because the sell price depends on the flash-loan-time pool state | Generic holder-fuse `deleverage` call; the "not emergency" revert is exactly a **guard-fuse post/pre-condition** (only allow this bundle if the market is actually in emergency) — moves to guard, or stays as an entry check either way is fine since it's cheap | None economically. The iterative solver inside `holder.deleverage` is untouched (holder is kept) |
| Holder's own functions (`open/increase/withdraw/rebalance/deleverage/onMorphoFlashLoan`) | Called only by the fuses above (`onlyVault`) | All the live pricing/solver logic described above | **Not fuses themselves — untouched**, per the "never edit pure forks / holder kept" decisions; only their callers (the fuses) get standardized wrappers | None |
| `holder.collectFees()` | Permissionless, moves pending fees into the holder's idle balances | None (pure collect) | Not part of any fuse bundle today (anyone can call it directly on the holder) — stays exactly as-is, no fuse involved | None |
| `holder.position()/katShareBps()/currentTick()` | Views used by the controller for planning | N/A (views) | Planner logic already — no fuse involved | None |

## 6. morpho/CurveYieldMorphoLoopFuses.sol + …LoopFuseBase.sol + …WindupLib.sol + …LoopLib.sol (market 14 — Morpho avKAT/KAT loop)

This is the hardest case flagged in the spec's "honest scope" section. Each of the four fuses bundles multiple IPOR
primitives (collateral, borrow, flash-loan, swap) around an on-chain search/loop that genuinely cannot be a pure view.

| current contract.function | what it does | on-chain decisions at execution time | replacement | behaviour change? |
|---|---|---|---|---|
| `CurveYieldMorphoLoopWindupFuse.enter(supplyBudgetAvkat)` | Runs `CurveYieldMorphoWindupLib.run`: up to `maxCycles` iterations of (supply collateral → borrow KAT → swap KAT→avKAT), each cycle re-checking the swap's *live* minimum-out quote and stopping early if a cycle's profit falls below the required bps | **Every cycle is a live decision**: the borrow size depends on the live collateral snapshot + oracle price; whether to do another cycle depends on the live swap quote (`ICySwapFuse.quoteExactInput`, not a view — it can differ from a prior view call); the loop can legitimately end after fewer than `maxCycles` cycles with no revert (#18) | **New generic "cycle while profitable" fuse** (spec's honest-scope item 1): a `CurveYieldLoopCycleFuse` that takes `(collateralFuse, borrowFuse, swapFuse, marketId, maxCycles, minBorrowKat, requiredProfitBpsSource)` as substrates/params and repeats IPOR's `MorphoCollateralFuse.enter` + `MorphoBorrowFuse.enter` + the swap fuse's `enter` internally, exactly like today — this is **not** replaceable by "IPOR fuse + planner" because the number of cycles and the per-cycle amounts are execution-time data, not plannable | **Two options, pick one (owner decision)**: (a) keep exact behaviour — write the generic cycle fuse that reproduces `CurveYieldMorphoWindupLib.run` faithfully (same stopping rule, same profit-split call per cycle); or (b) the spec's alternative — planner precomputes a fixed cycle count + amounts using a view-quote snapshot, and the guard fuse only checks the *aggregate* outcome (PPS floor, min profit) at the end, accepting that per-cycle profit gating is coarser (a single bad cycle deep in the sequence is no longer caught individually, only in aggregate). **(a) preserves behaviour exactly; (b) is simpler code but is a real behaviour change and must be owner-approved if chosen.** |
| `CurveYieldMorphoLoopLtvRebalanceFuse.enter()` | Same cycle engine, `idleBudgetAvkat=0`, optionally leaves bought avKAT idle if withdrawals are pending (`activeUnreleasedShares() != 0`) | Same live per-cycle decisions as windup, plus a live read of `withdrawManager.activeUnreleasedShares()` to decide idle-vs-resupply | Same `CurveYieldLoopCycleFuse` with `leaveProducedIdle` as a call-data flag; the withdraw-manager read can be done by the planner (it's a view) and passed in, or done live inside the fuse (today's behaviour) — passing it in as a flag is fine because the value doesn't change within one block's bundle in a way that matters here | None, this read is safe to hoist into the planner (no execution-time uncertainty between plan and execute in the same tx) |
| `CurveYieldMorphoLoopUnwindFuse.enter(neededAvkat, maxLossBps)` | Snapshot → `planUnwind` (a **secant-method numerical search** using the swap fuse's *live, non-view* `requiredInput` at every iteration, up to 12 iterations) → `enforceLoss` (revert if booked loss > cap) → `performUnwind` (flash-loan bundle: borrow repay via flash, `MorphoBorrowFuse.exit`, `MorphoCollateralFuse.exit`, swap avKAT→KAT to cover the flash) | The secant search is fundamentally execution-time: `_requiredInput` calls the live swap fuse's conservative binary/expanding search against the *current* pool state, which can differ from any view taken earlier. This cannot be replaced by a planner view without losing precision — spec's honest-scope item 4 | **IPOR `MorphoFlashLoanFuse.enter` for the flash-loan wrapper** (exact fit — same enter data struct, our code already comments "ABI-identical to IPOR MorphoFlashLoanFuseEnterData"), **IPOR `MorphoBorrowFuse.exit`** for the repay, **IPOR `MorphoCollateralFuse.exit`** for the withdraw — all three drop straight in. **The search itself (`planUnwind`) needs a new generic `CurveYieldUnwindSearchFuse`** that runs the secant loop against the live swap fuse and assembles the flash-loan callback internally (it cannot be precomputed by a view because the search calls a non-view swap quote at each step) | If `CurveYieldUnwindSearchFuse` reproduces the exact secant loop: **none**. The loss gate (`enforceLoss`) is a clean guard-fuse candidate (post-condition: realized loss ≤ cap) — moving it there is timing-neutral |
| `CurveYieldMorphoLoopEmergencyFuse.enter(repayKat)` | Snapshot; reverts unless `ltv > emergencyLtvBps`; `repayKat==0` → `planDeleverage` (fixed-point iterative solver, same shape as `planUnwind`) else `planPartialRepay` (one quote + an LLTV safety check); `performUnwind` | Both plans call the live swap fuse's `requiredInput` — same execution-time dependency as unwind | Same `CurveYieldUnwindSearchFuse` (parameterized by "search for deleverage target" vs. "search for fixed repay") + IPOR Morpho collateral/borrow/flash fuses; the "not emergency" revert is a guard-fuse pre-condition | None if the search fuse reproduces the math faithfully |
| `sweepKatDust` (library helper called after `performUnwind`) | Swaps any leftover KAT back to avKAT if the live quote says it's worth it | Live quote decision (dust often isn't worth a swap) | Folds into the same `CurveYieldUnwindSearchFuse`/cycle fuse as a trailing step, or a tiny separate "sweep if quoted > 0" step using the swap fuse directly — either way needs the live, non-view quote call | None |

**Summary for market 14**: 4 current fuse entry points → IPOR's `MorphoFlashLoanFuse` + `MorphoCollateralFuse` +
`MorphoBorrowFuse` cover the mechanical Morpho legs exactly (3 IPOR fuses, no new code), but **two new generic fuses
are unavoidable** (`CurveYieldLoopCycleFuse` for wind-up/relever, `CurveYieldUnwindSearchFuse` for unwind/emergency)
because the cycle count and the search convergence are genuinely execution-time, not plannable. The live custom swap
fuse (0x1fB8…) stays as the swap leg either way (see §9) — it is not replaced by IPOR's `UniversalTokenSwapperFuse`
because the loop needs `requiredInput`/`quoteExactInput` (conservative-search quote helpers) that
`UniversalTokenSwapperFuse` does not expose; see §11(c).

## 7. plus/CurveYieldPlusLoopFuses.sol (cyavKAT+ vault, wraps cyavKAT — market TBD, "market 36-adjacent" per spec's Plus mapping)

| current contract.function | what it does | on-chain decisions | replacement | behaviour change? |
|---|---|---|---|---|
| `CurveYieldPlusStepFuse.windupStep(flashAvkat, profitOutCy, withdrawManager)` | Inside a Morpho flash-loan callback: deposit flashed avKAT into cyavKAT, send profit share to 3 receivers, wrap free cyavKAT into the wrapper token, supply as Morpho collateral, borrow the flashed avKAT back | The "free" amount is `balanceOf - reserved`, where `reserved` reads `withdrawManager.getSharesToRelease()+owedSplitShares()` **live**, converted via `convertToAssets` — a live conversion-rate read, but deterministic given current state (no external price discovery) — arguably plannable if the planner reads the same views moments before | **IPOR `Erc4626SupplyFuse.enter`** for "deposit avKAT into cyavKAT" and again for "deposit cyavKAT into the wrapper" (two calls, both drop in exactly); the 3-way profit split → same `Erc20TransferFuse`/splitter-distribute question as §2; **`morpho.supplyCollateral`/`morpho.borrow` → IPOR `MorphoCollateralFuse.enter` + `MorphoBorrowFuse.enter`**. The "free = balance - reserved" sizing is close enough to plannable that it can become planner math (view-only reads, no swap/price discovery) with the guard fuse catching drift | Low risk if the planner's `reserved` snapshot is taken in the same transaction just before the bundle (guaranteed no other tx can land in between within one wind-up call) — **effectively none** |
| `CurveYieldPlusStepFuse.unwindStep(repayAvkat, withdrawWrapped)` | Inside flash callback: repay avKAT debt, withdraw wrapped collateral, redeem it back to cyavKAT, withdraw exactly `repayAvkat` worth of cyavKAT (pays cyavKAT's instant fee) | Same as above — deterministic given current state, no live price search | **IPOR `MorphoBorrowFuse.exit` + `MorphoCollateralFuse.exit` + `Erc4626SupplyFuse.exit`** (redeem wrapper) **+ `Erc4626SupplyFuse.exit`** (withdraw cyavKAT) — 4 IPOR calls, no new code | None |
| `CurveYieldPlusLoopFuse.windup()` | Asks the controller to `planWindup()` (flash size + profit-out), wraps `windupStep` in **IPOR `MorphoFlashLoanFuse.enter`** if a flash is needed, else calls it directly | `planWindup()` is already a controller view — genuinely plannable | Becomes pure planner logic + `MorphoFlashLoanFuse.enter` wrapping the IPOR calls above | None |
| `CurveYieldPlusLoopFuse.unwind(cyOut)` / `delever()` | Same pattern: `planUnwind`/`planDelever` (controller views) → flash-wrapped `unwindStep` | Views, not live searches (unlike the avKAT/KAT loop, cyavKAT+ has no swap leg — it's a wrap/unwrap, so no price discovery is needed) — this is **plannable exactly**, unlike §6 | Planner logic + IPOR Morpho/Erc4626 fuses + `MorphoFlashLoanFuse` | None — this is the one loop where the "honest scope" concern about live quotes does **not** apply, because there is no swap |
| `CurveYieldPlusLoopFuse.instantWithdraw(params)` | IPOR instant-withdraw hook; runs `unwind` through `executeInternal` wrapped in a manual `PlasmaVaultLib.executeStarted()/executeFinished()` toggle so the flash-loan callback is accepted, try/catches failure | The manual execution-flag toggle is a real mechanism gap: IPOR's instant-withdraw path normally runs *without* the execution flag set, but this vault's flash-loan callback handler requires it | **`CurveYieldPlannedInstantWithdrawFuse`** (spec item 2) is designed exactly for this: it is IPOR's instant-withdraw hook wrapper, and it can set/reset the execution flag around the planner-returned actions once, generically, instead of every planner reimplementing the toggle | None — this is precisely the case the new generic instant-withdraw fuse exists to standardize |

**Summary for cyavKAT+**: no genuinely-new "search" fuse needed here (unlike §6) because there is no swap in the
loop — it is IPOR Morpho fuses + IPOR `Erc4626SupplyFuse` + IPOR `MorphoFlashLoanFuse` + the one new
`CurveYieldPlannedInstantWithdrawFuse`, all planner-driven. This is the cleanest section of the whole inventory.

## 8. pol/CurveYieldPolFuse.sol + pol/CurveYieldPolBalanceFuse.sol (market 36 — Balancer v3 / CurveYield DEX Gyro E-CLP pool)

| current contract.function | what it does | on-chain decisions at execution time | replacement | behaviour change? |
|---|---|---|---|---|
| `enter(avkatIn)` | Buys cyavKAT in the pool at ≤ deposit-rate x (1+premium), adds liquidity proportionally at post-swap balances, burns leftover cyavKAT | The proportional-add sizing (`bptByCy`/`bptByAv`, "a hair under the limiting side") is computed from the **post-swap** pool balances — genuinely execution-time (depends on the swap's actual output, not a pre-swap view) | Swap leg → could use IPOR's balancer swap primitive if one exists for single-token swap (checked: IPOR's Balancer fuse set has `BalancerSingleTokenFuse` for single-sided add, not a raw swap — the pool swap itself uses `IBalV3Router.swapSingleTokenExactIn`, which is **not wrapped by any IPOR fuse** in this repo); liquidity add → **IPOR `BalancerLiquidityProportionalFuse.enter`** fits exactly (same Router API, `addLiquidityProportional`) once the swap's output is known. Needs: a small **generic Balancer-router swap fuse** (single `swapSingleTokenExactIn` call, pool/router as substrates) since IPOR doesn't ship one, then `BalancerLiquidityProportionalFuse.enter` for the add, then the burn (see below) | The two-step "buy then add at post-swap ratio, a hair under the limiting side" sizing has to be redone as **two separate fuse calls with the planner computing bptOut from a pre-swap estimate and the actual swap fuse enforcing its own minOut** — functionally equivalent but the "9,990/10,000 hair-under" fudge factor either moves into the planner's `bptOut` argument (same number) or into the new swap fuse. **No economic change if the planner reproduces the same formula**, but this is 3 fuse calls instead of 1 bespoke one, so gas and the guard's job both grow. |
| `exit(bpt, minSellBps)` | Proportional remove; the cyavKAT leg is sold **only if** a `try` swap clears `legNet * minSellBps/BPS`, else it's burned (never reverts on a failed sell) | The try/catch on the sell is a genuine execution-time branch — a view cannot know whether the swap will succeed/clear the floor | **IPOR `BalancerLiquidityProportionalFuse.exit`** for the proportional remove (drops in exactly); the "sell-or-burn" branch is exactly the spec's flagged hard case (#2 in honest scope) — needs a **new generic "try swap, else fallback action" fuse** (`CurveYieldTrySwapElseFuse`: try the swap fuse with a min-out; on revert, run a fallback FuseAction, here the burn) | If the try/catch semantics are reproduced exactly: **none**. This is explicitly called out in the spec as a known hard case requiring a bespoke generic fuse — count it honestly as **new code**, not "planner logic" |
| `payYieldFee(amount)` | Transfers the admin yield fee (computed by the executor) to the fee receiver, capped at idle avKAT | None (pure capped transfer) | **`Erc20TransferFuse`** (same one from §2) | None |
| `buyback(bpt, idleAvkat)` | Only while triggered: exit BPT, buy cyavKAT with all avKAT at ≤ rate x(1-minGain), burn everything, pay yield fee on the real profit | The buy price check and "real profit = bought value − avKAT spent" are both live, post-swap computations | `BalancerLiquidityProportionalFuse.exit` (remove) + the new Balancer swap fuse (buy) + `BurnHeldSharesFuse` (below) + `Erc20TransferFuse` (fee); the "only while triggered" check and the profit bookkeeping (`CONTROLLER.recordBuyback`) are guard/planner-side | If the guard enforces `NotTriggered` as a pre-condition instead of the fuse doing it inline: timing-neutral, **none** |
| `burnHeld()` | Burns 100% of the vault's own cyavKAT (via `PlasmaVaultBase.updateInternal`, the IPOR burn path) | None (deterministic burn of whatever balance exists) | **New generic `BurnHeldSharesFuse`** (spec item 4) — exactly this pattern, generalized: burn the caller-vault's own shares via the same `updateInternal` path IPOR's `BurnRequestFeeFuse` already uses (confirmed: `BurnRequestFeeFuse.enter` in IPOR routes through the identical `PlasmaVaultStorageLib.getPlasmaVaultBase().functionDelegateCall(IPlasmaVaultBase.updateInternal...)` call — same mechanism, different fee source). **This one is nearly a copy of an existing IPOR pattern**, just generalized past "only WithdrawManager fees" | None |
| `instantWithdraw(params)` | IPOR hook; computes `minSellBps` from the withdraw fee's headroom, tries `exit(bptFor(needed), minSell)`, never reverts | `minSellBpsForFee()` is a view (no execution-time uncertainty by itself), but the wrapped `exit` call embeds the sell-or-burn branch above | `CurveYieldPlannedInstantWithdrawFuse` (generic instant-withdraw wrapper) calling the planner's `planInstantWithdraw`, which in turn issues the `exit` bundle (still needs `CurveYieldTrySwapElseFuse` inside it) | None |
| `minSellBpsForFee()` | Public view helper (fee headroom math) | None — pure view | Pure **planner logic**, no fuse needed at all | None |
| `CurveYieldPolBalanceFuse.balanceOf()` | Values the vault's BPT share of RAW pool balances: avKAT at face, cyavKAT (the vault's own shares) at the NET rate, capped so a WITH_RATE token isn't double-counted | None — pure view | **New generic `RateAwareBalancerBalanceFuse`** (spec item 7): same RAW-balance-share math as IPOR's `BalancerBalanceFuse`, but priced through the vault's own oracle middleware feed for its own share token instead of IPOR's WITH_RATE convention — this is the one balance fuse that **cannot** just be IPOR's `BalancerBalanceFuse` because that fuse would price a WITH_RATE-registered BPT token twice (see §11) | None if the math matches |

## 9. vkat/CurveYieldVkatFuses.sol (Aragon-style voting-escrow avKAT/KAT lock — new market, e.g. 41-adjacent or its own)

None of IPOR's fuse set touches an Aragon/veToken escrow (confirmed: no `ve*`, `escrow`, `gauge_voter` fuse exists
anywhere in `ipor-fusion/contracts/fuses/`, including the `curve_gauge/` and `balancer/BalancerGaugeFuse.sol` ones,
which are Curve/Balancer-specific gauges, not a generic voting-escrow NFT pattern). Every function here needs new
generic code — this is the section the spec's "VeLockFuse / VeVoteFuse / VeExitFuse / VeConvertFuse" line covers.

| current contract.function | what it does | on-chain decisions | replacement | behaviour change? |
|---|---|---|---|---|
| `CurveYieldVkatLockFuse.enter(avkatShares)` | Redeems avKAT shares to KAT, locks/merges into the vault's single vKAT position | `previewRedeem` is a view, but "merge into existing position vs. create new" branches on the controller's live `positionTokenId()` — a plannable view, not execution-time price discovery | **New generic `VeLockFuse`**: escrow + NFT contract as substrates, amount in call data; merge-vs-create branch reproduced inside the fuse (deterministic given `positionTokenId`, a view the fuse can also read live — no ambiguity vs. a planner snapshot since nothing else can change it mid-tx) | None |
| `CurveYieldVkatConvertFuse.enter(avkatShares)` / `.instantWithdraw(params)` | Converts part/all of the position back to avKAT (split the NFT if partial); instant-withdraw hook, never reverts on the direct `enter` path but **does** propagate reverts on `instantWithdraw` today (no try/catch in this fuse!) | `conversionAvailable()` (first-half-of-epoch gate) and the split-vs-whole branch (`requestedKat + minimum >= locked`) are both live but deterministic reads | **New generic `VeConvertFuse`** | **Flag**: today's `instantWithdraw` does **not** wrap in try/catch (unlike the LP and Plus instant-withdraw hooks) — if this graduates to `CurveYieldPlannedInstantWithdrawFuse`'s try/catch wrapper, a call that used to revert the whole withdrawal now silently provides nothing instead. **This is a real behaviour change that needs explicit owner sign-off** — decide whether vKAT instant-withdraw should keep reverting (matches today) or start being "best effort" (matches the other two lanes and IPOR's general instant-withdraw contract, which the interface doc says "never reverts" is the norm for these hooks) |
| `CurveYieldVkatVoteFuse.enter()` | Refreshes gauge votes to controller targets; reverts if a target gauge isn't granted in market 54 or isn't active | The granted/active checks are live reads against a separate market's substrate registry and the external gauge voter's own state (a gauge could be deactivated between planning and execution) | **New generic `VeVoteFuse`**: gauge voter + delegation adapter as substrates, targets/weights from call data (planner already computes the vote split); the granted/active checks are exactly a guard-fuse-style pre-condition, but must be evaluated fresh at execution (gauge activity is external state) — keep them inside the fuse | None |
| `CurveYieldVkatExitPrepareFuse.enter(avkatWanted)` | Step 1 of the native-exit lane: computes how much loop collateral can be withdrawn without breaching the lane's LTV cap, withdraws it, locks it into a new vKAT NFT | `mustRemain`/`withdraw` sizing reads the **live** Morpho loop snapshot (`CurveYieldMorphoLoopLib.snapshot`) — same live-collateral dependency as §6, but here it's a bounded, non-search computation (one division, not an iterative solver), so it **is** safely plannable as long as the planner's view snapshot and the execution snapshot don't diverge across the same block — acceptable within one tx | **New generic `VeExitFuse`** (prepare action) + **IPOR `MorphoCollateralFuse.exit`** for the loop-collateral withdrawal (drops in) | None if planner and fuse agree on the same LTV-cap formula |
| `CurveYieldVkatExitBeginFuse.enter(tokenId)` / `.enterFromPosition(avkatAmount)` | Step 2: begins the 60-day withdrawal on a prepared NFT, or splits the voting position and begins immediately | Split-vs-whole branch, same shape as Convert | **New generic `VeExitFuse`** (begin action) | None |
| `CurveYieldVkatExitCompleteFuse.enter(tokenId)` / `.enterEarly(tokenId)` | Step 3: withdraws KAT from the escrow (fee applies unless "at minimum fee" or an early-exit premium was pre-funded), repays loop debt, pulls loop collateral back to target LTV | The debt-repay and collateral-pulldown amounts are live Morpho-loop reads (again bounded division, not a search) | **New generic `VeExitFuse`** (complete action) + **IPOR `MorphoBorrowFuse.exit`** (repay) + **IPOR `MorphoCollateralFuse.exit`** (pulldown) — both drop in exactly | None |

**Summary for vKAT**: 4 new generic fuses as the spec names them (`VeLockFuse`, `VeVoteFuse`, `VeExitFuse` covering
all 3 exit steps, `VeConvertFuse`), plus 2 IPOR Morpho calls reused inside the exit-prepare/complete steps. One real
behaviour question flagged (`VkatConvertFuse.instantWithdraw`'s missing try/catch today).

## 10. Sushi LP holder pattern — recap (not a separate fuse, see §5)

Already covered in §5; repeated here only to state explicitly: **the LP holder's own contract is unaudited-touch =
zero**, per the "never edit pure Balancer forks" / "holder kept" memory notes and the 2026-09-27 decision. Only the
wrapper fuses standardize.

## 11. Swaps — live `CurveYieldRouterSwapFuse` (0x1fB8…) + `CurveYieldSwapLib` (POL) + `CurveYieldSushiV3FeeRouter`

| current contract.function | what it does | on-chain decisions | replacement | behaviour change? |
|---|---|---|---|---|
| `CurveYieldRouterSwapFuse.enter(data)` | Exact-input swap avKAT↔KAT through the fixed Katana fee router; quote (min-out) computed live via `quoteExactInput`, then the router itself re-checks a TWAP floor | The live quote + TWAP floor computation is the whole point of this fuse — cannot be a view-only planner step because the router's `twapMinimumOut` and the QuoterV2 tick-walk are both live/gas-heavy calls whose result must be used in the same transaction | **Stays a bespoke fuse.** IPOR's `UniversalTokenSwapperFuse` targets/data are pure pass-through to a `SwapExecutor` with only a USD-oracle slippage check (`DEFAULT_SLIPPAGE_WAD` or a substrate override) — **it has no TWAP guard and no `requiredInput`/exact-output search**, so it cannot host the loop's "solve for input that produces exactly this output" calls (`requiredInput`/`requiredInputView`, used by the unwind search in §6). Two sub-options: (a) keep `CurveYieldRouterSwapFuse` exactly as-is (it is already close to the generic pattern per spec: "already almost generic"), just confirm its `enter` ABI is what the new generic loop/unwind fuses call; or (b) wrap it as the "allowed target" inside `UniversalTokenSwapperFuse` for the simple `enter` case and keep a **separate** small `TwapGuardedUniV3SwapFuse` (spec item 8) only for the `requiredInput`/search callers | None — the live fuse is unchanged either way; this is a wiring decision, not a rewrite |
| `.quoteExactInput` / `.requiredInput` (state-mutating "view-like" quote helpers) | Used **live**, mid-transaction, by the loop/unwind fuses (§6) to size borrow/repay amounts | Genuinely execution-time (gas-metered tick walk through QuoterV2) | Stays part of the swap fuse's public surface; the new `CurveYieldLoopCycleFuse`/`CurveYieldUnwindSearchFuse` call these directly (unchanged interface, confirmed ABI-identical to `ICySwapFuse`) | None |
| `.quoteExactInputView` / `.requiredInputView` | Read-only equivalents for off-chain / view-context callers (e.g. `sweepKatDust`'s check) | None (pure view) | Planner logic where used for pure sizing decisions that don't need a live guarantee | None |
| `.setRouteProtection` / `.setRewardToken` / `.setRewardFuse` | Manager-only (`AccessManager` role 300) admin config | N/A — governance, not a vault action | **Out of scope** — this is DAO-controlled router configuration, not part of "every fuse function a vault action" per the spec's non-fuse carve-outs (governance) | N/A |
| `.getRewardTokens` | View | N/A | N/A | N/A |
| `.swapAllRewards` | Sweeps whitelisted Merkl reward tokens to avKAT during a harvest, forwards caller reward, vests the rest | Live per-token quote + skip logic (`RewardTokenSkipped` reasons 1/2/3) | Not part of this refactor's four markets (7/14/19/36/41) — it's the Merkl harvest path, a separate concern; **note but do not fold into this inventory's generic-fuse count** | N/A |
| `CurveYieldSwapLib.balancerSwap`/`permit2Approve` | Used inside `CurveYieldPolFuse` (§8) for the Balancer leg | Part of POL, already covered | See §8 | — |
| `CurveYieldSwapLib.twapOut`/`twapOutRoute`/`bestRoute`/`swapBest` | **Not called from any fuse** — only from `CurveYieldPolCustody.sol` (the buyback custody controller) and `CurveYieldPolPriceLib.sol` (price computation) | N/A | **Out of scope**: `CurveYieldPolCustody` is a controller/custody contract, not a fuse (`IFuseCommon`/`IMarketBalanceFuse` not implemented) — it is explicitly one of the "non-fuse" contracts the spec excludes ("controllers-as-planners... custody") | N/A |

---

## (a) Final list of NEW generic fuses needed, with one-paragraph specs

1. **`CurveYieldBundleGuardFuse`** (already in spec). Market: none/administrative, runs at the start and end of every
   bundle. Substrates: none, or the set of markets/tokens it is allowed to read balances for. `enter()` (snapshot):
   stores `totalAssets`, `totalSupply`, and any chosen token/position balances the planner names, in transient
   storage. `exit(maxPpsDropBps, maxLtvBps[], minIdle, minProfitAvkat)` (post-check): asserts PPS ≥
   start x (1 − maxPpsDropBps) (0 by default; LP/POL exceptions only where already approved), optional per-Morpho-
   market max LTV, min idle avKAT, and min profit vs. a value the planner passed in at snapshot time. Checks:
   pure arithmetic against transient-stored snapshot + live reads; no external calls beyond `totalAssets`/balance
   getters and (optionally) Morpho position reads.

2. **`CurveYieldPlannedInstantWithdrawFuse`** (already in spec). Market: whichever market the planner's strategy
   belongs to (loop/POL/plus). Substrate: the planner's address (one per registered instant-withdraw lane).
   `instantWithdraw(params)`: `params[0]` = amount needed, `params[1]` = planner address (as bytes32); asks the
   planner's `planInstantWithdraw(amount) returns (FuseAction[])` view, then runs the actions via
   `executeInternal` wrapped in try/catch (and toggles `PlasmaVaultLib.executeStarted/Finished` around it if not
   already set, for flash-loan callback acceptance — needed by the Plus loop). Never reverts, exactly like every
   current instant-withdraw hook except vKAT-Convert's (flagged in §9).

3. **`VeLockFuse` / `VeVoteFuse` / `VeExitFuse` / `VeConvertFuse`** (already in spec, one paragraph each).
   - `VeLockFuse`: market = the veToken market. Substrates: escrow, NFT contract, wrapped-token (avKAT-equivalent).
     `enter(amount)`: redeem wrapped token to underlying, lock or merge into the vault's tracked position (position
     id read live, exactly as today).
   - `VeVoteFuse`: substrates = gauge voter, delegation adapter, allowed gauges (as asset substrates in a
     gauge-voting market, e.g. today's market 54). `enter(gauges[], weights[])`: delegate-if-needed, verify each
     gauge is granted + active, cast votes. Reverts if any target isn't granted/active — this is correctness, not
     a removable protection.
   - `VeExitFuse`: substrates = escrow, NFT contract, a linked "collateral market" env (loop's Morpho market) for
     the prepare/complete steps that touch loop collateral. Three actions in one fuse (`prepare(avkatWanted)`,
     `begin(tokenId)`/`beginFromPosition(amount)`, `complete(tokenId)`/`completeEarly(tokenId)`), matching the
     current three-step lane; could be three fuses instead if the owner prefers one-action-per-fuse strictly (see
     "decisions needed").
   - `VeConvertFuse`: substrates = escrow, NFT, wrapped token. `enter(amount)` / `instantWithdraw(params)`, same
     split-vs-whole logic as today; **decide the try/catch question in §9 before writing this one**.

4. **`BurnHeldSharesFuse`** (already in spec). Market: administrative (any market the vault registers it under,
   since it touches no external substrate). No substrates needed (it only ever burns the calling vault's own
   shares). `enter()`: burn 100% of `IERC20(address(this)).balanceOf(address(this))` via the same
   `PlasmaVaultBase.updateInternal` delegatecall IPOR's own `BurnRequestFeeFuse` already uses (confirmed identical
   mechanism) — this fuse is really "`BurnRequestFeeFuse` generalized past the withdraw-manager fee source", so it
   could even be proposed upstream to IPOR as an amount-agnostic variant.

5. **`Erc20TransferFuse`** (already in spec). Market: administrative. Substrates: token address(es) + allow-listed
   recipient address(es) (both as asset substrates). `enter(token, recipient, amount)`: capped `min(amount,
   balance)` transfer to a granted recipient only. Covers `CurveYieldExecutorPayFuse`, `payYieldFee`, and (if the
   split-by-bps approach in §2(a) is chosen) the profit-split legs.

6. **`PositionReaderBalanceFuse`** (already in spec). Market 7 (ERC20_VAULT_BALANCE) replacement. Substrates: plain
   ERC20 tokens (IPOR's existing logic, unchanged) + "position reader" addresses implementing a standard
   `positionValue(vault) returns (address asset, uint256 amount)`. `balanceOf()`: sums token balances (skip
   underlying) + calls every registered reader and converts its `(asset, amount)` to USD via the oracle. The LP
   holder and the vKAT-exit-queue view each need a tiny reader adapter written to this interface (not the holder
   itself — a 10-line wrapper).

7. **`RateAwareBalancerBalanceFuse`** (already in spec). Market 36 (POL). Substrates: the Gyro E-CLP pool.
   `balanceOf()`: RAW pool-balance share (not WITH_RATE-scaled, to avoid double counting IPOR's own rate logic)
   priced token-by-token through the vault's oracle middleware, with the vault's own share token (cyavKAT held in
   the pool) priced at the NET rate via the registered NetPps feed, never above it. This is IPOR's
   `BalancerBalanceFuse` with one substitution (RAW balances, not `lastBalancesLiveScaled18`, and a feed lookup for
   the self-referential BPT leg) — see §11(c) for why plain `BalancerBalanceFuse` cannot be reused unmodified.

8. **`TwapGuardedUniV3SwapFuse`** — only needed if option (b) in §11 is chosen (host the loop's `requiredInput`
   search inside `UniversalTokenSwapperFuse`'s target list instead of keeping the whole bespoke fuse). Market 7 (or
   wherever swaps are registered). Substrates: pools/routes, TWAP window + max deviation per route (mirrors
   `CurveYieldSushiV3FeeRouter`'s own per-route TWAP guard, but exposed as a fuse so any vault could reuse the
   TWAP-floor idea without the Katana-specific router). **Recommend NOT writing this one** — keeping the live
   `CurveYieldRouterSwapFuse` as-is (option (a) in §11) is strictly less new code and the fuse is "already almost
   generic" per the spec.

9. **`Erc1271SignerFuse`** (already in spec) — the generic version of the live `CurveYieldSignatureFuse`, only for
   future vaults; the live signature fuse itself is explicitly kept unchanged.

10. **`CurveYieldLoopCycleFuse`** (new, not named in the spec's numbered list but required by §6 and flagged in the
    spec's "honest scope" as the wind-up hard case). Market 14. Substrates: Morpho market id, collateral/borrow/swap
    fuse addresses, splitter. `enter(idleBudgetAvkat, leaveProducedIdle, minBorrowKat, maxCycles,
    requiredProfitBpsSource)`: reproduces `CurveYieldMorphoWindupLib.run` exactly — repeats
    (collateral-supply → borrow → swap → profit-split) up to `maxCycles` times, stopping early (not reverting) when
    a cycle's profit clears the required bps. This is the fuse that makes "one action per fuse" not quite literally
    true — it is one fuse wrapping an internal loop of several IPOR sub-calls, because the loop's length is
    execution-time data.

11. **`CurveYieldUnwindSearchFuse`** (new, required by §6's unwind/emergency paths). Market 14. Substrates: same as
    above plus flash-loan fuse. `enter(neededAvkat OR targetLtvBps OR fixedRepayKat, maxLossBps)`: reproduces the
    secant/fixed-point search (`planUnwind`/`planDeleverage`/`planPartialRepay`) against the live swap fuse, then
    executes the flash-loan bundle (`MorphoFlashLoanFuse.enter` wrapping `MorphoBorrowFuse.exit` +
    `MorphoCollateralFuse.exit` + the swap). Same "loop that can't be a view" justification as #10.

12. **`CurveYieldTrySwapElseFuse`** (new, required by §8's POL sell-or-burn). Market 36. Substrates: swap fuse
    address, fallback fuse address. `enter(swapCalldata, minOutBps, fallbackCalldata)`: tries the swap fuse's
    `enter` via a low-level try/catch; on success or on hitting `minOutBps`, done; on failure or shortfall below the
    floor, runs the fallback action (here, `BurnHeldSharesFuse`) instead. Generic enough to reuse for POL's
    `buyback` (buy-cyavKAT-or-nothing) too.

13. **A tiny "position reader" adapter contract per source** (not a fuse; a 10–20 line helper implementing
    `positionValue(vault)` for the LP holder and the vKAT exit-queue view) — needed by #6 (`PositionReaderBalanceFuse`)
    but not itself a fuse, so not counted in the fuse total.

That is **12 new fuse contracts** (#8 optional/likely skipped, #13 not a fuse) if TwapGuardedUniV3SwapFuse is
skipped as recommended — matching the spec's "~13–15 small generic fuses" estimate on the low end, because several
of the spec's honest-scope hard cases (loop cycle, unwind search, POL try/else) turned out to need their own
generic fuse rather than folding into an existing one.

## (b) Behaviour changes the owner must approve

1. **Loop wind-up/relever precision** (§6, `CurveYieldMorphoLoopWindupFuse`): choose (a) exact-behaviour
   `CurveYieldLoopCycleFuse` reproducing the per-cycle live loop, or (b) planner-precomputed fixed cycles + guard-only
   aggregate check (coarser, cheaper, genuinely different risk profile — a single bad cycle mid-sequence is no
   longer caught).
2. **vKAT `CurveYieldVkatConvertFuse.instantWithdraw` try/catch** (§9): today it reverts on failure (no try/catch);
   folding it into `CurveYieldPlannedInstantWithdrawFuse`'s standard never-revert wrapper silently changes it to
   best-effort. Decide whether to special-case it (keep reverting) or accept the behaviour change.
3. **`CurveYieldSushiLpRebalanceFuse`'s live re-check** (§5): recommend keeping the live `needsRebalance()` check
   inside the new holder-fuse (not moved to the guard), because moving it to the guard turns a silent no-op into a
   bundle-wide revert. Confirm this reading is what's wanted.
4. **`recordReduction` precision on lending-market decay** (§4): confirm whether the bookkeeping should reflect the
   requested amount (current, simpler) or the actual `MorphoSupplyFuse.exit` output (more correct, needs the
   planner/bundle to read the return value).
5. **Profit-split as N transfers vs. a dedicated distribute-fuse** (§2, §6 cycle profit split): both are
   behaviourally identical, but pick one implementation before the loop-cycle fuse is written, since the cycle fuse
   calls the split logic once per cycle.
6. **POL `enter`'s "hair under the limiting side" (9,990/10,000) constant** (§8): confirm it stays a
   planner-supplied `bptOut` argument with the same 0.1% haircut, not a fuse-side hardcode, so it remains
   owner-tunable the same way other bounded parameters are (per the "bounded parameters" rule already approved).
7. **Publishing target** (already flagged in the spec's decisions, repeated here because it affects how these 12
   new fuses are licensed/reviewed): PR to IPOR Fusion AND the curveyield2 "IPOR Fusion" folder — confirm per-fuse
   which of the 12 go to IPOR upstream (candidates: `BurnHeldSharesFuse` as a generalized `BurnRequestFeeFuse`,
   `Erc20TransferFuse`, `PositionReaderBalanceFuse`) vs. which stay CurveYield-only (candidates: the veToken set,
   `CurveYieldLoopCycleFuse`/`CurveYieldUnwindSearchFuse`, `RateAwareBalancerBalanceFuse` — all fairly
   CurveYield-shaped).

## (c) IPOR fuses that looked usable but do NOT fit

- **`BalancerBalanceFuse`** (for market 36 / POL): uses `lastBalancesLiveScaled18` (WITH_RATE-scaled balances) and
  would price the pool's own BPT-as-a-token leg through IPOR's standard rate convention — but the POL pool holds the
  **vault's own shares** (cyavKAT) as one leg, and IPOR's WITH_RATE handling plus the vault's own NetPps oracle feed
  for that same token would double-apply the conversion rate. Confirmed by reading `CurveYieldPolBalanceFuse`'s
  docstring, which explicitly exists "to avoid double counting IPOR's own rate logic". Needs
  `RateAwareBalancerBalanceFuse` instead (uses RAW balances + oracle middleware pricing for both legs).
- **`UniswapV3NewPositionFuse` / `ModifyPositionFuse` / `CollectFuse` / `Balance`** (for market 19 / Sushi LP): all
  four assume the **vault itself** holds the NFT, tracked in a single shared `FuseStorageLib.UniswapV3TokenIds` list
  across the whole vault. The 2026-09-27 decision keeps the Sushi LP **holder contract** (a separate address holding
  the NFT plus its own Morpho collateral/debt), so none of these four apply without either (a) removing the holder
  (rejected) or (b) writing wrapper "holder-fuse" contracts that call the *holder's* methods, which are not IPOR
  fuses at all, just new generic wrappers around an unaudited-touch holder.
- **`MorphoBorrowFuse.enter`** (plain, for the loop's per-cycle borrow): fits the *mechanical* borrow call exactly,
  but only as one leg of a bundle the loop cycle fuse must still orchestrate (borrow amount depends on a live swap
  quote decided in the same step) — it is *used*, not a full replacement for `CurveYieldMorphoLoopWindupFuse`.
- **`UniversalTokenSwapperFuse`** (for the loop/unwind swap leg, §11): its slippage protection is a flat USD-oracle
  bound (`DEFAULT_SLIPPAGE_WAD` or a per-substrate override), and it has **no `requiredInput`/exact-output search
  capability** and **no TWAP floor**. The unwind search (§6) specifically needs "solve for input X that produces at
  least output Y" (`requiredInput`), which `UniversalTokenSwapperFuse` cannot do — it only does exact-input swaps
  with a slippage floor on the *output* side, not an input-solving search. Confirmed by reading its `enter()`: it
  takes `amountIn`/`minAmountOut` and calls an external `SwapExecutor`, no search loop anywhere in the fuse.
- **`ConfigureInstantWithdrawalFuse`** (maintenance): looked like it might cover "register a planner as the
  instant-withdraw fuse for a market", but it's a maintenance/config fuse for **IPOR's own** instant-withdraw fuse
  list (`PlasmaVaultLib.configureInstantWithdrawalFuses`), i.e. it already exists to wire up whichever instant fuse
  (including our new `CurveYieldPlannedInstantWithdrawFuse`) is registered — it's a tool to use *alongside* the new
  fuse, not a replacement for it. No conflict, just noting it's orthogonal.
- **`PlasmaVaultBalanceAssetsValidationFuse`**: looked like a ready-made guard (min/max balance bounds per asset)
  but it only checks **static balance ranges**, not PPS-drop / LTV / min-profit relative to a snapshot taken earlier
  in the same bundle — it has no transient-storage snapshot step. It could be composed *alongside*
  `CurveYieldBundleGuardFuse` for simple absolute floors (e.g. "always keep ≥ X idle avKAT") but cannot replace the
  PPS-drop guard itself.
- **`BurnRequestFeeFuse`** (for POL's `burnHeld`): the *mechanism* is identical (confirmed, see §8/(a)#4), but the
  fuse is hard-wired to burn shares sourced from `PlasmaVaultStorageLib.getWithdrawManager().manager`'s fee balance
  specifically (`WithdrawManagerNotSet` check, fixed source) — POL needs to burn *whatever cyavKAT the vault itself
  holds*, not withdraw-manager fee shares, so it needs the generalized `BurnHeldSharesFuse`, not this fuse verbatim.

## (d) Market-substrate layout per market id after the refactor

| Market | Today | After refactor |
|---|---|---|
| **7** (ERC20_VAULT_BALANCE) | `CurveYieldErc20BalanceFuse`; substrates = plain ERC20 tokens | `PositionReaderBalanceFuse`; substrates = plain ERC20 tokens (unchanged) **+** position-reader addresses (2 new: LP-holder reader, vKAT-exit-queue reader) as a new substrate *type* within the same market — needs the substrate encoding extended (today's substrates are plain `address` tokens; readers need a distinguishing type, similar to how Balancer substrates already carry a `POOL`/`GAUGE` type tag via `BalancerSubstrateLib`) |
| **14** (Morpho avKAT/KAT loop) | `CyLoopEnv`-driven bespoke fuses; substrates implicit in the env struct (morpho, marketId, avkat, kat, fuse addresses) | Morpho market id as substrate for `MorphoCollateralFuse`/`MorphoBorrowFuse`/`MorphoFlashLoanFuse` (standard IPOR substrate-granting pattern) **+** `CurveYieldLoopCycleFuse`/`CurveYieldUnwindSearchFuse` each need their own substrate list (collateral/borrow/swap/flash fuse addresses, since they call them internally rather than being called alongside them) |
| **19** (Sushi LP) | Implicit via `CyLpParams`/holder addresses on the controller, not IPOR substrates today (the holder pattern predates the standard substrate model here) | New holder-fuse substrates: holder contract address (per vault) as a granted substrate; the position-reader adapter registered separately under market 7 (see above) for accounting, so market 19 itself may not need IPOR-style substrates beyond "which holder" |
| **36** (POL / Balancer v3) | `CurveYieldPolBalanceFuse`; pool/router/permit2 via `CyPolVenues` on the controller, not IPOR substrates | `RateAwareBalancerBalanceFuse` should use IPOR's standard `BalancerSubstrateLib` POOL/GAUGE substrate typing (already fits — POL only ever needs the POOL type) so the vault's substrate-granting UI/tooling treats it the same as any other Balancer market |
| **41** (IPOR lending market, avKAT deposited via `MorphoSupplyFuse`) | Already standard IPOR (Morpho market id substrate on `MorphoSupplyFuse`'s market) | **Unchanged** — `CurveYieldAvkatLendReduceFuse` deletion means market 41 needs no CurveYield-specific fuse at all afterward, only IPOR's own `MorphoSupplyFuse` + its paired `MorphoBalanceFuse`/`MorphoOnlyLiquidityBalanceFuse` (already live per spec) |
| **UNISWAP_V3** (if registered for Sushi, per spec's "else market 7" fallback) | Not used today (Sushi LP is accounted via the custom balance fuse, not IPOR's UniswapV3Balance, because of the holder pattern) | Still not directly usable while the holder is kept (see §11/(c) on `UniswapV3Balance`'s shared-token-id-list assumption) — **the spec's "IPOR UniswapV3Balance if registered for Sushi" branch does not apply** as long as the holder decision stands; market 7's `PositionReaderBalanceFuse` covers it instead. Flag this as a spec/decision mismatch worth a one-line correction: the spec's mapping table (line 37) still lists the UNISWAP_V3-market option as live, but the 2026-09-27 "holder kept" decision forecloses it. |
| **54** (gauge-vote grants, referenced by `CurveYieldVkatVoteFuse`) | Already a substrate-gated market (`isSubstrateAsAssetGranted(54, gauge)`) | Unchanged; `VeVoteFuse` uses the same market 54 substrate check |
| **new veToken market** (not numbered yet) | N/A | `VeLockFuse`/`VeConvertFuse`/`VeExitFuse` need their own market id for escrow/NFT/loop-controller substrates — needs a number assigned before scripts P2_01/02 etc. are updated, per the spec's "Scripts" impact note |

## (e) Risks

1. **The two hardest fuses (`CurveYieldLoopCycleFuse`, `CurveYieldUnwindSearchFuse`) are new, unaudited code that
   reproduces numerically-sensitive iterative solvers** (secant search, fixed-point deleverage search) that the
   *current* audited `CurveYieldMorphoStrategyFuse`-derived code already carries subtle convergence-tuning (over-
   relaxation factors, iteration caps, tolerance bands — see the `4x` over-relaxation constant and the `/10_000+1`
   tolerance in `_unwind`/`deleverage`/`planDeleverage`). Reproducing this exactly in a "generic, reusable" fuse
   without silently changing convergence behaviour is real engineering risk, not a mechanical rewrite.
2. **Splitting `CurveYieldErc20BalanceFuse`'s clamp-at-0 combination logic across independent position readers**
   (§1) risks a reader returning a negative-equivalent (e.g. holder debt > holder assets) that used to be absorbed
   by the single balance fuse's `if (plus > minus)` guard — if each reader is naively summed without a global floor,
   a market-7 balance could underflow-wrap or be misreported. Needs an explicit design decision on where clamping
   lives (each reader vs. the aggregating fuse).
3. **The generic holder-fuse pattern (§5) still calls into an unaudited-touch holder contract** — "generic" fuse
   wrappers around a bespoke holder do not make the holder itself any more reusable by other IPOR vaults; the
   "IPOR-standard, reusable building block" goal (spec's stated Goal) is only partially met for market 19, since the
   holder itself remains CurveYield-specific. This should be stated plainly to the owner: LP is the one market where
   "every vault could install this" is not really true after the refactor, only "every CurveYield-style holder
   deployment could reuse the wrapper fuses."
4. **`CurveYieldVkatConvertFuse.instantWithdraw`'s try/catch gap (§9/(b)#2)** is a silent correctness/safety
   regression if folded into the generic never-revert wrapper without a decision — flagged twice in this document
   deliberately because it's the one place today's code is *stricter* than the planned generic fuse.
5. **Market-substrate typing extension for `PositionReaderBalanceFuse` (§(d))** requires either extending
   `PlasmaVaultConfigLib`'s substrate encoding (a `type` tag like `BalancerSubstrateLib` already does) or overloading
   plain addresses to mean "this could be a token or a reader" — the latter is fragile (a compromised/misconfigured
   reader address that happens to also look like an ERC20 could be read as a token balance, or vice versa). Needs a
   typed substrate library, mirroring `BalancerSubstrateLib`, not a shortcut.
6. **Publishing 12 new generic fuses to IPOR Fusion's own repo** (decision 3 in the spec) means their audit surface
   is not fully "free" just because they're "generic" — IPOR's own reviewers will need to review CurveYield-authored
   code before it's usable elsewhere, so the audit-cost saving from "reuse audited IPOR fuses" only really applies
   to the ~14 direct-reuse rows in this document, not the ~12 new ones. The spec's "fewer custom fuses" framing
   (Impact section) is correct for code *volume* but not for audit *scope* — worth restating precisely to the owner
   before committing to "do this now, before your audit."
7. **Timing risk given "do this now, before your audit" (decision 4)**: this inventory alone does not de-risk the
   two hardest fuses (#10/#11 above) — those need their own design review/spec (matching the "spec-before-code"
   rule already in force for cyavKAT) before implementation starts, or the audit will be reviewing freshly-written
   numerical solvers with no prior track record, which is a materially different audit than reviewing "wiring
   changes around already-audited IPOR fuses."

---

## Counts (for the summary)

- Current fuse **files** read in full: 12 (`CurveYieldErc20BalanceFuse`, `CurveYieldExecutorFuses`,
  `CurveYieldSignatureFuse`, `CurveYieldAvkatLendReduceFuse`, `CurveYieldSushiLpFuses`, `CurveYieldSushiLpHolder`,
  `CurveYieldMorphoLoopFuses` + `…FuseBase` + `…WindupLib` + `…LoopLib`, `CurveYieldPlusLoopFuses`,
  `CurveYieldPolFuse` + `CurveYieldPolBalanceFuse` + `CurveYieldSwapLib`, `CurveYieldVkatFuses`) plus the live swap
  fuse and its router (2 more files).
- Distinct external **vault-action** entry points inventoried: **34** (enter/exit/named actions/instantWithdraw
  across all 9 contracts) + 4 `balanceOf()` views + the live swap fuse's ~10 functions (1 action, 4 quote views, 5
  admin/harvest).
- Of the 34 vault actions: **14 map onto an existing IPOR fuse call with no new code** (Morpho collateral/borrow/
  supply/flash-loan legs used across §4/§6/§7/§9, Erc4626 supply/exit legs in §7, Balancer liquidity proportional
  enter/exit in §8).
- **11 new generic fuse contracts recommended** (#1–#7, #9–#12 in list (a); #8 recommended against; #13 is a helper,
  not a fuse) covering the remaining 20 vault-action entry points (several entry points share one generic fuse,
  e.g. all 3 vKAT-exit steps share `VeExitFuse`).
- **7 behaviour-change items** need explicit owner sign-off before coding starts (list (b)).
- **7 IPOR fuses were checked and rejected** as not fitting, each with a specific technical reason (list (c)), not
  just "different name."
