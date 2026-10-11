# cyavKAT + cyavKAT+ — audit test plan (2026-09-29)

Repo: `C:\Users\user\Documents\Codex\2026-09-02\th\work\phase2` (Foundry, via-IR). Tests go in `test/` (empty today).
Specs: `C:\Users\user\Documents\Codex\2026-09-02\th\work\cyavkat-system-docs` — GATE_CONFIG_SPEC, SWAP_ROUTING_SPEC,
PPS_PROTECTION_SPEC, POL_SPEC, PHASE2..4_DESIGN_SPEC. Older tests to adapt (pre-standardization, may not compile as-is):
`_pre-standardization-2026-09-27/test/` (Phase2Fork, Phase2EdgeFork, Migration*, plus/*, governance/*, leaderboard/*).

## Rules
- Never broadcast; never read `C:\Users\user\Documents\Codex\deployer_key.txt`; never print keys from `.env`.
- RPC: `KATANA_RPC_URL` from `C:\Users\user\Desktop\Claude\.env` (private dRPC). Runner: `bash run-tests.sh [match] [trace]`.
- Do not change `src/` to make a test pass. If a test exposes a contract bug, stop and report it (test name, trace).
- Executor + WM v2 are deployed from the `size` profile (`FOUNDRY_PROFILE=size forge build src/executor/CurveYieldVaultExecutor.sol src/withdraw/CurveYieldWithdrawalManagerV2.sol`) — fork setups that run P2_01 need that build first.
- Invariant everywhere: vault PPS never drops except the IPOR management fee (assert assets-per-share ≥ before).

## Job 1 — unit tests (no fork)
1. `CurveYieldGovernanceGate` config registry: `registerConfig` once per key (fee authority only); `setConfigs` class
   rules (FEE keys fee authority only; DAO keys DAO or fee authority); values inside range, ranges inside immutable
   hard caps; `setConfigRange` (DAO for non-FEE, fee authority for FEE); guardian `setConfigByGuardian` only inside
   guardian range; group rules SUM_EQ / SUM_LE / ORDER_LE / ORDER_LT / EACH_LE / LOCK checked after the whole batch;
   `getMany` order; `registerArgRange` / `setArgRange` passthrough checks on `execute`, `executeProtected`,
   `executeGuardian`; protected calls unreachable by the DAO.
2. `CurveYieldGateConfig`: `setConfigGate` only by the current gate.
3. `CurveYieldSwapRouterV2` pure parts with mock pools: flat 0.1% fee to `feeRecipient`; min out = max(protected,
   caller min); `protectionBps` / TWAP window read from the gate; route set / remove; only owner sets routes;
   `setFeeRecipient` only owner.
4. `CurveYieldWithdrawalManagerV2` fee math with the gate set and unset (own storage): `_withdrawFee`, `_requestFee`,
   splits; `updateWithdrawFee` reverts `FeesInGate` when the gate is set; escrow / refund / earn of request fees.

## Job 2 — Katana fork suite (full stack, real scripts)
Setup: fork Katana; run `P0_00_DeployGateConfig`, `P2_01_Deploy`, `P2_02_ConfigureVault`, `P2_03_Cutover` with
`PHASE0_DEPLOYMENTS` / `PHASE2_DEPLOYMENTS` pointed at `deployments/test-*.json` (never the katana-*.json files).
1. Deploy: `deployAssets` with no requests (steps or NothingToDeploy); keeper reward ≤ gate cap and ≤ PPS gain.
2. Scheduled withdrawals: `requestShares` then (after ≥ 1 s) `fulfillAll`, `fulfillFor(requester, shares)`,
   `fulfillFor(…, maxChargeShares)`: request fee burned → PPS up; keeper reward = min(released × 0.2%, cap, profit);
   profit split legs paid; loss above the allowed fee reverts `UnwindLossAboveFee`.
3. Harvest: `RewardsClaimManager.claimRewards([swapFuseV2.sweep(...)])` with reward tokens dealt to the vault:
   swapped to avKAT through router v2, keeper reward to the executor → caller, rest to the RCM; token with no route is
   skipped (emits `RewardSweepSkipped`, no revert). `MerklClaimFuse` is added as a reward fuse.
4. Router v2 on the fork: avKAT↔KAT Sushi route, 0.1% fee, protected minimum (sandwich: move the pool first → revert).
5. Emergencies: `emergencyRepay` / `lpEmergency` loss covered by backstops then the caller (≤ max), else revert.
6. Native-exit lane: start / begin / complete / completeEarly keep PPS ≥ start.
7. Instant withdrawals through the configured instant-withdraw fuses.
8. POL (after `P5_01`): buyback only if PPS strictly rises (≥ minGain); lifetime budget; POL-funded fulfilment.
9. Gate governance (after `P3_03`–`P3_05`): router v2, executor, controllers owned by the gate; router v2
   `setFeeRecipient` protected; guardian ranges enforced.

## Job 3 — cyavKAT+ (Plus stack, `P4_*`)
Adapt `_pre-standardization-2026-09-27/test/plus/*`: Plus vault deposit / loop / deleverage with the emergency-fee
arm fuse (D3: cyavKAT+ exempt from cyavKAT instant fee only while deleveraging above its LTV), Plus executor, rewards,
leaderboard / referrals (buy split locked during a season).

## Report back
Per job: files added, pass / fail counts, and any contract behaviour that contradicts the specs (with traces).
