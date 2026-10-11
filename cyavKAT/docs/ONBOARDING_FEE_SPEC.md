# Onboarding fee + instant-fee burn — spec, APPROVED 2026-10-03 (resolves the deferred
# "WM custody fee share" question)

## Decisions (user, 2026-10-03)
- The instant withdrawal fee is split into an **onboarding (deposit) fee** and an **instant withdrawal fee**:
  - **onboarding fee 0.30%** — **70% to the profit custody, 30% to admin** (fee authority's admin receiver);
  - **instant withdrawal fee 0.90%** — **100% burned** (stays in the vault → holders' PPS); no custody cut, no split.
  - Total 1.20% (0.05% below today's 1.25% instant fee).
- **Scheduled request fee unchanged** (8.75%, current handling).
- Both percentages are FEE-class gate keys (fee authority only), with hard caps (onboarding ≤ 1%, instant ≤ 4%).

## Mechanics
1. **Onboarding fee = IPOR's native deposit fee:** `FeeManager.setDepositFee(0.30%)` (fee manager
   `0x11a8…5Ec6`; currently 0). IPOR mints the fee shares at deposit **to the vault's withdraw manager**
   (`PlasmaVaultFeesLib.prepareForRealizeDepositFee` → `getWithdrawManager().manager`); the depositor receives its
   shares minus the fee. No new contract on the IPOR side.
2. **WM v2 splits them:** new `settleOnboardingFee()` (permissionless, also called by the executor in `deployAssets`):
   onboarding shares = WM's cyavKAT balance − every share WM is accountable for (active requested shares + request-fee
   escrow + earned request fees + unpaid fee-split shares). A new tracked total `committedShares` makes that
   subtraction exact; 70% → profit custody, 30% → admin receiver, as cyavKAT shares (no swap, no redeem).
3. **Instant fee 100% burned:** WM v2 config — profit-custody cut off and fee split all zero for instant withdrawals
   (the code path that already burns the whole fee for `burnOnlyFee` accounts becomes the default for cyavKAT).
4. **The custody simply receives the onboarding shares into its general holdings** (user, 2026-10-03) — no separate
   bucket, no special redeem path or fee exemption; they are part of the same account it uses for everything it holds,
   and `cover()` and its other functions work from that general account as today.

## Tests (part of the test plan)
- deposit → depositor gets shares × (1 − 0.30%); WM receives the fee shares; `settleOnboardingFee` pays 70/30 exactly;
  request shares / escrow / earned fees are never touched by it (requests in flight during deposits and settles);
- instant withdrawal → 0.90% fee, all burned, PPS of remaining holders rises by it; nothing to custody or admin;
- scheduled requests unchanged (regression of the existing request-fee tests);
- the custody's received shares show up in its general holdings; PPS invariant everywhere.
