> **V21 source-cleanup notice:** Discontinued `archive/` contracts/scripts and broken legacy tests are excluded. Superseded `katana-phase2.json` and `test-conf-*` dry-run manifests have been removed rather than treated as deployments; P2_01 writes a fresh record. Retired P6_02 full-unwind script is absent. The executor still has its internal four-way split; only Phase 6 changes growth to RevenueCustodyV2 and Phase 2 uses ADMIN_FEE_SAFE as contributors recipient. Sections below describing older decisions and historical implementation steps are not independent deployment authority.

# IPOR fuse conformance and scope reduction — spec (2026-10-10, rev. 10; implementation status in Part 10)

> **V2 signing deployment update (2026-10-10):** This spec historically labels the original `CurveYieldSignatureFuse` as "kept". Its deployed code is preserved, but its vault registration must be REMOVED at the mandatory V2 Quest migration; the existing ERC-1271 wrapper remains active, delegating to the original IPOR base, while revised V2 `CurveYieldQuestSignerConfigFuse` handles ongoing signer changes. `docs/QUEST_SIGNING_LAYER_v2.md` and the enforced `Phase2Base._requireQuestSigningV2` gate control the actual deployment.

## Goal
1. **Remove** from the cyavKAT stack, both live and planned:
   - **Direct Sushi V3 liquidity provision**: the LP holder, LP fuses, and the custody farm's own Sushi V3 NFT
     positions and SushiStaker. **Sushi swap paths stay. Charm vaults stay**, including POL position B.
   - **vKAT** (locks, voting, conversion, native-exit lane). The locks are already empty (verified, §0).
   - **Merkl claiming** on the cyavKAT vault.
2. **Replace** the USDC supply loop with: borrow vbUSDC against avKAT, then **deposit it into the CurveYield USDC IPOR
   vault** `0xDf9CbCB8b57A031e91CAe673a6A5786d85Ce2eC5`.
3. Bring every fuse that **remains** to the **official IPOR Fusion methodology**, at the IPOR version the live vault
   runs. **Official fuses wherever one exists**; custom fuses only where IPOR has none.

Current source is `../upgrade/src/` and `../upgrade/script/`. The old standardization draft and `archive/` are not included (D15, §2.5).

## Part 0. Verified facts (on-chain at Katana block 44,942,500, and IPOR source)

| # | Fact | How it was checked |
|---|---|---|
| F1 | The live vault `0xEd83…4548` is an EIP-1167 clone of implementation `0xe0873c4f…a3b8`. Its IPOR base is `0x6D73E66A…4b49`, wrapped by our live ERC-1271 base `0x0a9eA25C…b365`. | `cast code`, base storage slot, `ORIGINAL_BASE()` |
| F2 | **Live IPOR version = official `ipor-fusion` commit `a1f79d6` (2026-09-07).** The implementation compiled from that source (solc 0.8.30, optimizer 200 runs, cancun) matches the live bytecode **byte for byte**, apart from the linked `PlasmaVaultMarketsLib` address `0x6475…cf08`, which itself matches the compiled library. `PlasmaVaultBase` matches **byte for byte**. The vault sources are identical from `00f8a66` (2026-06-16) to `a1f79d6`. The 2026-09-14 release (`setRedemptionDelay`) is **not** live. The current pin `9fb9e806` (2026-04-24) is **older** than live. | Built at both commits, diffed against `cast code` (method in §9) |
| F3 | Every official piece this spec needs exists at `a1f79d6`: `UniversalTokenSwapperFuse` (+ substrate lib with Slippage), `UpdateMarketsBalancesFuse`, `TransientStorageMapperFuse` / `SetInputsFuse`, `PlasmaVaultBalanceAssetsValidationFuse`, `Erc4626SupplyFuse`, `Erc4626BalanceFuse`, `MorphoFlashLoanFuse`, `ExchangeRateValidatorPreHook`. | `git cat-file` at `a1f79d6` |
| F4 | Live markets with balances: 7 (KAT, vKAT adapter) = 0; **14** (loop `0x80e6…`) = 13,466 avKAT; 12 (swapper config: Token KAT / avKAT, Target KAT / avKAT / `0x4e1d…`, **Slippage 0.2e18 = 20%**) = 0; 41 = 0; 54 (12 vKAT addresses) = 0. Dependencies: 14→7, 41→7, 54→7, **12→none**. The live swap fuse `0x1fB8…` runs in market **7**. | `getMarketSubstrates`, `totalAssetsInMarket`, `getDependencyBalanceGraph` |
| F5 | **vKAT is empty:** vKAT NFT `balanceOf(vault) = 0`, adapter balance 0, market 54 = 0. | `cast call` |
| F6 | RCM `0xA774…72Cb`: reward fuses = IPOR `MerklClaimFuse` `0xc6d0…`, `0x8c82…` (sweep), `0xb622…` (auto-harvest). It holds **20.39 avKAT** vesting over 15 days. Vesting is released by `transferVestedTokensToVault` and does not depend on the reward fuses. | `cast call` |
| F7 | `0xDf9C…` = **"CurveYield USDC" (cyvbUSDC)**: same IPOR implementation; asset vbUSDC `0x203A…` (6 dec); TVL **0.13 vbUSDC**; supplies Morpho `0xbd48…` (avKAT / vbUSDC, LLTV 62.5%), `0xf7fc…`, `0x76e3…`; perf. fee 10%, mgmt fee 0.8%. The cyavKAT vault **may** `deposit` / `withdraw` / `redeem` (`canCall` true, delay 0, redemption delay 0). | `cast call`, access manager |
| F8 | cyavKAT has no position on Morpho `0xbd48…`. cyavKAT's oracle `0x7B46…` has **no vbUSDC feed**; cyvbUSDC's oracle prices vbUSDC at 1.00 via `0x6451…`. | `position`, `getAssetPrice` |
| F15 | **Merkl rewards for the USDC strategy accrue to cyvbUSDC, not cyavKAT.** Merkl API: cyvbUSDC has 0.232 KAT from the `MorphoSupply_0xbd48…` and `MorphoSupply_0xf7fc…` campaigns; cyavKAT and its RCM have none. cyvbUSDC already claims them through its own RCM `0xC4C0…bBb0`, whose reward fuses are a Merkl claim fuse `0xF427…` (distributor `0x3Ef3…`) and a reward swap fuse `0xf3E4…` that routes through the **live Sushi V3 fee router `0x01F9…`**. The rewards therefore reach cyavKAT through cyvbUSDC's share price, and **`0x01F9…` must stay live**. | Merkl API `v4/users/{addr}/rewards`, `cast call` |
| F9 | Pre-hooks run **inside the `restricted` modifier, before** the function body. `ExchangeRateValidatorPreHook` compares the current rate with a stored rate within ± threshold and **re-stores** it when it drifts past half the threshold. | `PlasmaVault._checkCanCall`, hook source at `a1f79d6` |
| F10 | `PlasmaVault.fallback` routes: callback handler **only while `isExecutionStarted()`**, the votes plugin (vote selectors only), otherwise delegatecall to `PLASMA_VAULT_BASE`. There is no governance setter for the base. | source at `a1f79d6` |
| F11 | The instant-withdrawal path (`withdrawFromMarkets` → `instantWithdraw` delegatecall) **does not set the execution flag**. Neither base nor the implementation handles `onMorphoFlashLoan` (`0x31f57072`) outside `execute`. **A flash loan cannot run inside an instant withdrawal with official code.** | source + bytecode selector scan |
| F12 | After `execute`, balances are refreshed for the touched markets **plus their dependency graph** (`_checkBalanceFusesDependencies`). | `PlasmaVaultMarketsLib` source |
| F13 | IPOR `Erc20BalanceFuse` reads **every** substrate of its market as a token (`bytes32ToAddress` → `balanceOf` / oracle). A typed config entry in market 7 would be mis-valued or would revert. | source at `a1f79d6` |
| F14 | avKAT `asset()` = KAT `0x7F1f…` (unused: the loop must swap, D12). | `cast call` |
| F16 | The live custody `CurveYieldProfitCustody` `0xe7D1…5ADf` is a plain (non-proxy) contract owned by the fee Safe `0x4762…`. It runs its own avKAT/KAT Morpho loop (collateral ≈ 2,085 avKAT) and swaps through the Sushi fee router `0x01F9…` (`ROUTER()`). It has no Charm and no Merkl functions. | `cast call`, `cast code` |
| F17 | No `archive/` contract is deployed: none appears in a deployment record or in the vault's fuses or roles. The old dry-run Phase 2 manifest was removed; only fresh confirmed deployment receipts establish current addresses (§2.6). | deployment files, `cast codesize`, `isFuseSupported` |

---

## Part 1. Decisions (2026-10-10)

| # | Decision | Effect in this spec |
|---|---|---|
| D1 | Use the version the live vault runs. | **Pin = `a1f79d6`** (F2). Re-export the IPOR files byte-exact from it and update `SOURCE_PROVENANCE.md`. Use no file from any other commit. |
| D2 | IPOR ids will be requested, but meanwhile only **existing markets**; ERC-20 (7) is the market for fuses that move accountable assets. | §1.1 interim market rules. |
| D3 | Use the share-price pre-hook if it does the job; prefer official fuses in general. | **It does not do the job** (F9): it checks *before* `execute` against a ratcheting stored rate, so it cannot stop a bundle from lowering PPS within that transaction. **Keep the custom guard**, built on official `UpdateMarketsBalancesFuse` logic. *Optional:* install the pre-hook on user-facing selectors as a cross-transaction circuit breaker (D3a). |
| D4 | Universal swapper only if it automates the slippage guard, or a layer is added that does. | **Use IPOR `UniversalTokenSwapperFuse` (market 12)**. At `a1f79d6` it has (a) `minAmountOut`, (b) a USD slippage check through the vault oracle against a **Slippage substrate**, (c) Token / Target allowlists. The added layer is **swap router v2 as the only router Target**: it enforces its protected TWAP / hook-oracle minimum on every call, whoever the caller is. `CurveYieldRouterSwapFuseV2` is deleted. |
| D5 | ERC-1271 is critical; avoid swapping the base if possible. | **Not possible on this vault version** (F10): `isValidSignature` reaches the vault only through the fallback → base. The base swap is **already live** (`0x0a9e…` wraps `0x6D73…`). Keep it as is. The generic `CurveYieldErc1271*` fuses are only for new vaults. |
| D6 | Make flash-loan instant withdrawals instant if possible. | **Not possible with official code** (F11): it would need a custom fuse that sets the execution flag, and it would let any withdrawer trigger a leveraged unwind inside their own transaction. **Accepted (2026-10-10): no instant withdrawal from the loop or USDC positions for now.** They are served through WM v2 requests. |
| D7 | cyavKAT+ not in scope. | Superseded by D15: all of `archive/` is discontinued. |
| D8 | Sushi: remove only direct V3 liquidity provision; keep swap paths; **keep the Charm vaults**. | Part 2.1. Router v2 keeps the `SUSHI` venue. POL position B (`PolCustody`) and the custody farm stay with their Charm vaults (§2.4). The live Sushi V3 fee router `0x01F9…` stays (F15). |
| D9 | vKAT: locks are empty. | No wind-down; straight removal (Part 2.2, F5). |
| D10 | USDC loop → deposit into `0xDf9C…`; its economics are not a concern (Merkl incentives, F15). | §4.3, built only from official fuses. No spread gate. |
| D11 | Merkl claiming goes from the cyavKAT vault. | Part 2.3. Nothing accrues to cyavKAT (F15). USDC-strategy incentives are claimed by cyvbUSDC; the farm's Charm incentives are claimed by the farm. Neither is a cyavKAT vault claim. |
| D12 | Loop wind-up **must use swaps**. | §4.1: the cycle buys avKAT through UTS → router v2. There is no ERC-4626 deposit route (F14 is unused). |
| D14 | Custody (revised): **keep the live custody** for the loop; `RevenueCustodyV2` is the **layer on top** for everything beyond the loop, in one contract. | §2.4. No migration; the size problem is repaired (21.2 KB). |
| D17 | Delete the superseded custody sources if they are not deployed and not planned for deployment. | Verified: no deployment record or script references them. `CurveYieldCustodyFarm`, `CurveYieldCustodyFarmPlanner` and `CurveYieldPolCustody` were **deleted** from `upgrade/src` on 2026-10-10; `src/` and the P5 / P6 scripts build cleanly. |
| D15 | Everything in `archive/` is discontinued: not implemented, removed from the plan. | §2.5, including the governance consequence G1. |
| D16 | G1: the gate's `dao` role = the fee Safe. The superseded `katana-phase2.json` is removed; P2_01 generates the new deployment record. | §2.5, §2.6. |
| D13 | The executor is on-chain; **no logic moves off-chain**. | Every choice previously planned as off-chain (B1 cycle stopping, B2 sell-or-burn) is made **by the executor contract on-chain**, using `try vault.execute(...)` (§4.1). No custom fuse is needed for it, and no keeper decides anything. |

### 1.1 Interim market rules (until IPOR assigns ids, D2)
1. **Official fuses keep their official market:**
   - `UniversalTokenSwapperFuse` → 12;
   - Morpho collateral / borrow / balance → 14;
   - `MorphoFlashLoanFuse` → 19;
   - Balancer → 36;
   - lending → 41;
   - `Erc4626SupplyFuse` / `Erc4626BalanceFuse` → the official `ERC4626_000x` ids (100_001…).
2. **Every market that changes the vault's ERC-20 holdings gets a dependency edge to 7**, so market 7 is always
   refreshed (F12): add **12→7** (missing today, F4), 19→7, 36→7, 100_00x→7; keep 14→7 and 41→7.
3. **Custom fuses that move accountable assets** (ERC-20 transfer) take **`MARKET_ID = 7`**, as the live swap fuse
   already does (F4).
4. **Custom utility fuses** (guard, burn held shares, request-fee shares) take `ZERO_BALANCE_MARKET`.
5. **Typed config substrates of custom fuses can never go in market 7** (F13). Until IPOR assigns ids they live in
   **`ZERO_BALANCE_MARKET`** (live, valued by `ZeroBalanceFuse`, no official fuse reads its substrates). They are
   encoded by one `CurveYieldSubstrateLib`, with the **type in the top byte** (`type << 248 | payload`, IPOR swapper
   layout) and type codes unique across our fuses. This cross-market read is exception **E6**, which ends when ids
   are assigned: the fuses are then redeployed into their own markets, and nothing else changes.
6. **Market 54** (vKAT) is emptied and retired.

---

## Part 2. Removals

### 2.1 Direct Sushi V3 liquidity provision (swap paths and Charm vaults kept)
| Where | Item | Action |
|---|---|---|
| upgrade | `lp/CurveYieldSushiLpController`, `lp/CurveYieldSushiLpHolder` | **Delete** (no live LP position). |
| upgrade | `generic/CurveYieldHolderFuses` (5 fuses) | **Delete.** |
| upgrade | `accounting/CurveYieldPositionReaders` | **Delete** (both readers are gone; see 2.2). |
| upgrade | `generic/CurveYieldPositionReaderBalanceFuse` | **Delete.** Market 7 stays on IPOR `Erc20BalanceFuse`. |
| upgrade | The custody farm's **own Sushi V3 NFT positions** (NPM mint / increase / decrease / collect) and **SushiStaker** staking, with their allowlists, valuation and pro-rata legs | **Remove from `CurveYieldCustodyFarm` / `Planner`** (§2.4). |
| gate | `addr.lpController`, the 13 `lp.*` keys, the farm's Sushi-position keys | Remove. **Keep** the router's Sushi TWAP window and protection keys, and the Charm keys. |
| scripts | LP steps in `P2_01`, `P2_02`, `Phase2Base`; `SUSHI_NPM` / `SUSHI_STAKER` in `P6_01` | Remove. |
| **kept** | Router v2 `SUSHI` venue, `SUSHI_FACTORY`, V3 callback, Sushi TWAP minimum; the Charm vaults (the farm's and **POL position B** in `PolCustody`) and the Sushi WETH routes (§2.4); the live Sushi V3 fee router `0x01F9…`, which cyvbUSDC's reward swap fuse **and the live custody** use (F15, F16) | Kept. |

### 2.2 vKAT (empty; F5)
| Where | Item | Action |
|---|---|---|
| live | `CurveYieldVkatStrategyFuse` `0x987C…` (in the instant list), `VkatVotingFuse`, `AvKatVkatConversionFuse(V2)`, `AvKatVkatMergeFuse`, `CurveYieldVkatPartialConversionFuse`, `VkatBalanceFuse`, `VkatErc20AccountingAdapter` | Remove from the vault (M4). Revoke the adapter from market 7, revoke market 54, remove 54's balance fuse. The legacy token-id slot stays inert. |
| upgrade | `vkat/*`, `generic/CurveYieldVeFuses` | **Delete.** |
| upgrade | Executor native-exit lane (`startNativeExit`, `beginNativeExits`, `completeNativeExits`, `completeNativeExitEarly`, `_vkatBefore`, `_vkatSync`, `planNativeExit*`), the vKAT legs of `deployAssets` | **Delete.** |
| upgrade | WM v2 native-exit cost path | **Delete** (request-fee escrow stays). |
| upgrade | Allocation controller: `vkat` strategic leg, `VKAT_ESCROW`, `legacyVkatFuse` | Strategic class = loop (+ USDC strategy, §4.3). |
| upgrade | `withdraw/CurveYieldCallerRewardFuse` (copy of live) | **Delete.** |
| gate | `addr.vkatController`, `vkat.*` | Remove. |
| scripts | vKAT steps in `P0_00`, `P2_01`–`P2_04`, `P3_03`, `P3_05`, `P3_99`, `P5_01`, `Phase2Base` | Remove (`L*` scripts are history; untouched). |

### 2.3 Merkl claiming (cyavKAT vault)
| Where | Item | Action |
|---|---|---|
| live | RCM reward fuses `0xc6d0…` (IPOR `MerklClaimFuse`), `0x8c82…`, `0xb622…` (F6) | `removeRewardFuses` (M4). Nothing is left to claim for cyavKAT (F15); M3 re-checks the Merkl API first. The RCM stays and keeps vesting its 20.39 avKAT (F6). |
| not touched | cyvbUSDC's RCM and reward fuses (F15); the custody's Merkl claim for the Charm vaults (§2.4) | Not cyavKAT vault claims. |
| upgrade | Executor `harvest`, `merklClaimFuse` dep, `exec.harvestReward*`, `harvest.vestBps` | **Delete.** |
| upgrade | `CurveYieldRouterSwapFuseV2` (incl. `sweep`) | **Delete** (D4 → official swapper). |
| upgrade | `morpho/CurveYieldUsdcSupplyLoopFuse` | **Delete** (replaced by §4.3). |
| upgrade | `Phase2Base.MERKL_*`, RCM wiring in `P2_01` / `P2_03`, `IMerklDistributorKatana` | Remove. |

### 2.4 Custody: the live loop custody + revenue custody v2 as the layer on top (D14, revised 2026-10-10)
The live `CurveYieldProfitCustody` `0xe7D1…5ADf` (F16) is **kept, unchanged**. It runs the avKAT/KAT Morpho loop.
`CurveYieldRevenueCustodyV2` is the **layer on top** for every function beyond the loop: revenue lands in v2, which
allocates it. There is **no migration**: `P6_01` no longer schedules the live custody's unwind, and `P6_02` is not run.

| Contract | Holds / does |
|---|---|
| Live custody `0xe7D1…` (kept) | The Morpho loop, its wind-up distribution, its own 15-day full-unwind path. v2 is one of its guardians, so v2 can run its `deployAll`. |
| `CurveYieldRevenueCustodyV2` (new, one contract) | **Allocation:** `deployAll` sends the loop's share (`custody.loopTargetBps` of v2's value plus the loop custody's equity and idle avKAT) to the live custody and runs its `deployAll`; the rest goes pro rata over the farm's active Charm vaults. **Farm:** allowlisted Charm vaults (operators: deposit / withdraw / swap through router v2). **POL position B:** Charm Alpha Vault on the Sushi cyavKAT/WETH pool, funded by explicit custody operator reservation (`reserveAvkatForPolBps`), not via POL feeders; held outside vault PPS accounting. **Merkl:** `harvestMerkl` claims the rewards of every Charm position (POL B included), converts them to avKAT and splits them like a loop gain. **Cover:** the vault's PPS backstop, paying from idle avKAT, then the farm. |

**Size (repaired 2026-10-10).** The three planned contracts were large because each carried its own copy of shared
machinery:
- POL custody had a second, private swap engine (Sushi TWAP math via `TickMath`/`FullMath`, quoter route search),
  duplicating swap router v2.
- The farm carried the Sushi V3 NFT / staker stack, which is now removed.
- Custody v2 had loop code, which is now the live custody's job.

The compiler settings were not the cause: the legacy pipeline gave the same size, and the via-IR FunctionSpecializer
added only about 15%. Merged into one layer contract with one swap path, one valuation helper and one operator list,
v2 is **21,150 bytes under the default profile** (EIP-170 limit 24,576). No special build profile is needed.
`CurveYieldCustodyFarm`, `CurveYieldCustodyFarmPlanner` and `CurveYieldPolCustody` were never deployed and are
no longer planned. Their sources were deleted (D17).

**Behaviour notes:**
- **Cover no longer reaches the loop.** The live custody has no instant exit (its unwind is owner-scheduled with a
  15-day delay), so v2's cover pays from idle avKAT and the farm only. The earlier v2 design (`PPS_PROTECTION_SPEC` B5)
  also unwound the loop as a last resort.
- **POL B's WETH leg trades through router v2:** one configured Sushi route (avKAT–KAT 1% → KAT–WETH 0.05%), with
  router v2's 0.1% fee and protected TWAP minimum. Before, it took the best of two private routes with no fee. The
  avKAT↔cyavKAT leg still trades directly in the POL pool, bounded by the deposit rate.
- **v2's `executeFullUnwind`** (successor path, 15-day delay) moves v2's own holdings: avKAT, KAT, farm tokens and
  Charm shares, and POL B's Alpha shares, cyavKAT and WETH. It replaces `PolCustody.migrate` / `sweep`.
- `polCustody.twapWindow` and `polCustody.maxSlippageBps` are no longer read (router v2's protection applies);
  `polCustody.maxPremiumBps` still bounds cyavKAT buys.

**Scripts:**
- **`P5_01`** deploys v2 (with the live custody as its loop custody) in place of `PolCustody`. Only an explicit operator-selected custody reservation funds V2 POL B; router v2 gets the avKAT↔WETH routes; all v2 owner functions are protected (fee authority).
- **`P3_05`** hands v2 over to the gate through its existing `.polCustody` entry.
- **`P6_01`:**
  - wires the coverer and the Charm allowlist;
  - makes v2 a guardian of the live custody;
  - repoints authorized revenue and executor backstop to v2 without installing a feeder;
  - sends every gate call through the fee Safe (G1); it no longer uses an Aragon proposal.

### 2.5 Discontinued: everything in `archive/` (not implemented, not deployed, removed from the plan)
None of these contracts is live: no deployment record names them, and the vault has no fuse or role for them.

| Archived | Contracts / scripts | Action |
|---|---|---|
| DAO and governance tokens | `CurveYieldVotingLock`, `EngagementToken`, `EngagementRewards`, `VoterRewards`, `ProposalBond`, `OptimizationGuardian`, `AragonInterfaces`; `P3_01` (tokens), `P3_02` (Aragon DAO + TokenVoting) | **Not implemented.** Remove from `upgrade/` every import and deploy step: `P3_03` (it deploys `VoterRewards`, `ProposalBond`, `OptimizationGuardian`, `EngagementToken` / `Rewards`), `P3_05` / `P6_01` (Aragon Admin-plugin proposals, `AragonInterfaces`), `P3_99`. |
| Leaderboard | `CurveYieldLeaderboard`, `Referrals`, `SeasonPoints` | **Not implemented.** Remove the "leaderboard growth destination" repoint from `P6_01`. |
| cyavKAT+ | `PlusDepositRouter`, `PlusExecutor`, `PlusLoopController`, `PlusYieldBooster`, `SpecialRewards`, `NetPpsPriceFeed`, `ContributorsRewardFuse`, `EmergencyFeeArmFuse`; `P4_01`–`P4_05`, `P4_99` | **Not implemented.** Also remove the cyavKAT+-only paths kept in `upgrade/`: WM v2's emergency-fee-exempt arming (`EMERGENCY_EXEMPT_ARMED_SLOT`, used only by `EmergencyFeeArmFuse`), and the `CallerRewardFuse` copy (§2.2). |
| Tests and docs | `deployed/test/`, `archive/test/` and obsolete Phase 3/4 design specs | Removed from v21; no active test imports or deployment entrypoints may depend on them. |

**Governance without the DAO (G1, decided 2026-10-10: the fee Safe).** The governance gate stays: it is the owner of record and holder of the
vault's IPOR roles, and `FEE_AUTHORITY` (the fee Safe `0x4762…`) is unchanged. But its constructor requires a `dao`
address, and every non-protected change goes through `gate.execute`, which only `dao` may call. With no Aragon DAO,
`dao` must be another account: **`dao` = the fee Safe `0x4762…3C49`** (decided 2026-10-10; `setDao` can move it
later). The fee Safe then holds both the `dao` role and `FEE_AUTHORITY`. The guardian lane (`OptimizationGuardian`) is unused (`guardian = address(0)`); the
executor's on-chain keeper paths are unaffected. `P3_05`'s handover then accepts ownership through that Safe's
`gate.execute` calls instead of an Admin-plugin proposal.

### 2.6 Deployment records: fresh Phase 2 record required
`upgrade/deployments/katana-phase2.json` from the older simulated deployment has been **removed** because its addresses collided with unrelated live contracts. `P2_01_Deploy` generates the new Phase 2 record when executed. A JSON generated by a simulation, without confirmed on-chain transactions and live code/role checks, is **not** a valid deployed-contract receipt. Run P2_01 first and verify its result before proceeding with P2_02/P2_03. Never use an old Phase 2 manifest.
---

## Part 3. The IPOR fuse standard (conformance rules for custom fuses)

| # | Rule |
|---|---|
| R1 | `is IFuseCommon`; `VERSION = address(this)`; immutable `MARKET_ID` (constructor reverts on 0). Other immutables only for protocol singletons. No vault / gate / controller / recipient immutables. |
| R2 | `enter(<Fuse>EnterData)` / `exit(<Fuse>ExitData)` returning realised amounts; `exit(bytes)` → `<Fuse>ExitNotSupported()` when meaningless. One action per fuse; no action enums or extra mutators. |
| R3 | `enterTransient()` / `exitTransient()` through `TransientStorageLib` (chaining with `TransientStorageMapperFuse`). |
| R4 | Every address / scalar used is a substrate checked on every call: in its own market (official fuses), or under §1.1 rule 5 (custom, interim). Top-byte typing. |
| R5 | No reads of gate, controllers, planners or splitters at execution. The gate **writes** its settings as substrates (`grantMarketSubstrates`, same transaction) and keeps its hard caps; each fuse also hard-codes an absolute ceiling. |
| R6 | Stateless; persistent state only in ERC-7201 vault storage (`io.curveyield.<family>`). Never write IPOR storage through hard-coded slots. |
| R8 | Zero amount → return 0; cap to the available balance; min / max bounds in the struct. |
| R9 | `instantWithdraw(bytes32[])`, `params[0]` = amount; catches external failures, never reverts. |
| R10 | No `executeInternal`, no execution-flag toggling, no fuse-calls-fuse. Nesting only through `MorphoFlashLoanFuse` callbacks. |
| R11 | Balance fuses return USD WAD through the vault oracle; one per market; dependency graph to 7 (§1.1 rule 2). |
| R13 | `<Protocol><Action>Fuse` naming; `<Fuse>Enter` / `Exit` / `ExitFailed` events with `version`; `<Fuse><Reason>` errors; full NatSpec. |
| R15 | BUSL-1.1, solc 0.8.30, compiled against the `a1f79d6` sources; README per family; fork tests per fuse. |

---

## Part 4. Target design

### 4.1 What runs on the vault afterwards
| Function | Fuses (official unless marked *custom*) | Market |
|---|---|---|
| Swaps (all) | `UniversalTokenSwapperFuse`; Targets = **router v2** + the tokens it approves; Slippage substrate set by the gate (**live value 20% must come down**, suggested 1%) | 12 (dep → 7) |
| avKAT/KAT loop: wind-up (per cycle, **swap**, D12) | `[guard.enter, MorphoCollateralFuse.enter (avKAT), MorphoBorrowFuse.enter (KAT), UTS KAT → avKAT via router v2, guard.exit(minAssetsPerShareDelta = this cycle's required profit)]` | 14, 12 |
| avKAT/KAT loop: unwind / deleverage | `MorphoFlashLoanFuse` → `[MorphoBorrowFuse.exit, MorphoCollateralFuse.exit, UTS avKAT → KAT]`, then guard (max loss) | 19, 14, 12 |
| USDC strategy | §4.3 | 14, 100_001 |
| Lending (live) | `MorphoSupplyFuse` + `MorphoOnlyLiquidityBalanceFuse` | 41 |
| POL position A | `BalancerLiquidityProportionalFuse`, UTS, `CurveYieldBurnHeldSharesFuse` *custom*, `CurveYieldRateAwareBalancerBalanceFuse` *custom (adapted fork, E2)* | 36 (dep → 7) |
| Keeper reward, profit split | `CurveYieldErc20TransferFuse` *custom* | 7 |
| Bundle protection | `CurveYieldBundleGuardFuse` *custom* (rewritten, §4.2); `PlasmaVaultBalanceAssetsValidationFuse` for idle floors | ZERO_BALANCE |
| Request fees | `BurnRequestFeeFuse`; `CurveYieldRequestFeeSharesFuse` *custom* (split from the request fuse) | ZERO_BALANCE |
| Balance refresh / chaining | `UpdateMarketsBalancesFuse`, `TransientStorageMapperFuse` | ZERO_BALANCE |
| ERC-1271 | live `CurveYieldSignatureFuse` + live base `0x0a9e…` (D5) | — |

**How on-chain decisions move from custom fuses into the executor (D13: everything stays on-chain).** The executor
holds ALPHA and is a contract, so it can call `vault.execute` several times in one transaction and wrap each call in
`try/catch`. A reverted `execute` rolls back only that bundle. This gives the "try X, else Y" and "repeat while
profitable" behaviour that the custom fuses provided, without `executeInternal`, without a custom fuse, and without
off-chain logic.

- **(B1) Loop wind-up: same adaptive behaviour, official fuses, swaps.** The executor runs up to `maxCycles` cycles.
  For each one:
  1. it asks the loop planner (an on-chain view) for the cycle's amounts and its required profit (the same ramped
     required-profit curve as today, computed from pre-cycle state);
  2. it calls `try vault.execute(cycle bundle)`. In the bundle, the guard's `exit` enforces
     `gain ≥ required profit` and router v2 enforces its protected minimum on the swap;
  3. it **stops at the first cycle that reverts**, exactly as today's per-cycle gate does;
  4. after each successful cycle, it reads the realised gain on-chain (vault `totalAssets` / supply before and after)
     and runs a second `execute` with the profit-split legs (`CurveYieldErc20TransferFuse`).

  `CurveYieldLoopCycleFuse` / `CurveYieldLoopUnwindFuse` are **deleted**. The unwind amounts (the secant search)
  come from the planner view; the guard enforces the max loss.
- **(B2) POL "sell, else burn": on-chain in the executor.** `try vault.execute([guard.enter, UTS sale with
  minAmountOut = floor, guard.exit])`, and on revert `vault.execute([BurnHeldShares])`. This is the same atomic
  outcome as `CurveYieldTryElseFuse`, which is **deleted**.
- **(B3) No instant withdrawal from the loop or the USDC strategy** (D6, accepted for now).
  `CurveYieldPlannedInstantWithdrawFuse` is **deleted**. The instant list = market 41 `MorphoSupplyFuse` plus any
  other official fuse with `instantWithdraw` whose exit pays avKAT. Everything else goes through WM v2 requests.

### 4.2 Custom fuses that remain (each one only because IPOR has no equivalent)
| Fuse | Market | Why custom | Changes |
|---|---|---|---|
| `CurveYieldBundleGuardFuse` | ZERO_BALANCE | IPOR has no post-bundle PPS check (F9) | `enter` / `exit` refresh balances through `PlasmaVaultMarketsLib.updateMarketsBalances` (the code path behind `UpdateMarketsBalancesFuse`) instead of its own loop. `exit` adds an **optional per-Morpho-market max LTV** (from substrate ceilings; replaces the old USDC fuse's hard-coded 35%). The `maxPpsDropBps` ceiling becomes a substrate. `wrap` helpers move to a planner library. R3 / R13. |
| `CurveYieldErc20TransferFuse` | 7 | IPOR has no outbound transfer fuse | Typed Token / Recipient / MaxPerCall in ZERO_BALANCE (E6); caps to balance; R2 / R3 / R13. Exception E1 (outbound). |
| `CurveYieldBurnHeldSharesFuse` | ZERO_BALANCE | `BurnRequestFeeFuse` burns only WM fee shares | R2 / R3 / R13 only. |
| `CurveYieldRequestFeeSharesFuse` | ZERO_BALANCE | WM v2 is an adapted IPOR fork | Only `moveRequestFeeShares` / `configureManagerAssetAllowance`. `runSources` / `runPolSale` / `settle` move to the **executor** (it holds ALPHA and builds ordinary bundles). No gate reads, no `executeInternal`. |
| `CurveYieldRateAwareBalancerBalanceFuse` | 36 | IPOR's would double-count the vault's own share rate | R13 only (E2). |
| `CurveYieldErc1271InstallFuse` / `ConfigFuse` | ZERO_BALANCE | New vaults only | Split from the 4-action fuse (E3). Not installed on cyavKAT. |

**Deleted** custom fuses: `PlannedInstantWithdraw`, `TryElse`, `LoopCycle`, `LoopUnwind`, `PositionReaderBalance`,
`Holder*`, `Ve*`, `RouterSwapFuseV2`, `UsdcSupplyLoopFuse`, `WithdrawalRequestFuse` (split), the `CallerRewardFuse`
copy. This leaves **six custom fuses**; today there are 25+.

### 4.3 USDC strategy via cyvbUSDC (official fuses only)
- **Enter** (one guarded bundle):
  1. `MorphoCollateralFuse.enter` (avKAT into `0xbd48…`);
  2. `MorphoBorrowFuse.enter` (vbUSDC to the planner's target LTV);
  3. `Erc4626SupplyFuse.enter{vault: 0xDf9C…, minSharesOut}`;
  4. guard `exit` with max LTV for `0xbd48…`.
- **Exit:**
  1. `Erc4626SupplyFuse.exit{maxSharesBurned}` (vbUSDC back);
  2. `MorphoBorrowFuse.exit` (repay);
  3. `MorphoCollateralFuse.exit`;
  4. guard.

  Any vbUSDC shortfall (cyvbUSDC fees) is bought through UTS (avKAT → vbUSDC) before the repay.
- **Accounting:**
  - market 14 adds substrate `0xbd48…` (`MorphoBalanceFuse`: collateral − debt);
  - market **100_001** (`ERC4626_0001`) substrate `0xDf9C…` with `Erc4626BalanceFuse`;
  - dependencies 100_001→7 and 14→7;
  - vbUSDC added to market 7, so idle vbUSDC between steps is counted.
- **Oracle (required, F8):** add a vbUSDC USD feed to cyavKAT's middleware `0x7B46…`, the same source cyvbUSDC uses
  (`0x6451…`, 1.00) or a Chainlink USDC feed. Without it, `MorphoBalanceFuse` / `Erc4626BalanceFuse` revert.
- **Planner rules (gate-held, written as substrates where a fuse reads them):** target LTV 33%, ceiling 35%
  (guard), TVL cap `usdcLoop.maxTvlBps` (as today).
- **Yield:** the Merkl supply incentives on `0xbd48…` / `0xf7fc…`, earned and claimed by cyvbUSDC (F15), reach
  cyavKAT through cyvbUSDC's share price. cyavKAT needs no Merkl claim for this strategy.
- **Technical notes:** set `minSharesOut` on every deposit (cyvbUSDC is small today). The strategy is **not
  instant** (B3).

### 4.4 Market map after the change
| Market | Holds | Balance fuse | Dependency |
|---|---|---|---|
| 7 | KAT, vbUSDC (plain tokens only) | IPOR `Erc20BalanceFuse` | — |
| 12 | UTS Token / Target (router v2, tokens) / Slippage | `ZeroBalanceFuse` | → 7 (**new**) |
| 14 | loop `0x80e6…`, USDC `0xbd48…` | IPOR `MorphoBalanceFuse` | → 7 |
| 19 | flash-loan Morpho | `ZeroBalanceFuse` | → 7 |
| 36 | POL position A pool / gauge | `CurveYieldRateAwareBalancerBalanceFuse` | → 7 |
| 41 | lending (live) | `MorphoOnlyLiquidityBalanceFuse` | → 7 |
| 100_001 | cyvbUSDC `0xDf9C…` | IPOR `Erc4626BalanceFuse` | → 7 |
| ZERO_BALANCE | custom fuses' typed config (E6) | `ZeroBalanceFuse` | — |
| 54 | **retired** | removed | — |

---

## Part 5. Exceptions (for the audit package)
- **E1** Outbound `Erc20TransferFuse`; the recipient allowlist and per-call caps are the boundary.
- **E2** `RateAwareBalancerBalanceFuse`, an adapted fork.
- **E3** ERC-1271 base swap (live; D5 shows there is no alternative on this vault version).
- **E5** Custom PPS guard (D3: the pre-hook cannot enforce a 0 drop within a bundle).
- **E6** Interim: custom fuses read typed config from `ZERO_BALANCE_MARKET` until IPOR assigns ids.

## Part 6. Migration of the live vault
P2 is not broadcast yet; these steps rewrite `P2_01`–`P2_04`, `P5_01` and `P6_*` rather than adding phases.

| Step | Action | Script |
|---|---|---|
| M0 | Re-export the IPOR files from `a1f79d6` byte-exact (F2); update `SOURCE_PROVENANCE.md` and recompile `upgrade/`. Adjust code that relied on `9fb9e806`-only behaviour (e.g. `previewWithdraw` / `NoSharesToWithdraw` in the WM v2 fork). | new `P0_01` |
| M1 | Deploy the official fuses at `a1f79d6` (UTS, `Erc4626Supply` / `Balance`, `UpdateMarketsBalances`, `TransientStorageMapper`, `BalanceAssetsValidation`, unmodified `MorphoFlashLoanFuse`) and the six custom fuses. Deploy the slimmed executor / WM v2 / allocation / planners. | `P2_01` |
| M2 | Gate: add fuses / balance fuses; substrates (12 Slippage down from 20%, router v2 Target; 14 + `0xbd48…`; 100_001; 7 + vbUSDC; ZERO_BALANCE typed config); dependency graphs (§4.4); **vbUSDC oracle feed**; instant list = official avKAT-paying fuses only (B3). | `P2_02` |
| M3 | Re-check the Merkl API for anything claimable by cyavKAT (none at block 44,942,500, F15); claim it if there is. Confirm that no Sushi LP or vKAT position exists (F5). | `P2_03` |
| M4 | Cut the loop over (same Morpho market, no position move). Remove `MorphoStrategy`, `VkatStrategy`, all vKAT fuses and adapter (revoke market-7 entry first, F13), `CallerReward`, the v1 `RouterSwap` fuse from the vault (**the router `0x01F9…` itself stays live**, F15), the `CurveYieldMorphoFlashLoanFuse` subclass. `RCM.removeRewardFuses` ×3 (F6). Revoke market 54. | `P2_04` |
| M5 | POL position A in the vault; revenue custody v2 (holding position B, operator-managed POL reserve, no feeders). USDC strategy enabled after the vbUSDC oracle feed. | `P5_01` |
| M6 | `P6_01` wires custody v2 on top of the live custody (guardian there, coverer, Charm allowlist, revenue and backstop repointed to v2). No migration; `P6_02` is not run. The governance path is the fee Safe (G1), not an Aragon proposal. | `P6_01` |
| Rollback | Everything up to M4 is reversible: old fuses stay installed until M4, and M4 runs only after the fork suite passes on a post-M3 fork. | `P2_99` |

Untouched: market-41 lending, wrapper, haircut oracle, signature fuse + 1271 base, RCM (vesting continues).

## Part 7. Changes outside the fuses
- **Executor:**
  - minus `harvest`, the native-exit lane and the vKAT sync;
  - plus settlement (`runSources` / `runPolSale` / `settle`), the per-cycle wind-up loop (B1) and the on-chain POL
    sell-or-burn (B2), all as `try vault.execute(...)`;
  - builds loop and USDC bundles from official fuses;
  - re-check EIP-170 under the `size` profile. If it does not fit, the cycle / settlement logic moves to a library
    or a second on-chain executor module (still on-chain).
- **Planners (on-chain views):**
  - loop: per-cycle amounts and required profit (today's ramp), unwind search, max loss;
  - USDC strategy: new, with LTV and TVL cap;
  - lend, POL A: R3 mapper items;
  - deleted: vKAT and LP planners. The farm planner loses its Sushi-position valuation.
- **Custody (§2.4):** the live custody keeps the loop; custody v2 is the layer on top (allocation, Charm farm, POL B,
  Merkl, cover) in one 21.2 KB contract. Done 2026-10-10.
- **Governance (§2.5):** the gate deploys with `dao` = the fee Safe (G1); there are no archive contracts and no guardian
  contract. `P3_01` / `P3_02` / `P4_*` are not run; `P3_03` deploys the gate only; `P3_05` / `P3_99` / `P6_01` lose
  their Aragon steps.
- **Router v2:** unchanged (Sushi venue kept). It is the UTS Target, so its protected minimum covers every vault
  swap.
- **Gate:**
  - remove LP / vKAT / vault-harvest keys and the farm's Sushi-position keys;
  - add substrate bindings (UTS slippage, guard ceilings, transfer caps, USDC LTV ceiling) and
    `syncSubstrates(marketId)`.
- **WM v2:** minus the native-exit path; `requestFeeFuse` → `CurveYieldRequestFeeSharesFuse`; reconcile with
  `a1f79d6`'s `WithdrawManager`.
- **Docs:**
  - READMEs for the six custom fuses;
  - amend `SWAP_ROUTING_SPEC` (UTS + router v2), `POL_SPEC` (position B Merkl claim), `CUSTODY_FARM_SPEC` (no Sushi
    NFT / staker), `GATE_CONFIG_SPEC`, `CONFIG_VALUES`, `CONTRACTS_*_LIST`, `CONTRACT_CLASSIFICATION_AND_ROLES`,
    `SOURCE_PROVENANCE`, `FUSE_INVENTORY` (superseded rows), the README layout table.
- **Tests:** delete or archive the tests of removed contracts.

## Part 8. Testing and acceptance
- **Provenance:** a script reproduces F2 (build `PlasmaVault` / `PlasmaVaultBase` at the pin, diff against
  `cast code`). Every IPOR fuse we deploy is compiled from the pinned sources.
- **Conformance** over the final fuse list:
  - R1 / R2 / R3 / R8;
  - no `owner()`;
  - no `executeInternal` selector in any custom fuse;
  - ungranted substrate reverts;
  - no typed (top-byte ≠ 0) substrate in market 7.
- **Removal:** after M4, no address or market from Part 2 is in the vault's fuses, balance fuses, instant list,
  substrates or the RCM reward fuses. `forge build` is green with the deleted files gone.
- **Fork tests (Katana):**
  - loop wind-up cycles (swap through router v2) and unwind bundles built from official fuses (B1). The executor
    stops at the first unprofitable cycle;
  - the USDC strategy enter / exit against the live cyvbUSDC, including partial cyvbUSDC liquidity and the oracle
    feed;
  - UTS through router v2: the router minimum and UTS slippage both enforced;
  - POL B2 (sale reverts → burn runs, both in one executor transaction);
  - custody v2 `harvestMerkl` against the live distributor (Charm rewards, POL B included);
  - custody v2 `deployAll` feeding the live custody's loop (v2 as its guardian), and `cover` from idle avKAT + the farm;
  - the guard rejects any PPS drop;
  - dependency 12→7 refreshes market 7 (F12);
  - instant withdrawal draws only from the B3 list;
  - an M0–M5 migration rehearsal with `totalAssets` continuity per market.
- **Equivalence (B1, B2, settlement):** the executor-driven cycles, sell-or-burn and settlement give the same cycle
  counts and amounts as the 2026-09-27 fuse implementation on recorded fork states.
- **Exit criteria:** all green; every custom fuse meets R1–R15 or a listed exception; READMEs written.

## Part 9. Work order
1. M0 pin change and rebuild.
2. **Removals and discontinuations** (Part 2, incl. `archive/` dependencies) to a
   green build. (Custody layer: done.)
3. Executor / WM v2 / planner changes (settlement move, B1, B2, B3, USDC strategy); custody changes (§2.4).
5. Rewrite the six custom fuses.
6. Gate bindings and scripts.
7. Tests (Part 8), READMEs, audit package.

## Appendix: how F2 was established
Implementation `0xe0873c4f…a3b8` (from the clone's bytecode) and base `0x6D73E66A…4b49` (from
`CurveYieldVaultBase1271.ORIGINAL_BASE()`) were fetched with `cast code`. `contracts/` was exported from
`IPOR-Labs/ipor-fusion` at `a1f79d6`, with OpenZeppelin 5.0.2 from npm. It was built with solc 0.8.30, optimizer
200 runs, EVM cancun (IPOR's `foundry.toml` with the optimizer runs that reproduce the deployed size). CBOR metadata
was stripped before diffing. Results:
- `PlasmaVault`: 23,855 bytes, differing only in 2 × 20-byte link placeholders (= `PlasmaVaultMarketsLib` at
  `0x6475…cf08`).
- `PlasmaVaultMarketsLib`: identical, apart from its 20-byte self-address.
- `PlasmaVaultBase`: 21,032 bytes, identical.
- The pinned `9fb9e806` lacks `NoSharesToWithdraw()` (`0xf22c5001`), which the live code contains.
- `setRedemptionDelay` (2026-09-14 release) is absent from the live base.

---

## Part 10. Implementation status (2026-10-10, end of session 1)

No test was run in this session by instruction. Everything marked "done" compiled with `forge build` (src, script, test). The
non-fork suites (118 tests) passed before the last additions. The fork suites are **written but not run**, except that `P0_00`,
`P2_01` and `P2_02` executed on a Katana fork.

### 10.1 Contracts in the `cyavKAT` folder (kept for v2)

| Contract (live address) | Where in the folder | Role in v2 |
|---|---|---|
| cyavKAT PlasmaVault `0xEd83…4548` (EIP-1167 clone of `0xe0873c4f…`), PlasmaVaultBase `0x6D73…4b49`, PlasmaVaultMarketsLib `0x6475…cf08` | `ipor-fusion/contracts/vaults/**` at `a1f79d6` (byte-verified, F2) | the vault; unchanged |
| ERC-1271 base `0x0a9e…b365` and `CurveYieldSignatureFuse` `0x4a94…AeEb` | `upgrade/src/katana/` | kept (D5) |
| Live loop custody `CurveYieldProfitCustody` `0xe7D1…5ADf` | `deployed/phase1-controller/` | kept unchanged (D14) |
| Sushi V3 fee router `0x01F9…3582` | `deployed/phase1-router/` | kept live (F15, F16) |
| Lending: wcyavKAT `0x10dF…4692`, fee splitter `0xB537…8799`, burn forwarder, haircut oracle `0x2926…5137` | `upgrade/src/wrapper/`, `upgrade/src/oracles/` | kept |
| IPOR RewardsClaimManager `0xA774…72Cb`, PriceOracleMiddleware `0x7B46…47D6`, Erc20BalanceFuse (market 7) | `ipor-fusion/contracts/{managers/rewards,price_oracle,fuses/erc20}`, exported from `a1f79d6` | kept; **not byte-verified** against the live deployments (only the vault and base are) |
| IPOR Morpho collateral / borrow / supply fuses, FeeManager, AccessManager, `ERC4626PriceFeed`, `FixedValuePriceFeed` | `ipor-fusion/contracts/**` | kept |
| Live contracts removed by M4 (record only): old `BurnRequestFeeFuse`, v1 Morpho strategy, vKAT fuses and adapter, `CallerRewardFuse`, MerklAutoHarvest, `MorphoFlashLoanFuse` subclass, old WM `0x59B3…`, ControllerV2 | `deployed/phase1-*` | removed from the vault by P2_04 |

**Source not in the folder (cannot be restored from here):** the v1 `CurveYieldRouterSwapFuse` `0x1fB8…` and
`CurveYieldMerklRewardSweepFuse` `0x8c82…`. Both are removed from the vault in M4 and nothing depends on them, so their addresses
are the only record. The stale `upgrade/deployments/katana-phase2.json` has been removed (§2.6); the scripts now refuse any
recorded address that has no code.

### 10.2 Done

- **M0**: IPOR sources re-exported byte-exact from `a1f79d6` (90 files, 0 diffs), including the official swapper, ERC-4626,
  update-balances, transient-storage and balance-validation fuses. `SOURCE_PROVENANCE.md` is updated to the new pin.
- **Removals (Part 2)**: LP, vKAT, position readers, holder fuses, `CallerRewardFuse`, `RouterSwapFuseV2`, the USDC supply-loop
  fuse, `PlannedInstantWithdraw`, `TryElse`, the loop fuses, the withdrawal request fuse, the executor's harvest / native-exit /
  vKAT sync, the WM v2 native-exit cost path and emergency-exempt arming, and the gate keys for LP / vKAT / harvest / governance.
  Removed files were moved (not deleted) out of the tree; discontinued fork suites were excluded from the v21 package.
- **Custom fuses (§4.2)**: bundle guard (nested snapshots, substrate ceilings, LTV check, IPOR `PlasmaVaultMarketsLib` refresh),
  ERC-20 transfer, burn held shares, request-fee shares, rate-aware Balancer balance (names only), ERC-1271 install and config,
  and `CurveYieldSubstrateLib` (type in the top byte).
- **Planners and executor (§4.1, §4.3, Part 7)**: loop planner (one cycle per call, flash-loan unwind through the official fuse,
  UTS swaps via router v2), USDC strategy planner (cyvbUSDC), allocation controller (loop and USDC strategic, lend and POL
  reserve), POL controller (exit bundles, sell-or-burn pairs), and an executor with B1 cycles, B2 sell-or-burn, on-chain
  settlement and no instant loop / USDC (B3). EIP-170: executor 21.6 KB and WM v2 23.2 KB on the **default profile**;
  `[profile.size]` removed.
- **Gate (R5)**: substrate bindings, `syncSubstrates`, `previewSubstrates`; `dao` = fee Safe (G1).
- **Scripts**: `Phase2Base`, `P0_00`, `P2_01` to `P2_04`, `P3_03` to `P3_05`, `P3_99`, `P5_01`, `P6_01`, `P9` in the active script tree; the obsolete `P6_02` script has been removed.
- **Tests written**: gate substrate bindings (`GateSubstrates.t.sol`, not yet compiled or run) and `ConformanceFork.t.sol`
  (removals, market map, deploy keeps PPS; not run). Obsolete tests were removed from the WM suites.

### 10.3 Decisions taken while implementing (to confirm)

1. UTS slippage default is **4%** (the spec suggested 1%): the POL sale may go up to the 3.9% request-fee headroom below NAV, and
   at 1% it would always fall back to a burn. Range 0.1% to 20%, DAO class.
2. `usdcLoop.maxTvlBps` default is **10%** (it was 30% "as today"): the USDC strategy is now a strategic set beside the 75%
   loop, and 30% would leave no reserve. Target LTV 33%, guard ceiling 35%.
3. Balance fuses that already exist live (markets 12 and ZERO) are reused, not redeployed.
4. Dust KAT left after an unwind stays in market 7 (no sweep leg); the free collateral top-up repays debt with it.
5. When the router cannot quote an avKAT to vbUSDC shortfall, the USDC unwind shrinks to what cyvbUSDC covers.

### 10.4 Still to do

**Blocking the live migration**
- The old WM `0x59B3…` has **open requests (about 294 cyavKAT at block 44,946,877)**; `P2_03` refuses until they are fulfilled.
- The Merkl re-check for cyavKAT and the RCM (M3) before `removeRewardFuses`; no script written yet.
- A provenance script reproducing F2 (build at the pin under its own profile, diff against `cast code`); not written.

**Build and tests (nothing below has been run)**
- Compile and run `GateSubstrates.t.sol` and `ConformanceFork.t.sol` and fix what they reveal. The guard, swapper and planner
  bundles have **never executed on a fork**.
- Fork scenarios to add: B1 wind-up stops at the first unprofitable cycle; unwind bundle and max-loss guard; USDC enter and exit,
  including partial cyvbUSDC liquidity and the oracle feed; UTS with the router minimum and slippage; B2 sell-or-burn; custody
  v2 `harvestMerkl`, `deployAll` into the live custody, and `cover`; the guard rejects any PPS drop and nests; 12 to 7 refresh;
  instant withdrawal only from the B3 list; an M0 to M5 rehearsal with `totalAssets` continuity; equivalence of cycles,
  sell-or-burn and settlement against the 2026-09-27 fuse implementation.
- Fuse conformance tests (R1/R2/R3/R8, no `owner()`, no `executeInternal`, ungranted substrate reverts, no typed substrate in
  market 7) and `enterTransient` tests.
- Check on a fork that the oracle values avKAT on the conversion basis (the guard's gain check assumes it) and that cyavKAT, KAT,
  avKAT and vbUSDC are all priced for UTS.

**Docs (Part 7)**
- Per-family READMEs for the six custom fuses; amendments to `SWAP_ROUTING_SPEC`, `POL_SPEC`, `CUSTODY_FARM_SPEC`,
  `GATE_CONFIG_SPEC`, `CONFIG_VALUES`, `CONTRACTS_*_LIST`, `CONTRACT_CLASSIFICATION_AND_ROLES`, `FUSE_INVENTORY` and the README
  layout table; mark `PHASE3/4_DESIGN_SPEC` discontinued; the audit package for exceptions E1, E2, E3, E5, E6.

**Open design points**
- The gate holds `FUSE_MANAGER` (300) only after `P3_05`; confirm that role 300 is the one `grantMarketSubstrates` needs on this vault.
- The router routes for the farm tokens and for avKAT to vbUSDC depend on pool observation history; verify the quotes on a fork.
- `P2_02` (deployer) writes the config markets before the gate holds roles; `P3_05` asserts that the gate's lists equal the vault's.

---

## Part 11. v6 implementation delta and remaining acceptance (2026-10-10)

**This section supersedes the *implementation-status* claims in Part 10, not the
architecture decisions in Parts 0–9.** V6 is based on the v5 governance/Quest
stack. G1's historic statement that the fee Safe is the gate's `dao` is
superseded by `IPOR_GOVERNANCE_GATE_v5.md`: the gate delegates operating-role
authorization to the original IPOR Access Manager, the Safe retains IPOR OWNER,
while dedicated `ADMIN_FEE` is a self-managed gate-local role.

**Implemented in v6 (source changes)**

- M3: new `upgrade/scripts/merkl_preflight_v6.py` queries Merkl's v4 user
  reward endpoints for both vault and RCM. It fails closed if either has
  currently claimable rewards (`amount-claimed`), uses a Katana block-bound
  JSON receipt, and `P2_04` refuses to remove reward fuses unless the receipt
  matches chain/wallets, is ≤200 blocks old and has the expected block hash.
  Unclaimable pending values must be explicitly acknowledged.
- Fork harness migrates the **existing** Quest wrapper to the revised persistent
  signer config fuse before P2_01 and tests M4 with its own labelled synthetic
  receipt. Live scripts never create a synthetic Merkl receipt.
- R3 transient entrypoints added to guard, request-fee escrow, generic install/
  config ERC-1271, and explicit unsupported paths for burn/transfer. R2
  `enter`/`exit` wrappers added for request-fee shares, retaining legacy WM ABI.
  `CurveYieldRateAwareBalancerBalanceFuse` now rejects market ID zero (R1).
- New independent `FuseConformanceV6.t.sol` for R1, R3 malformed input,
  R8 zero/ungranted and disallowed owner/executeInternal selectors. Six
  per-family custom fuse READMEs in `docs/fuses/`; Merkl, provenance and
  deployment docs integrated with the current mandatory Quest/v5 governance.
- `upgrade/scripts/verify_ipor_pin_v6.py` checks all 90 bundled official
  IPOR sources byte-for-byte against pin `a1f79d6` in a GitHub environment.

**Not yet verified:** no local compiler or dependencies were used (per the
user's local-environment prohibition). V6 has **not** passed a `forge build`,
Foundry tests or a Katana fork run. Live provenance also requires independent
`cast code` runtime comparison; the source checker does not replace it.

**Blocking / missing runtime acceptance:** live P2_03 still needs zero open
v1 WM requests and confirmed vault permissions; the full Part 8 fork scenarios
(B1 profitable/unprofitable/unwind, USDC partial-liquidity, UTS/router slippage,
POL B2 fallback, custody harvest/deploy/cover, guard nested PPS, 12→7 refresh,
instant sources, M0–M5 migration and economic equivalence) have not been
executed or proven. They must run in a remote GitHub runner with a Katana RPC
before the upgrade can be declared release-ready. The new-vault generic
ERC-1271 fuses are not installed on the existing cyavKAT vault. R2's single-
action goal has a **narrow necessary compatibility exception** for the request
fee share fuse, documented in `docs/fuses/04_REQUEST_FEE_SHARES_v6.md`.
