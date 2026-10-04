# Vault swap routing — router v2 — spec, APPROVED 2026-09-29 (implemented in phase2)

One new router for every vault swap, on Sushi V3 and on the CurveYield DEX (Balancer V3), with one flat admin fee
and a manipulation-resistant minimum on every route. Replaces the adapter / route-registry draft.

## 1. CurveYieldSwapRouterV2
- **Routes are multi-hop and may mix venues** (user, 2026-09-29): a route is an ordered list of hops, each one of
  - SUSHI hop: one Sushi V3 pool (token pair + fee tier), executed directly with the V3 swap callback (only from the
    Katana Sushi factory's deterministic pools, as today);
  - BALANCER hop: one CurveYield DEX pool, executed through the Balancer V3 Router (`swapSingleTokenExactIn`, Permit2).
  The router holds the intermediate tokens between hops; nothing may remain in it after the swap.
- **Fee: a flat 0.1% on every swap, hard-coded** (constant, no setters, no per-route fee), taken from the output and
  sent to the fee receiver. Only the fee receiver is settable, by the fee authority.
- **Protected minimum per swap** (the router enforces max(protected minimum, caller's `minNetAmountOut`) on the final
  output): the expected amount is chained hop by hop, each hop valued manipulation-resistantly —
  - SUSHI hop: that pool's TWAP over the router-wide window, minus the pool fee;
  - BALANCER hop: the pool hook's time-weighted expected output (`quoteOracleProtectedSwapOut`); reverts if the hook is
    not warm —
  then minimum = final expected × (1 − protection) × (1 − 0.1%), with ONE protection setting for the whole router
  (0.3–3%, applied once per swap, whatever the number or kind of hops). Intermediate hops carry no minimum of their own;
  any hop being moved shows in the final output check.
- **Same external interface as v1** where it exists, so existing callers work unchanged: `routeFor`,
  `twapMinimumOut(tokenIn, tokenOut, amountIn)` (now = the protected minimum for either venue),
  `swapExactInput(tokenIn, tokenOut, amountIn, minNetAmountOut, recipient, deadline)`. New: `routeVenue(tokenIn,
  tokenOut)`, `quoteExactInput(tokenIn, tokenOut, amountIn)` (spot, for planning only).
- **Settings** (owner = the governance gate, decided 2026-09-29): per route the hop list; one router-wide Sushi TWAP
  window `twapWindow` (1 min–4 h, DAO class, in the gate; Balancer hops use their hook's own oracle window); one router-wide `protectionBps`, range 0.3–3%, held in the gate (DAO class).
- Reentrancy lock, deadline, exact input / output balance checks, no residue — as v1.

## 2. Vault swap fuse v2 (`CurveYieldRouterSwapFuseV2`)
- Calls router v2 only; the minimum passed is max(the router's protected minimum, the plan's own floor — e.g. POL's
  NAV-based floor).
- Keeps the loop library's quote surface (`quoteExactInput`, `requiredInput` and their view versions), computed from
  router v2's protected minimums, so `CurveYieldMorphoLoopLib` and the loop fuses work unchanged.
- No stored economic settings (no assumed fee, no slippage): both come from router v2.
- Replaces, in Phase 2: the router swap fuse `CurveYieldRouterSwapFuse` and the POL `CurveYieldBalancerV3SwapFuse`.
- **Harvest sweep** (`sweep(tokens, asset, rewardBps, rewardCap, rewardRecipient)`, a rewards-claim-manager reward
  fuse, run after IPOR's `MerklClaimFuse` in the same bundle): each listed token except the asset is swapped in full
  through router v2 (protected minimum; a token without a route is skipped, never reverting the harvest); the keeper
  reward (gate `exec.harvestReward*`) goes to the granted recipient (type 3, the executor), the rest to the rewards
  claim manager to vest. Constructor: `(marketId, substrateMarketId, router)`.

## 3. Who uses it
- cyavKAT Phase 2: loop, lending, vKAT, POL plans (through the swap fuse v2).
- Revenue custody v2: its router address points at router v2 (same `twapMinimumOut` / `swapExactInput` calls).
- The live swap fuse `0x1fB8…` and the live custody keep the v1 router until the Phase 2 cutover (their router address
  is immutable).
- The DEX's own fee settlement keeps its adapters; router v2 is for the vault stack.

## 4. PPS
The fee and the swap price are part of each swap's cost and stay inside the existing protections (wind-up profit
gate, request fee covering unwind loss, buyback required-increase guard).

## 5. Tests (fork)
Sushi-only, Balancer-only and mixed routes (e.g. avKAT → KAT on Sushi → X on a DEX pool): protected minimum enforced, 0.1% fee to the receiver, sandwich (spot moved first) reverts; cold hook
reverts; v1-compatible calls from the custody; loop wind-up / unwind and POL entry / exit / buyback through fuse v2.

## Decisions
- **R1** ~~Route venues~~ — decided: multi-hop routes mixing Sushi and CurveYield DEX pools.
- **R2** ~~Protection settings~~ — decided: router owned by the gate; one router-wide protection setting, 0.3–3%.
