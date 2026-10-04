# cyvbWBTC — fxUSD earn pool + automated scheduled withdrawals — spec v1 (DRAFT, awaiting approval)

## Decisions (user, 2026-10-04)
- Borrowed fxUSD is split between two strategies: the f(x) fxUSD stability pool **fxBASE**
  (`0xdE2E0736Ee813C425b0eE1a6e0627233B3B1EeF8`, "earn pool") and **cyvbUSDC**. Configurable. **Launch: 0% earn** (the fxBASE gauge has never distributed rewards - checked on-chain 2026-10-04; f(x) team contacted); **60% / 40%** once the gauge is funded (new fuse version).
- fxBASE instant redemption costs 1% (`instantRedeemFeeRatio`), so the earn pool is **not** an instant-withdrawal source.
  Withdrawals that need it use a **scheduled withdrawal**: the keeper bot automatically frees the funds and releases
  them (~1 hour); the user then claims with `redeemFromRequest` as usual.
- Fees: **0.75% onboarding** (covers the ~0.67% full-swap deploy cost at 0% earn; can drop to ~0.5% once the earn leg is on), **1.00% instant withdrawal**, **0.50% scheduled withdrawal** (instant must cost more than scheduled).

## Live facts (Katana, 2026-10-04)
- fxBASE: deposit `fxUSD` or `vbUSDC` → shares; `requestRedeem(shares)` then `redeem(receiver, shares)` after
  `redeemCoolDownPeriod` = 3,600 s, fee-free; redemption pays a pro-rata **mix of fxUSD and vbUSDC**.
  A new `requestRedeem` resets the 1 h timer for everything pending (keeper batches). Requests never expire.
- TVL today ≈ $162 (124 fxUSD + 38 vbUSDC) — the displayed ~20% APR is a small reward stream on tiny TVL; our
  deposit will dilute it. Reward source / claim path: TBD (needed for the harvest leg).
- It is a stability pool: it absorbs f(x) rebalances/liquidations (some fxUSD may be converted).

## 1. Capital deployment (`deployFreshCapital`, `rebalanceLtv` low branch)
Borrowed fxUSD (one `operate()`, as today) is split:
- `EARN_BPS` (default 6,000) → **fxBASE.deposit(vault, fxUSD, amount, minShares)** — fxUSD goes in directly, **no
  fxUSD→vbUSDC swap** (avoids the ~1.1% fxUSD discount on that part).
- the rest → swap fxUSD→vbUSDC → deposit into cyvbUSDC (unchanged).
`EARN_BPS` is a fuse immutable (0–10,000), like the LTV policy: changing it = installing a new fuse version (fuse
manager). A keeper `rebalanceSplit` moves value between the two legs when they drift (later, optional).

## 2. Accounting (`FxMintCyvbWbtcBalanceFuse` v5)
Adds the fxBASE leg: `previewRedeem(shares)` → fxUSD + vbUSDC, valued at $1 each (fxUSD at face, consistent with
how the fxUSD debt is valued) — plus shares locked in a pending redeem request (still owned by the vault).

## 3. Instant withdrawals (unchanged sources)
Collateral-only → else repay with the **cyvbUSDC leg** + withdraw collateral in one `operate()`. The earn pool is never
touched instantly. Instant capacity ≈ what the cyvbUSDC leg can repay (~40% of the debt) plus the collateral-only
headroom; anything larger reverts → the user uses a scheduled withdrawal.

## 4. Scheduled withdrawals — custom withdraw manager, no bot
`CyvbWbtcWithdrawManager_v1`: IPOR's WithdrawManager logic (requests, withdraw window, releaseFunds, the vault's
canWithdrawFromRequest / canWithdrawFromUnallocated hooks) plus the scheduling, installed with IPOR's
UpdateWithdrawManagerMaintenanceFuse and granted ALPHA. Auth is checked in-contract (vault-only hooks; ATOMIST for fee
and window setters via the vault's access manager) because factory clones have no access-manager admin to map a new
manager's functions.
1. **Request (1 tx):** `requestShares(shares)` records the request and takes the 0.75% request fee by pulling the fee
   shares from the user (share approval to the manager, set once in the dapp; IPOR's transferRequestSharesFee needs a
   technical role only the factory manager can hold). It then **starts the earn redeem itself**: `vault.execute` →
   strategy fuse `requestEarnRedeem` (gauge unstake + `fxBASE.requestRedeem` sized from all pending requests).
2. **After the 1 h cooldown (permissionless):** `finish()` → `vault.execute` → strategy fuse
   `completeScheduledWithdrawal`: `fxBASE.redeem` → fxUSD (+ vbUSDC → fxUSD) → one `operate(pos, -coll, -debt)` freeing the
   vbWBTC for all pending requests at or below the LTV target; burns the held fee shares
   (IporBurnRequestFeeFuse_v1); then the manager releases the funds. The dapp sends `finish()` + the user's
   `redeemFromRequest` together (finish can't run inside the redeem: IPOR's vault shares one reentrancy lock between
   withdrawals and execute). Anyone's finish settles every matured request.

## 4b. Rewards (gauge, weETH)
fxBASE shares are staked in the fxBASE gauge (`0x76a84525c5f61136cf562dc1bd5abb19fb8b53fc`, reward token weETH
`0x9893989433e7a383Cb313953e4c2365107dc19a7`) — unstaked only for a scheduled redeem. A reward fuse (cyvbUSDC
KatRewardSwapAndSplitFuse pattern) claims weETH, swaps it to vbWBTC through the CurveYield router (route needed:
weETH→vbWBTC) and sends 70% to the RewardsClaimManager (vests into PPS) / 30% to the fee Safe — same split as cyvbUSDC.
Note: the gauge's weETH reward rate read 0 on 2026-10-04 (stream not currently funded).

## 5. Fees summary
Onboarding 0.75% (burned for holders via `IporBurnRequestFeeFuse_v1`), instant 0.75% (burned on exit), scheduled 0.75%
(request fee, burned in finish). Management/performance unchanged.

## Open questions
1. 70/30 weETH reward split (as cyvbUSDC) — confirm.

## PPS guard (2026-10-04)
deployFreshCapital and completeScheduledWithdrawal snapshot PPS, burn the fee shares the withdraw manager holds, act, and revert if PPS ends lower; instantWithdraw reverts if the unwind costs more than requested x instant fee (burned by the vault right after). rebalanceLtv is intentionally unguarded (deleveraging must always work).

Performance fee (user, 2026-10-04, option A): the PPS rise from burning onboarding / request fee shares counts as holder income, so IPOR's 10% performance fee applies to it at the next interaction (~0.1% of the burn gain's PPS, never below the pre-burn PPS). Accepted - not treated as a PPS drop.

Deploying capital is chunked: `deployFreshCapital(amount, ...)` burns the chunk's pro-rata share of the fee shares; the keeper deploys in chunks the fee covers (fxUSD/vbUSDC slippage grows with size).
