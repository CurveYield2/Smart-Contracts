# cyavKAT system — contract short list

Katana (chain 747474). Reconstructed 2026-09-24 from live on-chain state, the vault's full event history, Katanascan
verification, and local deployment records; extended 2026-09-27 to cover the finished Phase 2 (strategy layer),
Phase 3 (governance) and Phase 4 (cyavKAT+ ecosystem) stack, the wcyavKAT wrapper, the market-41 lending upgrade and
Katana quest signing, all built in `work/phase2/src`; **refreshed again 2026-09-27 (later same day)** for the fuse
standardization refactor (`FUSE_STANDARDIZATION_SPEC.md`, `LOOP_FUSES_SPEC.md`, `FUSE_INVENTORY.md`): the Phase
2–4 + POL fuses listed in PART A5-style "outdated" rows below are now replaced by ~13 generic, IPOR-style fuses in
`src/generic` plus IPOR's own audited fuses, with the former CurveYield fuse contracts rewritten as **planner
controllers** (views returning `FuseAction[]`). Companion: `CONTRACTS_LONG_LIST.md` (full functionality).

Legend — **Active**: in use by the live system · **Outdated**: slated for removal (spec #4) · **Live**: deployed and
in production use (address confirmed in `phase2/deployments/katana-lending-v1.json` or `katana-quests.json`) ·
**Built**: code complete and deployable, not yet cut over on Katana (deploy script named) · **Planned**: not yet
built (roadmap phase in brackets) · **Replaced**: deleted from `src` in the fuse standardization; source snapshot
kept at `phase2/_pre-standardization-2026-09-27/`.

Only IPOR-registered markets **7** (ERC20_VAULT_BALANCE), **14** (MORPHO), **19** (MORPHO_FLASH_LOAN), **36**
(BALANCER / POL), **41** (MORPHO_LIQUIDITY_IN_MARKETS, "Lend Only"), **54** (substrate-only registry, extended by the
refactor — see PART G) and, for cyavKAT+, **100001**/**100002** (`ERC4626_0001`/`ERC4626_0002`, IPOR's ERC-4626
market kind) are used anywhere in this system; no fuse invents a market id. See PART G for the full
market-substrate layout.

---

## PART A — EXISTING CONTRACTS

### A1. Fuses installed on the cyavKAT vault (8)

| Name | Address | Status | Summary |
|---|---|---|---|
| BurnRequestFeeFuse (IPOR) | `0x44D368e85f419C59aC01b7270D234d8BF19Df36e` | Active | Burns the withdrawal-request fee shares collected by the withdraw manager. |
| MorphoCollateralFuse (IPOR) | `0xda9a20690a185DAA3b0fD198C6232234835B6929` | Active | Supplies/withdraws avKAT collateral in Morpho market `0x80e6…` (avKAT collateral / KAT loan). Market 14. |
| MorphoBorrowFuse (IPOR) | `0x08095Aef82A5B33b5B478d254052618A5366cd78` | Active | Borrows/repays KAT in Morpho market `0x80e6…`. Market 14. |
| CurveYieldCallerRewardFuse | `0x70a2f848E21c912D660FE2263E5Be538268A41Ec` | Active | Quotes and pays avKAT keeper rewards for controller actions (deploy, harvest, fulfil, emergency) and moves request-fee shares. |
| CurveYieldRouterSwapFuse | `0x1fB8b83bAf40c90F0b450A3fd7A8b2E97Ab2a3Ff` | Active | TWAP/slippage-protected KAT↔avKAT (and reward-token) swaps through the CurveYield Sushi V3 fee router; exposes quotes to other fuses. Market 7. |
| CurveYieldVkatStrategyFuse | `0x987C05943855B22552898F032c1AEa7930E340da` | Active (instant-withdrawal fuse) | vKAT allocation, gauge voting and vKAT→avKAT conversion; the vault's only instant-withdrawal fuse. |
| CurveYieldMorphoFlashLoanFuse | `0x84927bFf2a35a543ed94A7d96D5ccd162a167947` | Active | Takes Morpho flash loans and runs nested fuse actions in the callback (used for de-leveraging). |
| CurveYieldMorphoStrategyFuse | `0x79E88DD967Ef9a31046455dB94b1e487329Ed705` | Active | The Morpho avKAT/KAT loop: wind-up, withdrawal-driven unwind, fulfilment, emergency repay, managed-avKAT accounting, allocation limits. Market 14. |

### A2. Balance fuses (vault accounting)

| Name | Address | Market | Status | Summary |
|---|---|---|---|---|
| ZeroBalanceFuse (IPOR) | `0xE3E28F04499470bAc1dAc842aEe424a185d14D42` | max-uint (request-fee market) | Active | Reports zero for the request-fee bookkeeping market. |
| MorphoBalanceFuse (IPOR) | `0x83790D83C23461cd22429276406C4f09DB885A85` | 14 | Active | Values the vault's Morpho loop position (collateral − debt) in USD. |
| ERC20BalanceFuse (IPOR) | `0xb81C00eb71a3D629E6f7Ba66a26218c418D438b8` | 7 | Active | Values non-underlying ERC-20s held by the vault (KAT, vKAT-position token). |
| ZeroBalanceFuse (IPOR) | `0x96393AcF49769a8C2318635fd27ab69F9c92bD1c` | 12 | Active | Zero-value placeholder for market 12 (legacy swap market). |
| VkatErc20AccountingAdapter | `0xD3d3fd4fe4c09d9BB826A37D368Cf8033e512507` | 54 (+ ERC-20 in market 7) | Active | "vKAT Position" accounting token/adapter that values the vault's vKAT locks. |
| VkatBalanceFuse (v1) | `0xcCe77F9e1c1a8C181417f9F9E2C97af15a80ADaD` | 54 | Outdated | Original vKAT balance fuse, superseded by the adapter above. |

### A3. Rewards-claim-manager fuses

| Name | Address | Status | Summary |
|---|---|---|---|
| MerklClaimFuse (IPOR) | `0xc6d024E53204CADa27a3c60C77dA4de2e7eb5166` | Active | Claims Merkl rewards to the rewards claim manager. |
| CurveYieldMerklRewardSweepFuse | `0x8c82b1ba53784F888Ea49463e2138cDF82973470` | Active | Sweeps claimed reward tokens for conversion. |
| CurveYieldMerklAutoHarvestFuse | `0xb62241b19995Dac16D5905050804e1f06caC9704` | Active | Controller-triggered Merkl harvest (claim + swap to avKAT + caller reward). |

### A4. Non-fuse contracts

| Name | Address | Status | Summary |
|---|---|---|---|
| PlasmaVault — cyavKAT (IPOR) | `0xEd83daf48429cfb2C650Fd721b9241e180fd4548` | Active | The cyavKAT ERC-4626 vault (20 decimals, asset avKAT). Impl `0xE0873c4F…A3B8`, base `0x6D73E66A…4b49`. |
| IporFusionAccessManager | `0xd7f408f203c5c6a76c9c55c9f6b015929F151fAA` | Active | Role-based permissions for the vault, managers and fuses (ADMIN unheld; deployer holds OWNER/ATOMIST/ALPHA/FUSE_MANAGER…). |
| PriceOracleMiddlewareManager | `0x7B46bfc6b34f032030cd1dD5814a7663cE4447D6` | Active | USD price source for vault accounting (avKAT, KAT). |
| FeeManager (IPOR) | `0x11a81a7B7436CB1E8f73866AF74961cE499f5Ec6` | Active | Holds the vault's fee configuration; perf fee account `0xe40276A6…A321` (10%), mgmt fee account `0xfEa31a44…45eB` (0.5%). |
| RewardsClaimManager (IPOR) | `0xA77470B748A8Fb50056Ca3c07375dC76Aa3A72Cb` | Active | Claims external rewards and vests them into the vault. |
| ContextManager (IPOR) | `0x8a4a6fbd2d23aa11985b0471d1a2ac6fd21dc4d5` | Active | Context/caller plumbing for IPOR managers. |
| CurveYieldWithdrawalManager | `0x59B340EAb30AFE0cecD51C609d3190e8C75C40AE` | Active (live withdraw manager) | Scheduled withdrawal requests, request/instant fees, request pruning, targeted releases. Proxy → impl `0x3710c70D…d94D`. |
| CurveYieldKatanaVaultControllerV2 | `0xbFdf2d2653859B66A8A15e1C85F6d6cdEe89698f` | Active | Public "executor": dispatches fixed fuse bundles (deploy, harvest, fulfil, emergency) and pays caller rewards. |
| CurveYieldProfitCustody | `0xe7D109Ce6b34447Dd45B54e5615F4177291D5ADf` | Active | Receives 30% of loop wind-up profit and runs its own avKAT/KAT Morpho position; owned by Safe `0x47623C62…3C49`. |
| CurveYieldSushiV3FeeRouter v3 (current, **verified 2026-09-24**) | `0x01F9894f92ea9224fECc8C35482E20a05De13582` | Active | TWAP-guarded swap router used by the swap fuse `0x1fB8` and the profit custody. Routes avKAT↔KAT through the **1% pool** both ways, with a 900 s TWAP guard and 330 bps maximum deviation. Source: `work/router/contracts/CurveYieldSushiV3FeeRouter.sol` (byte-exact match). Owned by Safe `0x47623C62…3C49`. |
| CurveYieldSushiV3FeeRouter (v2) | `0x346f02528aD59D1B57315b6d67FD6a43559a87Bb` | Outdated | Earlier router (0.05% pool routes); used by the first router swap fuses; superseded by `0x01F9…`. |
| IporVaultHaircutOracle | `0xE6004a4cc9EC14311E754694ea86f502ECfC0A2C` | Active | Morpho oracle for avKAT-loan / cyavKAT-collateral market `0x5c60…` (5% haircut). |
| IporVaultToKatHaircutOracle | `0x20f3648f3c55da18ff1bBC2e422338C23b5705d0` | Active | Morpho oracle for KAT-loan / cyavKAT-collateral market `0x7358…` (15% haircut). |
| WithdrawManager (IPOR, original) | `0x7a0928c0E99e50b2D51C8db7DC400123982687CF` | Outdated | Factory-created withdraw manager, replaced by CurveYieldWithdrawalManager. |

### A5. Outdated contracts — previous cyavKAT vault (spec #4 removal targets)

| Name | Address | Summary |
|---|---|---|
| PlasmaVault — old cyavKAT | `0x5E4D67594c2BA85249231D483ebf3C9f55382c37` | Previous vault; almost fully withdrawn. |
| Old controller | `0x579FBe177CE1499c1bC43042A451ec0354a2F9d2` | Old vault's controller. |
| Old access / price / withdraw / fee / rewards / context managers | `0x45E36C3A…b556`, `0x90df6e6a…46c2`, `0x3040D3c9…2F2f`, `0x7adbe1A6…885B`, `0x780C9333…7e65`, `0x5A557D22…a51c` | Old vault's IPOR managers. |
| Old vault fuses | `0x3eB4…b6`, `0xE851…19`, `0xb512…BF`, `0x1f26…B3`, `0x4079…Bb`, `0x7C96…cF9`, `0x8d27…99`, `0xE719…83`, `0x1259…F1`, `0x350F…92` | Old vault's fuse set (vKAT market 54 fuses, Morpho, etc.). |

Previously removed from the live vault (history only): `0x431b0520…`, `0x4818b6c2…` (AvKatVkatConversionFuse), `0x8FcB4072…`
and `0xFc3168e2…` (older router swap fuses), `0x020c664C…` and `0xfd444fC5…` (VkatVotingFuse v1/v2), `0x3d35B0B1…`,
`0x3e6B5770…`, `0xCECEE795…` (withdraw-manager maintenance fuse), `0xd7A66371…`, `0x29cB0bD7…` (Morpho strategy fuse v1).

### A6. External dependencies (not CurveYield-owned)

Morpho Blue `0xD50F2DffFd62f94Ee4AEd9ca05C61d0753268aBc` · AdaptiveCurveIrm `0x4F708C0ae7deD3d74736594C2109C2E3c065B428` ·
Morpho loop oracle (MorphoChainlinkOracleV2) `0xC5d4f6f7B1F5deC7Ec191d3612388F95F5f7f47c` · avKAT `0x7231dbaCdFc968E07656D12389AB20De82FbfCeB` ·
KAT `0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d` · vKAT NFT `0x106F7D67Ea25Cb9eFf5064CF604ebf6259Ff296d` · vKAT escrow
`0x4d6fC15Ca6258b168225D283262743C623c13Ead` · Sushi V3 factory `0x203e8740894c8955cB8950759876d7E7E45E04c1` · Sushi V3
position manager `0x2659c6085d26144117d904c46b48b6d180393d27` · avKAT/KAT pools 1% `0x8640e186…3B13`, 0.05% `0x4Dc349C3…4C77` ·
QuoterV2 `0x92dea23ED1C683940fF1a2f8fE23FE98C5d3041c` · Merkl distributor `0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae` ·
IPOR FusionFactory `0xc29b8D591d6a3f109Ca7ba384F2e00162866D37B` · IPOR DAO Safe `0xF6a9bd8F…5569` · CurveYield Safe
`0x47623C62f281807D615eeb4A2CEee9d97F9D3C49` · Morpho markets `0x80e6…83e9` (loop), `0x5c60…d014` (avKAT/cyavKAT),
`0x7358…2201` (KAT/cyavKAT).

Separate stack, prepared but not deployed: **CurveYield DEX** (Balancer V3 fork, 31 contracts + Aragon DAO + crvYIELD) —
see `CurveYield DEX/KATANA_DEPLOYMENT.md`; required by spec #25.

---

## PART B — PHASE 2: STRATEGY LAYER (built, spec #1–#19; standardized 2026-09-27; `work/phase2/src`)

Deploy scripts: `P2_01_Deploy` (everything below except the withdrawal-manager cutover), `P2_02_ConfigureVault`
(wires fuses/markets on the vault), `P2_03_Cutover` (switches the live vault onto this layer; also grants the
executor role 1100, `UPDATE_REWARDS_BALANCE`, for `RewardsClaimManager.updateBalance()` calls from the transfer-fuse
profit split), `P2_04_RemoveV1Fuses` (retires the Phase 1 monolith fuses in PART A5). Not yet cut over on Katana:
`katana-phase2.json` holds only fork/dry-run addresses. The 7-day seasoned wind-up cap
(`MORPHO_CAP_SEASONING_SPEC.md`) ships inside this layer. **2026-09-27 fuse standardization**
(`FUSE_STANDARDIZATION_SPEC.md`/`LOOP_FUSES_SPEC.md`, all decisions approved): every CurveYield fuse below is now
either (a) an IPOR-audited fuse called directly by the planner, or (b) one of ~13 small **generic** fuses in
`src/generic` (stateless, substrate-checked, reusable by any IPOR vault), with the former bespoke fuse contracts
**deleted** and their protections/decisions moved into the controller, now a **planner** (a view returning
`FuseAction[]`). Every bundle the executor assembles ends in `CurveYieldBundleGuardFuse` (PPS-drop / LTV / min-profit
post-condition check). Deleted-source snapshot: `phase2/_pre-standardization-2026-09-27/`. Compiles; **not yet
tested** (the audit writes the new tests — `test/` is currently empty).

| Name | File | Summary |
|---|---|---|
| CurveYieldAllocationController | `allocation/CurveYieldAllocationController.sol` | One `managedAvkat()` total and idle-bucket budgeting (strategic vs reserve class, vault floor bps) for every set (#18). Also holds the 7-day **seasoned managed-avKAT** checkpoint (`checkpoint`, `seasonedManagedAvkat`, `seasoningDays` 0–14) that gates loop wind-ups only. Unchanged by the fuse standardization (not a fuse). |
| CurveYieldVaultExecutor | `executor/CurveYieldVaultExecutor.sol` | Replaces ControllerV2: `deployAssets`/`fulfillAll`/`fulfillFor(requester, shares, maxChargeShares)`/`rebalance`/`emergencyRepay`/`lpEmergency`/`harvest`, plus the vKAT **native-exit lane** (`startNativeExit`/`beginNativeExits`/`completeNativeExits`/`completeNativeExitEarly`) and, since the fuse refactor, POL deploy/reduce/maintenance (burn-held + buyback, try/catch), a PPS-based loss reference for fulfilments, and a vKAT `sync()` call after every bundle that may have created/changed the position NFT. Pays a bounded caller reward; wraps every bundle with the snapshot/guard fuse pair (`deployGuardDropBps`, default 0, owner-settable 0–100 bps). |
| **Replaced:** CurveYieldExecutorPayFuse / CurveYieldProfitSplitFuse | *(deleted; was `executor/CurveYieldExecutorFuses.sol`)* | Now: **`CurveYieldErc20TransferFuse`** (generic, `src/generic/CurveYieldErc20TransferFuse.sol`) pays the caller reward and runs the loop-profit N-way split as N transfers (decision #5: no dedicated distribute fuse) — token + allow-listed recipients are typed `RECIPIENT`/`TRANSFER_TOKEN` substrates in market 54; the cap/split % logic stays in the executor / splitter (a planner decision, not a fuse one). |
| **Morpho loop set (market 14, Morpho `0x80e6`, avKAT collateral / KAT loan)** | `morpho/` | |
| CurveYieldMorphoLoopController (now a planner) | `CurveYieldMorphoLoopController.sol` | Loop settings (allocation, ramped wind-up profit, LTV targets, loss buffers). Its `planDeploy`/`planReduce`/`planWithdraw`/`planLtvRebalance`/`planEmergency` views now return `FuseAction[]` built around the two generic loop fuses below (no more direct on-chain execution logic of its own). Wind-up cap uses `seasonedManagedAvkat()` (#14). |
| **Replaced:** CurveYieldMorphoLoopWindupFuse / …LtvRebalanceFuse | *(deleted)* | Now: **`CurveYieldLoopCycleFuse`** (generic, `src/generic/CurveYieldLoopFuses.sol`, per `LOOP_FUSES_SPEC.md`) — identical per-cycle math (supply→borrow→swap, live TWAP-guarded profit gate, ramped required-profit curve, revert if a cycle falls short), substrates = Morpho market id + collateral/borrow/swap fuse addresses (typed `COMPONENT`) + profit-split recipients (typed `RECIPIENT`), all in market 54. `leaveProducedIdle` flag replaces the old LTV-rebalance fuse's "fund scheduled withdrawals first" branch (#15). |
| **Replaced:** CurveYieldMorphoLoopUnwindFuse / …EmergencyFuse | *(deleted)* | Now: **`CurveYieldLoopUnwindFuse`** (generic, same file) — identical secant-search unwind / fixed-point de-lever / partial-repay math, `mode` (0 UNWIND / 1 DELEVERAGE / 2 PARTIAL) selects the plan; `maxLossBps`/`minLtvBpsToAct` come from the planner (bounded by the controller's config) instead of being read from controller storage inside the fuse. Uses IPOR's own `MorphoFlashLoanFuse`/`MorphoCollateralFuse.exit`/`MorphoBorrowFuse.exit` for the mechanical legs. |
| CurveYieldLoopProfitSplitter | `CurveYieldLoopProfitSplitter.sol` | Configurable 4-way profit split (growth custody / contributors / vault / rewards manager, ≤50% each, sum 100%) (#16); unchanged. Its incoming growth leg is now re-pointed through **CurveYieldPolFeeder** (PART G) for the POL top-up; consumed as N transfers by `CurveYieldErc20TransferFuse` instead of the old dedicated split fuse. |
| **avKAT lending set (market 41, "Lend Only", Morpho `0x5c60`)** | `lend/` | |
| CurveYieldAvkatLendController (now a planner) | `CurveYieldAvkatLendController.sol` | Dynamic cap: 20% ownership trigger (10,000 avKAT exempt) / liquidity trigger, ≤10% decay per 12h, 3% liquidity floor (#13). `planDeploy`/`planReduce`/`planWithdraw` now build `FuseAction[]` calling IPOR's own `MorphoSupplyFuse` directly (enter and exit both). |
| **Replaced:** CurveYieldAvkatLendReduceFuse | *(deleted)* | Fully removed, no replacement fuse needed — the planner calls IPOR's audited `MorphoSupplyFuse.exit` directly. `recordReduction`'s decay-interval bookkeeping now records the **actual** amount withdrawn (2026-09-27 decision #4), read back from the bundle rather than the requested amount. |
| **Sushi avKAT/KAT LP set (market 7 fuses + market 54 substrates, 1% pool, Morpho `0x80e6`)** | `lp/` | |
| CurveYieldSushiLpController (now a planner) | `CurveYieldSushiLpController.sol` | Optimal range (tick step above conversion rate, ≥5% KAT), rebalance gate (off-range AND close ≥ basis), allocation linear with LP-vs-lending yield advantage (+30%→+100%) (#19). `planDeploy`/`planReduce`/`planWithdraw`/`planInstantWithdraw`/`planEmergency` build `FuseAction[]` for the holder fuses below. **The LP holder is kept** (2026-09-27 decision #2 — not removed), so IPOR's own Uniswap-V3 fuses do not apply (they assume the vault itself holds the NFT); see PART G. |
| CurveYieldSushiLpHolder | `CurveYieldSushiLpHolder.sol` | Unchanged (holder logic never moves per the standardization decisions): holds the NFT + its own Morpho `0x80e6` position; open/increase/withdraw/rebalance/emergency de-lever via flash loan. |
| **Replaced:** CurveYieldSushiLpOpenFuse / …IncreaseFuse / …WithdrawFuse / …RebalanceFuse / …EmergencyFuse | *(deleted, was `CurveYieldSushiLpFuses.sol`)* | Now: **`CurveYieldHolderFuses`** (generic, `src/generic/CurveYieldHolderFuses.sol`) — one holder-fuse family (Open/Increase/Withdraw/Rebalance/Deleverage), holder address as a typed `HOLDER` substrate, live re-checks (`needsRebalance`, the 1%/4% loss gates, the emergency-LTV revert) kept **inside** the fuse per decision #3 (correctness, not a "protection" that belongs in the guard). Doubles as the instant-withdrawal hook via `CurveYieldPlannedInstantWithdrawFuse`. |
| **vKAT set (split of the v1 monolith, #9) + native-exit lane** | `vkat/` | |
| CurveYieldVkatController (now a planner) | `CurveYieldVkatController.sol` | One voting-position NFT; allocation vs conversion-window plans; the native-exit lane (spec §2.8): prepare/begin/complete exits at the 60-day minimum 2.5% fee, or pay early. New `sync(lastLockIdBefore, newLockIsPosition)` (executor-only) reconciles `lastLockId`/the position NFT after a bundle that may have created one — needed because the very first lock votes in the same bundle without the position id being known yet (2026-09-27 accepted behaviour note). |
| **Replaced:** CurveYieldVkatLockFuse / …ConvertFuse / …VoteFuse / …ExitPrepareFuse / …ExitBeginFuse / …ExitCompleteFuse | *(deleted, was `CurveYieldVkatFuses.sol`)* | Now: **`CurveYieldVeFuses`** (generic Aragon-VotingEscrow set, `src/generic/CurveYieldVeFuses.sol`): `VeLockFuse`/`VeConvertFuse`/`VeVoteFuse`/`VeExitBeginFuse`/`VeExitWithdrawFuse` — escrow, NFT, gauge voter, delegation adapter and exit queue are typed substrates in market 54 (plain-address entries, unchanged encoding), so the same fuses could run on any vault holding an Aragon-style ve token. `VeVoteFuse`'s granted/active gauge checks stay inside the fuse (execution-time external state, not plannable). Free conversion's instant-withdraw hook (`VeConvertFuse`) keeps IPOR's own generic never-revert behaviour (decision #2). |
| CurveYieldErc20BalanceFuse | *(deleted, was `accounting/CurveYieldErc20BalanceFuse.sol`)* | Now: **`CurveYieldPositionReaderBalanceFuse`** (generic, `src/generic/CurveYieldPositionReaderBalanceFuse.sol`, market 7): IPOR's own ERC20BalanceFuse logic for plain-token substrates, **plus** typed `READER` substrates in market 54 (`bytes32(1<<160\|reader)`) each implementing `positionValue(vault) -> (asset, amount)` — the LP holder and the vKAT native-exit lane each get a thin reader adapter (`src/accounting/CurveYieldPositionReaders.sol`). Clamp-at-0 combination is preserved by the fuse's own accumulation (see FUSE_INVENTORY.md risk (e)1 for the audit's clamping question). |
| CurveYieldWithdrawalManagerV2 | `withdraw/CurveYieldWithdrawalManagerV2.sol` | Fee + unwind loss recognised together at release (#3b); optional 3-way fee split (cyavKAT+ only) on top of the single profit-custody cut. **New (POL, PART G):** `burnOnlyFee[account]` (owner/DAO, reversible) — the whole fee is burned for a flagged account (the POL custody), no admin/special/booster/profit-custody cut; `chargeRequest(requester, shares)` (controller-only) — the executor's `fulfillFor(…, maxChargeShares)` charges a requester the POL 0.5%-floor shortfall, burned. |
| CurveYieldCallerRewardFuse | `withdraw/CurveYieldCallerRewardFuse.sol` | v2 caller-reward validator: per-action bps/cap (owner, ≤300 bps / 100 avKAT), pro-rata deploy split between the loop and vKAT sources, request-fee share moves for the withdrawal manager. Unchanged (not touched by the fuse-standardization mapping, which only names the executor's own pay/split fuses). |
| CurveYieldBounds / CurveYieldProfitSplitLib | `libraries/` | Shared `CyBound` min/max range-check library (every limit is a constructor value, #9); profit-split transfer helper used by the loop cycle fuse and the executor's transfer fuse. |
| **New:** CurveYieldBundleGuardFuse | `generic/CurveYieldBundleGuardFuse.sol` | Generic snapshot/guard pair: `enter` (start of bundle) stores totalAssets/totalSupply/chosen balances in transient storage; `exit` (end of bundle) asserts PPS ≥ start × (1 − `maxPpsDropBps`) (default 0), plus optional max-LTV / min-idle / min-profit checks the planner supplies. Ends every executor bundle. |
| **New:** CurveYieldPlannedInstantWithdrawFuse | `generic/CurveYieldPlannedInstantWithdrawFuse.sol` | Generic IPOR instant-withdraw hook: substrate is a planner address; asks it for `FuseAction[]` sized to the requested amount and runs them via `executeInternal` in try/catch (never reverts). Used by the loop, LP holder, vKAT convert and POL instant paths. |
| **New:** CurveYieldTryElseFuse | `generic/CurveYieldTryElseFuse.sol` | Generic "try an action, else run a fallback" fuse — used for POL's sell-or-burn choice (sell the cyavKAT leg above its floor, else burn it) where the outcome depends on the real, non-view sale result. |
| **New:** CurveYieldBurnHeldSharesFuse | `generic/CurveYieldBurnHeldSharesFuse.sol` | Generalizes IPOR's `BurnRequestFeeFuse` to burn *whatever cyavKAT the vault itself holds* (not just withdraw-manager fee shares) — used by POL's `burnHeld`/buyback-and-burn path. |
| **New:** CurveYieldErc1271SignerFuse | `generic/CurveYieldErc1271SignerFuse.sol` | Generic rewrite of the live `CurveYieldSignatureFuse` (PART E) with the `VAULT` immutable dropped (context read from the delegatecall) so the same fuse is installable on any vault. **The live copy (PART E) stays deployed as-is** — this is for future vaults only, not a migration. |
| **New:** CurveYieldSubstrateTypes | `generic/CurveYieldSubstrateTypes.sol` | The type-tag registry for every generic fuse's entries in market 54 (`bytes32(type<<160\|address)`): `READER`=1, `COMPONENT`=2, `RECIPIENT`=3, `HOLDER`=4, `HOOK`=5, `PLANNER`=6, `BASE_1271`=7, `TRANSFER_TOKEN`=8. Type 0 (untagged) stays the plain-address IPOR convention (the ve contracts' escrow/NFT/gauges, unchanged). See PART G. |

## PART C — PHASE 3: GOVERNANCE (built, spec #6–#8; `work/phase2/src/governance`)

Deploy scripts: `P3_01_DeployGovernanceTokens`, `P3_02_DeployDao` (Aragon TokenVoting + Admin plugin), `P3_03_DeployGovernanceCore`, `P3_04_ConfigureGate` (wires the gate's protected calls / access managers), `P3_05_Handover` (moves ownership to the gate), `P3_99_Rollback`.

| Name | File | Summary |
|---|---|---|
| CurveYieldVotingLock | `CurveYieldVotingLock.sol` | Non-transferable voting token (#7): lock cyavKAT, power ramps linearly over a 60-day `RAMP`, drops immediately on unlock; delegatable; Aragon `IVotes` + ERC-6372 compatible. |
| CurveYieldEngagementToken | `CurveYieldEngagementToken.sol` | Non-transferable, decaying (180-day) engagement-reward units (#8); minting slows existing lots 2:1 for 120 days; ≤64 lots per holder (oldest merged). |
| CurveYieldEngagementRewards | `CurveYieldEngagementRewards.sol` | Epoched pro-rata forwarding of whitelisted reward tokens to engagement-token holders; pauses minting during a snapshot. |
| CurveYieldVoterRewards | `CurveYieldVoterRewards.sol` | Pull-based engagement rewards for executed Aragon proposals: voter pool split by cast power, delegator/delegatee haircut (default 50% / 20% of that). |
| CurveYieldProposalBond | `CurveYieldProposalBond.sol` | Anyone proposes an in-range parameter change against a 200-cyavKAT bond; the 2-of-3 Safe links or rejects it; `settle` refunds + rewards on execution or slashes 1/3 each to admin / contributors / engagement rewards (#6). |
| CurveYieldGovernanceGate | `CurveYieldGovernanceGate.sol` | Owner of record of every CurveYield contract and holder of the vault's IPOR roles. DAO calls go through `execute` and are refused if protected (admin-fee setters, ownership moves, generic call wrappers, non-allowlisted access-manager calls); only FEE_AUTHORITY can `executeProtected`. |
| CurveYieldOptimizationGuardian | `CurveYieldOptimizationGuardian.sol` | The maintenance bot's only handle: runs owner-registered (target, selector, bounds) actions through the gate's guardian lane, and can pause (not unpause) the vault. |
| Aragon DAO (TokenVoting + Admin plugin) | deployed by `P3_02_DeployDao` | cyavKAT-voter DAO; the Admin plugin is kept per user instruction until explicitly removed. |
| Gnosis Safe 2-of-3 | external, wired by `P3_03_DeployGovernanceCore` | Proposal-creation / link-or-reject authority for `CurveYieldProposalBond`. |

## PART D — PHASE 4: cyavKAT+ ECOSYSTEM (built, spec #20, #22–#25; `work/phase2/src/plus`, `leaderboard`)

Deploy scripts: `P4_01_CreatePlusVault` (clones cyavKAT+ from IPOR's FusionFactory), `P4_02_DeployPlusStack`,
`P4_03_ConfigurePlus`, `P4_04_DeployRewards`, `P4_05_GovernPhase4`, `P4_99_RollbackPhase4`.

| Name | File | Summary |
|---|---|---|
| cyavKAT+ vault ("CurveYield Looped cyavKAT") | FusionFactory clone, `P4_01_CreatePlusVault` | ERC-4626 over cyavKAT; IPOR DAO fee package 2 (0.5% mgmt / 0% perf); private (whitelist role 800 = the deposit router only). |
| CurveYieldPlusLoopController | `CurveYieldPlusLoopController.sol` | Sizes the wcyavKAT/avKAT Morpho loop (target LTV 70%, de-lever above 72.2%, MAX 75%): `planWindup`/`planUnwind`/`planDelever` (windup flash size, unwind slice, de-lever amount); profit split special/compound/booster/admin (default 40/40/10/10, sum 100%). |
| **Replaced:** CurveYieldPlusStepFuse / CurveYieldPlusLoopFuse | *(deleted, was `CurveYieldPlusLoopFuses.sol`)* | Now: IPOR's own **`MorphoFlashLoanFuse`** + **`Erc4626SupplyFuse`** (cyavKAT, then wcyavKAT) + **`MorphoCollateralFuse`**/**`MorphoBorrowFuse`** + the guard, assembled by the planner; instant withdrawals via **`CurveYieldPlannedInstantWithdrawFuse`**. Accounted on IPOR's own `ERC4626_0001`/`ERC4626_0002` markets (100001/100002, `ZeroBalanceFuse` — see PART G) instead of a bespoke market. |
| CurveYieldPlusExecutor | `CurveYieldPlusExecutor.sol` | Keeper entry points (`windup`/`delever`/`fulfill`) for cyavKAT+; holds ALPHA and is its withdrawal manager's controller. Unchanged shape; assembles the IPOR-fuse bundle above instead of calling the deleted CurveYield step/loop fuses. |
| CurveYieldPlusDepositRouter | `CurveYieldPlusDepositRouter.sol` | The vault's only depositor; takes the 35% deposit fee from the depositor's cyavKAT (never dilutive), split 20/25/25/30 admin / rewards manager / special rewards / booster; whitelist (contributors) pays no fee. |
| CurveYieldPlusYieldBooster | `CurveYieldPlusYieldBooster.sol` | Collects cyavKAT (30% of deposit/withdraw fees, 10% of loop profit) and drips 10%/day into the cyavKAT+ rewards-claim manager so PPS rises smoothly. |
| CurveYieldNetPpsPriceFeed | `CurveYieldNetPpsPriceFeed.sol` | IPOR price feed for cyavKAT net of its own pending (not yet crystallised) performance fee, so the main vault's fee crystallisation never moves cyavKAT+'s PPS. |
| CurveYieldSpecialRewards | `CurveYieldSpecialRewards.sol` | Epoched cyavKAT distribution (#22) to leaderboard-registered or engagement-token holders, incl. cyavKAT+ held via registered forwarder contracts (e.g. LP tokens); admin share ≤20%, caller reward 0.01–4%. |
| CurveYieldContributorsRewardFuse | `CurveYieldContributorsRewardFuse.sol` | Custody (#23) for the contributors' revenue share; converts avKAT → cyavKAT → cyavKAT+ and distributes to the leaderboard top-100 / engagement rewards / a timelocked grand prize. |
| CurveYieldLeaderboard | `leaderboard/CurveYieldLeaderboard.sol` | Seasonal points (#24): holding (2-week epochs, tranches, long-hold bonus), referrals (2-tier), buying points, admin allocation (≤ adminCapBps); top-100 board. |
| CurveYieldSeasonPoints | `leaderboard/CurveYieldSeasonPoints.sol` | One non-transferable points token minted per season by the leaderboard. |
| CurveYieldReferrals | `leaderboard/CurveYieldReferrals.sol` | 2-tier referral registry: pre-deposit claims (fee, capped open claims) or a one-time self-named referrer after depositing. |
| CurveYield DEX LP fuse set | not built | **#25 waits for CurveYield DEX on Katana** — see `never-edit-pure-balancer-forks.md`; the vendored Balancer/ReClamm fork must ship first. |

## PART E — WRAPPER, LENDING MARKET 41 & KATANA QUEST SIGNING (LIVE; `L*` and `K1_QuestSigning` scripts)

| Name | Address | Status | Summary |
|---|---|---|---|
| CurveYieldWrappedCyavKat (wcyavKAT) | `0x10dF0e197bc1FEF44D1D1a648C2874c9cdC34692` | Live | Immutable ERC-4626 over cyavKAT (20 decimals); 2%/yr management fee, 8% performance fee above a high watermark, both net-priced so `totalAssets()` never jumps at accrual. Collateral for the market-41 lending upgrade. |
| CurveYieldWrapperFeeSplitter | `0xB53787F6b85E1bE7FEDabCfB6BBcd8bf6b1a8799` | Live | Splits wrapper fees 40% admin / 40% contributors / 20% burned (via the vault's withdraw manager + `BurnRequestFeeFuse`). |
| IporVaultHaircutOracle12 | `0x2926dD048e1571DA8fc26BF6CB15cB9cA8135137` | Live | Morpho oracle: wcyavKAT → cyavKAT → avKAT, 12% haircut (86% LLTV × 88% = 75.68% max borrow). Deployed/wired by `L1_InstallLendingV1`/`L9_LendingToMarket41`. |
| Market-41 lend supply fuse (IPOR `MorphoSupplyFuse`, market 41) | `0x1af82A748cd81958f419F7aCD0D12Ec2372BEa98` | Live | IPOR's own audited "Lend Only" fuse (`MORPHO_LIQUIDITY_IN_MARKETS`); supply-only valuation (never prices wcyavKAT collateral, unlike the old market-14 approach). Moved from market 14 to market 41 by `L9_LendingToMarket41` (2026-09-25); lent amounts adjusted by `L2_LendAvkat`/`L3_WithdrawLend`/`L5_LendMarket12`/`L5b_FinishLendMarket12`/`L6_PauseLending`. |
| cyavKAT / wcyavKAT price feeds (IPOR `ERC4626PriceFeed`) | live since 2026-09-25 (cyavKAT feed `0xf9f3…c3Ea`) | Live | Deployed by `L7_CyavkatPriceFeed`: USD price sources for cyavKAT and wcyavKAT in the vault's price oracle middleware. |
| CurveYieldVaultBase1271 | `0x0a9eA25C827Ec0C6B2619C231B7566846619B365` | Live (since 2026-09-26) | Wraps the vault's `PLASMA_VAULT_BASE`; answers `isValidSignature` for Katana Quests SIWE login (domain-bound prefix + authorized-signer ECDSA), delegates every other call unchanged to the original base. |
| CurveYieldSignatureFuse | `0x4a94978F67C071e357158b55C64d867dFb69AeEb` | Live (since 2026-09-26) | Executor-only fuse: install/uninstall the 1271 base, manage authorized quest signers and the required message prefix. Deployed by `K1_QuestSigning`. |

## Part F: Protocol-owned liquidity + buyback-and-burn (#25 revised, POL_SPEC.md) — built 2026-09-27, not deployed; fuses standardized same day

| Contract | File | Deploy | What it does |
|---|---|---|---|
| CurveYieldPolController (now a planner) | pol/CurveYieldPolController.sol | P5_01 | Position A (vault-owned Gyro E-CLP cyavKAT/avKAT, IPOR market 36): cap 3%, triggers (300/100 bps), cooldown 12 h, 0.5% withdrawal floor (`minPolProfitBps`, default 50), yield fee 10% on real profit only (fee authority). `planDeploy`/`planReduce`/`planPolWithdraw`/`planInstantWithdraw`/`planBuyback`/`planBurnHeld` build `FuseAction[]` for the fuses below. Reserve-class set in the allocation controller. Values cyavKAT at the vault's actual share deposit rate (`convertToAssets`) everywhere, incl. caps and sale floors (2026-09-27 decision). |
| CurveYieldPolFuse | pol/CurveYieldPolFuse.sol | P5_01 | Market 36 fuse (vault context): buy cyavKAT in the POL pool (<= deposit rate), add/exit proportionally (BPT sized from the guaranteed swap minimum, leftover cyavKAT burned), sell the cyavKAT leg only above its floor else burn it (via **`CurveYieldTryElseFuse`** + **`CurveYieldBurnHeldSharesFuse`**, generic), buyback-and-burn, instant-withdrawal hook (**`CurveYieldPlannedInstantWithdrawFuse`**). No fuse-side `msg.sender == executor` check (IPOR ALPHA-only norm, 2026-09-27 behaviour note). |
| CurveYieldPolBalanceFuse | *(now `CurveYieldRateAwareBalancerBalanceFuse`, generic, `generic/CurveYieldRateAwareBalancerBalanceFuse.sol`)* | P5_01 | Market 36 valuation: BPT share of RAW pool balances (not IPOR's WITH_RATE `BalancerBalanceFuse`, which would double-count the vault's own share-rate conversion), cyavKAT hard-set at the vault's net `convertToAssets` rate (never above), avKAT at face value. Uses IPOR's standard `BalancerSubstrateLib` POOL/GAUGE substrate typing. |
| CurveYieldPolCustody | pol/CurveYieldPolCustody.sol | P5_01 | Position B, off the vault's books: our Charm Alpha Vault on the Sushi V3 0.3% cyavKAT/WETH pool; buys cyavKAT (POL pool) + WETH (best of two Sushi routes, TWAP-guarded); exits to avKAT via the cheaper of sale-above-NAV or burn-only instant redemption. Never burns. Owner functions fee-authority protected. Not itself a fuse; unaffected by the standardization. |
| CurveYieldPolFeeder (incoming) | pol/CurveYieldPolFeeder.sol | P5_01 | Loop profit splitter growth leg -> 20% POL custody, rest profit custody 0xe7D1. |
| CurveYieldPolFeeder (yield) | pol/CurveYieldPolFeeder.sol | P5_01 / P3_05 | Profit custody fee share -> 15% POL custody, rest previous fee recipient. setConfig fee-authority protected. |
| CurveYieldWrapperBurnForwarder | wrapper/CurveYieldWrapperBurnForwarder.sol | L10 | Turns the live wrapper fee split 40/30/30 into the approved 40 admin / 40 contributors / 20 burned. |
| WM v2 additions | withdraw/CurveYieldWithdrawalManagerV2.sol | P2_01 | `burnOnlyFee[account]` (POL custody redemptions: whole fee burned), `chargeRequest(requester, shares)` (fulfillFor POL charge, burned). See PART B. |
| Executor additions | executor/CurveYieldVaultExecutor.sol | P2_01 | POL deploy/reduce/maintenance (`deployGuardDropBps` 0), PPS-based loss, POL withdrawal step (0.5% floor), `fulfillFor(requester, shares, maxChargeShares)`. See PART B. |

Venues created manually by the operator (POL pool, cyavKAT/WETH 0.3% pool, Alpha Vault): addresses are inputs to P5_01 or the owners' setVenues.

## PART G: Market-substrate layout (post fuse-standardization, 2026-09-27) — spec #12 deliverable, `FUSE_INVENTORY.md` (d)

Every market id used anywhere in the system, and what its substrates hold after the refactor. Type tags below are
`CurveYieldSubstrateTypes` (`generic/CurveYieldSubstrateTypes.sol`), encoded `bytes32(type << 160 | address)`.

| Market | Kind | Substrates after the refactor |
|---|---|---|
| **7** (ERC20_VAULT_BALANCE) | IPOR standard | Plain ERC-20 token addresses (unchanged, IPOR convention, type 0). Balance fuse: `CurveYieldPositionReaderBalanceFuse` — same market's plain tokens, **plus** typed `READER` (1) entries that live in market **54** (not market 7 itself — see FUSE_INVENTORY.md's original "extend market 7's own substrate typing" idea was superseded by reusing market 54 as the shared registry, below). |
| **14** (MORPHO) | IPOR standard | The loop's Morpho market id (`0x80e6…83e9`) only — asserted loop-only by `P2_02_ConfigureVault` (`subs14.length == 1`). `CurveYieldLoopCycleFuse`/`CurveYieldLoopUnwindFuse` read their collateral/borrow/flash/swap fuse addresses from typed `COMPONENT` (2) entries in market 54, not from market 14 substrates. |
| **19** (MORPHO_FLASH_LOAN) | IPOR standard, **cyavKAT+ only** | Not the Sushi LP market: used by `P4_02_DeployPlusStack` for the cyavKAT+ loop's `MorphoFlashLoanFuse` (`ZeroBalanceFuse` valuation, since the flash-loan leg nets to zero at rest). `FUSE_INVENTORY.md`'s (d) table had speculated market 19 for the Sushi LP set instead — **that speculation was not followed**: the shipped `Phase2Base.s.sol` has no LP-specific market constant at all; every Phase-2 generic fuse (holder, ve, transfer, guard, planned-instant, position-reader) registers under **market 7** (`MARKET_ERC20`) with its typed substrates in market 54 (below). |
| **36** (BALANCER, POL) | IPOR standard, custom balance fuse | Standard `BalancerSubstrateLib` POOL/GAUGE typing (the Gyro E-CLP pool) for `CurveYieldRateAwareBalancerBalanceFuse`. |
| **41** (MORPHO_LIQUIDITY_IN_MARKETS, "Lend Only") | IPOR standard, live | Unchanged: the lending Morpho market id, IPOR's own `MorphoSupplyFuse` + `MorphoOnlyLiquidityBalanceFuse`. No CurveYield-specific fuse or substrate needed here at all after `CurveYieldAvkatLendReduceFuse`'s deletion. |
| **54** (substrate-only registry) | Extended, 2026-09-27 | **Was**: gauge-vote grants only (`isSubstrateAsAssetGranted(54, gauge)`, plain addresses, type 0 — the ve contracts' escrow/NFT/gauges, unchanged). **Now also**: the shared typed-entry registry for every generic fuse in the whole system — `READER` (1, position readers for market 7), `COMPONENT` (2, loop collateral/borrow/flash/swap fuses), `RECIPIENT` (3, profit-split / transfer-fuse payees), `HOLDER` (4, the LP holder), `HOOK` (5, holder checkpoint/rebalance-check callers), `PLANNER` (6, `CurveYieldPlannedInstantWithdrawFuse`'s planner addresses), `BASE_1271` (7, `CurveYieldErc1271SignerFuse`), `TRANSFER_TOKEN` (8, `CurveYieldErc20TransferFuse`'s token). Wired by `P2_02_ConfigureVault._substrates54`. **This resolves `FUSE_INVENTORY.md`'s open question** ("new veToken market, not numbered yet") — the implementation reused market 54 with type tags instead of registering a new market id; the inventory's own market-14/market-7 typing proposals were likewise folded into this one shared market rather than per-market extensions. |
| **100001** / **100002** (`ERC4626_0001` / `ERC4626_0002`, IPOR ERC-4626 market kind) | IPOR standard, new for cyavKAT+ | cyavKAT and wcyavKAT respectively, each with IPOR's own `ZeroBalanceFuse` — the ERC-4626 legs the loop steps through (`Erc4626SupplyFuse`) net to zero at rest and are counted as idle, not double-booked; the loop's real economic position (Morpho collateral/debt) is valued on market 14 as usual, and its flash-loan leg on market 19 (`ZeroBalanceFuse` there too). Deployed by `P4_02_DeployPlusStack`. |

Not a market id, but adjacent: the live gauge-voter/delegation-adapter/escrow addresses stay type-0 (plain) entries
in market 54, exactly as before the refactor — only the *new* generic fuses' entries needed a type tag, so old
substrate grants did not need to be re-encoded.

---

Last updated: 2026-09-27 (fuse standardization pass, same day as the prior 2026-09-27 refresh — see the intro note).
Next regeneration: end of the audit / whenever the fuse standardization's remaining code (test suite, IPOR/GitHub
publishing decisions) lands.
