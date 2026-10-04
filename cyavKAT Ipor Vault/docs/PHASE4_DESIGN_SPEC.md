# Phase 4 design spec: cyavKAT+ ecosystem (#20, #22, #23, #24, #25)

Status: **APPROVED 2026-09-25 (§7)** · local build only; audited with the full stack before deployment.
Standing rules that apply:
- IPOR-registered markets only;
- admin-fee receivers and percentages are fee-authority-only (governance gate);
- everything stays reversible until final;
- the Aragon Admin plugin is kept.

Build order (from the roadmap): #24 leaderboard → #20 cyavKAT+ → #22 special reward distribution → #23 contributors reward fuse → #25 DEX LP fuse.

---

## 1. cyavKAT+ vault (#20): "CurveYield Looped cyavKAT"
**Vault.** A new IPOR PlasmaVault (factory) with asset cyavKAT (20 decimals), symbol `cyavKAT+`.
- **Created WITH IPOR's `PlasmaVaultVotesPlugin`.** The plugin can only be set when a vault is created. It gives cyavKAT+ per-account balance history, which the points system needs (§4).

**Fees:**
- IPOR management fee 0.5% a year (IPOR DAO);
- **performance fee 15% to admin** (protected);
- **deposit fee 35%** (IPOR FeeManager `setDepositFee`; protected);
- **instant withdraw fee 15%** and **scheduled withdrawals with the same 15% request fee** (IPOR withdraw manager, created by the factory; both protected).

**Fee handling (`CurveYieldPlusFeeRouter`, the fee account):**
- **Whitelisted depositors are rebated.** They deposit through `CurveYieldPlusRebateRouter`, which records the fee shares minted on their deposit and pays those shares back from the fee router in the same transaction.
- **Everyone else's fee is split:** 20% to the admin receiver (protected); 25% as vault profit through the RewardsClaimManager; 25% to the special reward distribution (§2); 30% to the cyavKAT+ yield booster.
- The split is configurable within per-category bounds.

**Strategy (the only one):** 100% of deposits go into a leveraged loop:
1. Wrap cyavKAT into wcyavKAT (that market's collateral).
2. Supply it as collateral in the lending market (`0xe0e5…`).
3. Borrow avKAT, deposit it into cyavKAT, wrap, and supply again, and so on, with a flash-loan wind-up like the Phase 2 loop library.

**Accounting:**
- Market 14 (MORPHO): collateral wcyavKAT, loan avKAT.
- The cyavKAT+ oracle middleware needs price feeds for wcyavKAT, cyavKAT and avKAT. All three exist as recipes.

**Withdrawals (unwinding):** flash avKAT (Morpho: plenty) → repay the slice's debt → withdraw collateral → unwrap → **redeem about 2.3× the withdrawn equity of cyavKAT through cyavKAT's instant withdrawal** to repay the flash → the rest goes to the user as cyavKAT. Cost: cyavKAT's 1.25% instant fee on the redeemed part, about 2.9% of equity, well inside the 15% fee (the PPS rule holds).
- **The bottleneck** is cyavKAT's instant liquidity (idle avKAT plus its instant-withdrawal fuses).
  - **Instant exits** are capped at what cyavKAT can redeem at that moment; the dapp shows the live maximum.
  - **Scheduled requests** (added 2026-09-25, same 15% fee): the cyavKAT+ executor fulfils them in slices as cyavKAT's instant liquidity allows, oldest first.
- cyavKAT+ never places scheduled requests on cyavKAT itself. At 8.75% × 2.3 that would cost about 20% of equity, more than the fee, which would break the PPS rule.

**Profit (wind-up):**
- As cyavKAT appreciates, the LTV falls. Re-levering back to the target is a wind-up, and the equity gained since the last checkpoint is profit.
- **Split:** 40% special reward distribution, 40% compounded, 10% cyavKAT+ yield booster, 10% admin (protected).

**Risk points:**
1. **LTV (§7 P4-1).** "75% LTV" can't mean Morpho's LTV. Morpho sees collateral at 0.88 × value and liquidates at 86%, so the real maximum is **75.7% of market value**. At 75% the buffer would be about 0.7%: one wrapper-fee accrual or a small rate dip would liquidate it.
2. **Wrapper fees (P4-2).** cyavKAT+ collateral is wrapped, so it pays the wrapper's 2% a year + 8% of gains **on the levered position**, about 4× the equity. That drags heavily on cyavKAT+ yield, and the fee goes to your own admin.
3. **Reflexivity.** cyavKAT+ borrows the avKAT the main vault lends and deposits it back into cyavKAT. The main vault's TVL inflates, which is harmless to its price, but the ownership and liquidity rules on the main vault's lending (20% cap, decay) cap the size of the loop. A sharp cyavKAT price drop, such as a loop-unwind loss in the main vault, hits cyavKAT+ with about 4× leverage.

## 2. Special reward distribution (#22)
- **Inflows:** holds cyavKAT from the cyavKAT+ fee split, cyavKAT+ profit, and point purchases (§4).
- **`distribute()` (public).** An epoch design, exactly like `CurveYieldEngagementRewards`: open → paginate → claim, so gas stays bounded.
  - The admin share (default 10%, range 0–20%) goes out first. The share is protected.
  - The rest goes to **eligible registered cyavKAT+ holders**, pro rata to cyavKAT+ balance. The first X cyavKAT+ of each holder is excluded (X 0–20, configurable).
- **Eligible holders** = the leaderboard's registered point users ∪ engagement-token holders.
- **Balance used:** cyavKAT+ balance at the epoch snapshot (votes-plugin checkpoints, `getPastVotes`, which requires self-delegation at registration). A 35% deposit fee makes just-in-time deposits unprofitable anyway.
- **Forwarders** (LP tokens that hold cyavKAT+):
  - Registration is permissionless and costs 0–500 cyavKAT+ (configurable).
  - The cyavKAT+ each forwarder holds is attributed to registered holders of its token, pro rata.
  - A forwarder is removed when it holds less than 0–10,000 cyavKAT+ (configurable).
- **Caller reward:** 0.01–4% of the distribution, capped at 0–20 cyavKAT+.

## 3. Contributors reward fuse (#23)
- **A custody fuse on the main vault,** like the Vault Growth Custody. It receives the avKAT already assigned to contributors (the loop profit splitter's 20% contributors share, the wrapper splitter's 30%, the proposal bond's slash third) **before** the vault books it. It reports no accounting.
- **Atomic conversion:** avKAT → cyavKAT (deposit) → cyavKAT+ (deposit, whitelisted so no 35% fee).
- **Payouts:**
  - `distributeLeaderboard(bps)`: bps% of the unreserved balance, pro rata to season points (§4);
  - `distributeGovernance(bps)`: bps% pro rata to engagement-token balances;
  - both paginated through epochs.
- **Grand prize:** a reserve % (configurable) of all cyavKAT+ held, time-locked until an unlock date set with the %. `grandPrizeEvent()` pays it out by leaderboard rank or points (§7 P4-7) and resets, so a new % and date can be set.

## 4. Leaderboard tracking (#24)
- **Seasons.** Each season has a start, an end, and its own **non-transferable, non-decaying** points token. All parameters are set **between** seasons only and frozen during one.
- **Every season is a 100% fresh start.** Users register again. Balances, tranches (long-hold bonus ages) and points all begin anew; nothing carries over.
- **Earning ramp:** an initial rate (bps of the maximum) plus up to 3 cliffs (date, % reached), linear between points, and 100% at the season end.
- **Four ways to earn:**
  1. **Holding.** 2-week epochs, base points per unit held, and a long-hold bonus of +x% per consecutive epoch on the amount held continuously. The source of balances is decision **P4-3** below.
  2. **Referrals:**
     - Claim up to 10 not-yet-deposited addresses at once, for a 0–100 cyavKAT fee. After depositing, a user can name their referrer once, free, which overrides any earlier claim. Admin can change referrers.
     - Referrers get up to 40% of tier-1 points and 20% of tier-2 (on-chain; partner programs are admin allocations, P4-5). This is **of everything the referee earns** (holding, bought and admin-allocated points). Referral points never cascade.
     - Caps relative to own earned points: full rate up to x% (20–500%); then a 20–50% cut until 40–1,000%; then a cumulative 30–50% cut.
  3. **Buying points with cyavKAT.**
     - Tiered rates relative to earned points: a starting rate of 10–1,000 cyavKAT-held-for-4–26-epochs per cyavKAT; then a 20–50% cut after purchases reach 10–50% of earned points; another cut after 25–100%; a further cut after 40–200%.
     - The spend is split 30% admin (protected) / 40% special reward distribution / 20% cyavKAT Growth Custody / 10% cyavKAT+ yield booster. Each category is configurable 0–50%.
  4. **Admin allocation,** capped at 5–30% of all points distributed.
- **Registration:** minimum balance 0–1,000 cyavKAT to register and to stay registered, and a 0–100 cyavKAT fee. Late registrants are **back-paid** where history allows (cyavKAT+ has it; cyavKAT doesn't, see P4-3).
- **On-chain:**
  - a sorted top-100 `leaderboard()` (insertion into a fixed array, O(100) per update);
  - `pointsOf(address)` and per-season totals;
  - accounting entry points `accountLeaderboard()`, `accountAll(cursor, count)`, `accountArray(address[])`, `accountRange(minPts, maxPts, cursor, count)`.
  - Every call is paginated, so one call stays under 50% of the block gas limit and below $0.10. An off-chain bot is only the last resort.

## 5. DEX LP fuse (#25) — revised 2026-09-25 after Balancer v3 research
- **Pool:** a CurveYield DEX **ReClamm** pool, **cyavKAT / avKAT**. cyavKAT is registered WITH_RATE (rate provider = cyavKAT's share price) and has an ERC-4626 buffer (cyavKAT <-> avKAT) initialized on the DEX side. ReClamm allows **proportional liquidity only** (disableUnbalancedLiquidity; no single-token add or remove).
- **The vault moves avKAT only.** Through the DEX's **composite router**:
  - add: `addLiquidityProportionalToERC4626Pool` (wrap the cyavKAT side from avKAT through the buffer);
  - remove: `removeLiquidityProportionalFromERC4626Pool` (unwrap back to avKAT).
  - Proportional means no swaps and no swap loss.
- **Valuation (registered BALANCER market 36, custom balance fuse):** LP = BPT share × (raw avKAT + raw cyavKAT × cyavKAT's **net** rate), i.e. the avKAT the LP converts to at the rate.
  - It uses **raw** balances. IPOR's BalancerBalanceFuse multiplies rate-scaled balances by a rate-bearing price, double counting the rate.
  - The self-reference (cyavKAT held via the pool) settles like treasury shares; swaps inside the pool at the rate don't move it.
- **Withdrawals:** only to fulfil **scheduled** requests (never instant). If the buffer is short of avKAT, the unwrap redeems cyavKAT and pays its 1.25% instant fee, covered by the withdrawer's 8.75% scheduled fee (PPS rule).
- **Caps:** a protocol-owned-liquidity cap (share of managed avKAT) with a sub-cap per pool type; ReClamm is the only type for now.
- **Open:** (a) the cap size; (b) is cyavKAT's `paysYieldFees` on in that pool (part of the pool's cyavKAT yield goes to the DEX fee policy)? (c) the DEX must be deployed on Katana first (addresses of the composite router, pool and buffer).

## 6. Contract list (new)
- CyPlus vault (IPOR factory)
- CurveYieldPlusLoopController + fuses
- CurveYieldPlusFeeRouter
- CurveYieldPlusRebateRouter
- CurveYieldPlusYieldBooster
- CurveYieldSpecialRewards
- CurveYieldContributorsRewardFuse
- CurveYieldLeaderboard (season points tokens deployed per season, by a factory)
- CurveYieldDexLpController + fuses

All are gate-owned after the handover; every admin share and receiver is protected.

## 0. Design invariant (user, 2026-09-25)
**Once the system is complete, the vault PPS must never drop by a notable amount under any circumstances.**
- Every action that could lower PPS (unwind losses, early exits, de-leverage costs, conversions) is protected. It may only run when the caller, or the fee they pay, covers the full cost plus a margin.
- The only accepted exception is the Sushi LP position. It stays at a very low cap, and its accounting may be adjusted so that a PPS dip is mathematically impossible.

## 7. Decisions (answered)
| # | Decision |
|---|---|
| P4-1 | **Target LTV 70% of market value; de-lever at 72.2%.** Hard maximum 75.68% (0.86 × 0.88), so about 3.5 points of buffer at the de-lever line. That is about 3.33× leverage. |
| P4-2 | **cyavKAT+ pays the wrapper fees and uses the wcyavKAT market** (about 100% base APR × about 3.3× outweighs the fee and borrow costs). |
| P4-3 | **Holding points on cyavKAT = min(snapshot at epoch start, snapshot at epoch end).** Only **registered** addresses earn (a contract can't list holders). Public paginated `snapshotEpoch(cursor,count)` at each 2-week boundary (maintenance bot or anyone, with a caller reward) records balanceOf. No back-pay before registration on cyavKAT; exact votes-plugin history on cyavKAT+. |
| P4-4 | **Confirmed:** cyavKAT+ is primarily a contributor reward vault; the whitelist rebate router is the main deposit path. |
| P4-5 | **The on-chain referral system is 2-tier only** (40% / 20%). The whitelisted 10-layer partner program is **entirely off-chain**. A private GitHub workflow reads the on-chain referral links, computes the 10-layer points for whitelisted partners, and grants them through the leaderboard's **admin allocation** (`adminAllocate(address[], uint256[])`, called by a dedicated `pointsAllocator` key, a GitHub secret). The admin-allocation cap (5–30% of all points) therefore bounds it. No partner contract exists on-chain, and it isn't mentioned in public docs or the dapp. |
| P4-6 | DEX LP accounting in BALANCER (36) if IPOR's fuses accept our Vault; otherwise market 7 |
| P4-7 | Grand prize: pro rata to final season points of the top 100 |
| P4-8 | Build order #24 → #20 → #22 → #23 → #25 |

### Original suggestions (for reference)
| # | Question | Suggestion at the time |
|---|---|---|
| **P4-1** | cyavKAT+ loop target LTV (of market value; the hard maximum is 75.7%) | **62% target, 66% re-lever trigger, 70% emergency de-lever.** That leaves about a 7.7-point buffer to liquidation. |
| **P4-2** | Wrapper fees on cyavKAT+'s own collateral (2%/yr + 8% on about 4× leverage) | Exempt cyavKAT+. Either give the wrapper-market route a fee-free variant for whitelisted holders, which means a second **wrapper v2** market; or let cyavKAT+ borrow from a separate cyavKAT-collateral market that the main vault also lends to (market 41 supports several substrates). **Suggest the second market.** |
| **P4-3** | Holding points for **cyavKAT**, which has no on-chain balance history | Points on **min(balance at epoch start, balance at epoch end)**. You have to hold across the whole 2 weeks to earn, and gaming it costs a 1.25% instant-fee round trip. **cyavKAT+** uses exact votes-plugin history. |
| P4-4 | 35% deposit fee on cyavKAT+: intended as a partner/whitelist-only vault? | Confirm. Nearly all deposits would then go through the rebate router. |
| P4-5 | 10-layer referral rewards for whitelisted addresses | Keep it, but note that multi-level payouts can attract regulatory scrutiny (MLM-style). Maybe cap at 3 layers. |
| P4-6 | DEX LP accounting market | BALANCER (36) if IPOR's fuses accept our Vault address; otherwise market 7 |
| P4-7 | Grand prize payout rule | Pro rata to the season's final points for the top 100 |
| P4-8 | Build order | As the roadmap says: #24 → #20 → #22 → #23 → #25 |
