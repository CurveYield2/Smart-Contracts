# Protocol-owned liquidity + buyback-and-burn (#25 revised) — spec, APPROVED 2026-09-27 (all decisions in)

Replaces PHASE4 #25 (ReClamm). Two LP positions, plus a buyback-and-burn that turns LP back into cyavKAT and burns
it when cyavKAT trades below its deposit rate.

## 1. Positions
| # | Position | Venue | Tokens | Owner | Accounting |
|---|---|---|---|---|---|
| A | Gyro E-CLP pool | CurveYield DEX (Balancer v3 fork + upstream `pool-gyro`) | cyavKAT / avKAT | the cyavKAT vault (BPT) | IPOR market 36 (BALANCER), custom balance fuse |
| B | Our own Charm Alpha Vault on the Sushi V3 **0.3%** pool | Sushi V3 + Alpha Vault (our bot = manager) | cyavKAT / WETH | **POL custody** (new), not the vault | **not accounted in the vault** |

**Position A** is funded from vault idle avKAT within its cap (% of managed avKAT, configurable). It is a withdrawal
source under the 0.5%-profit rule (section 3c). The pool is created manually by the operator; the system only
deposits into / exits from the configured pool address (no pool parameters in the system).

**Position B** is off the vault's books (only-up share policy: its ETH exposure never touches PPS). It is funded only
from a share of gains, through a new **CurveYieldPolFeeder** placed in front of the live profit custody `0xe7D1`
(the custody keeps running its avKAT/KAT Morpho loop unchanged):
- *incoming*: the loop profit splitter's growth-custody leg is re-pointed to the feeder; the feeder sends
  `polIncomingBps` to the POL custody and the rest on to the profit custody.
- *earned yield*: the custody's own wind-up fee share (`feeRecipient`, 5–20% of each custody loop, 9% today) is
  re-pointed to the feeder; it sends `polYieldBps` to the POL custody and the rest to the previous fee recipient.
  Admin-fee rule: re-pointing and `polYieldBps` are fee-authority only (custody owner = fee Safe).
- **CurveYieldPolCustody** swaps what it receives (avKAT) into cyavKAT + WETH at the Alpha Vault's ratio
  (TWAP-guarded) and deposits. Owner: fee Safe / fee authority. Exits go only to the fee Safe, or into
  buyback-and-burn (section 4).

## 2. cyavKAT is always BOUGHT, never minted
To build a position, avKAT is swapped for cyavKAT on the market (best of the Gyro pool and Sushi pools, TWAP-guarded)
— never deposited into the vault. No shares are minted, so there is no deposit loop and no fee/cap/whitelist
interaction. WETH for position B is also bought with avKAT (Sushi, TWAP-guarded).

## 3. Valuation (position A; conservative, PPS-never-drops)
- cyavKAT inside the pool = the vault's own shares, valued at the vault's actual share deposit rate (convertToAssets), hard-set in the balance fuse (never a market or oracle price).
- avKAT at face value. Amounts = the pool's proportional-exit amounts for the vault's BPT (raw balances x the net
  rate; avoids IPOR's BalancerBalanceFuse, which double-counts WITH_RATE tokens).

## 3b. Standard exits (withdrawals, cap reductions, converting POL) — cheapest path, fee ignored
Proportional exit, avKAT leg kept, then the cyavKAT leg goes by whichever is better for the vault:
- **Market sale** (TWAP-guarded, slippage cap) — used only when its avKAT proceeds exceed the leg's value at the
  net rate (a gain for the vault).
- **Instant withdrawal**, the withdraw fee ignored (it stays with vault holders) — used otherwise. Done so that no
  value leaves the vault through a fee split or a profit calculation:
  - *Position A (vault-owned)*: the vault's own shares are **burned directly** through the IPOR burn path
    (withdraw manager + BurnRequestFeeFuse). It never calls `redeem`, so there is no withdraw-manager fee, no
    admin/special/booster split, no profit-custody cut and no profit booking. Valued at the net rate (<= PPS), the
    burn is PPS-neutral or positive. Any avKAT the withdrawal needs comes from the other sources (normal plans).
  - *Position B (POL custody, a normal holder)*: redeems through the vault's instant withdrawal. Withdraw manager
    v2 gets a `burnOnlyFee[account]` flag (owner/DAO, reversible) set for the POL custody: its whole fee is burned
    (PPS up), nothing goes to admin, special rewards, booster or the profit custody, and nothing is booked as
    profit.
- Invariant (tested): no POL exit or conversion lowers PPS or pays admin / custody out of vault value.

## 3c. Withdrawals funded from POL: the vault keeps at least 0.5%
`cost` = everything the vault gives up to turn the needed POL into avKAT for the requester: LP exit fees, the
cyavKAT leg's shortfall vs its net-rate value when sold, swap fees and slippage. `fee` = the withdraw fee the
requester pays (it stays with the vault's holders). Rule: `fee - cost >= minPolProfitBps x amount` (default 50 = 0.5%).
- **Instant withdrawals**: POL is used as an instant source only when the rule holds for that withdrawal; otherwise
  it is skipped (other instant sources, or the request goes to the scheduled queue).
- **Executor `fulfillFor(requester, shares)`** (withdraw a specific request): may draw from POL even when the rule
  fails; the missing part (`cost + minPolProfitBps x amount - fee`) is **charged to that requester** (deducted from
  their payout and kept by the vault), so the vault still ends with >= 0.5%. The charge is quoted by a view first
  and bounded by a max the caller passes.
- Other scheduled fulfilment (`fulfillAll`) uses POL only when the rule holds.

## 4. Buyback-and-burn (the ONLY path that turns LP into cyavKAT)
Active only while market price <= deposit rate x (1 - `triggerBps`); deposit rate = avKAT per cyavKAT at the net
rate (what a depositor gets).
`buybackBurn(position, lpAmount)`:
1. Withdraw `lpAmount` from position A (vault) — or from B (POL custody, if `polBuyback` is on).
2. Swap the non-cyavKAT legs (avKAT, WETH) for cyavKAT on the market (TWAP-guarded, slippage cap).
3. Burn all of it through the vault's IPOR burn path (withdraw manager + BurnRequestFeeFuse): shares down, PPS up.
4. Reverts unless the effective price paid per cyavKAT (all legs, all costs) is >= `minGainBps` below the deposit rate.

Automatic inside `deployAssets()`: when triggered, up to `maxPerRunBps` of the position per run, once per `cooldown`,
positions in `priority` order. Market price = cyavKAT/avKAT TWAP from the Gyro pool (fallback: Sushi pools via the
oracle). Optional `idleBuyback` (default off): also buy with vault idle avKAT above the floor, up to `maxIdleBps`.

## 5. Parameters (owner / DAO, within bounds, all reversible)
| Parameter | Default (proposed) | Bounds |
|---|---|---|
| capBps A (of managed avKAT) | 3% | 0–10% |
| yieldFeeBps A (LP fees to admin) | 10% | 0–20% (fee authority) |
| polIncomingBps / polYieldBps (feeder) | 20% / 15% | 0–100% (polYieldBps: fee authority) |
| minPolProfitBps (withdrawals from POL) | 50 (0.5%) | 0–500 |
| burnOnlyFee[POL custody] (WM v2) | on | on/off |
| triggerBps | 300 (market >= 3% under the deposit rate) | 50–2,000 |
| minGainBps (after all costs) | 100 | 0–1,000 |
| maxPerRunBps (of a position) | 2,500 | 0–10,000 |
| cooldown | 12 h | 1 h–7 d |
| priority / polBuyback | A then B / on | any order / on-off |
| idleBuyback / maxIdleBps | off / 1% | 0–5% |
| swap slippage cap / TWAP window | 100 bps / 30 min | 10–500 bps / 5 min–24 h |

## 6. Decisions (2026-09-27)
1. Gyro E-CLP pool cyavKAT / avKAT: created manually by the operator (range and factory are the operator's); the
   system takes the pool address as configuration and only deposits / exits.
2. Sushi V3 cyavKAT/WETH pool: **0.3%** fee tier (to be created and seeded).
3. Charm: **our own Alpha Vault instance**, our bot as manager.
4. Position B: **not accounted**; funded only from a share of gains via the feeder (section 1).

5. Feeder defaults 20% incoming / 15% yield, configurable. Exit rule (3b): cheapest path, fee ignored, no fee leakage.
6. POL withdrawals keep the vault >= 0.5% (3c); `fulfillFor` passes the extra cost to the requester.

## 7. Build plan (after approval)
Contracts: POL controller (position A: cap, exits, triggers, plans) + fuses (buy, add/remove A, sell for exits,
buyback-burn), market 36 balance fuse (A), executor hook in `deployAssets()`; CurveYieldPolFeeder;
CurveYieldPolCustody (position B: swaps, Alpha Vault deposit/withdraw, buyback-burn). Scripts: Alpha Vault deploy
(Charm contracts, unmodified), feeder + custody wiring (splitter destination; custody.setFeeRecipient by the fee
Safe). Tested on a Katana fork against a local CurveYield DEX (+ pool-gyro) and a local Alpha Vault, with venue
addresses as inputs.

## 8. Implemented (2026-09-27; compiles, not yet tested — the audit covers testing)
Deploy order: P2_01 → P2_03, P2_04, P3_01 → P3_04, P4_01 → P4_04, **P5_01**, P3_05, P4_05 (rollbacks P3_99 / P4_99; POL
contracts included). Wrapper fee fix: L10 (40/40/20, live-ready).

| Contract | File | Role |
|---|---|---|
| CurveYieldPolController | src/pol/CurveYieldPolController.sol | Position A: venues, params, valuation (net rate), cost basis, plans, triggers |
| CurveYieldPolFuse | src/pol/CurveYieldPolFuse.sol | Market 36: enter / exit / buyback / burnHeld / instantWithdraw / payYieldFee |
| CurveYieldPolBalanceFuse | src/pol/CurveYieldPolBalanceFuse.sol | Market 36 value: BPT share of raw balances, cyavKAT at the net rate |
| CurveYieldPolCustody | src/pol/CurveYieldPolCustody.sol | Position B (off-books): buys cyavKAT (POL pool) + WETH (best Sushi route), Alpha Vault; exits to avKAT; no burning |
| CurveYieldPolFeeder x2 | src/pol/CurveYieldPolFeeder.sol | incoming 20% (splitter growth leg), yield 15% (profit custody fee share) to the POL custody |
| CurveYieldSwapLib / PolPriceLib | src/pol/ | best-of-routes Sushi swaps (QuoterV2) + TWAP guard; Balancer v3 swaps (Permit2); deposit / market rate |
| WM v2 additions | src/withdraw/CurveYieldWithdrawalManagerV2.sol | burnOnlyFee (armed per redemption, transient), chargeRequest (fulfillFor charge, burned) |
| Executor additions | src/executor/CurveYieldVaultExecutor.sol | POL in deploy/reduce, maintenance (burnHeld + buyback, try), PPS-based loss, POL withdrawal step, fulfillFor(…, maxChargeShares) |

Final rules as built:
- Yield fee (10% to the fee Safe, fee authority): only on REAL profit of withdrawals (withdraw fee − POL cost, above the
  0.5% floor) and buybacks (net value of cyavKAT bought − avKAT spent). Never on cap reductions, never on value already in PPS.
- Withdrawal sale floor = BPS² / (BPS + h), h = fee − minPolProfit: the vault provably keeps >= 0.5% of what POL provides.
- avKAT → WETH routes: avKAT/KAT 1% → KAT/WETH 0.05%, and avKAT/KAT 1% → KAT/USDC 0.05% → USDC/WETH 0.05%; best quote wins.
- Only the vault-owned position (A) burns; the POL custody never does.
- POL custody `migrate(newCustody)` (owner, fee authority): moves the Alpha Vault shares + all avKAT / cyavKAT / WETH.
  Afterwards re-point both feeders (`setConfig`) and move `burnOnlyFee` on the withdraw manager to the new custody.


## Amendment 2026-09-29 — lifetime POL buyback budget (user decisions)
- **Net POL contributed** (`netContributed`): + every avKAT deposited into position A (entries); − the value of every
  non-buyback exit (cap reductions, POL-funded withdrawals, deallocation, migration). Buybacks never change it.
- **Budget:** `buybackBudgetBps` (default 35%, hard cap 50%) × netContributed. `convertedToBuybacks` (cumulative value
  of POL exited for buybacks) may never exceed it; a buyback that would cross it is sized down to fit; when the budget
  is below what was already converted (e.g. after a deallocation), POL buybacks stop until new entries raise it.
- **Per run:** `maxPerRunBps` (default 10%, hard cap 25%) of the POL position per automatic buyback, as before.
- **Idle buybacks are separate** (vault idle, `idleBuyback` / `maxIdleBps`): they do not count against this budget and have no lifetime cap (user, 2026-09-29): spending idle avKAT on cyavKAT below NAV and burning it removes the matching liability (fewer shares that could claim vault funds), so PPS does not fall; the per-run cap `maxIdleBps` (≤ 5%) and the off-by-default switch remain.
- Both counters live in the POL controller, updated by the executor after each successful bundle (entry, exit,
  buyback), measured from the bundle's actual amounts.
- **Buybacks must always increase PPS (user, 2026-09-29).** Every buyback bundle (POL and idle) is guarded with a
  required increase, not just "no drop": the guard's `minAssetsPerShareDelta` = the plan's guaranteed net gain
  (minimum cyavKAT bought x deposit rate - avKAT spent - admin yield fee), so the bundle reverts unless the share price
  rises by at least that. `minGainBps` gets a hard floor above 0 (proposed 0.1%; range 0.1-10%), so a buyback at NAV
  (zero gain) can never be configured.
