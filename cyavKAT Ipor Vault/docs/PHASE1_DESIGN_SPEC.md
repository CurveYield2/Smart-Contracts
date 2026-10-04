# Phase 1 design spec: configuration quick wins

Status: **approved 2026-09-24** (P1-5 sized to 100 slots) · 2026-09-24 · vault cyavKAT `0xEd83daf48429cfb2C650Fd721b9241e180fd4548` (Katana)

Scope: spec items #1, #2, #3a, #5a, plus one operational fix found during planning (P1-5). There is **no new contract code**. Every change is a call to an existing setter, sent from the deployer `0x11b7…FA35`. Each call was simulated from the deployer against live state today and passes.

## 1. Changes

| ID | Spec | Contract | Call | Current | New | Access (verified) |
|---|---|---|---|---|---|---|
| P1-1 | #1 instant withdraw fee | WithdrawalManager `0x59B3…40AE` | `updateWithdrawFee(uint256)` | 0.009e18 (0.9%) | **0.0125e18 (1.25%)** | access-manager template permission; deployer OK |
| P1-2 | #2 scheduled withdraw fee | WithdrawalManager | `updateRequestFee(uint256)` | 0.039e18 (3.9%) | **0.045e18 (4.5%)** | same |
| P1-3 | #3a unwind economics | MorphoStrategyFuse `0x79E8…d705` | `setWithdrawalEconomics(requestFeeBps, minProfitBps, lossAllowanceBps)` | (390, 125, 265) | **(450, 50, 400)** | owner = deployer |
| P1-4a | #5a swap slippage KAT→avKAT | RouterSwapFuse `0x1fB8…b3Ff` | `setRouteProtection(KAT, avKAT, 0, 30)` | (0, 100) | **(0, 30)** | role 300; deployer holds it with no delay |
| P1-4b | #5a swap slippage avKAT→KAT | RouterSwapFuse | `setRouteProtection(avKAT, KAT, 0, 30)` | (0, 100) | **(0, 30)** | same |
| P1-5 | ops (TWAP reliability) | Sushi 1% avKAT/KAT pool `0x8640…3B13` | `increaseObservationCardinalityNext(100)` | 1 | **100** | permissionless |

## 2. What each change does

**P1-1 instant fee 1.25%.**
- Charged on `redeem` when idle avKAT or instant vKAT conversion covers the withdrawal.
- 30% of the fee goes to the ProfitCustody (`revenueShareBps` 3,000). The rest stays in the vault as share value.

**P1-2 scheduled fee 4.5%.**
- Escrowed when `requestShares` is called.
- Earned once the request is released. Refunded if the request expires unreleased.
- Only applies to requests made after the change. There are 0 active requests today, so no one is affected mid-request.

**P1-3 unwind economics.** The Morpho fuse treats the scheduled fee as the budget for unwind losses.
- The effective loss allowance is `min(requestFeeBps − minProfitBps, lossAllowanceBps)` = min(450 − 50, 400) = **400 bps (4%)**.
- The vault always keeps at least **0.5%** of each fulfilled request as profit.
- `requestFeeBps` **must equal the withdraw manager's request fee**. P1-2 and P1-3 therefore ship in the same run so they never disagree.

**P1-4 slippage 0.3%.**
- The fuse's minimum output becomes the higher of two floors:
  - the live QuoterV2 quote − 0.3% (the quote already includes the 1% pool fee);
  - the router's TWAP floor, which is 3.3% below the 15-minute TWAP.
- The quote and the swap happen in the same transaction, so 0.3% only guards against the pool moving between quote and swap inside the transaction. It does not add friction to normal swaps.

**P1-5 pool price history.**
- Today the 1% pool stores one price reading. The router's 15-minute TWAP therefore reverts for 15 minutes after any price-moving swap, which blocks deploy, fulfil, emergency repay, harvest and the custody's own loop.
- With 100 readings the TWAP keeps working after swaps, unless price-moving swaps land more often than every 9 seconds (the pool is lightly used).
- One transaction, about 2.3M gas (~0.00002 ETH).
- It takes effect from the pool's next swap and fully covers the 15-minute window from 15 minutes later.
- Script: `Desktop/Claude/script/IncreaseAvkatPoolObservations.s.sol`.

## 3. What Phase 1 does NOT fix (remains until Phase 2)

- **#3b same-transaction accounting:** fulfilling a scheduled withdrawal still books the unwind loss when the unwind runs, and the fee only when the request is released. This needs the Phase 2 code change (executor + WM v2). Until then share value can dip briefly during a fulfil.
- **#5b accurate profit:** wind-up profit is still measured against the avKAT conversion rate, not market value. The fuse reports +4.68% while the market result is about −1% per cycle. This is a Phase 2 rebuild item. Until then, whether to keep the Morpho allocation at 7,501 bps is your call.
- **#18 deploy revert when over target:** unchanged until Phase 2.

## 4. Delivery

1. **Script** `Desktop/Claude/script/Phase1ConfigQuickWins.s.sol`, run with the deployer key:
   - checks chain and owners, and reads and logs the current values;
   - sends P1-1, P1-2, P1-3, P1-4a and P1-4b as 5 transactions, in that order;
   - reads everything back and `require`s the new values.
   - P1-5 stays in its own existing script, so it can be run independently or first.
2. **Fork test** (local anvil, before you broadcast). After the changes it runs:
   - `requestShares`, checking the 4.5% escrow;
   - an instant `redeem`, checking the 1.25% fee and the 30% custody cut;
   - `deployAssets`, checking swaps still pass at 0.3%;
   - `fulfillAll` on the new request, checking it proceeds only if the loss is ≤ 4%;
   - a price-moving swap followed by an immediate `deployAssets`, checking the P1-5 effect.
3. **Docs:** update `CONTRACTS_LONG_LIST.md` section A0 with the new live values.

## 5. Rollback

Every change can be reverted by the same caller with the old values:
- `updateWithdrawFee(0.009e18)`
- `updateRequestFee(0.039e18)`
- `setWithdrawalEconomics(390, 125, 265)`
- `setRouteProtection(…, 0, 100)` in both directions

P1-5 cannot be reversed, but it only adds price-history storage and has no downside.

## 6. Decisions

All approved by the user on 2026-09-24. P1-5 was sized to 100 slots.
