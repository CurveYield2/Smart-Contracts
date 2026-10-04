# Fuse standardization (IPOR style, reusable) — spec for approval (2026-09-27)

## Goal
Every fuse becomes an IPOR-standard, reusable building block that any IPOR Fusion vault could install:
- one action per fuse, `enter(struct)` / `exit(struct)` (+ `enterTransient` / `exitTransient` like IPOR);
- stateless: no vault address, no CurveYield controller, no hard-coded pools — everything it may touch is a **market
  substrate** of its market (pools, tokens, routers, escrows), checked on every call;
- every amount / limit comes in through the call data.
Our protections do not move into the fuses: they stay in the controllers, which become **planners** (views that
return `FuseAction[]` with explicit amounts and limits), plus a generic **guard fuse** at the end of each bundle that
enforces the post-conditions on-chain (PPS never drops, LTV, min profit, balances).

## Architecture
```
bot / anyone ──> Executor (policy, roles, caller reward)
                   │  asks the planners (our controllers, views) for FuseAction[] with explicit parameters
                   ▼
                 vault.execute([ snapshot, generic fuse, generic fuse, ..., guard ])
                                   ▲ IPOR audited fuses wherever one exists; our new generic fuses otherwise
```
- **Snapshot / guard**: `CurveYieldBundleGuardFuse` — `enter` at the start stores totalAssets, totalSupply and chosen
  balances in transient storage; `exit` at the end asserts: PPS >= start x (1 - maxPpsDropBps) (0 by default),
  optional max LTV per Morpho market, min idle, min profit (assets gained vs a value passed by the planner).
  Generic: parameters in the call data, markets / tokens checked against its market's substrates.
- **Instant withdrawals** (IPOR calls `instantWithdraw(params)` on listed fuses, with no planner in between):
  `CurveYieldPlannedInstantWithdrawFuse` — generic: its substrate is a planner address; it asks the planner for
  `FuseAction[]` for the amount and runs them through `executeInternal` inside try/catch (never reverts). Our loop /
  POL / cyavKAT+ planners implement one view: `planInstantWithdraw(uint256 amount) returns (FuseAction[])`.
- **Flash-loan bundles** (Morpho loops): IPOR `MorphoFlashLoanFuse` already takes the callback `FuseAction[]` —
  planners build the whole cycle (collateral, borrow, swap, guard) up front.

## Mapping: every current fuse → standard fuses
| Current fuse (file) | Becomes |
|---|---|
| MorphoLoopWindupFuse / LtvRebalanceFuse / UnwindFuse / EmergencyFuse (morpho/) | IPOR MorphoFlashLoanFuse + MorphoCollateralFuse + MorphoBorrowFuse + swap fuse (below) + guard. Planner = loop controller (cycle sizes, profit gate, loss buffer computed in the view; enforced by the guard) |
| AvkatLendReduceFuse (lend/) | IPOR MorphoSupplyFuse.exit with the planner's amount (fuse deleted) |
| SushiLp Open / Increase / Withdraw / Rebalance / Emergency (lp/) + LpHolder | The holder contract is removed; the vault holds the Sushi NFT and its own Morpho position: IPOR UniswapV3NewPositionFuse / ModifyPositionFuse / CollectFuse (Sushi V3 = Uniswap V3 ABI) + Morpho fuses + swap fuse + guard. Valuation: IPOR UniswapV3Balance (market UNISWAP_V3) if registered for Sushi, else market 7 via the generic position-reader balance fuse (below) |
| Vkat Lock / Convert / Vote / ExitPrepare / ExitBegin / ExitComplete (vkat/) | New generic **Aragon VotingEscrow fuse set** (`VeLockFuse`, `VeVoteFuse`, `VeExitFuse`, `VeConvertFuse`): escrow, gauge voter, exit queue and clock are substrates; any vault holding avKAT/KAT (or another Aragon ve token) can use them |
| PlusStepFuse / PlusLoopFuse (plus/) | IPOR MorphoFlashLoanFuse + Erc4626SupplyFuse (cyavKAT, then wcyavKAT) + MorphoCollateral/Borrow + guard; instant withdrawals via the planned instant-withdraw fuse |
| PolFuse (pol/) | IPOR BalancerLiquidityProportionalFuse (enter/exit) + swap fuse (Balancer router + Sushi) + new generic **BurnHeldSharesFuse** + guard; instant withdrawals via the planned instant-withdraw fuse |
| ExecutorPayFuse / ProfitSplitFuse (executor/) | New generic **Erc20TransferFuse**: token and recipients are substrates, per-call amount; the executor's policy (caps, split %) stays in the executor / splitter |
| SignatureFuse (katana/) — LIVE | Already almost generic: drop the VAULT immutable (context from the delegatecall), prefix/signers in call data. Live copy stays until a migration is wanted |
| Erc20BalanceFuse (accounting/, market 7) | Generic **PositionReaderBalanceFuse**: IPOR Erc20 logic for substrate tokens + a list of "position reader" substrates (standard `positionValue(vault) → (asset, amount)` interface) — our vKAT exit queue / LP readers plug in; no hard-coded controllers |
| PolBalanceFuse (market 36) | Generic **RateAwareBalancerBalanceFuse**: BPT share of RAW balances, each token priced by the vault's oracle middleware (the vault's own share priced by its registered feed, e.g. NetPps). Replaces IPOR BalancerBalanceFuse only where WITH_RATE double counting applies |
| Swaps (fee router 0x01F9, SwapLib) | IPOR UniversalTokenSwapperFuse (targets/tokens as substrates) with our TWAP-guarded router as an allowed target, or a new generic **TwapGuardedUniV3SwapFuse** (best of listed routes, TWAP floor; pools and routes are substrates) |

Unchanged (not fuses): executor, allocation, controllers-as-planners, withdraw manager, wrapper, governance, rewards.

## New generic fuses (to write, each small, each reusable)
1. CurveYieldBundleGuardFuse  2. CurveYieldPlannedInstantWithdrawFuse  3. VeLockFuse / VeVoteFuse / VeExitFuse /
VeConvertFuse  4. BurnHeldSharesFuse  5. Erc20TransferFuse  6. PositionReaderBalanceFuse  7. RateAwareBalancerBalanceFuse
8. TwapGuardedUniV3SwapFuse (if UniversalTokenSwapper is not enough)  9. Erc1271SignerFuse (generic SignatureFuse)
Everything else is IPOR's audited fuses.

## Rules kept (enforced by planners + the guard)
PPS never drops (guard default 0 drop, LP / POL exceptions only where already approved), registered markets only
(7, 14, 19, 36, 41 + UNISWAP_V3 if registered), protected fee paths (fee authority), reversible settings, bounded
parameters, 7-day seasoned wind-up cap, 0.5% POL floor, burn-only fees.

## Impact
- Code: all Phase 2–4 + POL fuses rewritten or deleted; controllers change from "fuse reads me" to "I return
  FuseAction[]"; the executor assembles bundles with snapshot/guard. Largest items: LP holder removal, loop cycles
  precomputed in views, vKAT fuse set.
- Scripts: P2_01/02, P4_02/03, P5_01 (fuse lists, substrates per market, instant-withdraw list).
- Nothing live changes except by choice: live fuses (signature fuse, lending market 41 IPOR fuses, wrapper) stay.
- Audit: fewer custom fuses (IPOR ones are already audited), but new generic fuses + planners.

## Decisions needed
1. Approve the planner + generic fuse + guard architecture?
2. Sushi LP: remove the LP holder (vault holds the NFT + its own Morpho position) — OK?
3. Publish the generic fuses for others how: a PR to IPOR Fusion (their repo/licence, their review), or our own
   public library (BUSL or MIT)?
4. Order: do this now, before your audit (recommended — nothing here is deployed yet), then continue.

## Decisions (2026-09-27)
1. Architecture (planners + generic fuses + guard): **approved**.
2. Sushi LP holder: **kept** (no removal). Its steps become a generic "holder" fuse pattern (holder address as a
   substrate, standard holder interface) instead of vault-held NFT fuses.
3. Publishing: a PR to **IPOR Fusion** AND GitHub **CurveYield2/Smart-Contracts** (public, empty as of 2026-09-27), folder
   "IPOR Fusion". Pushing publishes: only after the owner explicitly approves each push / PR.
   Always written locally too: code in work/phase2/src, publish mirror in work/Smart-Contracts/IPOR Fusion/.
   The IPOR Fusion PR waits until AFTER the audit.
4. Timing: **now**, before the audit.

## Honest scope (correction)
Not "IPOR fuses + 9 new fuses for every function". Expected: IPOR fuses where they fit + ~13–15 small generic fuses
of ours, and a few documented behaviour changes. Known hard cases:
- Loop wind-up stops adaptively per cycle (swap quotes are not views): either precomputed cycle count + guard
  (slightly different behaviour) or a generic "cycle while profitable" fuse (exact behaviour).
- POL sell-or-burn depends on the real sale result: generic "try swap, else fallback action" fuse.
- LP holder kept: generic holder fuses (deposit / withdraw / rebalance / collect through a standard interface).
- Instant withdrawals from loops need the vault's execution flag for flash-loan callbacks (generic instant fuse
  handles it).
- Non-fuse contracts (executor incl. vKAT exit-lane tickets, WM, allocation, controllers, wrapper, governance,
  rewards) are not part of this refactor.
Step 1 = an exact inventory: every external function of every current fuse -> its standard replacement (IPOR fuse,
new generic fuse, or planner logic), with any behaviour change called out. Coding starts after that is reviewed.

## Decisions on FUSE_INVENTORY.md (b) — all recommendations approved (2026-09-27)
1. Loop wind-up: exact `CurveYieldLoopCycleFuse` (per-cycle profit gate kept); unwind: `CurveYieldUnwindSearchFuse`.
   Both get their own spec before code (numerical solvers).
2. vKAT convert instant withdrawal: generic never-revert behaviour accepted (IPOR still reverts a redemption it
   cannot pay).
3. LP rebalance: the live needs-rebalance check stays inside the holder fuse (no-op when not needed).
4. Lending decay bookkeeping: records the ACTUAL amount withdrawn.
5. Profit split: N transfers through `CurveYieldErc20TransferFuse` (no dedicated distribute fuse).
6. POL add-liquidity haircut: planner-supplied, bounded 0–50 bps, default 1 bp (0.01%).
7. Which fuses go upstream to IPOR: decided after the audit.
Correction: the mapping table's "IPOR UniswapV3Balance if registered for Sushi" option does not apply while the LP
holder is kept; market 7's PositionReaderBalanceFuse values the LP.
- 2026-09-27: loop fuses spec APPROVED; Sushi LP set KEPT (holder wrapper fuses to be written).
- Snapshot of src/ + script/ before the fuse standardization: phase2/_pre-standardization-2026-09-27/ (old fuses kept there; the lend reduce fuse reconstructed).

## Implemented (2026-09-27) — compiles (src + all scripts); NOT tested (the audit tests)
Generic fuses (src/generic, mirrored to work/Smart-Contracts/IPOR Fusion/fuses): BundleGuard, PlannedInstantWithdraw,
TryElse, BurnHeldShares, Erc20Transfer, Erc1271Signer, PositionReaderBalance (+ 2 readers), RateAwareBalancerBalance,
BalancerV3Swap, LoopCycle, LoopUnwind, Ve{Lock,Convert,Vote,ExitBegin,ExitWithdraw}, Holder{Open,Increase,Withdraw,
Rebalance,Deleverage}; one type registry (CurveYieldSubstrateTypes); typed entries live in the substrate-only market 54.
Planners: loop, lend (IPOR MorphoSupplyFuse directly), vKAT (+ sync() from lastLockId), LP holder, POL, cyavKAT+ (IPOR
Morpho + ERC-4626 fuses; ERC4626_0001/0002 with ZeroBalanceFuse). Executor: transfer-fuse pay + split legs, guard on
deploy (deployGuardDropBps 5, 0..100) and POL maintenance (0), PPS-based loss, vKAT sync, actual lend reduction, early
exit planned after the premium. Old fuses deleted from src (snapshot: phase2/_pre-standardization-2026-09-27/).
Scripts: P2_01/02/03, P4_02/03/04, P5_01 updated (market 54 appends; executor role 1100; instant list via the planned fuse).
Behaviour differences to note for the audit:
- NEW guard: no deploy bundle or POL maintenance may lower PPS (deployGuardDropBps default 0, owner-settable 0..100).
- vKAT: the very first lock votes in the same bundle without naming the position id (not known yet).
- POL enter sizes the BPT from the guaranteed swap minimum (leftover cyavKAT burned); buyback yield fee on the
  guaranteed profit (<= real profit).
- Fuses no longer check the caller is the executor (IPOR norm: ALPHA-only).
- test/ still targets the old fuses (not updated; the audit covers testing).
- 2026-09-27 decisions: guard 0 (approved); vKAT first-lock vote and POL sizing/fee notes accepted; POL values cyavKAT at
  the vault's ACTUAL share deposit rate (convertToAssets) everywhere — the rate-aware balance fuse hard-sets the
  vault's own share leg this way (no oracle, no market price), and the POL planner uses the same rate for caps and
  sale floors.
- Correction (2026-09-27): the Sushi LP set's generic holder fuses run in market 7 with typed substrates in market 54; market 19 is only cyavKAT+'s flash-loan market (FUSE_INVENTORY.md's market-19 guess for the LP was not used).
