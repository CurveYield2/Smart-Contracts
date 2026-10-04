# Governance gate as the config registry — spec, APPROVED 2026-09-29 (implemented in phase2, see §9)

Goal: every numerical setting of the cyavKAT system lives in (or is reached through) the governance gate, with its
accepted range and its authority class, so there is one place to read, change, protect and audit the numbers.

## 1. Scope
- **In (read the gate):** every not-yet-deployed cyavKAT-side contract — vault executor, allocation controller, loop
  controller, vKAT controller, lending controller, Sushi LP controller, loop profit splitter, POL controller, POL custody,
  POL feeder, revenue custody v2, withdraw manager v2 — and governance / leaderboard / referrals (proposal bond, voter
  rewards, engagement rewards, leaderboard, referrals).
- **Kept in place, gate passthroughs (read + write through the gate):**
  - fuses, so they stay usable by other vaults: CurveYieldContributorsRewardFuse. (The live CurveYieldCallerRewardFuse
    and CurveYieldRouterSwapFuse are no longer used by cyavKAT from Phase 2: keeper rewards are gate keys, §9, and
    swaps go through router v2 / swap fuse v2, SWAP_ROUTING_SPEC.)
  - already-live contracts: wcyavKAT wrapper, live withdraw manager, live revenue custody (until v2);
- **Out:** the cyavKAT+ stack (Plus controller, Plus WM, deposit router, booster, special rewards).
- **Not numbers, unchanged:** the gate's own governance (DAO, guardian, fee authorities, protected roles), wiring
  addresses (executors, fuses, venues, destinations), ownership rules.

## 2. Registry model
- Each setting has an id `bytes32 key` (e.g. `keccak256("loop.targetLtvBps")`) and a record:
  `value`, `min`, `max` (the current range), `hardMin`, `hardMax` (immutable caps), `class` (FEE / DAO / GUARDIAN),
  `group` (for cross-setting rules), `guardianMin/Max`.
- **Hard caps (immutable):** every key carries the hard-coded limits the contracts enforce today (contract constants such
  as `MAX_REWARD_BPS`, `MAX_LTV_BPS`, `MAX_REVENUE_SHARE_BPS`, `MAX_MANAGEMENT_FEE_BPS`, and the deploy-time bounds in
  P2_01 / P5_01). They are set when the key is registered and can never change; every range and every value must stay
  inside them, so no one — DAO or fee authority — can set an unsafe value. The catalogue's "Range" column is the hard cap;
  the initial range equals it.
- **Policy (user, 2026-09-29): every key has a hard upper cap, and every value that affects user funds has one tighter
  than its natural limit.** New caps: instant withdraw fee ≤ 4%, request fee ≤ 12.5%.
- **Classes**
  - FEE: only a fee authority may set it (every admin-fee receiver share / percentage and every fee rate — today's
    protected-selector list, see §5). The DAO can never change it.
  - DAO: the DAO (through the gate's proposal path) or a fee authority.
  - GUARDIAN: as DAO, and the Optimization Guardian may also set it inside `guardianMin..guardianMax` (today's guardian
    lane: allocation / cap / decay / vault-floor settings).
- **Changing a range** (`setRange(key, min, max)`, always inside the hard caps; the current value must stay inside):
  the DAO may change the range of DAO and GUARDIAN keys; only a fee authority may change the range of FEE keys
  (protected admin-fee settings). Decided 2026-09-29 (G1).
- **Setting a value:** `set(key, value)` checks class, range and the key's group rule, then stores and emits
  `ConfigSet(key, old, new)`. Batch `setMany(keys, values)` validates each group after all writes (for sums).
- **Reading:** one struct getter per consumer (e.g. `loopParams()`, `polParams()`) so a contract reads all its values in
  one call; plus `get(key)` and `keys()` for tools and the dapp.

## 3. Group rules (validated by the gate)
- sums = 100%: loop profit split (growth / contributors / vault / rewards manager); leaderboard buy split.
- withdraw-manager fee split: each ≤ 50%, total ≤ 75%.
- orderings: loop rampStart ≤ rampEnd; loop target < emergencyTarget < emergency LTV; LP the same; POL minGain ≤ trigger;
  LP minBps ≤ maxBps; LP advantageStart ≤ advantageFull; revenue custody distribution pair within its min/max.
- leaderboard buy split: refused while a season is active (the gate asks the leaderboard).

## 4. Consumers
- Each in-scope contract drops its parameter storage, bound structs and numeric setters, stores `gate`, and reads its
  struct getter where it used its params. `setGate(address)` callable only by the current gate (so the gate can be
  replaced without redeploying consumers).
- Wiring setters (addresses) stay on the contracts, owned by the gate as today.
- Withdraw manager v2: `getWithdrawFee()` / `getRequestFee()` / fee split return the gate's values (the vault already
  reads them through the manager, so IPOR sees no difference).
- Executor: no settings of its own; keeper rewards are the gate's `exec.*` keys (§9). The withdrawal request fuse
  reads `exec.fulfilReward*` itself (it holds the gate address as an immutable; a gate migration redeploys it).

## 5. Passthroughs (values stay in the target contract)
`passSet(target, key, value)` / `passGet(target, key)`: the gate keeps, per passthrough key, the target, the setter /
getter selectors, the range and the class, and calls the target. Covers:
- Contributors Reward Fuse: grandPrizeBps (set once; DAO).
- wcyavKAT: managementFeeBps 0–5%/yr, performanceFeeBps 0–15% (FEE; the wrapper's own limits).
- Live withdraw manager and live revenue custody (until replaced): as their v2 keys (FEE).

## 5b. Not in the gate (user, 2026-09-29)
- IPOR management / performance fee: cannot be changed; not in the gate.
- Swap fee router (CurveYieldSushiV3FeeRouter `0x01F9…3582`: fees, routes, TWAP guards): stays configurable in the
  router by its current admin only.
- Router swap fuse `assumedFeeBps`: removed from the gate (to be replaced by the router's live fee, see the router /
  fuse rework proposal).
- LP `standardLossBps` / `scheduledLossBps`: replaced by the min-profit settings in §6, so an LP exit always leaves
  the vault the configured profit after its fee.

## 6. Key catalogue (in scope, read from the gate)
| Key | Range | Class | Consumer |
|---|---|---|---|
| wm.withdrawFee | 0–4% | FEE | WM v2 |
| wm.requestFee | 0–12.5% | FEE | WM v2 |
| wm.feeSplitBps[0..2] | each 0–50%, total ≤ 75% | FEE | WM v2 |
| alloc.vaultFloorBps | 10–50% | GUARDIAN | allocation |
| alloc.seasoningDays | 0–14 | DAO | allocation |
| loop.allocationBps | 0–80% | GUARDIAN | loop |
| loop.rampZoneBps | 0–50% | DAO | loop |
| loop.baseWindupProfitBps | 1–10% | DAO | loop |
| loop.rampStartProfitBps / rampEndProfitBps | 3–20% (ordered) | DAO | loop |
| loop.minUnwindProfitBps | 0.1–5% (allowed unwind loss = request fee − this; lossBufferBps removed) | DAO | loop |
| loop.targetLtvBps / emergencyTargetLtvBps / emergencyLtvBps | 50–76% / 50–76.8% / 50.01–76.9% (ordered) | DAO | loop |
| loop.ltvRebalanceToleranceBps | 0–5% | DAO | loop |
| loop.maxCycles | 1–16 | DAO | loop |
| vkat.allocationBps | 0–90% | GUARDIAN | vKAT |
| vkat.nativeExitMaxLtvBps | 75–76.2% | DAO | vKAT |
| vkat.deployWindow | 0–7 days | DAO | vKAT |
| lend.capBps | 0–55% | GUARDIAN | lending |
| lend.ownershipTriggerBps | 5–50% | DAO | lending |
| lend.decayBps | 0–25% | GUARDIAN | lending |
| lend.decayInterval | 1–48 h | DAO | lending |
| lend.liquidityFloorBps | 0–20% | DAO | lending |
| lend.ownershipExemptAvkat | 0–50,000 avKAT | DAO | lending |
| lp.minBps / maxBps | 0–55% (ordered) | GUARDIAN (max) / DAO | LP |
| lp.advantageStartBps / advantageFullBps | 0–500% (ordered) | DAO | LP |
| lp.minKatBps | 0–20% | DAO | LP |
| lp.minInstantProfitBps (instant LP exits: allowed loss = retained instant fee − this) | 0.1–5%, default 0.25% | DAO | LP |
| lp.minScheduledProfitBps (scheduled LP exits: allowed loss = request fee − this) | 0.1–5% | DAO | LP |
| lp.targetLtvBps / emergencyTargetLtvBps / emergencyLtvBps | 50–76.9% (ordered) | DAO | LP |
| lp.slippageBps | 0–1% | DAO | LP |
| lp.yieldWindow | 1–30 days | DAO | LP |
| split.growth / contributors / vault / rewardsManager | each 0–50%, sum 100% | FEE | splitter |
| pol.capBps | 0–10% | GUARDIAN | POL |
| pol.triggerBps | 0.5–20% | DAO | POL |
| pol.minGainBps | 0.1–10% (floor > 0: buybacks must increase PPS), ≤ trigger | DAO | POL |
| pol.maxPerRunBps (share of the POL position one buyback may convert) | 0–25%, default 10% | DAO | POL |
| pol.buybackBudgetBps (lifetime POL buyback budget, % of net POL contributed) | 0–50%, default 35% | DAO | POL |
| pol.cooldown | 1 h–7 d | DAO | POL |
| pol.minPolProfitBps | 0–5% | DAO | POL |
| pol.maxChargeDiscountBps | 0–30% | DAO | POL |
| pol.maxSlippageBps | 0.1–5% | DAO | POL |
| pol.twapWindow | 5 min–24 h | DAO | POL |
| pol.idleBuyback / maxIdleBps | on-off / 0–5% | DAO | POL |
| pol.addHaircutBps | 0–0.5% | DAO | POL |
| pol.yieldFeeBps | 0–20% | FEE | POL |
| polCustody.twapWindow | 5 min–24 h | DAO | POL custody |
| polCustody.maxSlippageBps | 0.1–5% | DAO | POL custody |
| polCustody.maxPremiumBps | 0–2% | DAO | POL custody |
| polFeeder.polBps | 0–30% | FEE | POL feeder |
| custody.revenueShareBps | 0–35% | FEE | revenue custody v2 |
| custody.rewardManagerDistributionBps | 10–30% | FEE | revenue custody v2 |
| custody.feeRecipientDistributionBps | 5–20% | FEE | revenue custody v2 |
| bond.bondAmount | 10–10,000 cyavKAT | DAO | proposal bond |
| bond.proposerReward | 0–1,000 | DAO | proposal bond |
| bond.intakeWindow | 1–30 days | DAO | proposal bond |
| voter.pool | 0–1,000 | DAO | voter rewards |
| voter.delegatorHaircutBps | 0–80% | DAO | voter rewards |
| voter.delegateeCutBps | 0–80% | DAO | voter rewards |
| engagement.minEpochInterval | 1–90 days | DAO | engagement rewards |
| leaderboard.buySplit[0..3] | each 0–50%, sum 100%, not during a season | FEE (admin leg) / DAO | leaderboard |
| referrals.claimFee | 0–100 cyavKAT | FEE | referrals |
| router.protectionBps | 0.3–3%, default 2% | DAO | swap router v2 |
| router.twapWindow | 1 min–4 h, default 15 min | DAO | swap router v2 |
| exec.deployRewardBps / deployRewardCap | 0–1% / 0–10 avKAT, default 0.2% / 10 | DAO | executor |
| exec.fulfilRewardBps / fulfilRewardCap | 0–1% / 0–10 avKAT, default 0.2% / 10 | DAO | withdrawal request fuse |
| exec.harvestRewardBps / harvestRewardCap | 0–1% / 0–10 avKAT, default 0.2% / 5 | DAO | executor (paid by swap fuse v2) |

## 6b. Settings removed (user, 2026-09-29)
- `exec.deployGuardDropBps`: deploys always run under a zero-drop guard.
- `pol.maxPremiumBps`: POL entries only ever buy cyavKAT at or below NAV.
- `loop.lossBufferBps`: the unwind loss a scheduled fulfilment may take is only `request fee − minUnwindProfitBps`
  (0 if the fee is below it), so no setting can make a fulfilment lower PPS.

## 9. Keeper rewards, harvest and fulfilment (approved 2026-09-29, implemented)
- **Caller Reward Fuse dropped from cyavKAT Phase 2.** Its economic settings are the `exec.*` keys above (rate hard cap
  1%, payout hard cap 10 avKAT; every payout is also capped by what the action gained, so no reward is paid out of
  principal). Its request-fee share logic moved to the withdrawal request fuse. It stays in use by cyavKAT+.
- **Deploy reward:** `min(deployed × deployRewardBps, deployRewardCap, the deploy's PPS gain)`, paid by the executor.
- **Harvest:** one reward bundle through the rewards claim manager — IPOR's official `MerklClaimFuse` claims (the
  claimed tokens stay in the vault), then swap fuse v2 `sweep` converts each listed token to avKAT through router v2
  (a token without a route, e.g. an LP token, is skipped), pays `min(out × harvestRewardBps, harvestRewardCap)` to the
  executor (forwarded to the caller) and sends the rest to the rewards claim manager to vest. The vault and the claim
  manager only ever hold avKAT, so no snapshot step is needed.
- **Withdrawal request fuse** (`CurveYieldWithdrawalRequestFuse`, the WM v2 `requestFeeFuse`):
  - request-fee shares: `moveRequestFeeShares`, `configureManagerAssetAllowance` (withdraw manager only);
  - fulfilment phase 1: `runSources` (the allocation controller's source order; planners granted type 6) and
    `runPolSale` (the POL controller's plan);
  - fulfilment phase 2: `settle` — the fulfilment's real profit (fee − loss − POL minimum − admin yield fee), the keeper
    reward `min(released × fulfilRewardBps, fulfilRewardCap, profit)` to the calling executor, the profit split legs.
  - The executor keeps the ordering, the PPS measurements and the withdraw-manager calls between the phases (release /
    charge run their own vault execution, and IPOR `execute` is non-reentrant).
- **Build:** the executor and WM v2 deploy from foundry `[profile.size]` (solc's default Yul sequence without the
  FunctionSpecializer, which cloned functions per constant-argument set): executor 22,680 bytes, WM v2 22,756 bytes.

## 7. Deployment and migration
- The gate deploys first; consumers take its address at construction.
- P2_01 / P2_02 / P3_* / P4_04 (governance, leaderboard, referrals parts) / P5_01 lose their `setParams` calls; the gate
  deploy registers every key with its range, class, group and initial value (today's defaults).
- P3_04's protected-selector list shrinks to ownership, wiring and the passthrough targets' own setters.
- Optimization Guardian: its action list for numeric settings is replaced by the gate's guardian ranges **[G2]**.

## 8. Tests
Class enforcement (DAO cannot set FEE keys; guardian only inside its range); range and group rules; batch sums;
season lock; every consumer reads the gate's values; passthrough reads / writes; `setGate` only by the gate.

## Decisions
- **G1** ~~Who changes ranges~~ — decided: DAO for DAO / GUARDIAN keys, fee authority only for FEE keys; all ranges
  bounded by immutable hard caps (today's hard-coded limits).
- **G2** ~~Guardian action list~~ — decided: replaced by per-key guardian ranges in the gate.
- **G3** ~~Classes~~ — decided: as proposed (FEE = protected list, GUARDIAN = guardian lane).

## 10. Wiring addresses (APPROVED 2026-10-03 — extends this spec; requirement: redeploy any single contract alone)
- The gate also holds the **stack-internal wiring**: `bytes32 key → address` (e.g. `keccak256("addr.lpController")`).
  Stack contracts read their stack dependencies with `gate.addr(key)` at call time (≈ 2–3k gas) instead of
  immutables. Replacing one contract = deploy it + `setAddr(key, new)`; nothing else is redeployed.
- **Not in the gate:** external protocol addresses (avKAT, KAT, Morpho, Sushi, the vault itself) stay immutable in each
  contract; fuses keep IPOR's add/remove model. The gate address itself is the one anchor every contract holds.
- **New class WIRING — DAO only** (the gate's proposal path), decided 2026-10-03. **No extra gate timelock:** the DAO's
  own process (proposal → vote → timelock) already gives the review window; a second delay was rejected as excessive.
- On-chain checks: the new address must have code; every change emits `AddrSet(key, old, new)` (bots/dashboard alert).
- Scope: the ≈ 20 contracts that today hold immutable pointers to other stack contracts (positions readers → LP / vKAT
  controllers, LP controller → withdraw manager, LP holder → controller, revenue custody v2 / swap fuse v2 → router,
  withdrawal request fuse → config gate / splitter / transfer fuse, governance → voting / lock / engagement / Safe,
  wrapper → fee splitter, …). Exact key list in the implementation pass.
