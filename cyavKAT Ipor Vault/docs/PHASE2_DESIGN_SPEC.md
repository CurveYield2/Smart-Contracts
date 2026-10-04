# Phase 2 design spec: strategy-layer rebuild

Status: **decisions resolved 2026-09-24; approved to build** · 2026-09-24 · vault cyavKAT `0xEd83daf48429cfb2C650Fd721b9241e180fd4548` (Katana)

Spec items covered: #3b, #5b, #9, #11, #13, #14, #15, #16, #18, #19. Housekeeping items that come after Phase 2 deploys: #4, #10, #12, #17.

Every contract below is new code that handles vault funds. It is built, fork-tested on Katana and run through the V7 audit before any mainnet deployment.

---

## 0. Facts this design depends on (verified 2026-09-24)

| Fact | Consequence |
|---|---|
| The vault prices avKAT at the **conversion rate**: price middleware avKAT/KAT = 6.767/5.012 = 1.3502. | Vault accounting books avKAT bought below conversion as a gain. See decision D1. |
| IPOR runs instant-withdrawal fuses with **no try/catch** (`PlasmaVaultMarketsLib.withdrawFromMarkets`). | Every new instant-withdrawal fuse must **never revert**. When it cannot help, it returns without doing anything. |
| The existing loop position belongs to the vault itself (Morpho market `0x80e6`, vault market 14). | The new Morpho set works on that same position. **No funds move during migration**; only fuses and controllers change. |
| The withdraw manager releases shares only when its `controller` calls it. The executor will become that controller. | The request fee can be burned in the same transaction as the unwind loss (#3b, §4). |
| Pool `0x8640` now keeps 100 price readings (Phase 1). | TWAP quotes stay available right after swaps. |
| The 1% pool is effectively flat for trades up to about 5,000 KAT (no measurable price impact). | Sizing math can treat the swap cost as the 1% fee plus slippage. |

## 1. Architecture

```
                    ┌─────────────── CurveYieldVaultExecutor (public; ALPHA; WM controller) ───────────────┐
 keeper / bot ───►  │ deployAssets · fulfillAll · fulfillFor · rebalance · emergency(set) · harvest         │
                    └──┬───────────────┬──────────────────┬────────────────┬──────────────────┬────────────┘
                       │ plan/views    │                  │                │                  │
              AllocationController  MorphoLoop       AvkatLend        SushiLp            Vkat
              (idle split, floors,  Controller       Controller       Controller         Controller
               managed-avKAT sum)      │                 │                │                  │
                                  4 loop fuses     supply / instant   open / close /     lock / convert /
                                  + ProfitSplitter  / balance fuse    rebalance / emerg  vote fuses
                                                                      / instant / loss   (+ existing
                                                                      + SushiLpCustody    adapter m54)
                       ▼
                 PlasmaVault.execute(one FuseAction[] bundle per call)
```

Principles:
1. **One function per fuse** (#9). Controllers hold the settings and compute plans. Fuses carry out a plan and check it against the controller.
2. **Every limit is a constructor value.** Each setting has a `[min, max]` fixed at deployment; setters revert outside it (#9).
3. **Over target never reverts** (#18). A set's controller returns `planDeploy() = 0` when the set is at or over target, and `planReduce() > 0` when it can safely reduce. The executor skips a set that has nothing to do.
4. **One share of the total.** `AllocationController.managedAvkat()` = vault idle + the Σ `managedAvkat()` of every set + rewards-manager balance. Every allocation is a share of this single total, which fixes the gap where lent and LP avKAT were not counted.
5. **Executor-only actions.** Fuses check `msg.sender == executor` and "execution started". Config reads go through each controller's address, as the current `VERSION` pattern does.

## 2. Contracts

### 2.1 CurveYieldVaultExecutor
Replaces ControllerV2. It receives ALPHA (200) and becomes the WM controller, the RCM claim caller, and every fuse's executor.

| Function | Behaviour |
|---|---|
| `deployAssets()` | 1. Prune the WM queue.<br>2. Pull vested rewards.<br>3. **If scheduled requests exist:** make the funding plan (§2.2 #11/#15) and release shares.<br>4. Else: for each set in order Morpho loop → lending → LP → vKAT, add `planDeploy()` actions, or `planReduce()` actions when the set is over target.<br>5. Run everything as one `vault.execute`, then pay the caller reward. |
| `fulfillAll()` / `fulfillFor(requester, shares, maxContribution)` | Gathers the needed avKAT from each source in turn: idle above the floor → lending (instant) → vKAT (conversion window) → LP (only if the gate passes, §2.5) → loop unwind. Then it releases shares and **burns the earned request-fee shares in the same transaction** (§4). |
| `rebalance()` | Runs pending reduce plans (lending cap decay, an off-optimal LP, the loop's LTV target). The LTV-up proceeds follow #15. |
| `emergency(uint8 setId, bytes data)` | Public. Only runs when that set's own emergency condition is true (loop LTV > emergency level; LP custody LTV > 76%). |
| `harvest(tokens, amounts, proofs)` | Same as today. |
| `setControllers(...)`, `setCallerReward(...)` | Owner only; bounded. |

### 2.2 Morpho loop set (market 14, same position)

**MorphoLoopController** settings (constructor bounds → default):

| Setting | Range | Default | Spec |
|---|---|---|---|
| `allocationBps` (the loop's share of managed avKAT) | 0–8,000 | 7,500 | — |
| `rampZoneBps`: last share of the allocation where the required profit ramps up | 0–5,000 | **4,000** | #14 (was a hard-coded 3,500) |
| `baseWindupProfitBps`: required below the ramp zone | 0–1,000 | **225** | #14 |
| `rampStartProfitBps` → `rampEndProfitBps`: required inside the ramp zone | 0–1,000 | **300 → 700** | #14 |
| `minUnwindProfitBps` / `lossBufferBps` | 0–1,000 / 0–1,000 | **40 / 835** | #3; request fee 8.75%, loss buffer 8.35% (covers the ~8.33% native-exit lane at 75% LTV), minimum profit 0.40% (2026-09-24) |
| `slippageBps` | 0–100 | 30 | #5 |
| `targetLtvBps` / `emergencyLtvBps` / `emergencyTargetLtvBps` | 5,000–7,600 / target–7,690 / target–(emergency − 1) | 7,500 / **7,660** / **7,620** | Emergency triggers only above **76.6%** and de-leverages only down to **76.2%**, a small, cheap shift (2026-09-24). LLTV is 77% |
| `maxCycles` | 1–16 | 8 | — |

Views:
- `planDeploy()` returns 0 whenever `WM.activeUnreleasedShares() > 0` (#11).
- `planUnwind(neededAvkat)`, `snapshot()`, `managedAvkat()` (net equity).
- `windupProfitBps(borrowKat)` uses the method chosen in **D1**.

| Fuse | Does exactly one thing |
|---|---|
| **MorphoLoopWindupFuse** `enter(cycles)` | Supply → borrow → swap cycles toward the target LTV. Each cycle re-checks profit with the D1 method and stops at the first failing cycle rather than reverting. It sends profit through the ProfitSplitter. |
| **MorphoLoopUnwindFuse** `enter(neededAvkat, maxLossBps)` | Flash repay → withdraw collateral → sell → end at the target LTV. Reverts if the loss exceeds `maxLossBps`. |
| **MorphoLoopLtvRebalanceFuse** `enter()` | When LTV is below target (avKAT's conversion rate has grown), borrows KAT up to 75%, swaps to avKAT and **leaves it idle as withdrawal funding** when requests exist (#15). With no requests it re-supplies it. |
| **MorphoLoopEmergencyFuse** `enter(repayKat)` | Only above `emergencyLtvBps`. Uses today's full/partial plan logic. |

**LoopProfitSplitter** (#16):
- `setSplit(growth, contributors, vault, rewardsManager)`: each ≤ 5,000, sum 10,000, default **3,500 / 2,000 / 2,000 / 2,500**.
- Growth goes to the Vault Growth Custody (today's ProfitCustody `0xe7D1`).
- The contributors share is held in the splitter until the Phase 4 ContributorsRewardFuse exists (**D5**).
- The vault share stays in the vault.
- The rewards-manager share goes to the RCM and vests over 15 days.
- It applies to wind-up profit and to unwind profit (**D2**).

### 2.3 avKAT lending set: Morpho `0x5c60efbf…d014` (loan avKAT, collateral cyavKAT)

**AvkatLendController** (#13):

| Setting | Range | Default |
|---|---|---|
| `capBps` (share of managed avKAT) | 0–5,500 | **2,000** (D3) |
| `ownershipTriggerBps` (vault's share of total market supply) | 500–5,000 | 2,000 |
| `decayBps` per `decayInterval` | 0–2,500 per 1–48 h | 1,000 per 12 h |
| `liquidityFloorBps` (market liquidity that must remain) | 0–2,000 | 300 |

Behaviour:
- `planDeploy()` = 0 when the vault's share of the market's supply is above 20%, or when the market's available liquidity is below the vault's supply. It also never supplies above the cap.
- When either trigger holds, `planReduce()` withdraws at most `decayBps` of the lent amount per interval, and never takes the market's liquidity below `liquidityFloorBps`.

Fuses:
- **AvkatLendSupplyFuse** `enter(amount)` / `exit(amount)`: substrate is market `0x5c60` only.
- **AvkatLendInstantWithdrawFuse** `instantWithdraw(params)`: withdraws min(needed, available liquidity above the floor); never reverts.
- **AvkatLendBalanceFuse** `balanceOf()`: supply assets × avKAT USD price. New vault market id **60**.

### 2.4 vKAT set (split of `0x987C`)
- **VkatController**: `allocationBps` 0–9,000 (the bot sets it, #17), the vote targets, `planDeploy()`, `planConvert(needed)`.
- **VkatLockFuse** `enter(amount)`: merge into the vault's NFT, or create one.
- **VkatConvertFuse** `enter(amount)` + `instantWithdraw(params)`: never reverts.
- **VkatVoteFuse** `enter()`.
- Logic is carried over from the current fuse. Market 54 and the accounting adapter `0xD3d3` stay.

### 2.5 Sushi avKAT/KAT LP set (1% pool `0x8640`, tick spacing 200)

**SushiLpCustody** (a standalone contract that only the vault can drive):
- Holds its own Morpho `0x80e6` position (avKAT collateral, KAT loan, target 75% LTV) and the Sushi V3 NFT.
- `open`, `close`, `collect`, `repayAndWithdraw`, and `onMorphoFlashLoan` (hash-bound).
- Tracks its **basis**: every avKAT sent in, counted in avKAT (#19).

**SushiLpController** (your earlier decisions, now as rules):

| Rule | Value |
|---|---|
| Upper tick | First multiple of 200 strictly above the conversion-rate tick (today 3,200). |
| Lower tick | The step at or below the current tick, moved down until the KAT share is ≥ `minKatBps` (today 2,400, 5.7% KAT). |
| `minKatBps` | 0–2,000, default **500**. |
| Rebalance trigger | The optimal range differs by ≥ 1 step **and** closing and reopening is profitable (**D4**). |
| Target allocation | `minBps` **200** / `maxBps` **500** (D3; constructor range 0–5,500). Linear between them. It stays at `minBps` until the LP's trailing yield is ≥ **+30%** above the lending yield, and reaches `maxBps` at **+100%** (#19). |
| Yield measure | LP: (fees + net-equity change since the last checkpoint) ÷ basis, over a trailing `yieldWindow` (default 7 days, from stored checkpoints). Lending: the Morpho `0x5c60` supply APY from the IRM. |
| Loss gates (#19) | Return ≥ basis − **1%**: normal rebalances and instant withdrawals allowed.<br>Loss up to **4%**: scheduled fulfilment only.<br>Loss above 4%: only `withdrawWithLoss(percentBps)`, owner-triggered. |
| Emergency | Public when custody LTV > **76%**. Flash-repays back to **75%** (copied from the loop emergency plan). |

Fuses:
- **SushiLpOpenFuse** and **SushiLpCloseFuse**
- **SushiLpRebalanceFuse**
- **SushiLpEmergencyFuse**
- **SushiLpInstantWithdrawFuse**: never reverts, and respects the 1% gate
- **SushiLpWithdrawWithLossFuse**
- **SushiLpBalanceFuse**: LP amounts + uncollected fees + collateral − debt, in USD. New market id **61**.

### 2.6 AllocationController (#18, idle split)
- Owns the **vault floor**: at least 3,000 bps of idle-class avKAT stays in the vault (range 1,000–5,000).
- Owns `managedAvkat()` (principle 4).
- Every set's `planDeploy` is limited to what remains above the floor after all sets ahead of it in the order.

### 2.7 Supporting upgrades

| Contract | Change |
|---|---|
| **CallerRewardFuse v2** | One action per executor function. Limits are set in the constructor. Keeps the current "fund, then validate" model. |
| **RouterSwapFuse v2** | Limits set in the constructor. The **view** quotes use the pool quote minus 0.3% instead of only the TWAP floor (#5). Keeps using router `0x01F9`, now verified. |
| **CurveYieldWithdrawalManager v2 (new contract; approved 2026-09-24)** | The live manager is a **non-upgradeable EIP-1167 clone**, and it only burns a request fee after the user redeems, plus a later prune. v2 burns the earned request fee **inside `releaseActiveShares` / `releaseFor`** and returns the burned shares, so fee and loss land in one transaction (#3b). The 30% custody cut on request fees is dropped (the #16 split replaces it, D2); the instant-fee custody cut is unchanged. Migration: with 0 open requests, deploy v2 and point the vault at it using a one-off maintenance fuse (the same method as the previous swap), then remove that fuse. |
| **ProfitCustody** (Vault Growth Custody) | Unchanged in Phase 2, unless **D7** changes how it distributes. |

### 2.8 Native-exit lane for scheduled withdrawals (added 2026-09-24)

**Why:** while the 1% pool trades below the conversion rate, unwinding the loop through the pool books about 24% of the avKAT freed (fork-measured: 2,907 lost freeing about 12,000). The vKAT exit queue instead converts at the conversion rate for a flat **2.5% fee** after a **60-day cooldown** (on-chain: queue `0x6dE9…578d`, `cooldown` 5,184,000 s, `feePercent` 2500).

**Flow**
1. **Start** (executor `startNativeExit(shortfallAvkat)`, only when a pool unwind would exceed the loss buffer).
   - avKAT to exit comes from other sources first: vault vKAT locks (exited directly), then idle avKAT above released-but-unredeemed shares, then lending, then LP.
   - Only if those are not enough: withdraw loop collateral while letting the loop LTV rise to at most **76.2%** (`nativeExitMaxLtvBps`, range target–7,620).
   - The avKAT is locked to a vault-owned vKAT NFT (`avKAT.withdrawTokenId`), then the exit starts (`escrow.resetVotesAndBeginWithdrawal`).
2. **Complete** (public, once `canExit` is true after 60 days).
   - `escrow.withdraw` pays KAT minus 2.5% to the vault.
   - Repay loop debt with it (borrow fuse exit, **no flash loan**).
   - Withdraw collateral back down to the 75% target.
   - Release the covered scheduled shares (fee burned in the same transaction, #3b).
3. **Accounting.** Exiting NFTs stay valued through the vKAT accounting adapter (market 54) until they are withdrawn, so no share-price step occurs at the start. The 2.5% fee is booked at completion together with the fee burn.

**Economics (please read; leverage multiplies the 2.5%)**
- The loop is 75% debt. To hand out 1 avKAT of loop equity, the vault must repay debt, which means converting about **3.3 avKAT** into KAT for each 1 avKAT paid out.
- Cost: 2.5% × 3.3 ≈ **8.3% of the amount paid out** (vs about 24% through the pool today, and 4% covered by the request fee).
- Throughput when the avKAT must come from loop headroom: at most 1.57% of collateral per round (75% → 76.2%), which frees about 0.3× that per 60 days. That is about **150 avKAT per 60 days** at the current size. Other sources (vKAT locks, idle) raise that, and rounds can overlap as headroom frees.
- For comparison, the #15 re-lever (borrow into the headroom that avKAT's ~45% yield creates, buy avKAT below conversion) currently **books a gain** and funds about 600+ avKAT a month.

**Order of scheduled-fulfilment sources:**
1. idle
2. lending
3. vKAT conversion window (free)
4. LP (gated)
5. **#15 re-lever proceeds**
6. pool unwind *only if within the loss buffer*
7. **native-exit lane**

Requests keep their 90-day window. Exits are started early enough to complete inside it (60 days + processing).

**Decision N1 (2026-09-24):**
- The scheduled request fee rises to **8.75%**, the unwind loss buffer to **8.35%**, and minimum unwind profit is 0.40%. Requesters therefore cover the lane cost.
- Live script: `Desktop/Claude/script/ScheduledFee875.s.sol`.
- 8.35% covers even a request funded 100% by the lane at 75% LTV (about 8.33%).
- **Profit split rule:** each fulfilment splits only its own actual profit = its burned request fee (valued at the pre-burn share price) − the unwind loss measured for that fulfilment (including the lane's 2.5% exit fee when it completes) − the caller reward. The whole fee is never split. A fulfilment whose loss eats the fee splits nothing.

## 3. Vault market map after Phase 2

| Market | Balance fuse | Substrates | Notes |
|---|---|---|---|
| 14 | MorphoBalanceFuse (existing) | market `0x80e6` | Loop, unchanged position |
| 7 | ERC20BalanceFuse (existing) | KAT, vKAT adapter | Swap / flash |
| 54 | adapter `0xD3d3` (existing) | gauges | vKAT |
| **60** | AvkatLendBalanceFuse (new) | market `0x5c60` | Lending |
| **61** | SushiLpBalanceFuse (new) | custody address | LP |
| max-uint, 12 | zero fuses (existing) | — | Kept |

Instant-withdrawal order: **lending (60) → vKAT convert (54) → LP (61)**. Each one does nothing when it cannot help.

## 4. Same-transaction fee and loss (#3b)

In `fulfillAll` / `fulfillFor`:
1. `vault.execute`: the unwind and source fuses run and produce the avKAT (the loss is booked here).
2. `WM.releaseActiveShares` / `releaseFor`: the fee on those shares becomes earned.
3. `vault.execute`: `BurnRequestFeeFuse.enter(earnedFeeShares)`. The burn lifts the share price by the fee.

All three steps run inside **one executor transaction**, so nobody can transact at the dipped price. The net effect on holders is fee − loss ≥ +0.5% of the released amount, enforced by the unwind gate.

## 5. Migration (one run from the deployer, then fork-verified)

1. Deploy all Phase 2 contracts with their constructor bounds.
2. On the vault:
   - `addFuses` for the new fuses;
   - `addBalanceFuse` for markets 60 and 61;
   - grant their substrates;
   - set the dependency graphs;
   - set the instant-withdrawal fuses in the new order.
3. Grant ALPHA to the executor, revoke it from ControllerV2, and point the RCM claim permission at the executor.
4. Point the WM controller at the executor with `setDependencies(executor, burnFuse, feeFuse, prevManager)`.
5. Fork check: run deploy, fulfil, instant withdrawal, emergency and rebalance, and compare against the current behaviour.
6. After a monitored period: `removeFuses` for `0x79E8`, `0x987C`, the old reward and swap fuses, and the outdated items in the short list (#4).

Nothing here moves user funds. The loop position, vKAT NFT and idle avKAT stay where they are.

## 6. Build order and deliverables

1. ~~Router verification (D6)~~: done; `0x01F9` is verified.
2. AllocationController + MorphoLoop set + ProfitSplitter + executor, with unit tests.
3. Lending set.
4. vKAT split.
5. LP custody + LP set.
6. Katana fork test suite covering every flow in §2 and §4, the migration of §5, the over-target cases (#18), and the never-revert instant-withdrawal cases.
7. Deploy and migration scripts (you broadcast them), then the V7 Lite audit of the Phase 2 source.
8. Afterwards: the maintenance bot (#17), removal of old fuses (#4), repositories and IPOR submission (#10), and regenerated contract lists (#12).

## 7. Decisions (answered 2026-09-24)

| # | Decision |
|---|---|
| D1 | **Conversion basis** for wind-up profit, including the real 1% pool fee and 0.3% slippage. |
| D2 | Unwind profit for the #16 split = **the request fee kept above the actual loss**. |
| D3 | Lending cap **20%**. **LP range 2% → 5%** until further testing (you changed this from the proposed 5 → 25%). Vault floor 30% of idle. |
| D4 | LP rebalance runs only if **return ≥ basis** after all close, swap and reopen costs. |
| D5 | The contributors' 20% is **held in the ProfitSplitter** until the Phase 4 fuse exists. |
| D6 | Router `0x01F9` **verified** on Katanascan. It is a byte-exact match with the local source, so there is no redeploy and every function stays compatible with the stack. |
| D7 | **Keep** the Vault Growth Custody as designed. It is fuelled by vault profit. Your condition is met: the collateral earning interest went from 430.8 to 833.7 avKAT (+402.9), and the net carry is positive (see below). |
| D8 | #14 reading **confirmed**: ramp zone 0–50%, set to 40%; required profit 3% → 7% inside it, 2.25% below it. |

**D7 check (2026-09-24):**
- Rates: KAT borrow in `0x80e6` is 4.83% APY at 91.5% utilization. avKAT's yield (growth of its conversion rate) is 44.6% APY over 30 days and 75.9% over 7 days.
- Custody position: 833.7 avKAT of collateral against 841.8 KAT of debt.
  - Earns about 502–854 KAT a year.
  - Pays about 40.7 KAT a year.
  - Net ≈ **+342 to +602 avKAT a year** on 210 avKAT of equity.
- Each wind-up loop adds collateral: all 8 loops increased the avKAT supplied.
