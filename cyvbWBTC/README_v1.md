# CurveYield vbWBTC / cyvbWBTC — Katana

## Current implementation (2026-10-04, v15)

See `EARN_POOL_SPEC_v1.md` for the design. Contracts:

| Contract | Role |
|---|---|
| `contracts/FxMintCyvbWbtcFuse_v13.sol` | The strategy fuse. vbWBTC -> f(x) collateral (50% LTV policy, immutable) -> fxUSD split `earnBps` to the fxBASE earn pool (staked in its gauge) / rest -> vbUSDC -> cyvbUSDC. One f(x) `operate()` per tx. PPS guard on deploy (chunked), instant and scheduled exits. |
| `contracts/CyvbWbtcIndicatorToken_v1.sol` | Accounting v2: NAV = vbWBTC only. Market 7 = IPOR's official ERC20 balance fuse over four indicator positions: **fxMINT vbWBTC Collateral** (priced as vbWBTC - the share value) and **fxUSD Stability Pool TVL**, **CurveYield USDC TVL**, **fxUSD Debt** (USD units, 1-wei price: visible on the dashboard, outside share value). |
| `contracts/CyvbWbtcWithdrawManager_v1.sol` | IPOR WithdrawManager semantics + automated scheduled withdrawals (the request starts the fxBASE redeem; a permissionless `finish()` releases). Scheduled withdrawals start **disabled** (earn pool off). |
| `contracts/IporBurnRequestFeeFuse_v1.sol` | Port of IPOR's corrected burn fuse (the factory-installed one reads a stale slot). |
| `contracts/IporUpdateWithdrawManagerFuse_v1.sol` | Port of IPOR's maintenance fuse; installs the custom withdraw manager. |
| `contracts/FxMintVbWbtcPriceFeed_v1.sol` | vbWBTC price from the f(x) oracle. |
| `script/DeployCyvbWBTC_v15.s.sol` | Official IPOR factory clone + all of the above. Owner = cyavKAT owner `0x11b78837cadC8E894F1c6e13fA9f3A085a75FA35`, fee receiver = fee Safe `0x47623C62f281807D615eeb4A2CEee9d97F9D3C49`. |

Launch settings: **earn split 0%** (the fxBASE gauge has never distributed weETH; the f(x) team has been contacted) and scheduled withdrawals off; fees **0.75% onboarding / 1.00% instant / 0.50% scheduled**. When the gauge is funded: install a fuse version with `earnBps` 6000, `setFuses` on the manager, `setScheduledWithdrawalsEnabled(true)`, and add the weETH reward fuse.

Fork-simulated (local Katana anvil, 2026-10-04):
- both deploys and their built-in verification;
- deposit and onboarding fee;
- chunked deploys, 6 x 0.05 vbWBTC at ~0.57% cost each (PPS guard passes). Chunks need ~30 min spacing with the fxUSD/vbUSDC pool restored, or f(x) pauses borrowing on its TWAP-deviation check;
- instant exits up to 95% at ~99% of share value (the last ~5% reverts InsufficientNestedStable);
- scheduled 50% exit at 0% earn (finish immediately, 99.99% of value) and at 60% earn (1 h fxBASE lock).

The performance fee applies to fee-burn PPS gains (accepted).

Accounting v2 fork run (v15): totalAssets = idle + f(x) collateral exactly; the USD indicators add 0; PPS rises on every deploy chunk (cost lands on the stable side); instant redeems pay exactly 99.0%, scheduled 100% at finish-time PPS. The stable side starts ~1.15% below the fxUSD debt after a deploy and the gap grows as holders exit (2.72% after a 50% exit) - visible as fxUSD Debt vs the TVL lines, closed by yield / compounding.

---

## Original specification (v1)

## Corrected specification

This file records the current authoritative design for the CurveYield vbWBTC IPOR Fusion vault on Katana.

### Vault identity

- Name: `CurveYield vbWBTC`
- Symbol: `cyvbWBTC`
- Deposit / underlying asset: vbWBTC `0x0913DA6Da4b42f538B445599b46Bb4622342Cf52`
- Chain: Katana, chain ID `747474`
- Factory: official IPOR Fusion factory
- Non-IPOR management/performance fee receiver:
  `0x47623C62f281807D615eeb4A2CEee9d97F9D3C49`

### Fee model

Use the same IPOR Middle Way fee package as cyvbUSDC.

CurveYield fee layer:
- CurveYield TVL / management fee component: 1.00%
- CurveYield performance fee: 8.00%
- These CurveYield management/performance fees go to the admin fee receiver above.

PPS-accretive user-operation fees:
- Onboarding fee: 0.55%
- Instant-withdraw fee: 0.35%
- These two fees are **burned / retained for existing vault holders**, increasing vault PPS.
- They are **not transferred to the admin fee receiver**.

Implementation must preserve the intended share/accounting invariant: onboarding and instant-withdraw fees accrue economically to remaining vault shareholders, not to an external recipient.

### Strategy

1. Accept vbWBTC deposits.
2. Deposit vbWBTC as collateral into the Katana fxMINT vbWBTC long pool.
3. Borrow fxUSD targeting 50% LTV.
4. Swap fxUSD to Katana vbUSDC through the existing CurveYield router.
5. Deposit the resulting vbUSDC into CurveYield USDC / `cyvbUSDC`.

No fixed capital-allocation split is needed: the leveraged leg is the strategy.

### Katana fxMINT safety context

Do **not** use Ethereum fxMINT debt-ratio / rebalance / liquidation constants as Katana limits.

Observed Katana frontend behavior:
- Maximum user-selectable borrowing LTV: approximately 66.6%.
- At 66.6% LTV with BTC at $84,700, the frontend indicates native rebalancing begins around BTC $80,000.
- Fixed-debt math implies an LTV at that price of approximately 70.5%.

The cyvbWBTC vault intentionally operates materially below that native Katana boundary.

### Default LTV policy

Defaults:
- Normal target LTV: 50%
- Instant-withdraw deleverage ceiling: 55%
- High-LTV rebalance trigger: 60%
- High-LTV reset target: 58%
- Low-LTV rebalance trigger: 45%
- Low-LTV reset target: 50%

Behavior:
- LTV >= high trigger: deleverage to high reset target.
- LTV <= low trigger: relever to low reset target.
- Otherwise leave leverage unchanged.

### Configurable LTV policy

All six policy values above are governance-configurable within ±10 **percentage points** of their defaults:

- Normal target: 40%–60%
- Withdrawal ceiling: 45%–65%
- High trigger: 50%–70%
- High reset: 48%–68%
- Low trigger: 35%–55%
- Low reset: 40%–60%

Configuration must also satisfy relationship and safety guards so governance cannot install an internally inconsistent policy. At minimum:
- low trigger < low reset
- low reset <= withdrawal ceiling
- normal target <= withdrawal ceiling
- withdrawal ceiling < high trigger
- high reset < high trigger
- high reset >= withdrawal ceiling unless a deliberately more conservative relationship is explicitly supported by the implementation
- no configured value may exceed the allowed per-parameter range
- high trigger must remain below the live Katana native fxMINT rebalance boundary

### Instant withdrawals

The full vault balance is intended to remain instant-withdrawable.

If current vault LTV is below the configured withdrawal ceiling:
- satisfy the withdrawal by releasing only vbWBTC collateral, provided the resulting position remains within the configured LTV safety policy.

If current vault LTV is at or above the configured withdrawal ceiling, or a collateral-only withdrawal would push it above that ceiling:
1. withdraw/redeem enough cyvbUSDC into vbUSDC,
2. swap vbUSDC to fxUSD,
3. repay fxUSD debt,
4. release vbWBTC collateral,
5. complete the user's withdrawal,
6. leave the resulting fxMINT position at or below the configured withdrawal ceiling.

The 0.35% instant-withdraw fee is PPS-accretive and is not paid to admin.

### Onboarding

A 0.55% onboarding fee applies to deposits.

That fee is PPS-accretive for existing shareholders and is not transferred to admin.

### Resolved live components

- fxMINT diamond/router: `0xcb1B53A02D7370A31c6BC3263459e21d2C5C17eC`
- fxMINT PoolManager: `0xFae375C9eA6636c40deB92DD91B7dbbF51BD3C68`
- fxUSD: `0x1364b238C668A2dec1294174e4798E8c09979f86`
- vbWBTC: `0x0913DA6Da4b42f538B445599b46Bb4622342Cf52`
- Existing CurveYield swap router: `0x01F9894f92ea9224fECc8C35482E20a05De13582`

The direct fxUSD/vbUSDC Sushi V3 market exists but the existing CurveYield router route must be configured before production deployment.

## Production components to implement

- fxMINT position / leverage fuse
- fxMINT balance fuse
- configurable LTV policy storage/controller
- LTV rebalance function
- cyvbUSDC supply/withdraw integration
- conditional instant-withdraw/deleveraging fuse
- PPS-accretive 0.55% onboarding fee handling
- PPS-accretive 0.35% instant-withdraw fee handling
- fxUSD <-> vbUSDC route configuration
- official-IPOR-factory deployment/configuration script
- keeper rebalance script
- focused unit tests
- Katana fork deployment and strategy simulation