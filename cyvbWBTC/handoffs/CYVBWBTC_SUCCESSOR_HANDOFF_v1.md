# cyvbWBTC Successor Handoff v1

## Mission

Finish, verify, and deployment-test the Katana **CurveYield vbWBTC / cyvbWBTC** IPOR Fusion vault.

This handoff is the durable continuation point. Do **not** restart discovery that is already resolved. Read the current `cyvbWBTC/` folder on `CurveYield2/Smart-Contracts` first, preserve useful work, repair the known defects below, add focused tests, and then run a full Katana fork deployment/strategy simulation through the existing `CurveYield2/Contract-Automation` simulation tooling.

No production broadcast is requested yet.

---

## Canonical repositories / current branch state

### Smart contracts

Repository:

https://github.com/CurveYield2/Smart-Contracts

Dedicated vault folder:

https://github.com/CurveYield2/Smart-Contracts/tree/main/cyvbWBTC

Main commit at handoff creation:

`7fcdc48bcbbbd27dbde35aca47d62a58349f1895`

### Contract-Automation

Repository:

https://github.com/CurveYield2/Contract-Automation

Main commit at handoff creation:

`ff468b253f70098d1a9bae572840ba58e24909b9`

Successful cyvbUSDC deployment-simulation pattern to reuse:

`packages/github-native-sim/audit-harnesses/cyvbusdc-deployment-simulation-v1/`

Most useful current adapter:

`run-v7.mjs`

The cyvbUSDC work established the working Katana fork pattern: use Contract-Automation's Anvil tooling and Katana dRPC when the primary public RPC is unreliable. The exact-sequence deployment adapter was used because current Foundry's literal `forge script` execution path misclassifies Katana's OP-stack hardfork before contract execution.

Reference successful cyvbUSDC simulation runs:

- https://github.com/CurveYield2/Contract-Automation/actions/runs/37159249454
- https://github.com/CurveYield2/Contract-Automation/actions/runs/37159257279

Use that pattern rather than inventing a new simulation framework.

---

# 1. AUTHORITATIVE USER REQUIREMENTS

## Vault identity

- Chain: Katana, chain ID `747474`
- Name: `CurveYield vbWBTC`
- Symbol: `cyvbWBTC`
- Deposit / underlying token: vbWBTC
  `0x0913DA6Da4b42f538B445599b46Bb4622342Cf52`
- Deploy through the **official IPOR Fusion factory**
- Strategy nests into the soon-to-exist CurveYield USDC vault, `cyvbUSDC`

Official IPOR Fusion factory:

`0xc29b8D591d6a3f109Ca7ba384F2e00162866D37B`

## Management / performance fees

Use the same IPOR **Middle Way** package as cyvbUSDC.

Current intended interpretation:

- IPOR management cut remains separate: 0.30%
- IPOR performance cut remains separate: 2.00%
- CurveYield admin TVL / management component: **1.00%**
- CurveYield performance component: **8.00%**
- CurveYield management/performance receiver:
  `0x47623C62f281807D615eeb4A2CEee9d97F9D3C49`

Thus current code targets:

- aggregate management fee = 1.30%
- aggregate performance fee = 10.00%

Do not redirect IPOR's cut.

## CRITICAL USER CORRECTION: onboarding / instant-withdraw fees

The following two user-operation fees are **NOT admin revenue**:

- Onboarding fee: **0.55%**
- Instant-withdraw fee: **0.35%**

User explicitly corrected the prior implementation:

> both fees are burned / PPS-accretive, increasing vault PPS, and are not sent to admin.

Economic invariant:

**The fee value must remain for existing vault holders without minting corresponding new economic ownership, so PPS increases. It must not be transferred to `0x4762...3C49` or any other fee receiver.**

The current gateway implementations violate this and MUST be replaced/fixed before deployment.

Recommended implementation direction to validate carefully:

- Deposit/onboarding: user supplies gross vbWBTC; user receives shares economically corresponding to net 99.45%; the 0.55% fee value remains/donates into the vault without matching shares.
- Instant exit: burn/consume shares for the gross withdrawal, pay user 99.65%, and retain/return the 0.35% fee value to the vault without minting shares.

Do not assume this is safe merely because the arithmetic works. Explicitly test:
- first depositor / near-zero total supply,
- last-holder / full-vault withdrawal,
- zero total supply after full exit,
- no orphan assets that a later depositor can capture,
- PPS before/after fee realization,
- no fee bypass through direct ERC4626 entry/instant-exit paths.

If IPOR's virtual-share/dead-share accounting makes the edge cases safe, prove it in tests. Otherwise adapt the mechanism while preserving the PPS-accretive requirement.

Scheduled/non-instant IPOR withdrawal request paths were intentionally not specified as carrying the 0.35% instant fee.

---

# 2. STRATEGY

Canonical strategy:

1. Accept vbWBTC.
2. Deposit vbWBTC as collateral into the **Katana f(x)/fxMINT vbWBTC long pool**.
3. Borrow fxUSD to the configured target LTV; default target = **50%**.
4. Swap fxUSD -> vbUSDC through the existing CurveYield Sushi V3 router.
5. Deposit vbUSDC into `cyvbUSDC`.
6. Keeper/ALPHA can rebalance LTV.
7. Entire vault balance must remain instant-withdrawable using conditional deleveraging/unwind logic.

Katana vbUSDC:

`0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36`

fxUSD:

`0x1364b238C668A2dec1294174e4798E8c09979f86`

Existing CurveYield swap router:

`0x01F9894f92ea9224fECc8C35482E20a05De13582`

---

# 3. LTV POLICY — USER REQUIREMENTS AND CORRECTION

Defaults:

- Normal target: **50%**
- High trigger: **60%**
- High reset: **58%**
- Low trigger: **45%**
- Low reset: **50%**
- Instant-withdraw ceiling: **55%**

Behavior:

- LTV >= 60% -> deleverage to 58%
- LTV <= 45% -> relever to 50%
- otherwise do nothing
- instant withdrawals must leave the position at or below 55%

## Configurability

User requested the **target plus rebalancing trigger/reset amounts** to be configurable within a 20% total range, 10% up/down from their defaults.

The latest implementation `CyvbWbtcLtvConfig_v3.sol` interprets this as **relative +/-10%**, which matches the user's phrasing and the later corrective commit:

- target 50% -> 45%–55%
- high trigger 60% -> 54%–66%
- high reset 58% -> 52.2%–63.8%
- low trigger 45% -> 40.5%–49.5%
- low reset 50% -> 45%–55%

The 55% instant-withdraw ceiling is currently **fixed**, not configurable.

The current README incorrectly says +/-10 percentage points and incorrectly counts six configurable values. Correct the documentation. The current v3 config contract is the intended baseline unless the user explicitly changes the requirement.

Required ordering/hysteresis invariant currently implemented:

`low trigger < low reset <= target <= high reset < high trigger`

Also ensure configured policy remains safely below the effective Katana-native f(x) rebalance region.

---

# 4. CRITICAL KATANA-SPECIFIC LTV WARNING

Do **not** treat the raw f(x) getter values observed on Katana as the user-facing borrowing/rebalance LTV limits.

Raw live pool getters returned:

- `getDebtRatioRange()` upper: ~86.6667%
- `getRebalanceRatios()`: 88%
- `getLiquidateRatios()`: 95%

The user explicitly corrected this interpretation:

**Those are representative of the Ethereum implementation semantics and are not the effective Katana frontend limits. Do not use them as the Katana user-facing safety boundaries.**

Observed Katana frontend behavior supplied by the user:

- maximum selectable borrowing LTV: ~66.6%
- at 66.6% LTV with BTC around $84,700, frontend says rebalancing begins around BTC $80,000

Fixed-debt math:

`66.6% * 84,700 / 80,000 ~= 70.5%`

So the effective frontend-implied native rebalance threshold is about **70.5% LTV**, not 88%.

The cyvbWBTC max configurable high trigger is 66%, which remains below that observed ~70.5% region.

Successor should verify the current Katana frontend/on-chain semantics before final deployment and document what the raw 86.67/88/95 getters actually represent. Do not replace the user-observed Katana limit with Ethereum assumptions.

---

# 5. INSTANT WITHDRAWAL REQUIREMENT

The entire balance must be instant-withdrawable.

The live f(x) collateral token is vbWBTC. The earlier user phrase "cbWBTC collateral" should be implemented as the actual vbWBTC collateral used by the resolved Katana pool.

## Starting below 55%

When current LTV is below 55%:

- satisfy as much as safely possible by withdrawing vbWBTC collateral only;
- do not allow a collateral-only withdrawal to leave the position above 55%.

The current `FxMintCyvbWbtcFuse_v2` uses this conservative staged interpretation: collateral-only until the safe limit, then deleverage for any remainder.

## At / above 55%, or if requested withdrawal would cross 55%

1. redeem enough nested `cyvbUSDC` -> vbUSDC,
2. swap vbUSDC -> fxUSD,
3. repay f(x) debt,
4. release vbWBTC,
5. complete withdrawal,
6. resulting LTV <= 55%.

## Full unwind

If the requested instant withdrawal consumes value held in both:
- the f(x) collateral leg and
- nested cyvbUSDC,

then fully unwind:
- redeem nested cyvbUSDC,
- use vbUSDC -> fxUSD to repay remaining debt,
- withdraw collateral,
- convert residual vbUSDC -> vbWBTC as needed,
- satisfy the user withdrawal,
- retain/burn the 0.35% exit fee economically for remaining shareholders.

Test 100% withdrawal explicitly.

Also test **withdraw 100% -> deposit again -> redeploy strategy**. The single f(x) position registry must remain reusable or correctly create a new position.

---

# 6. RESOLVED LIVE KATANA f(x) TOPOLOGY

Successful evidence run:

https://github.com/CurveYield2/Smart-Contracts/actions/runs/37162120601

### Core addresses

f(x)/fxMINT diamond/router:

`0xcb1B53A02D7370A31c6BC3263459e21d2C5C17eC`

PoolManager:

`0xFae375C9eA6636c40deB92DD91B7dbbF51BD3C68`

vbWBTC long pool:

`0xE32B9b4C8f776687Ec54B4b6B62DbD9ce5fd4b99`

Pool configuration:

`0xB582Eb17059171D09B4F78f0BB63E47C7ceEfF62`

Live pool `priceOracle()` observed by successful probe:

`0xeDA71e4ab642e97FBAA04beB3a7c4Bd6139a23C5`

fxBASE:

`0x6cf6757725886716Bc3c6A4bB93d02F1d1E3e7Dd`

fxUSD:

`0x1364b238C668A2dec1294174e4798E8c09979f86`

vbWBTC:

`0x0913DA6Da4b42f538B445599b46Bb4622342Cf52`

vbUSDC:

`0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36`

### Live probe facts

- registered f(x) pools count: 2
- vbWBTC pool is pool[0]
- pool `fxUSD()` matches expected fxUSD
- pool `poolManager()` matches expected PoolManager
- `nextPositionId` observed: 4
- borrow paused: false
- redeem paused: false
- fxBASE stableToken = vbUSDC
- fxBASE stable price was approximately $1 during probe
- vbWBTC token scaling factor = `1e28`
- pool fee ratio observed for zero recipient:
  - supply: 3,000,000 / 1e9 = 0.30%
  - withdraw: 1,000,000 / 1e9 = 0.10%
  - borrow: 0
  - repay: 0

### IMPORTANT current deployment-script inconsistency

`DeployCyvbWBTC_v2.s.sol` currently contains:

`FX_PRICE_ORACLE = 0xB4Fb797338b5CA45CE9aF43BfcA9E873BDac8C7B`

But the successful live vbWBTC-pool probe returned:

`pool.priceOracle() = 0xeDA71e4ab642e97FBAA04beB3a7c4Bd6139a23C5`

`FxMintVbWbtcPriceFeed_v1.sol` expects an oracle implementing `getPrice()` and describes itself as wrapping the **live f(x) vbWBTC pool oracle**.

Therefore **do not trust the current B4Fb... constant**. Verify both addresses and use the actual pool oracle or the correct intended adapter. This must be resolved before deployment testing.

---

# 7. RESOLVED SWAP ROUTES / LIQUIDITY

Existing CurveYield router:

`0x01F9894f92ea9224fECc8C35482E20a05De13582`

Current router is missing the required cyvbWBTC routes until configured.

## fxUSD <-> vbUSDC

Direct Sushi V3 0.01% pool:

`0xe1578cEF06331d77bC99273d5f1aF48eC2de92db`

Route fee tier: 100.

Both directions are required:
- fxUSD -> vbUSDC
- vbUSDC -> fxUSD

## vbUSDC -> vbWBTC

Pools observed:

- 0.01%: `0x92C97b702b5f8DfEa8B87535d63f7Dbe8E40E3E8`
- 0.05%: `0x744676B3CeD942D78F9b8e9cd22246Db5c32395c`
- 0.30%: `0x4488005Fd5EEa2E22a80cb2A0e820ED6066e687F`

Liquidity probe:

https://github.com/CurveYield2/Smart-Contracts/actions/runs/37162675656

Observed liquidity:
- 0.01% pool: ~210,923
- 0.05% pool: ~10,183,722,154
- 0.30% pool: ~3,383,831,787

Therefore current `ConfigureCyvbWbtcRoutes_v1.s.sol` intentionally chooses the much deeper **0.05%** vbUSDC/vbWBTC pool.

Unwind route probe:

https://github.com/CurveYield2/Smart-Contracts/actions/runs/37162505458

At that time `router.routeFor(vbUSDC, vbWBTC)` returned `0x`.

Route script configures:
- fxUSD -> vbUSDC, 0.01%
- vbUSDC -> fxUSD, 0.01%
- vbUSDC -> vbWBTC, 0.05%
- route-specific CurveYield router fee = 0 bps
- TWAP guard = 15 minutes / 200 bps

Do not production-broadcast those routes yet. In fork tests, configure them fork-only first.

---

# 8. CURRENT SMART-CONTRACTS TREE

Current dedicated folder:

https://github.com/CurveYield2/Smart-Contracts/tree/main/cyvbWBTC

## Most-current implementation candidates

### Use / continue from

- `contracts/CyvbWbtcLtvConfig_v3.sol`
  - latest LTV policy
  - relative +/-10% configurability
  - fixed 55% instant-withdraw ceiling
  - single f(x) position registry

- `contracts/FxMintCyvbWbtcFuse_v2.sol`
  - current strategy / rebalance / instant-withdraw implementation
  - fresh capital -> f(x) -> fxUSD -> vbUSDC -> cyvbUSDC
  - staged collateral-only/deleveraging withdrawal
  - full unwind path

- `contracts/FxMintCyvbWbtcBalanceFuse_v2.sol`
  - current strategy accounting
  - f(x) collateral less debt + nested cyvbUSDC + residual stable assets
  - excludes idle underlying because PlasmaVault counts underlying separately

- `contracts/FxMintVbWbtcPriceFeed_v1.sol`
  - IPOR-compatible price-feed adapter around f(x) `getPrice()`

- `contracts/CyvbWbtcGatewayGatePreHook_v2.sol`
  - unified direct ERC4626 entry/exit gate to mandatory gateway
  - scheduled `redeemFromRequest` intentionally not gated

- `script/ConfigureCyvbWbtcRoutes_v1.s.sol`
  - current route configuration candidate

### MUST be replaced / corrected before use

- `contracts/CyvbWbtcGateway_v2.sol`
  - **WRONG FEE ECONOMICS**
  - currently sends both 0.55% onboarding and 0.35% instant-exit assets to `FEE_RECEIVER`
  - contradicts latest user instruction
  - create `CyvbWbtcGateway_v3.sol` (or next whole version) implementing PPS-accretive/burn economics

- `script/DeployCyvbWBTC_v2.s.sol`
  - currently deploys `CyvbWbtcLtvConfig_v2`, not current v3
  - deploys wrong-fee `CyvbWbtcGateway_v2`
  - has unresolved oracle constant issue
  - create next whole-number version after corrections

### Legacy/superseded files still present

These are not current authority and should be removed only after successor versions are green:

- `CyvbWbtcGateway_v1.sol`
- `CyvbWbtcInstantExitGateway_v1.sol`
- `CyvbWbtcInstantExitGatePreHook_v1.sol`
- `CyvbWbtcLtvConfig_v1.sol`
- `CyvbWbtcLtvConfig_v2.sol`
- `FxMintCyvbWbtcBalanceFuse_v1.sol`
- `FxMintCyvbWbtcFuse_v1.sol`
- `DeployCyvbWBTC_v1.s.sol`

Do not delete useful historical code before the corrected current versions compile/test; then clean the live folder so only usable current files remain.

---

# 9. CURRENT CI STATUS / KNOWN IMMEDIATE BUILD BLOCKERS

Current verification workflow:

`.github/workflows/cyvbWBTC_verify_v1.yml`

Latest run at handoff:

https://github.com/CurveYield2/Smart-Contracts/actions/runs/37164381732

Status: **FAIL**

The current failure is compiler checksum syntax, before meaningful runtime verification:

1. Legacy `DeployCyvbWBTC_v1.s.sol` uses non-checksummed pool literal.
   Correct checksum:
   `0xE32B9b4C8f776687Ec54B4b6B62DbD9ce5fd4b99`

2. `DeployCyvbWBTC_v2.s.sol` uses invalid-checksum oracle literal.
   Solidity suggests checksum:
   `0xb4fB797338B5cA45Ce9aF43bfca9e873BdAc8C7B`

But fixing only the checksum is NOT enough: the B4Fb oracle itself is suspect because the live pool's `priceOracle()` was eDA71... as noted above.

A prior compile run succeeded before later contract/script changes:

https://github.com/CurveYield2/Smart-Contracts/actions/runs/37162858610

Do not infer that current main is compile-clean from that older success.

---

# 10. CURRENT DOCUMENTATION DEFECT

`cyvbWBTC/README_v1.md` has the latest fee correction but still incorrectly says:

- all six policy values are configurable
- ranges are +/-10 percentage points

Correct behavior from `CyvbWbtcLtvConfig_v3.sol` and the user's requested wording is:

- five values configurable
- +/-10% **relative**
- fixed 55% instant-withdraw ceiling

Update README in the next version.

---

# 11. FEE-GATE / BYPASS REQUIREMENTS

The gateway must be mandatory for:
- deposit
- mint
- depositWithPermit
- instant withdraw
- instant redeem

The existing `CyvbWbtcGatewayGatePreHook_v2` is intended to enforce that.

Successor must verify exact IPOR pre-hook semantics with real tests. Required invariant:

**There is no direct public path that allows a user to bypass the 0.55% onboarding fee or 0.35% instant-exit fee.**

Scheduled IPOR withdrawal requests are separate/non-instant and may remain outside this gate.

For the corrected PPS-accretive gateway, test receiver/owner/allowance behavior for:
- self deposit
- third-party receiver
- withdraw by owner
- withdraw by approved third party
- redeem by owner
- redeem by approved third party

---

# 12. REQUIRED UNIT / FOCUSED TESTS

There is not yet a complete focused `cyvbWBTC/test/` suite. Create it.

Minimum tests:

## LTV config
- defaults exact
- each min/max relative range exact
- outside range reverts
- invalid ordering reverts
- ownership handoff
- vault binding one-time
- position ID one-time / lifecycle behavior

## Gateway and PPS fees
- 0.55% onboarding economics exactly
- 0.35% instant-exit economics exactly
- **no admin transfer for either**
- fee value increases PPS / benefits existing shares
- no direct vault bypass
- first depositor
- multiple holders
- near-zero supply
- last holder / full exit
- deposit after total exit
- no orphan fee assets / next-depositor windfall

## Strategy fuse
- fresh capital opens/reuses position
- target 50% default
- fxUSD output swaps to vbUSDC
- vbUSDC deposits into nested cyvbUSDC
- min-out and deadline checks
- router missing route reverts safely
- approvals reset where appropriate
- high trigger -> high reset
- low trigger -> low reset
- no rebalance inside band
- configurable policy honored

## Instant withdrawal
- start <55%, small withdrawal: collateral-only
- start <55%, large withdrawal crossing 55%: collateral-only up to safe point then deleverage
- start >=55%: nested cyvbUSDC redeem + vbUSDC->fxUSD repay first
- resulting LTV <=55%
- 100% vault withdrawal / full unwind
- no residual debt
- no stranded nested shares
- expected acceptable dust only
- 0.35% fee is PPS-accretive, not admin-paid
- full exit then redeposit/redeploy works

## Balance fuse
- idle underlying not double-counted
- f(x) collateral net of correct live protocol withdrawal fee
- subtract fxUSD debt
- add nested cyvbUSDC assets
- add residual fxUSD/vbUSDC
- correct decimals
- fee recipient/context semantics correct

## Price feed
- uses the actual vbWBTC pool oracle
- anchor price matches live pool accounting convention
- zero/invalid price reverts
- no Ethereum-chain oracle constants

---

# 13. DEPLOYMENT SCRIPT REQUIREMENTS

Create the next version of the deployment script only after gateway/oracle/config corrections.

It must:

1. assert Katana chain ID 747474
2. verify official IPOR factory
3. verify Middle Way package live
4. accept nested `cyvbUSDC` address via environment/config; do not hard-code a not-yet-live address
5. verify nested vault:
   - code exists
   - symbol `cyvbUSDC`
   - asset = vbUSDC
6. verify all three swap routes before deployment
7. clone `CurveYield vbWBTC / cyvbWBTC`
8. deploy current LTV config
9. deploy corrected PPS-accretive gateway
10. deploy mandatory pre-hook
11. deploy verified f(x)-oracle price feed
12. deploy strategy fuse
13. deploy balance fuse
14. configure roles
15. configure IPOR price source
16. install strategy fuse and balance fuse
17. configure strategy as instant-withdraw fuse
18. install mandatory gateway pre-hooks
19. configure CurveYield 1% management + 8% performance recipients
20. leave IPOR Middle Way cuts untouched
21. do not use IPOR native deposit fee if it conflicts with the PPS-accretive 0.55% requirement
22. convert public / enable shares as intended
23. perform comprehensive post-deployment assertions
24. hand ownership/config ownership to final owner safely

Do not production-broadcast yet.

---

# 14. KATANA FORK DEPLOYMENT TESTING — MANDATORY BEFORE COMPLETION

Use **Contract-Automation**.

Do not substitute a local ad-hoc harness.

Starting point:

`packages/github-native-sim/audit-harnesses/cyvbusdc-deployment-simulation-v1/run-v7.mjs`

Recommended fork backend based on prior successful cyvbUSDC work:

`https://katana.drpc.org/`

## Nested cyvbUSDC dependency

If cyvbUSDC is not live on production Katana at test time:

1. in the SAME Anvil fork, deploy/configure the cyvbUSDC candidate first using its already-proven exact-sequence simulation adapter;
2. capture the simulated cyvbUSDC vault address;
3. feed that address to cyvbWBTC deployment as `CURVEYIELD_USDC_VAULT`.

Do not fake an ERC4626 mock for the final deployment simulation. The final simulation should exercise the real cyvbUSDC candidate.

## Fork-only route setup

In the fork only, configure:
- fxUSD -> vbUSDC
- vbUSDC -> fxUSD
- vbUSDC -> vbWBTC

using the existing CurveYield router/Safe pattern.

Do not mutate production.

## Full deployment simulation assertions

At minimum assert:

- official factory clone succeeds
- name/symbol/underlying
- all roles
- current LTV config v3 or successor
- current strategy fuse
- current balance fuse
- mandatory gateway pre-hook
- verified price oracle/feed
- management/performance fee totals and recipients
- operation fees not sent to admin
- routes and TWAP guards
- instant withdrawal configuration
- nested cyvbUSDC asset compatibility

## Live strategy simulation

Use real forked contracts/tokens.

Acquire vbWBTC on fork by:
- impersonating a real vbWBTC holder, or
- another deterministic fork-only method that does not mutate production.

Then test:

1. deposit through gateway
2. verify 0.55% PPS-accretive economics
3. deploy fresh capital
4. verify f(x) position created
5. verify ~50% target LTV
6. verify fxUSD borrowed
7. verify fxUSD -> vbUSDC swap
8. verify nested cyvbUSDC shares received
9. partial instant withdrawal below 55%
10. withdrawal large enough to require deleveraging
11. verify vbUSDC -> fxUSD repay path
12. verify post-withdraw LTV <=55%
13. full instant withdrawal
14. verify debt/nested-position cleanup
15. verify 0.35% PPS-accretive fee
16. deposit again after full unwind and redeploy
17. verify no stranded approvals/assets or unusable position ID

Persist raw transaction/action evidence and a machine-readable PASS/FAIL summary as Contract-Automation artifacts.

If literal `forge script` hits the known Katana/Optimism hardfork-classifier bug before contract execution, use the proven exact-sequence Anvil adapter pattern and explicitly record that tooling limitation. Do not misreport a client-side hardfork classification error as a contract failure.

---

# 15. CURRENT EVIDENCE LINKS

Live f(x) pool resolution:

https://github.com/CurveYield2/Smart-Contracts/actions/runs/37162120601

f(x) storage-layout recovery:

https://github.com/CurveYield2/Smart-Contracts/actions/runs/37162054274

Dependency / pool-fee / Sushi-pool probe:

https://github.com/CurveYield2/Smart-Contracts/actions/runs/37162717031

vbUSDC/vbWBTC liquidity comparison:

https://github.com/CurveYield2/Smart-Contracts/actions/runs/37162675656

Unwind route probe:

https://github.com/CurveYield2/Smart-Contracts/actions/runs/37162505458

Latest current verifier failure:

https://github.com/CurveYield2/Smart-Contracts/actions/runs/37164381732

---

# 16. DO NOT DO

- Do not use Ethereum f(x) limits as Katana user-facing LTV limits.
- Do not call 86.67%/88%/95% the effective Katana borrow/rebalance/liquidation LTVs without proving their Katana semantics.
- Do not send onboarding or instant-withdraw fees to the admin receiver.
- Do not leave `CyvbWbtcGateway_v2` as the production gateway.
- Do not use `CyvbWbtcLtvConfig_v2` in the final deployment.
- Do not hard-code a fake/not-yet-live cyvbUSDC address.
- Do not assume the current B4Fb... oracle constant is correct.
- Do not production-broadcast routes or the vault during development/testing.
- Do not delete useful current work before successor versions compile/test.
- Do not stop after compile-only success; deployment and strategy behavior must pass on a Katana fork.
- Do not declare completion while the current verification workflow is red or without a green Contract-Automation deployment/strategy simulation.

---

# 17. SUCCESSOR EXECUTION ORDER

1. Read this handoff and current `cyvbWBTC/` folder.
2. Fix README to relative +/-10% / five configurable values.
3. Resolve the eDA71... vs B4Fb... oracle discrepancy.
4. Implement PPS-accretive onboarding/instant-exit fees in next gateway version.
5. Update deployment script to current LTV config + corrected gateway + correct oracle.
6. Remove/fix legacy checksum blockers after successor versions exist.
7. Make Smart-Contracts compile workflow green.
8. Add focused test suite and make it green.
9. Run current live dependency probes again immediately before simulation.
10. Build cyvbWBTC simulation harness in Contract-Automation by adapting the successful cyvbUSDC Anvil harness.
11. Deploy cyvbUSDC first in same fork if no live nested vault exists.
12. Configure swap routes in fork only.
13. Deploy cyvbWBTC in fork.
14. Run deposits, leverage, rebalances, partial exits, deleveraging exits, 100% unwind, fee/PPS checks, redeposit.
15. Repair every failure and rerun until PASS.
16. Clean superseded files/workflows from the live dedicated folder only after green verification.
17. Update README/current deployment runbook.
18. Leave production deployment unexecuted unless separately instructed.

---

# 18. COMPLETION DEFINITION

cyvbWBTC is not complete until all of the following are true:

- current Smart-Contracts stack compiles
- no superseded file causes CI failure
- operation-fee economics match the user's burn/PPS instruction
- current LTV policy matches relative +/-10% configurability
- Katana-specific LTV semantics are documented correctly
- correct live f(x) oracle is used
- all required routes are validated
- focused tests pass
- full Katana fork deployment succeeds
- real strategy capital deployment succeeds
- partial instant withdrawal succeeds
- deleveraging instant withdrawal succeeds
- 100% full unwind succeeds
- fee/PPS invariants pass
- redeposit/redeploy after full unwind succeeds
- evidence artifact / machine-readable simulation summary says PASS
- dedicated `cyvbWBTC/` folder contains only the current usable stack + current runbook

Production broadcast is **not** part of this handoff unless the user explicitly requests it later.
