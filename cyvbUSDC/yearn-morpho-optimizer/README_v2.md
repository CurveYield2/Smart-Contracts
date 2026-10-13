# CurveYield vbUSDC — Yearn V3 ranked Morpho optimizer v2

**Status:** 2026-10-13 **merged into `main`; 25/25 focused tests and a fully seeded Katana-fork deployment simulation PASS**.
**Not broadcast to live Katana. Not security audited; production deployment still requires review.**

## Vault identity and actual deployment

- **Yearn V3 vault name:** `CurveYield vbUSDC`
- **Vault share symbol:** `cyvbUSDC` (same letters as existing IPOR token; they remain independent tokens)
- **Deposit asset:** `vbUSDC` `0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36`, six decimals
- **Factory:** official Yearn V3.1.0 `0x310aC28ACF5E514abDbFF9Ab25e21f1bfe22bcAC`
- **Official Yearn TokenizedStrategy implementation:** `0x310f5Db015E9d6E542fd41bd4542640790791e76`
- **Morpho Blue core (read dynamically from IPOR's supply fuse):** `0xD50F2DffFd62f94Ee4AEd9ca05C61d0753268aBc`
- **IPOR reference vault:** `0xDf9CbCB8b57A031e91CAe673a6A5786d85Ce2eC5`
- **Deployment script:** `script/DeployCurveYieldVbUSDCYearn_v2.s.sol`

The script calls **Yearn's real factory `deploy_new_vault`** and attaches one ranked master
via `add_strategy(master)`, sets unlimited maximum strategy debt and deposit limit,
and enables Yearn's `auto_allocate`: real user vault deposits allocate through
the master and onward into the dedicated Morpho markets.

**No IPOR vault or protocol configuration is modified.** The new cyvbUSDC share
token is NOT the already-issued IPOR cyvbUSDC vault token.

## Four child strategies (direct supply, never MetaMorpho vault)

| Registration rank (initial only) | Name | Morpho Blue ID |
| --- | --- | --- |
| **1st** | **vbUSDC against yvAUSD** | `0xcfac40b9f06194a33d9526f73642f6849b908c2b6d8669ad9d2d4a3e7dcb017a` |
| **2nd** | **vbUSDC against avKAT** | `0xbd48214a2f12e951da20ad0b8fd83b611c693b5bbaa280b68ba4075678f2a138` |
| 3rd | vbUSDC against siUSD | `0xf7fc5cc82200ddf8f23188ddbd6727eda2c8bc41863e91fb767bbc6e4f71890e` |
| 4th | vbUSDC against weETH | `0x76e311d4b0e2e6ae88ad9bab18063452a6d39837d7104c430ff62457b91cb2cb` |

**Initial allocation is determined by the child registration order**, not historical
performance (which has not yet been measured). After first optimization, the
master re-ranks by realized report-boundary PPS gain; registration order no
longer determines the winners. For the funded **2 vbUSDC** fork case, nominal
initial targets after four 0.1 vbUSDC floors are: **yvAUSD 1.22, avKAT 0.58,
siUSD 0.10, weETH 0.10 vbUSDC** (subject to ERC4626/Morpho rounding).

**Provenance:** first three IDs copied from the repository's
`cyvbUSDC/script/DeployCyvbUSDC_v4.s.sol`; fourth provided in the user Morpho link.
On 2026-10-13, the **live IPOR vault returned `[]`** for
`getMarketSubstrates(41)`. Thus the original IPOR file is historical
configuration evidence, **not evidence of presently active IPOR investments**.
The deployment script checks this live call. If nonempty it must exactly match
those three; when empty it uses the repository-configured identifiers and
independently validates **all four** immutable Morpho market parameters on-chain.
The Katana fork confirmed all four loan tokens are the exact vbUSDC address.

## Master allocation and child floor

- Each optimization requires **at least one nonempty Merkl claim bundle**,
  but bundles may be provided for **any subset** of the enabled children, in
  any order, up to all ten. Unknown, duplicated, zero-entry, or malformed
  bundles revert atomically. Merkl verifies each claim proof on-chain; for
  single-leaf Merkle trees a valid claim entry can have zero sibling hashes.
- For a child **with** claim data: **pre-PPS → claimAndCompound(Merkl proof
  arrays) → child.report() → post-PPS**. `claimAndCompound` explicitly rejects
  zero claim entries.
- For a child **without** claim data: **pre-PPS → compoundWithoutClaim()
  (sweep idle vbUSDC only) → child.report() → post-PPS**. A child without
  proofs does not attempt an unsafe KAT swap without a slippage minimum; its
  already-held KAT remains until a future proven claim bundle. All children
  participate in performance ranking; rebalance runs after all reports.
- **Zero** Merkl claim bundles are intentionally invalid for the master's
  `optimizeFunds` call. This is an owner-requested execution requirement,
  not a limitation of Yearn's underlying `report()`.
- Default performance rank weights **70% best / 30% second**; up to **10** child
  strategies; change `setRankWeights([..])` to any list totaling 10000 basis points.
- **Owner-controlled hard minimum per child**:
  `minimumChildDeposit() = 100000` (vbUSDC atomic units = **0.1 vbUSDC**).
  `setMinimumChildDeposit(uint256 amountInAtomicVbUsdc)` changes it.
- The minimum is reserved **before** ranked 70/30 distribution. With 4 active
  children and 1 vbUSDC, first two receive **0.52 / 0.28 vbUSDC**, and the
  other two **0.10 / 0.10 vbUSDC**. No child is 0; sufficient funding is
  required for observable PPS yield.
- Initial position seeding requires at least **0.4 vbUSDC** to fill four
  children; individual Yearn vault deposits smaller than that are expected to
  revert until sufficient master assets exist. Subsequent small deposits do not
  re-impose the four minimums on each deposit.
- If the master is already funded, **adding a new child seeds it immediately**
  by rebalancing existing children, before its first PPS measurement. Likewise,
  changing the minimum automatically rebalances; a floor too large to fund
  reverts without changing its prior value.
- `setProbeBps` (0 by default) is an *additional proportional* optional probe;
  effective floor is `max(minimumChildDeposit, probeBps of NAV)`.
- Zero-profit-unlock children are required for the explicit PPS-before/after
  measurement. The vault itself uses a 1-day profit unlock configuration.

## Deployment and governance

Foundry deployment on **Katana chain 747474 only**, script guarded by
on-chain implementation, factory release, IPOR source and market validation.

Environment:
- `DEPLOYER_FX` — private key, **only supply via a secret**, never check it in.
- `FINAL_OWNER` — defaults to `0x11b78837cadC8E894F1c6e13fA9f3A085a75FA35`.
- `STRATEGY_KEEPER` — defaults to deployer; may be delegated to a keeper EOA.
- `INITIAL_SEED_VBUSDC` — optional base-unit vbUSDC deposit funded by deployer,
  defaults **0**. If nonzero must be >=400000 and deployer must have that balance.

Required post-transaction governance acceptance:
1. `FINAL_OWNER` calls `accept_role_manager()` on the new Yearn vault.
2. `FINAL_OWNER` calls Yearn `acceptManagement()` on master and **each of the
   four children**, completing the two-step handoff.
3. Set/verify a reliable authorized `STRATEGY_KEEPER`, Merkl proofs and
   minimum-output guarded KAT→vbUSDC router route. Keeper reward input is still
   necessary; **no off-chain APR values** influence rankings.
4. Prior to accepting real deposits, ensure all four child markets are liquid
   and eligible for Merkl rewards attributable to **each child contract**.
5. Consider seeding from a safe-controlled account with >=0.4 vbUSDC to
   ensure even an otherwise unallocated child generates measurable yield.

The script sets deployer's Yearn-vault roles to 0 after granting `FINAL_OWNER`
all roles and proposing role-manager transfer, unless owner is deployer.
The strategy management handoff is pending until owner accepts. Final owner's
future ownership enables `setMinimumChildDeposit` and re-weighting.

### Execution examples

Use the project's existing GitHub-hosted verification workflow:
`.github/workflows/yearn_morpho_optimizer_verify_v2.yml`.
It installs dependencies **only on GitHub**, compiles and runs v2 unit tests,
and replays a **non-broadcast** strategy+vault deployment on a funded Anvil
Katana fork.

Actual deployment **requires explicit operator authorization** and a valid
`DEPLOYER_FX` secret on a suitable GitHub runner:

```bash
forge script cyvbUSDC/yearn-morpho-optimizer/script/DeployCurveYieldVbUSDCYearn_v2.s.sol:DeployCurveYieldVbUSDCYearn_v2 \
  --rpc-url https://rpc.katana.network/ --broadcast
```

Do not execute live until fork-level reward/liquidity and audit approval.

## Verification evidence

- Latest successful GitHub Action on `main` with funded deployment:
  https://github.com/CurveYield2/Smart-Contracts/actions/runs/38477566433
- Focused v2 tests: **25 passed, 0 failed** (15 master, 8 child, 2 real-router
  integration tests).
- GitHub-hosted funded Anvil Katana fork: created all four children, master,
  and official Yearn V3.1.0 factory vault, then simulated a **2 vbUSDC initial
  deposit** and asserted the vault funded its master, each child received
  shares, and every child's assets were at least its **0.1 vbUSDC floor**
  within 2 atomic units of ERC4626 rounding. No live network broadcast.
- The onchain factory returned API version **3.1.0**, implementation code exists,
  and all four Morpho market loan tokens were confirmed vbUSDC.
- Fork simulation addresses (deterministic dummy signer) **are not actual
  deployed addresses** and must not be used to send funds.
- Actual Merkl distributor proof validation still requires a live eligible
  reward for one of the Yearn child addresses. Mock proofs unit-test forwarding
  and child eligibility checks; a separate Katana fork test uses the **real
  cyavKAT Sushi fee router** and Morpho, but mocks the Merkl distributor call.
