# cyavKAT system: long contract list

Katana (chain 747474). Companion to `CONTRACTS_SHORT_LIST.md`. Sources used:
- local contract sources in `work/controller`, `work/merkl`, `work/router`, `work/contracts`, and `Desktop/Claude/src`;
- live getter reads on 2026-09-24 (quoted as **Live**);
- the vault's full event history (`idle-avkat-strategies/inventory/inventory.json`);
- (2026-09-27) the finished Phase 2/3/4 source in `work/phase2/src` (accounting, allocation, executor, governance,
  katana, leaderboard, lend, libraries, lp, morpho, oracles, plus, vkat, withdraw, wrapper), the `P2_*`/`P3_*`/`P4_*`/
  `L*`/`K1_QuestSigning` deploy scripts in `work/phase2/script`, and `work/phase2/deployments/*.json` (only
  `katana-lending-v1.json` and `katana-quests.json` hold confirmed live addresses; `katana-phase2.json` etc. are
  fork/dry-run values from the deploy scripts' local runs);
- (2026-09-27, later same day) the **fuse standardization refactor**: `FUSE_STANDARDIZATION_SPEC.md`,
  `LOOP_FUSES_SPEC.md`, `FUSE_INVENTORY.md`, `POL_SPEC.md`'s implemented section, the new `src/generic` (13 generic
  IPOR-style fuses + `CurveYieldSubstrateTypes`), `src/accounting/CurveYieldPositionReaders.sol`, the rewritten
  controllers (now planners), and the updated `P2_01`–`P2_03`, `P4_02`–`P4_04`, `P5_01` scripts. The pre-refactor
  fuse sources are kept at `phase2/_pre-standardization-2026-09-27/` (code and old `test/`, not deleted from disk,
  only from `src`/`script`'s live tree).

Only IPOR-registered markets **7**, **14**, **19**, **36**, **41**, **54** (substrate registry, extended by the
refactor) and, for cyavKAT+, **100001**/**100002** (`ERC4626_0001`/`ERC4626_0002`) are used anywhere in this system.
See PART G for the full market-substrate layout after the refactor.

Conventions:
- **bps**: 10,000 = 100%.
- **WAD**: 1e18 = 100%.
- **Access** says who may call:
  - *owner*: Ownable2Step owner, currently the deployer `0x11b7…FA35` unless noted.
  - *role N*: IPOR access-manager role.
  - *vault ctx*: runs only by delegatecall inside the vault.
  - *controller*: `msg.sender` must be the set's controller.
  - *public*: anyone.
- **Impl-only** means the call must go to the fuse's own address (the `VERSION` storage holds the config). The vault's delegatecalls read that config through `VERSION`.

Part A documents what exists today. Part B is the draft function surface of every contract still to be built. Each phase's design spec finalises its part of Part B before any code is written.

---

## PART A: EXISTING CONTRACTS

### A0. Live system state (2026-09-24)

| Item | Value |
|---|---|
| Vault total managed avKAT (Morpho fuse view) | 9,577.66 avKAT |
| Morpho loop position | 27,583 avKAT collateral · 27,933 KAT debt · **LTV 75.00%** · net equity 6,895 avKAT |
| Allocation config | Morpho 7,501 bps · vKAT 0 bps · reserve (idle) 2,499 bps |
| Morpho strategy config | request fee 450 · minimum profit 50 · loss allowance 400 · wind-up profit 200 → 450 bps (Phase 1) |
| Withdraw manager | window 90 days · instant fee 1.25% · request fee 4.5% (Phase 1) |
| Caller rewards (all 4 actions) | 10 bps, capped at 3 avKAT · extra wind-up reward 100 bps of excess profit |
| Profit custody | revenue share 30% · wind-up split 16% rewards manager / 9% fee recipient · position LTV 74.16% (431 avKAT / 431 KAT) |
| Swap protection | avKAT↔KAT: 0 bps assumed fee, **30 bps slippage** (Phase 1) · router routes both ways via the **1% pool**, TWAP 900 s / 330 bps · 1% pool price-history buffer raised to 100 (Phase 1, active from its next swap) |
| Reward tokens swept by harvest | `0x203A662b…FD36` (vbUSDC) |
| vKAT vote target | gauge `0x744676B3…395c` at 100% |

### A1. Interconnection map: the main flows

```
Keeper ──► ControllerV2 ──execute()──► PlasmaVault (delegatecall) ──► fuses
                  ▲                                  │
                  └──── callbacks (release / contribution) ◄── MorphoStrategyFuse
```

1. **deployAssets** (public, ControllerV2):
   1. Prune expired withdraw requests (up to 500).
   2. `RewardsClaimManager.transferVestedTokensToVault()`.
   3. `vault.execute`, running in order:
      - `MorphoStrategyFuse.deployAssets()`: up to 8 wind-up cycles. Each cycle supplies collateral through MorphoCollateralFuse, borrows through MorphoBorrowFuse, swaps KAT→avKAT through RouterSwapFuse, and sends a profit share to ProfitCustody. After the cycles it requires vault avKAT ≥ reserve + reward.
      - `VkatStrategyFuse.publishDeployReward()`
      - `MorphoStrategyFuse.fundDeployReward()`
      - `VkatStrategyFuse.finalizeDeploy()`: lock avKAT to vKAT and vote.
      - `CallerRewardFuse.enter(0)`
   4. The controller pays the caller.
2. **fulfillAll** (public):
   1. Prune. If the queue is not fully pruned, stop there (event only).
   2. `MorphoStrategyFuse.fulfillAll()` finds the largest profitable share count. It unwinds through the FlashLoan, Collateral, Borrow and Swap fuses, then calls back `ControllerV2.releaseActiveSharesFromStrategy`, which calls `WithdrawalManager.releaseActiveShares`.
   3. `CallerRewardFuse.enter(2)`.
3. **fulfillFor** (public): a targeted release of one requester's shares. If the unwind costs more than the fee covers, the caller pays the difference (`maxContributionAvkat` bound) through `collectContributionFromStrategy`.
4. **emergencyRepay** (public): only when the loop LTV is above 76%. De-levers back to 75% with a full or partial plan.
5. **harvest** (public):
   1. The controller sets `harvestActive`.
   2. `RewardsClaimManager.claimRewards([MerklAutoHarvestFuse.harvest])` claims from the Merkl distributor.
   3. `RouterSwapFuse.swapAllRewards()` swaps whitelisted tokens to avKAT.
   4. The caller reward goes through `CallerRewardFuse.forwardHarvestReward`; the rest vests in the RewardsClaimManager over 15 days.
6. **User withdrawals:**
   - *Instant* `redeem`: the vault pulls idle avKAT. If short, it calls instant-withdrawal fuse `VkatStrategyFuse.instantWithdraw`, which converts vKAT during the first half of the epoch. `WithdrawalManager.canWithdrawFromUnallocated` charges the 1.25% fee; the ProfitCustody revenue-share cut comes from that fee.
   - *Scheduled* `requestShares`: charges the 4.5% request fee in escrow. After a fulfil releases the shares, the user redeems within the window.

### A2. CurveYield contracts: complete function reference

#### A2.1 CurveYieldMorphoStrategyFuse: `0x79E88DD967Ef9a31046455dB94b1e487329Ed705`
The avKAT/KAT Morpho loop in market `0x80e6…83e9` (avKAT collateral, KAT loan, LLTV 77%). Vault market 14.

Constants:
- MAX_MORPHO_ALLOCATION_BPS 7,501
- MAX_COMBINED_ALLOCATION_BPS 9,000
- TARGET_LTV 7,500
- EMERGENCY_LTV 7,600
- MAX_LOOP_COUNT 8
- MAX_MIN_PROFIT_BPS 1,000

| Function | Access | Parameters / ranges | What it does | Interacts with |
|---|---|---|---|---|
| `setController(address)` | owner, impl-only | ≠ 0 | Sets the controller allowed to trigger actions. | — |
| `setDependencies(struct)` | owner, impl-only | 9 addresses, all non-zero | Sets withdrawManager, rewardsClaimManager, collateral, borrow, flash, swap, callerReward, vkat fuses, and profitCustody. | — |
| `setMorphoAllocationBps(uint16)` | owner, impl-only | ≤ 7,501; plus vKAT bps ≤ 9,000 | Sets the loop's target share of total managed avKAT. | VkatStrategyFuse.vkatAllocationBps |
| `setWithdrawalEconomics(req, minProfit, lossAllow)` | owner, impl-only | req ≤ 10,000; minProfit ≤ 1,000; lossAllow ≤ 10,000; req ≥ minProfit | Sets the unwind economics. Effective loss allowance = min(req − minProfit, lossAllow). | — |
| `setMorphoWindupEconomics(base, upper)` | owner, impl-only | base ≤ upper ≤ 1,000 | Sets the required wind-up profit. It ramps linearly from `base` to `upper` as the position fills toward its limit. | — |
| `deployAssets()` | vault ctx + controller + execution started | — | Runs up to 8 cycles toward 75% LTV. Each cycle needs profit ≥ the required bps, where profit = avKAT produced × **conversion rate** vs KAT borrowed; spec #5 replaces this with real market value. A 30% profit share (revenueShareBps) goes to ProfitCustody. **Reverts `UnwindNotSafe` if vault avKAT < reserve + reward (the spec #18 bug).** Publishes (action, basis, excess, reward) to transient storage. | Collateral, Borrow, Swap fuses; ProfitCustody; CallerRewardFuse quote |
| `fulfillAll()` | same | — | Binary-searches the largest profitable share count up to `activeUnreleasedShares`. Plans an unwind (repay, withdraw, sell) to 75% LTV. Checks the round-trip loss plus reward is ≤ the loss allowance, runs it, funds the caller reward, and releases the shares through a controller callback. | FlashLoan, Collateral, Borrow, Swap fuses; WM via controller |
| `fulfillFor(caller, requester, shares, maxContribution)` | same | shares = 0 means all available; ≤ available | Targeted release. The caller pays any cost beyond the allowance, up to `maxContribution`. | as above + controller `collectContributionFromStrategy` |
| `emergencyRepay(uint256 repayKat)` | same | LTV > 7,600; repayKat ≤ debt; 0 = full plan | De-levers to 75% (full plan), or repays a given amount while staying ≤ LLTV (partial). | FlashLoan, Collateral, Borrow, Swap fuses |
| `fundDeployReward()` | same | — | Moves the Morpho share of the deploy reward to the controller after the vKAT fuse has published the split. | VkatStrategyFuse transient output |
| `morphoSnapshot()` | view | — | Returns collateral, debt, collateral value in KAT (oracle), LTV bps, and net equity in avKAT. | Morpho, oracle, avKAT |
| `totalManagedAvkat()` | view | — | Vault avKAT + loop net equity + RewardsClaimManager balance + vKAT locked KAT converted to avKAT. **Excludes lent and LP avKAT.** | Morpho, RCM, vKAT escrow |
| `reserveAllocationBps()` | view | — | 10,000 − Morpho bps − vKAT bps. | VkatStrategyFuse |
| `morphoAllocationBps()`, `strategyConfig()`, `dependencies()` | view | — | Config reads. | — |
| `currentUnwindCostBps()` / `quoteUnwindForShares(shares)` | view | shares ≤ active unreleased | The unwind cost for the given (or all) requested shares, and the extra contribution the caller would need to pay. | Swap fuse view quotes |

#### A2.2 CurveYieldVkatStrategyFuse: `0x987C05943855B22552898F032c1AEa7930E340da`
vKAT lifecycle: lock avKAT into the vault's vKAT NFT, vote, and convert back to avKAT. It is also the vault's **instant-withdrawal fuse**. Uses market 54 substrates (gauges).

Constants:
- MAX_VKAT_ALLOCATION_BPS 9,000
- combined cap 9,000
- VKAT_DEPLOY_WINDOW 3 days before the vote ends

| Function | Access | Parameters / ranges | What it does | Interacts with |
|---|---|---|---|---|
| `setController(address)` | owner, impl-only | ≠ 0 | Sets the controller. | — |
| `setDependencies(struct)` | owner, impl-only | Morpho fuse and callerReward ≠ 0 | Sets its dependencies. | — |
| `setVkatAllocationBps(uint16)` | owner, impl-only | ≤ 9,000; plus Morpho bps ≤ 9,000 | Sets the vKAT target share (**Live: 0**). | MorphoStrategyFuse |
| `setVoteTargets(gauges[], weights[])` | owner, impl-only | non-empty, equal length, non-zero entries | Sets the gauge vote split. | — |
| `publishDeployReward()` | vault ctx + controller | — | Reads the Morpho result, plans the vKAT deployment (capacity = limit − current, above the reserve), and publishes the combined reward split. | MorphoStrategyFuse output, CallerRewardFuse quote |
| `finalizeDeploy()` | vault ctx + controller | — | Funds the vKAT reward share. When allocation is active, merges the planned avKAT into the existing vKAT NFT (or creates one) and refreshes the vote. | avKAT `withdrawTokenId`, vKAT escrow `merge`, gauge voter, delegation adapter |
| `convertNeeded(shares)` | vault ctx, execution started | — | Converts vKAT back to avKAT (split or whole NFT) to supply `shares` avKAT. | vKAT escrow `split`, avKAT `depositTokenId` |
| `exit(tokenId, kat, minShares)` / `exitWhole(tokenId, minShares)` | vault ctx, execution started | tracked NFT; both halves ≥ escrow minDeposit | Converts part or all of a specific NFT. | same |
| `instantWithdraw(bytes32[] params)` | vault ctx | params[0] = avKAT shares needed | Instant-withdrawal hook. Converts only while `vkatConversionAvailable`; otherwise returns 0 silently. | same |
| `vkatAllocationActive()` | view | — | True when voting is active and fewer than 3 days remain before the vote ends. | epoch clock, gauge voter |
| `vkatConversionAvailable()` | view | — | True in the first half of the 2-week epoch when the escrow allows splits. | epoch clock, escrow |
| `convertibleVkatAvkat()`, `voteTargets()`, `dependencies()`, `vkatAllocationBps()`, `CONTROLLER()` | view | — | Reads. | — |

#### A2.3 CurveYieldCallerRewardFuse: `0x70a2f848E21c912D660FE2263E5Be538268A41Ec`
Keeper reward validation and payment. Also the withdraw manager's in-vault helper.

Actions: 0 deploy · 1 harvest · 2 fulfilAll · 3 emergency.

Constants:
- MAX_REWARD_BPS 300
- MAX_REWARD_CAP 100 avKAT
- MAX_EXTRA_WINDUP_REWARD_BPS 1,000

| Function | Access | Parameters / ranges | What it does | Interacts with |
|---|---|---|---|---|
| `setController(address)` | owner, impl-only | ≠ 0 | Sets the controller. | — |
| `setWithdrawManager(address)` | owner, impl-only | ≠ 0 | Sets the manager allowed to move request-fee shares. | — |
| `setSourceFuse(action, source)` | owner, impl-only | action < 4 | Sets the fuse whose transient output funds each action (Live: 0 = vKAT, 1 = swap, 2/3 = Morpho). | — |
| `setCallerRewardConfig(action, bps, cap)` | owner, impl-only | bps ≤ 300; cap ≤ 100e18 | Reward rate and cap per action (**Live: 10 bps / 3 avKAT each**). | — |
| `setExtraWindupCallerRewardBps(bps)` | owner, impl-only | ≤ 1,000 | Extra reward as a share of wind-up excess profit (**Live: 100**). | — |
| `quoteMorphoReward(action, basis, excess)` | view | — | Exact reward = basis × bps, capped by 300 bps and the cap. | — |
| `quoteDeployRewardSplit(morphoBasis, vkatBasis, excess)` | view | — | One capped deploy reward split pro rata between Morpho and vKAT. | — |
| `enter(action, recipient)` | vault ctx + controller | recipient ≠ 0 or vault | Checks the source fuse's published reward equals the quote, then marks it consumed. | source fuse transient storage |
| `forwardHarvestReward(basis, amount)` | vault only, impl address, harvest active | amount ≤ basis × bps ≤ cap | Forwards the harvest caller reward to the controller. | ControllerV2.harvestActive |
| `moveRequestFeeShares(from, to, amount)` | vault ctx, caller = WM | one side must be the WM | Moves cyavKAT fee shares through PlasmaVaultBase `updateInternal`. | WithdrawalManager |
| `configureManagerAssetAllowance(prev)` | vault ctx, caller = WM | — | Rotates the vault's avKAT allowance to the current WM. | WithdrawalManager |

#### A2.4 CurveYieldRouterSwapFuse: `0x1fB8b83bAf40c90F0b450A3fd7A8b2E97Ab2a3Ff`
Swaps through the fee router with quote + TWAP protection; also sweeps harvested rewards. Market 7.

Constants:
- MAX_ASSUMED_ROUTER_FEE_BPS 2,000
- MAX_SLIPPAGE_BPS 500
- minimum reward output 1 avKAT
- RewardsClaimManager vesting must be 15 days

| Function | Access | Parameters / ranges | What it does | Interacts with |
|---|---|---|---|---|
| `enter({tokenIn, tokenOut, amountIn, requiredNetAmountOut})` | vault ctx, execution started | tokenOut ∈ {avKAT, KAT}; amountIn > 0 | Exact-input swap. The minimum output is the higher of (quote − fee − slippage, the TWAP floor) and the caller's minimum. Checks exact balance deltas. | Router `swapExactInput`, QuoterV2 |
| `quoteExactInput(in, out, amt)` | impl-only (state-changing quote) | — | Returns (expected net, minimum net) from QuoterV2 plus the TWAP floor. | QuoterV2, router |
| `requiredInput(in, out, needOut, maxIn)` | impl-only | maxIn > 0 | Searches for the smallest input that yields `needOut`. | same |
| `quoteExactInputView` / `requiredInputView` | view | — | Same, but uses **only the TWAP floor** (used by the Morpho unwind plans). | router TWAP |
| `setRouteProtection(in, out, feeBps, slipBps)` | **role 300 (FUSE_MANAGER)**, no delay | fee ≤ 2,000; slippage ≤ 500; route must exist | Per-direction protection (**Live avKAT↔KAT: 0 / 30**). | router `routeFor` |
| `setRewardToken(token, enabled)` | role 300 | not avKAT or KAT; route and protection must exist | Adds or removes a harvest reward token (Live: vbUSDC). | router |
| `setRewardFuse(address)` | role 300 | ≠ 0 | Sets the caller-reward sink for harvest. | — |
| `swapAllRewards()` | vault ctx via MerklAutoHarvestFuse marker, harvest active | — | Swaps each whitelisted reward to avKAT. Sends the caller reward through CallerRewardFuse and vests the rest in the RewardsClaimManager (15 days). | CallerRewardFuse, RewardsClaimManager, router |
| `getRewardTokens()`, `REWARD_FUSE()`, `ROUTER()`, `MANAGER()`, `AUTHORITY()`, `QUOTER_V2()` | view | — | Reads. | — |

#### A2.5 CurveYieldMorphoFlashLoanFuse: `0x84927bFf2a35a543ed94A7d96D5ccd162a167947`
Thin subclass of IPOR `MorphoFlashLoanFuse` (market 7). `enter({token, amount, callbackFuseActionsData})` takes a Morpho flash loan. In the callback it runs the nested fuse actions inside the vault; the vault's `onMorphoFlashLoan` callback handler repays. The Morpho fuse uses it for unwinds. Interacts with Morpho Blue and the PlasmaVault callback handler.

#### A2.6 CurveYieldKatanaVaultControllerV2: `0xbFdf2d2653859B66A8A15e1C85F6d6cdEe89698f`
The public executor. It holds vault ALPHA (role 200) to call `execute`. Owner: deployer.

| Function | Access | Parameters / ranges | What it does | Interacts with |
|---|---|---|---|---|
| `setDependencies(struct)` | owner | 6 addresses, all contracts | Sets WM, RCM, Morpho, vKAT, callerReward and merklAutoHarvest fuses. | — |
| `deployAssets()` | public, nonReentrant | — | Flow A1-1; pays the caller reward. | WM, RCM, vault, fuses |
| `harvest(tokens[], amounts[], proofs[][])` | public | Merkl proofs | Flow A1-5. | RCM, MerklAutoHarvestFuse |
| `fulfillAll()` | public | — | Flow A1-2. Defers (event only) if pruning is incomplete. | WM, Morpho fuse |
| `fulfillFor(requester, shares, maxContribution)` | public | caller must have approved the controller for avKAT when a contribution is due | Flow A1-3. | Morpho fuse, WM |
| `emergencyRepay(repayKat)` | public | see A2.1 | Flow A1-4. | Morpho fuse |
| `pruneExpiredRequests()` | public | batch 500 | Prunes the WM queue. | WM |
| `releaseActiveSharesFromStrategy`, `releaseForFromStrategy`, `collectContributionFromStrategy` | vault only, during `strategyActive` | amount ≤ maximum | Strategy callbacks into the WM, and the caller-contribution pull. | WM, avKAT |
| `currentUnwindCostBps`, `quoteUnwindForShares`, `morphoSnapshot`, `totalManagedAvkat`, `vkatAllocationStatus`, `fixedAddresses`, `dependencyAddresses`, `fuseAddresses` | view | — | Pass-through reads. | Morpho and vKAT fuses |
| `harvestActive`, `strategyActive` | view | — | Re-entrancy context flags read by the fuses. | — |

#### A2.7 CurveYieldWithdrawalManager: proxy `0x59B340EAb30AFE0cecD51C609d3190e8C75C40AE` (impl `0x3710c70D…d94D`)
A derivative of IPOR's WithdrawManager with a request queue, fee escrow and targeted releases. Configuration uses **access-manager template permissions** from the role template manager: the same roles as IPOR's `updateWithdrawFee`, etc.

| Function | Access | Parameters / ranges | What it does | Interacts with |
|---|---|---|---|---|
| `requestShares(gross)` | public | > 0 | Replaces the caller's request (refunding any unearned fee). Escrows fee = gross × requestFee (rounded up). Window = now + withdrawWindow. | CallerRewardFuse `moveRequestFeeShares` |
| `canWithdrawFromRequest(account, shares)` | vault only | — | Consumes released, reserved shares during redeem. | — |
| `canWithdrawFromUnallocated(shares)` | vault only | — | Instant path. Fee shares = shares × withdrawFee. Sends ProfitCustody its revenue-share part. Requires unreleased liquidity. | ProfitCustody |
| `pruneExpiredRequests(max)` | public | 1…500 | Expires requests, refunds the unearned fee, and burns earned fees. | vault BurnRequestFeeFuse |
| `releaseActiveShares(ts, shares)` / `releaseFor(requester, ts, shares)` | controller | ts < now; shares ≤ available | Reserves shares FIFO (or for one requester) and marks the fee as earned. | — |
| `setDependencies(controller, burnFuse, feeFuse, prevManager)` | template permission of `updatePlasmaVaultAddress` | non-zero | Wires the controller and fuses, and rotates the allowance through the vault. | vault execute |
| `setProfitCustody(address)` | same | ≠ 0, ≠ self | Sets the revenue-share recipient. | — |
| `updateWithdrawWindow(s)` | template permission | — | **Live: 90 days** (constructor default 120). | — |
| `updateWithdrawFee(wad)` | template permission | ≤ 1e18 | Instant fee (**Live 0.0125e18**, Phase 1). | — |
| `updateRequestFee(wad)` | template permission | ≤ 1e18 | Scheduled fee (**Live 0.045e18**, Phase 1). | — |
| `updatePlasmaVaultAddress(a)` | template permission | — | Sets the vault link. | — |
| `requestInfo`, `rawRequestInfo`, `activeRequestedShares`, `activeUnreleasedShares`, `reservedSharesOf`, `earnedFeeShares`, `controller`, `profitCustody`, `getWithdrawWindow/Fee`, `getRequestFee`, `getSharesToRelease`, `getLastReleaseFundsTimestamp`, `hasMoreStaleEntries`, `getPlasmaVaultAddress` | view | — | Reads. | — |

#### A2.8 CurveYieldProfitCustody: `0xe7D109Ce6b34447Dd45B54e5615F4177291D5ADf`
Owner: Safe `0x47623C62…3C49`. Runs its own 75%-LTV loop in `0x80e6` with the avKAT it receives.

Constants:
- MAX_REVENUE_SHARE 3,500
- reward-manager split 1,000–3,000
- fee split 500–2,000
- FULL_UNWIND_DELAY 15 days

| Function | Access | Parameters / ranges | What it does | Interacts with |
|---|---|---|---|---|
| `setGuardian(addr, bool)` | owner | ≠ 0 | Adds or removes operators. | — |
| `setRevenueShareBps(v)` | owner | ≤ 3,500 | Share of vault wind-up profit and instant fee sent here (**Live 3,000**). | read by Morpho fuse and WM |
| `setWindupDistributionBps(rm, fee)` | owner | rm 1,000–3,000; fee 500–2,000 | Split of this contract's own wind-up output (**Live 1,600 / 900**). | — |
| `setFeeRecipient(a)` | owner | ≠ 0, ≠ self | — | — |
| `deployAll()` | owner/guardian | — | Supplies idle avKAT and winds up to 75%. | Morpho, router `0x01F9` |
| `balanceLtv()` | owner/guardian | — | Winds up below 75%; flash de-levers above 75%. | Morpho flash loan |
| `scheduleFullUnwind(recipient)` / `cancelFullUnwind()` / `executeFullUnwind()` | owner / operator / owner | 15-day delay | Timelocked full exit to a recipient. | Morpho, router |
| `onMorphoFlashLoan(assets, data)` | Morpho only, hash-bound | — | Flash de-lever callback. | Morpho |
| `positionSnapshot()` | view | — | Collateral, debt, value and LTV. | Morpho oracle |

#### A2.9 CurveYieldMerklAutoHarvestFuse: `0xb62241b19995Dac16D5905050804e1f06caC9704`
A rewards-claim-manager fuse.
- `setSwapFuse(addr)`: owner, impl-only.
- `harvest(tokens[], cumulativeAmounts[], proofs[][])`: vault ctx, caller = RewardsClaimManager. Tokens must be unique and non-zero. It claims from the Merkl distributor `0x3Ef3…d9Ae`, marks the swap fuse, and runs `swapAllRewards` through `executeInternal`. It reverts if the marker is not consumed.
- Reads: `SWAP_FUSE`, `VAULT`, `MANAGER`, `DISTRIBUTOR`.

#### A2.10 Swap routers
**Current `0x01F9894f…3582`: CurveYieldSushiV3FeeRouter v3, Solidity 0.7.6. Verified on Katanascan 2026-09-24.**
- Byte-exact match with `work/router/contracts/CurveYieldSushiV3FeeRouter.sol`. Deployed by the deployer at block 42,845,759. Owner: the Safe.
- Owner functions:
  - `transferOwnership`, `setFeeRecipient`, `setFeeBps` (≤ 2,000);
  - `setRoute(in, out, path)`: validated path, pools must come from the Sushi factory;
  - `removeRoute`, `setRouteFeeBps` (≤ 2,000), `clearRouteFee`;
  - `setRouteTwapGuard(in, out, window > 0, deviation ≤ 2,000)`.
- Views: `owner`, `routeFor` (Live: avKAT↔KAT via the 1% pool), `routeTwapGuard` (Live: 900 s, 330 bps), `twapMinimumOut`, `DEFAULT_TWAP_WINDOW` (900), `DEFAULT_TWAP_DEVIATION_BPS` (330).
- `swapExactInput(in, out, amt, minNet, recipient, deadline)`: enforces the fee and the TWAP floor. `uniswapV3SwapCallback`: callable only by the pool.
- The fee recipient and fee values are stored privately; there are no public getters.

**v2 `0x346f…87Bb` (outdated): the earlier build, without the TWAP-guard functions. Owner: Safe.**
- `transferOwnership`, `setFeeRecipient`, `setFeeBps` (≤ 2,000)
- `setRoute(in, out, path)`: validated path, pools must come from the Sushi factory
- `removeRoute`, `setRouteFeeBps` (≤ 2,000), `clearRouteFee`
- `setRouteTwapGuard(in, out, window > 0, deviation ≤ 2,000)`
- Views: `routeFor`, `routeTwapGuard`, `twapMinimumOut`
- `swapExactInput(in, out, amt, minNet, recipient, deadline)`: swaps with fee and TWAP floor enforcement
- `uniswapV3SwapCallback`: pool only, during an active swap

#### A2.11 VkatErc20AccountingAdapter: `0xD3d3fd4fe4c09d9BB826A37D368Cf8033e512507`
Market 54 balance source and an ERC-20-shaped "vKAT Position" token.
- `balanceOf(account)` = the account's vKAT locked KAT, summed over its escrow NFTs.
- `balanceOf()` (no args) = 0, so the market 54 balance-fuse slot reports zero.
- The ERC20BalanceFuse in market 7 values it as a token.
- `name`, `symbol`, `decimals` (18), `MARKET_ID` 54.

#### A2.12 Morpho market oracles
- **IporVaultHaircutOracle** `0xE6004a4c…0A2C`: `price()` = cyavKAT `convertToAssets` (avKAT per share) × 0.95, scaled to 1e36. Immutables: VAULT, LOAN_TOKEN, ONE_SHARE.
- **IporVaultToKatHaircutOracle** `0x20f3648f…05d0`: `price()` = cyavKAT → avKAT → KAT × 0.85.
- Neither has admin functions; both are immutable.

### A3. IPOR contracts in this system (factory-deployed; the relevant surface only)

The full IPOR ABIs are public in the IPOR Fusion repository. Only the calls this system uses or depends on are listed.

| Contract | Functions used (access) | Notes |
|---|---|---|
| PlasmaVault `0xEd83…4548` | **User:** `deposit`/`mint` (whitelist role 800 if enabled), `redeem`/`withdraw` (checks WM), `redeemFromRequest`. **Operations:** `execute(FuseAction[])` (ALPHA 200), `executeInternal` (vault-internal, during execution). **Fuse config:** `addFuses`/`removeFuses`, `addBalanceFuse`/`removeBalanceFuse`, `grantMarketSubstrates`, `updateDependencyBalanceGraphs`, `configureInstantWithdrawalFuses`, `setupMarketsLimits`, `activateMarketsLimits` (FUSE_MANAGER 300 / ATOMIST 100). **Vault config:** `setTotalSupplyCap`, `enableTransferShares`, `setRewardsClaimManagerAddress`, `setPriceOracleMiddleware`, fee config (ATOMIST 100 / OWNER 1). **Reads:** `getFuses`, `getInstantWithdrawalFuses`, `getMarketSubstrates`, `totalAssets`, `totalAssetsInMarket`. | 20 decimals; asset avKAT. |
| IporFusionAccessManager `0xd7f4…1faA` | `grantRole`/`revokeRole`, `setTargetFunctionRole`, `hasRole`, `canCall`, `updateTargetClosed` (ADMIN 0 / role admins) | The deployer holds OWNER/ATOMIST/ALPHA/FUSE_MANAGER; the controller holds ALPHA. |
| PriceOracleMiddlewareManager `0x7B46…47D6` | `setAssetsPriceSources` (role 1200), `getAssetPrice` | avKAT and KAT USD sources. |
| RewardsClaimManager `0xA774…72Cb` | `claimRewards(FuseAction[])` (ALPHA or controller-granted), `transferVestedTokensToVault()` (public), `updateBalance`, `setupVestingTime`, `getVestingData`, `balanceOf` | 15-day vesting, required by the swap fuse. |
| FeeManager `0x11a8…5Ec6` | fee-recipient config (unverified source) | Perf 10% → `0xe402…A321`; mgmt 0.5% → `0xfEa3…45eB`; IPOR DAO share to Safe `0xF6a9…5569`. |
| ContextManager `0x8a4a…d4d5` | `setupApprovedTargets`, `runWithContext` | Not used by CurveYield flows. |
| BurnRequestFeeFuse `0x44D3…f36e` | `enter(amount)` (vault ctx) | The WM burns earned request-fee shares through it. |
| MorphoCollateralFuse `0xda9a…6929` / MorphoBorrowFuse `0x0809…cd78` | `enter`/`exit` (vault ctx) | Market 14 substrate = market `0x80e6`. |
| Balance fuses (A2 of the short list) | `balanceOf()` (vault ctx) | Market 14 Morpho, market 7 ERC-20, zero-balance fuses. |
| MerklClaimFuse / MerklRewardSweepFuse | `claim`/`sweep` (RCM ctx) | Legacy manual path, kept installed on the RCM. |

### A4. External contracts (read or called)
- **Morpho Blue:** `supply`, `supplyCollateral`, `borrow`, `repay`, `withdrawCollateral`, `flashLoan`, `position`, `idToMarketParams`, `expectedBorrowAssets`.
- **avKAT (ERC-4626 over KAT with vKAT deposit):** `convertToShares`, `previewRedeem`, `previewMint`, `depositTokenId`, `withdrawTokenId`.
- **vKAT escrow:** `locked`, `ownedTokens`, `split`, `merge`, `minDeposit`, `canSplit`.
- **vKAT voting stack:** epoch clock `0x1704…95ab`, gauge voter `0x5e75…9352`, delegation adapter `0xB67A…f25A`.
- **Sushi V3:** 1% pool `0x8640…3B13` (`slot0`, `observe`), QuoterV2 `quoteExactInput`, and the NPM (to be used by the LP set).
- **Merkl distributor:** `claim`.

### A5. Known gaps in the existing system that the phases address

| Gap | Where | Spec |
|---|---|---|
| Deploy reverts when idle avKAT is below reserve + reward (over-target) | MorphoStrategyFuse.deployAssets, VkatStrategyFuse._planVkatDeployment | #18 |
| Wind-up profit uses the conversion rate, not market exit value; view unwind quotes use only the TWAP floor | Morpho fuse `_windupProfit`; swap fuse `*View` | #5 |
| Unwind loss and fee are recognised at different times | Morpho fuse `fulfillAll` + WM | #3 |
| Wind-up can proceed while scheduled requests exist | Morpho fuse | #11, #15 |
| Hard-coded limits (7,501 / 9,000 / 300 / 1,000) | all CurveYield fuses | #9 |
| Monolithic fuses | Morpho and vKAT strategy fuses | #9 |
| Lent and LP avKAT are not counted in `totalManagedAvkat` | Morpho fuse | Phase 2 |
| ~~Swap router `0x01F9` unverified~~ **Resolved:** verified 2026-09-24 | router | — |

---

## PART B: PHASE 2 — STRATEGY LAYER (built, spec #1–#19, #9, #18; `work/phase2/src`, deploy scripts `P2_01`–`P2_04`)

This section replaces the earlier draft surface now that the code is written and reviewed. Rules that ended up
applied to every contract below:
- one function per fuse (#9);
- every upper and lower limit is a **constructor value** (`CyBound`), never a hard-coded constant (#9);
- going over an allocation target causes a reduce plan or blocks new deployment, never a revert of the whole deploy (#18);
- configuration stays owner-only (the deployer) until Phase 3 hands ownership to the governance gate.
Not yet cut over on the live vault: `P2_03_Cutover` performs the switch and `P2_04_RemoveV1Fuses` retires the PART
A5 monolith fuses. `katana-phase2.json` currently holds only fork/dry-run addresses from local script runs.

**2026-09-27 fuse standardization (later the same day; supersedes the "current fuse" columns below wherever they
name a deleted contract):** every bespoke CurveYield fuse in this Part is deleted from `src` and replaced by either
an IPOR-audited fuse called directly, or one of the ~13 generic fuses in `src/generic` (each stateless, market-54
substrate-checked, reusable by any IPOR vault) — see `FUSE_STANDARDIZATION_SPEC.md`'s mapping table and
`FUSE_INVENTORY.md` for the exact function-by-function derivation. The controllers below become **planners**: their
config/limit functions are unchanged, but their execution-flow functions (`deployAssets`, `fulfillAll`, per-fuse
`enter`, etc.) are replaced by `planDeploy`/`planReduce`/`planWithdraw`/`planInstantWithdraw`/`planEmergency` views
returning `FuseAction[]`, assembled by the executor into one bundle per call, snapshotted and guarded by the new
`CurveYieldBundleGuardFuse`. Every subsection below is annotated inline; the old deleted-fuse rows are kept (marked
**superseded**) because they still document the exact math the new generic fuse reproduces unchanged, per
`LOOP_FUSES_SPEC.md`'s "identical behaviour" guarantee for the loop, and the analogous decisions for the others.
Deleted-source snapshot: `phase2/_pre-standardization-2026-09-27/`. Status: compiles (src + all scripts); **not
tested** (old tests moved to the snapshot's `test/`; the audit writes new ones — live `test/` is empty).

### B1. Allocation & executor (spec #9, #18; market-agnostic)

#### B1.1 CurveYieldAllocationController — `allocation/CurveYieldAllocationController.sol`
Owner: deployer (until Phase 3 hands it to the governance gate). One `managedAvkat()` total for the whole vault, the
idle-bucket split (strategic class: loop + vKAT; reserve class: idle + lending + LP), and the 7-day seasoned
wind-up cap (`MORPHO_CAP_SEASONING_SPEC.md`, implemented 2026-09-27).

| Function | Access | Parameters / ranges | What it does | Interacts with |
|---|---|---|---|---|
| `setSets(CySets)` | owner | 4 addresses (loop/vkat/lend/lp), 0 = not built yet | Registers each set controller. | — |
| `setVaultFloorBps(uint16)` | owner | within the constructor's `vaultFloorBound` (≤ 10,000) | Share of the reserve-class target that always stays idle. | — |
| `setSeasoningDays(uint8)` | owner | 0–14 (`MAX_SEASONING_DAYS`), default 7 | Window for `seasonedManagedAvkat`; 0 = today's total (old behaviour). | — |
| `checkpoint()` | public (permissionless) | — | Records today's low of `managedAvkat()`; called at the start of every executor `deployAssets`/`rebalance`, and once a day by the maintenance bot. Gaps are back-filled conservatively so a deposit can never count early. | executor, bot |
| `seasonedManagedAvkat()` | view | — | `min(now, daily lows of the last seasoningDays + today)`; used only by the loop's wind-up cap — reduce/withdraw/lending/LP still use the live `managedAvkat()`. | loop controller, windup lib |
| `managedAvkat()` | view | — | Vault idle avKAT + RCM balance + each registered set's `managedAvkat()` + legacy vKAT (until the vKAT set replaces it). | RCM, sets, vKAT escrow |
| `budgets()` | view | — | `Budgets{managed, idle, reserveTarget, reserveClass, vaultFloor, strategicBudget}` consumed by the executor's deploy plan. | — |

#### B1.2 CurveYieldVaultExecutor — `executor/CurveYieldVaultExecutor.sol`
Owner: deployer. Holds vault ALPHA and is the withdrawal manager's controller; replaces ControllerV2.

| Function | Access | Parameters / ranges | What it does | Interacts with |
|---|---|---|---|---|
| `setDependencies(CyExecutorDeps)` | owner | all 6 non-zero (allocation, WM, RCM, merklAutoHarvestFuse, payFuse, kat) | Wiring. | — |
| `setCallerReward(uint16 bps, uint256 cap)` | owner | within constructor bounds | Reward rate/cap for `deployAssets`/`fulfil*`. | — |
| `deployAssets()` | public | — | Prunes, checkpoints, then (if scheduled requests exist) re-levers the loop and fulfils from idle only; otherwise runs each set's `planDeploy` in order strategic (loop, vKAT) → reserve (lend, LP) → each set's `planReduce`, in ONE `vault.execute`, then pays the caller. Over-target sets get a reduce plan, never a revert (#18). | allocation, all sets, WM, RCM |
| `fulfillAll()` / `fulfillFor(requester, shares)` | public | — | Sources avKAT lend → vKAT (or legacy vKAT) → LP → loop; loss and request fee are recognised together (#3b); splits only the fulfilment's own profit (D2). | WM, all sets |
| `rebalance()` | public | — | Runs the loop's LTV re-lever plus every set's `planReduce`. | sets |
| `emergencyRepay(repayKat)` / `lpEmergency()` | public | loop / LP holder LTV above the emergency level | Dispatches the loop's or the LP holder's emergency de-lever. | loop / LP set |
| `harvest(tokens, amounts, proofs)` | public | — | Unchanged Merkl harvest path via the RCM. | RCM, MerklAutoHarvestFuse |
| `startNativeExit()` | public | vKAT + loop sets required | Sizes and starts vKAT native-exit lane tickets to cover the scheduled-request shortfall idle/in-flight exits cannot; sources the vKAT position first, then loop LTV headroom up to `nativeExitMaxLtvBps` (76.2%). | vKAT controller, loop |
| `beginNativeExits()` / `completeNativeExits()` / `completeNativeExitEarly(tokenId, maxPremiumKat)` | public | early completion: caller pays the fee above the 2.5% minimum in KAT, capped by `maxPremiumKat` | Advances the lane's 60-day exit queue; on completion the KAT repays loop debt and pulls collateral back to target LTV, then fulfils scheduled requests with the released avKAT. | vKAT controller, loop, WM |

#### B1.3 CurveYieldExecutorPayFuse / CurveYieldProfitSplitFuse — `executor/CurveYieldExecutorFuses.sol` — **superseded 2026-09-27**
Executor-only vault-context fuses (market 0, no accounting). `PayFuse.enter(amount)`: transfers at most the
constructor's `MAX_PAY_AVKAT` ceiling to the executor. `ProfitSplitFuse.enter(profitAvkat)`: runs
`CurveYieldProfitSplitLib.distribute` against the loop profit splitter (#16).

**Fuse standardization**: both deleted. Replaced by the generic **`CurveYieldErc20TransferFuse`**
(`generic/CurveYieldErc20TransferFuse.sol`, market 7, substrates in market 54: typed `TRANSFER_TOKEN` (8) for the
token, `RECIPIENT` (3) for each allow-listed payee) — the caller-reward payment is one transfer call with the
planner supplying the (already-capped) amount; the profit split is N transfer calls, one per splitter leg
(2026-09-27 decision #5: N transfers, no dedicated distribute fuse). The `MAX_PAY_AVKAT` ceiling and the split-bps
math move to the executor / `CurveYieldLoopProfitSplitter`'s own logic — same numbers, enforced one level up.

### B2. Morpho loop set (market 14, Morpho `0x80e6…83e9`, avKAT collateral / KAT loan) — `morpho/`

#### B2.1 CurveYieldMorphoLoopController
Owner: deployer. Every bound (`CyLoopParamBounds`) is a constructor value (#9): `allocationBps`, `rampZoneBps`,
`profitBps` (base/rampStart/rampEnd/minUnwindProfit), `lossBufferBps`, `targetLtvBps`, `emergencyLtvBps`,
`emergencyTargetLtvBps`, `ltvRebalanceToleranceBps`, `reduceLossBps`, `maxCycles`.

| Function | Access | Parameters / ranges | What it does | Interacts with |
|---|---|---|---|---|
| `setParams` / `setAllocationBps` | owner | within bounds; `rampStartProfitBps ≤ rampEndProfitBps`; `targetLtvBps < emergencyLtvBps ≤ emergencyTargetLtvBps` invariants enforced | Full or single-field (guardian-friendly) parameter update. | — |
| `requiredWindupProfitBps(equity, limit)` | view | — | Ramped required wind-up profit: flat `baseWindupProfitBps` below the ramp zone, linear `rampStartProfitBps → rampEndProfitBps` inside it (#14). | windup lib |
| `planDeploy(budget, managedTotal)` | view (`ICyStrategySet`) | — | **Blocks while scheduled requests exist (#11).** Cap = `seasonedManagedAvkat() × allocationBps` (not the live total). | allocation controller, windup fuse |
| `planReduce(managedTotal)` | view | — | Only when `reduceLossBps` is configured (else blocks new deploys only, never unwinds a profitable position at a loss). | unwind fuse |
| `planLtvRebalance()` | view | re-levers only when LTV has drifted `> ltvRebalanceToleranceBps` below target | Routes proceeds to scheduled withdrawals first when any exist (#15). | ltvRebalance fuse |
| `planEmergency(repayKat)` | view | only above `emergencyLtvBps` | `repayKat` 0 = full de-lever to `emergencyTargetLtvBps`. | emergency fuse |

#### B2.2 Loop fuses — `CurveYieldMorphoLoopFuses.sol` (`CurveYieldMorphoLoopFuseBase`: vault ctx + executor-only) — **superseded 2026-09-27**
- `CurveYieldMorphoLoopWindupFuse.enter(supplyBudgetAvkat)`: runs `CurveYieldMorphoWindupLib.run` — up to `maxCycles`
  supply→borrow→swap cycles; each cycle's profit is judged on the swap's **live minimum output** (pool quote incl. fee,
  minus slippage/TWAP floor) against the ramped required bps, and split per #16; a cycle short of profit ends the
  loop instead of reverting (#18).
- `CurveYieldMorphoLoopLtvRebalanceFuse.enter()`: same windup lib with `idleBudget = 0`; if scheduled requests exist
  the bought avKAT is left idle for them instead of re-supplied.
- `CurveYieldMorphoLoopUnwindFuse.enter(neededAvkat, maxLossBps)`: secant-search unwind plan (`CurveYieldMorphoLoopLib.planUnwind`), reverts `LossAllowanceAboveConfig` if `maxLossBps` exceeds `max(lossBufferBps, reduceLossBps)`.
- `CurveYieldMorphoLoopEmergencyFuse.enter(repayKat)`: full de-lever to `emergencyTargetLtvBps` (0) or a bounded
  partial repay, both via a Morpho flash loan.

**Fuse standardization** (`LOOP_FUSES_SPEC.md`, approved): all four deleted, replaced by two generic fuses with
**identical math** — only the parameter source changes (call data + market-54 substrates instead of the loop
controller's own storage):
- **`CurveYieldLoopCycleFuse.enter(LoopCycleData)`** (`generic/CurveYieldLoopFuses.sol`) replaces Windup + LtvRebalance:
  same per-cycle snapshot→target-debt→quote→profit-gate→supply/borrow/swap→split loop as `CurveYieldMorphoWindupLib.run`
  today, `idleBudget = 0` + `leaveProducedIdle` flag covers the old re-lever case. Substrates (market 54, typed
  `COMPONENT` = 2): Morpho market id, collateral/borrow/flash/swap fuse addresses; profit legs are typed `RECIPIENT`
  (3). The controller's `requiredWindupProfitBps` ramp formula moves unchanged into the fuse, parameters supplied by
  the planner (the controller's own view still computes them — same numbers, called by the planner instead of read
  live from storage inside the fuse).
- **`CurveYieldLoopUnwindFuse.enter(LoopUnwindData)`** (same file) replaces Unwind + Emergency: same secant-search
  `planUnwind` (second point 5x the gap, tolerance amount/1000+1, 12 iterations), same fixed-point `planDeleverage`,
  same `planPartialRepay` LLTV check, same `enforceLoss`, then IPOR's own `MorphoFlashLoanFuse` + `MorphoBorrowFuse.exit`
  + `MorphoCollateralFuse.exit` for the mechanical unwind legs (drop-in, ABI-identical per the code's own comment).
  `mode` (0 UNWIND / 1 DELEVERAGE / 2 PARTIAL) replaces having four separate fuses; `minLtvBpsToAct` replaces the old
  emergency fuse's inline `ltv > emergencyLtvBps` revert.
- Behaviour change: **none intended** in the math. One structural change, flagged for the audit: neither generic fuse
  checks `msg.sender == executor` any more (removed per the IPOR norm that only an ALPHA-role holder can call
  `execute` at all — today only the executor holds ALPHA on cyavKAT, so this is currently equivalent, but any future
  ALPHA grant would let that holder run these fuses with its own parameters, bounded only by the market-54
  substrates).

#### B2.3 CurveYieldLoopProfitSplitter — `CurveYieldLoopProfitSplitter.sol`
Owner: deployer. `setSplit(growthBps, contributorsBps, vaultBps, rewardsManagerBps)`: each within the constructor's
`categoryBound`, must sum to 10,000 (#16). `split(amount)` view is called by `CurveYieldProfitSplitLib.distribute`
from both the windup lib and the executor's `ProfitSplitFuse`. `setContributorsSink`/`sweepContributors()`: until the
Phase 4 `CurveYieldContributorsRewardFuse` exists, the contributors' share accrues here and is swept later.

### B3. avKAT lending set (market 41 in production; the Phase 2 controller targets market 14's `0x5c60…d014`
sub-market before the L9 migration) — `lend/`

#### B3.1 CurveYieldAvkatLendController — `CurveYieldAvkatLendController.sol`
Owner: deployer. Constructor bounds: `capBps`, `ownershipTriggerBps`, `decayBps`, `decayInterval`,
`liquidityFloorBps`, `ownershipExemptAvkat` (spec #13, first-10k exemption added 2026-09-24).

| Function | Access | Parameters / ranges | What it does | Interacts with |
|---|---|---|---|---|
| `setParams` / `setCapBps` / `setDecayBps` | owner | within bounds | Cap (target share of managed avKAT), decay rate. | — |
| `marketState()` | view | — | Vault supply, market total supply/borrow, available liquidity, vault share bps, ownership/liquidity trigger flags. | Morpho |
| `planDeploy(budget, managedTotal)` | view | never past the ownership trigger even after the deposit (closed-form max deposit) | Supplies up to the cap unless triggered. | IPOR `MorphoSupplyFuse` |
| `planReduce(managedTotal)` | view | decay ≤ `decayBps` of lent per `decayInterval`; liquidity floor always respected | Shrinks over-cap or triggered positions. | `CurveYieldAvkatLendReduceFuse` |
| `planWithdraw(needed, scheduled)` | view | — | User withdrawals may use all available market liquidity (no floor/interval). | — |
| `recordReduction(amount)` | vault only | — | Timestamps the last decay step (spaces them by `decayInterval`). | reduce fuse |

`CurveYieldAvkatLendReduceFuse.enter(amount)` (executor-only, vault ctx): withdraws via the configured supply fuse
and calls back `recordReduction`. **Superseded 2026-09-27: fully deleted, no replacement fuse.** The planner calls
IPOR's own `MorphoSupplyFuse.exit` directly (it already did all the delegation — this fuse was pure passthrough plus
one bookkeeping call). `recordReduction`'s decay-interval timestamp now records the **actual** amount withdrawn
(2026-09-27 decision #4, resolving `FUSE_INVENTORY.md` §4's open question) rather than the requested amount, read
back from the bundle.

### B4. Sushi avKAT/KAT LP set (market 7 valuation; 1% pool `0x8640…3B13`; the holder's own Morpho `0x80e6…83e9` position) — `lp/`

#### B4.1 CurveYieldSushiLpController — `CurveYieldSushiLpController.sol`
Owner: deployer. Constructor bounds: `allocationBps` (min/max), `advantageBps` (start/full), `minKatBps`, `lossBps`
(standard/scheduled), `ltvBps` (target/emergency/emergencyTarget, hard sanity `< 7,700`), `slippageBps` (≤ 200
hard), `yieldWindow`.

| Function | Access | Parameters / ranges | What it does | Interacts with |
|---|---|---|---|---|
| `optimalRange()` | view | 200-tick spacing | Upper = first step strictly above the avKAT conversion tick; lower moves down until KAT ≥ `minKatBps` (5%) of the range. | holder |
| `needsRebalance()` | view | hysteresis: only when off-optimal or price left the current range | AND gate: also requires `closeValueAvkat() ≥ basisAvkat()` (D4) — never rebalances at a loss. | holder |
| `targetAllocationBps()` | view | linear `minBps` (LP yield ≤ lending + `advantageStartBps`) → `maxBps` (≥ `advantageFullBps`), spec #19: +30%→+100% | LP-vs-lending yield comparison (`lpYieldBps`/`lendYieldBps`, trailing `yieldWindow`, default 7 days). | Morpho lending market |
| `planDeploy`/`planReduce`/`planWithdraw` | view | reduce/rebalance via 1% (`standardLossBps`) or 4% (`scheduledLossBps`) loss gates | Standard `ICyStrategySet` surface. | holder, fuses |
| `planEmergency()` | view | only above `emergencyLtvBps` | Holder de-lever plan. | holder |

#### B4.2 CurveYieldSushiLpHolder — `CurveYieldSushiLpHolder.sol`
Vault-only. Holds the NFT and its own Morpho `0x80e6…83e9` position (avKAT collateral / KAT loan, LTV sized to the
LP's own KAT side at `holderSettings().targetLtvBps`). `open`/`increase`/`withdraw`/`rebalance` move liquidity and
collateral together; `deleverage(targetLtvBps)` repays via a Morpho flash loan, selling avKAT for KAT through the
CurveYield fee router (QuoterV2 slippage check, `holderSettings().slippageBps`); `position()` values LP liquidity +
uncollected fees + Morpho collateral − debt.

#### B4.3 LP fuses — `CurveYieldSushiLpFuses.sol` (vault ctx + executor-only, `owner` also allowed for `enterWithLoss`) — **superseded 2026-09-27**
`OpenFuse.enter(amount, lower, upper)`, `IncreaseFuse.enter(amount)`, `WithdrawFuse.enter(bps, maxLossBps)` /
`enterWithLoss(bps)` (owner/executor, no gate — spec #19 "withdrawWithLoss") / `instantWithdraw(params)` (1% gate,
try/catch, never reverts), `RebalanceFuse.enter(lower, upper)` (re-checks `needsRebalance` live), `EmergencyFuse.enter()`
(only above `emergencyLtvBps`, de-levers via the holder's flash loan).

**Fuse standardization**: the Sushi LP **holder is kept** (2026-09-27 decision #2 — not removed, so none of IPOR's
Uniswap-V3 fuses apply; they assume the vault itself holds the NFT in a shared token-id list). All five fuses above
are deleted and replaced by one generic holder-fuse family, **`CurveYieldHolderFuses`**
(`generic/CurveYieldHolderFuses.sol`: Open/Increase/Withdraw/Rebalance/Deleverage), holder address as a typed
`HOLDER` (4) substrate in market 54. Per `FUSE_INVENTORY.md`'s §5 analysis, decisions taken:
- The live re-checks that used to gate execution inline (`needsRebalance()` before a rebalance, the "not emergency"
  revert before a de-lever) **stay inside the fuse** rather than moving to the end-of-bundle guard (decision #3): a
  no-op rebalance / a blocked de-lever is correctness, not a "protection", and moving it to the guard would turn a
  silent no-op into a bundle-wide revert — a real behaviour change the audit flagged as worth avoiding.
- `WithdrawFuse`'s inline `maxLossBps` gate moves to `CurveYieldBundleGuardFuse`'s post-condition check (a clean
  split: the fuse does the mechanical withdraw, the guard checks the realized loss) — timing-neutral within one
  transaction, no owner-visible change.
- `instantWithdraw` becomes the generic **`CurveYieldPlannedInstantWithdrawFuse`** asking the LP controller's
  `planInstantWithdraw(amount)` view for `FuseAction[]`, run in try/catch — same 1%-gate economics, same
  never-revert contract.
- The holder's own functions (`open`/`increase`/`withdraw`/`rebalance`/`deleverage`/`onMorphoFlashLoan`) are
  **untouched** (holder logic never moves per the standardization decisions); only their fuse callers are
  standardized.

### B5. vKAT set + native-exit lane (split of the v1 monolith, spec #9; native-exit lane per spec §2.8) — `vkat/`

#### B5.1 CurveYieldVkatController — `CurveYieldVkatController.sol`
Owner: deployer. Constructor bounds: `allocationBps`, `nativeExitMaxLtvBps` (< 10,000), `deployWindow`. Holds one
voting-position NFT (`positionTokenId`), lane NFTs being prepared (`_prepared`) and exit tickets (`_exiting`).

| Function | Access | Parameters / ranges | What it does | Interacts with |
|---|---|---|---|---|
| `setVoteTargets(gauges[], weights[])` | owner | non-empty, equal length, no zero entries | Gauge vote split. | — |
| `allocationActive()` | view | — | True only in the last `deployWindow` seconds before the gauge vote closes — new avKAT locks only then. | epoch clock, gauge voter |
| `conversionAvailable()` | view | — | True in the first half of the 2-week epoch, and only while the escrow allows splits. | epoch clock, escrow |
| `planDeploy`/`planReduce`/`planWithdraw` | view | escrow `minDeposit` respected | Standard `ICyStrategySet` surface: lock+vote / convert excess back / free conversion. | lock/convert/vote fuses |
| `planNativeExitStart(exitAvkat)` | view | — | Sources from the vKAT position first (`exitBegin.enterFromPosition`), then a fresh lock from loop headroom (`exitPrepare`). | loop controller |
| `planNativeExitBegin()` / `planNativeExitComplete()` | view | complete only when `exitAtMinimumFee` (60-day cooldown reached) | Advances prepared/exiting lane NFTs. | exit queue |
| `earlyExitPremiumKat(tokenId)` | view | — | KAT above the vault's 2.5% cost the caller must pay to complete early (queue fee decays 25%→2.5% linearly over 60 days per `ICyExitQueue`). | exit queue |

#### B5.2 vKAT fuses — `CurveYieldVkatFuses.sol` (vault ctx + executor-only) — **superseded 2026-09-27**
`VkatLockFuse.enter(avkatShares)` (merge into or create the position), `VkatConvertFuse.enter(avkatShares)` +
`instantWithdraw(params)` (free conversion, first-half-of-epoch only), `VkatVoteFuse.enter()` (refreshes the gauge
vote; requires the gauge granted in market 54 substrates), `VkatExitPrepareFuse.enter(avkatWanted)` (withdraws loop
collateral within `nativeExitMaxLtvBps`, locks a fresh vKAT NFT), `VkatExitBeginFuse.enter(tokenId)` /
`enterFromPosition(avkatAmount)` (starts the escrow's withdrawal timer), `VkatExitCompleteFuse.enter(tokenId)` /
`enterEarly(tokenId)` (withdraws the KAT, repays loop debt, pulls collateral back to the loop's target LTV — no
flash loan, no swap).

**Fuse standardization**: all six fuses deleted, replaced by the generic Aragon-VotingEscrow set
**`CurveYieldVeFuses`** (`generic/CurveYieldVeFuses.sol`): `VeLockFuse`, `VeConvertFuse`, `VeVoteFuse`,
`VeExitBeginFuse` (folds Prepare + Begin), `VeExitWithdrawFuse` (the Complete step, incl. `enterEarly`). Escrow, NFT,
gauge voter, delegation adapter and exit queue are plain (type-0) substrates — unchanged encoding, so any vault
holding an Aragon-style ve token could reuse these fuses. Per `FUSE_INVENTORY.md`'s analysis: `VeVoteFuse`'s
granted/active gauge checks stay **inside** the fuse (a live external-state pre-condition, not something a view
planner can know in advance — a gauge could be deactivated between planning and execution); `VeConvertFuse`'s
instant-withdraw hook keeps IPOR's own generic never-revert behaviour (2026-09-27 decision #2 — accepted even though
IPOR itself still reverts a redemption it truly cannot pay). The controller gained `sync(lastLockIdBefore,
newLockIsPosition)` (executor-only) to reconcile `lastLockId`/the position NFT after a bundle, because the very
first lock now votes in the same bundle without the position id being known yet (accepted behaviour note, not
present in the old fuse set, where the controller's own storage tracked this synchronously).

### B6. CurveYieldErc20BalanceFuse — `accounting/CurveYieldErc20BalanceFuse.sol` (market 7) — **superseded 2026-09-27**
Balance fuse replacing IPOR's own ERC20BalanceFuse on market 7: (1) IPOR's unchanged token-balance logic for every
other market-7 substrate; (2) the Sushi LP holder's net position (LP + collateral + idle avKAT, LP + idle KAT, minus
KAT debt, clamped at 0); (3) the vKAT native-exit lane's exiting avKAT (locked KAT net of the exit queue's minimum
fee). All values priced through the vault's existing price oracle middleware.

**Fuse standardization**: deleted, replaced by the generic **`CurveYieldPositionReaderBalanceFuse`**
(`generic/CurveYieldPositionReaderBalanceFuse.sol`, still market 7): IPOR's ERC20 token-balance logic (part 1)
unchanged, plus a list of typed `READER` (1) substrate entries in market **54**, each implementing
`positionValue(vault) returns (address asset, uint256 amount)` — a thin reader adapter for the LP holder and one for
the vKAT exit-queue (`src/accounting/CurveYieldPositionReaders.sol`), replacing parts 2 and 3. `FUSE_INVENTORY.md`'s
risk (e)1 flagged that splitting the old single clamp-at-0 combination across independent readers could let a
reader's own negative-equivalent (debt > assets) go unclamped if summed naively; confirm during audit review that
each reader (or the aggregating fuse) still floors at 0 the same way the monolithic fuse did.

### B7. CurveYieldWithdrawalManagerV2 — `withdraw/CurveYieldWithdrawalManagerV2.sol` (spec #3b)
Upgradeable, `AccessManagedUpgradeable`; configuration uses the same access-manager template permissions as the v1
IPOR-derived manager (`updateWithdrawFee`/`updateRequestFee`/`updateWithdrawWindow`/`updatePlasmaVaultAddress`
selectors gate the call, regardless of which contract actually defines them).

| Function | Access | Parameters / ranges | What it does | Interacts with |
|---|---|---|---|---|
| `requestShares(gross)` | public | > 0 | Escrows the request fee; **v2 change:** the fee earned at release is burned in the same call as `releaseActiveShares`/`releaseFor`, so fee and unwind loss land together (#3b) — no separate profit-custody cut on the request fee (only the instant-fee cut remains). | `moveRequestFeeShares` |
| `canWithdrawFromUnallocated(shares)` | vault only | — | Instant path; if a cyavKAT+-style fee split is configured, the split amount **accrues** (paid later by `settleSplit`, never blocking this redeemer); otherwise the single profit-custody cut is quoted and transferred here. | profit custody |
| `setFeeSplit(recipients[3], bps[3], splitRequestFee)` | fee-authority-gated (`updateWithdrawFee` selector permission) | each ≤ 5,000 bps, sum ≤ 7,500 (≥ 25% always stays burned) | Optional 3-recipient fee split (cyavKAT+ use); all-zero = off. | — |
| `settleSplit()` | public (bot) | — | Pays the accrued instant-fee split from idle not reserved for released requests. | — |
| `pruneExpiredRequests(max)` | public | 1–500 | Expires stale requests, refunds unearned fee, burns earned fee. | `BurnRequestFeeFuse` |
| `releaseActiveShares(ts, shares)` / `releaseFor(requester, ts, shares)` | controller only (the executor) | ts < now; shares ≤ available | FIFO or targeted release; returns the fee shares burned in the same call. | executor |

### B8. CurveYieldCallerRewardFuse (v2) — `withdraw/CurveYieldCallerRewardFuse.sol`
Owner: deployer. `MAX_REWARD_BPS` 300 (hard), `MAX_REWARD_CAP` 100 avKAT (hard), `MAX_EXTRA_WINDUP_REWARD_BPS` 1,000.
Per-action (`ACTION_DEPLOY_ASSETS`/`HARVEST`/`FULFILL_ALL`/`EMERGENCY_REPAY`) `rewardConfig` (bps/cap, owner-set,
defaults 20 bps / 5–10 avKAT) and `sourceFuse` (which fuse publishes the transient reward output). `enter(actionId,
recipient)` (vault ctx, controller-only) validates the published amount against `quoteMorphoReward` and marks it
consumed; `quoteDeployRewardSplit` pro-rates the one deploy-action cap between the loop and vKAT sources. Also
carries the withdrawal-manager helpers `moveRequestFeeShares`/`configureManagerAssetAllowance` (withdraw-manager
context only).

### B9. Shared libraries — `libraries/`
- **CurveYieldBounds** (`CyBound{min,max}`): `validate`/`check` — every configurable limit in Phase 2 is a
  constructor-fixed `CyBound`, never a hard-coded constant (#9), with an `OutOfBounds`/`InvalidBound` revert per field.
- **CurveYieldProfitSplitLib.distribute(splitter, avkat, profit)**: runs in vault context; sends the growth,
  contributors and rewards-manager shares out per the splitter's `split()`, leaves the vault's share in place, calls
  `RewardsClaimManager.updateBalance()`.

---

## PART C: PHASE 3 — GOVERNANCE (built, spec #6–#8; `work/phase2/src/governance`)

### C1. CurveYieldVotingLock — `CurveYieldVotingLock.sol` (spec #7)
No owner (immutable parameters: `TOKEN` = cyavKAT, `RAMP` = 60 days, set at construction). Non-transferable;
Aragon `IVotes` + ERC-6372 (`clock()`, timestamp mode) compatible for TokenVoting v1.4.

| Function | Access | Parameters / ranges | What it does | Interacts with |
|---|---|---|---|---|
| `lock(amount)` | public | > 0 | Locks cyavKAT; the ramp start moves to the amount-weighted average of the old and new lock (rounded up to the next UTC day). | cyavKAT |
| `unlock(amount)` | public | ≤ locked | Power drops pro rata immediately (ramp start unchanged). | — |
| `delegate(to)` | public | 0 = self | Moves all present and future voting power. | — |
| `getVotes`/`getPastVotes`/`getPastTotalSupply` | view | — | Ramped power at a timepoint; total supply is every **locked** share (not ramped) — the conservative quorum base. | Aragon TokenVoting |

### C2. CurveYieldEngagementToken — `CurveYieldEngagementToken.sol` (spec #8)
Owner: deployer → governance gate. Non-transferable; `DECAY` 180 days, `SLOW` 120 days, `SLOW_PER_UNIT` 2, `MAX_LOTS`
64. `mint(to, amount)` (minter-only, e.g. `VoterRewards`/`ProposalBond`): a fresh lot slows 2 existing units per unit
minted (oldest lots first) for 120 days; `setDistributor`/`setMintingPaused` let `EngagementRewards` pause minting
during its epoch snapshot.

### C3. CurveYieldEngagementRewards — `CurveYieldEngagementRewards.sol` (spec #8)
Owner: deployer. `openEpoch()` (public, ≥ `minEpochInterval` apart, default 7 days) locks the free balance of every
whitelisted reward token and pauses minting; `processEpoch(count)` (public, paginated) snapshots holder balances at
the open timestamp; `claim(epoch, holder)` (public, paid to holder) pays pro rata. Receives 33.33% of every slashed
`CurveYieldProposalBond` (plus any forwarded reward tokens, e.g. from the wrapper fee splitter or wcyavKAT).

### C4. CurveYieldVoterRewards — `CurveYieldVoterRewards.sol` (spec #8, D-G4/D-G7)
Owner: deployer. `voterPool` ≤ `MAX_POOL` (1,000e18) per executed proposal; `delegatorHaircutBps` (default 5,000)
and `delegateeCutBps` (default 2,000) owner-configurable ≤ 10,000. `claim(proposalId, account)` (public, pull-based,
once per proposal/account) mints engagement units via `CurveYieldEngagementToken.mint`, split by cast voting power
at the Aragon proposal's snapshot (own power in full for voters; delegators keep `(1 - haircut)` of their own power;
delegatees additionally earn `haircut × delegateeCut` of delegated-in power).

### C5. CurveYieldProposalBond — `CurveYieldProposalBond.sol` (spec #6, D-G4/D-G5/D-G9)
Owner: governance gate (protects `setAdminReceiver` for the fee authority only). `bondAmount` default 200 cyavKAT,
`proposerReward` ≤ `MAX_PROPOSER_REWARD` (1,000e18), `intakeWindow` 1–30 days (default 7).

| Function | Access | Parameters / ranges | What it does | Interacts with |
|---|---|---|---|---|
| `request(paramId, value)` | public | value within the registered `Param`'s [min, max] | Pays the bond, opens a `Pending` request. | cyavKAT |
| `linkProposal(requestId, proposalId)` | the 2-of-3 Safe only | the Aragon proposal must carry exactly one action `target.setter(value)` matching the request | Marks `Linked`. | Aragon TokenVoting |
| `reject(requestId)` | Safe only | — | Safety-bot refusal: slashes the bond. | — |
| `settle(requestId)` | public | after the vote ends | Executed → refund + `proposerReward` engagement units; not executed → slash 1/3 each to admin fee receiver, contributors sink, engagement rewards. | `CurveYieldEngagementToken`, `CurveYieldEngagementRewards` |
| `refund(requestId)` | public | past `intakeWindow` with no link/reject | Returns the bond (bots-down safety valve). | — |

### C6. CurveYieldGovernanceGate — `CurveYieldGovernanceGate.sol` (PHASE3_DESIGN_SPEC §1.9)
No owner; self-administered `isFeeAuthority` set (last holder cannot be removed). Becomes the owner of record of
every CurveYield contract and holds the vault's IPOR roles.

| Function | Access | Parameters / ranges | What it does | Interacts with |
|---|---|---|---|---|
| `execute(target, data)` | DAO only | refused if `isProtected` | The DAO's only path into the system. | every gated contract |
| `executeProtected(target, data)` | fee authority only | never to the gate itself | Can make protected calls (admin-fee setters, ownership moves). | — |
| `executeGuardian(target, data)` | the registered `guardian` only | must be an allow-listed (target, selector) via `setGuardianCall`, never protected | The Optimization Guardian's bot lane. | `CurveYieldOptimizationGuardian` |
| `isProtected(target, data)` | view | — | True for admin-fee setters (`setProtectedCalls`), `transferOwnership`/`renounceOwnership`, any generic call wrapper (`multicall`/`execute` on any target — closes the "smuggle a protected call" hole), and non-allowlisted access-manager calls (only `grantRole`/`revokeRole`/`renounceRole` on non-protected roles, and `labelRole`, are DAO-permitted). | — |
| `setFeeAuthority(account, granted)` | fee authority only | cannot remove the last one | Self-administered fee-authority set. | — |

### C7. CurveYieldOptimizationGuardian — `CurveYieldOptimizationGuardian.sol` (PHASE3_DESIGN_SPEC §1.8, D-G8)
Owners: deployer, fee Safe, DAO (any one). `run(id, value)` calls a registered `(target, selector, min, max)` action
through the gate's guardian lane (so the gate's protections still apply); `pauseVault()`/`unpauseVault()` hold IPOR
`GUARDIAN_ROLE` (2) — the operator (or an owner) can pause, only owners can unpause.

### C8. Aragon DAO + Gnosis Safe 2-of-3
Deployed by `P3_02_DeployDao` (TokenVoting + Admin plugin; the Admin plugin is intentionally kept per user
instruction — see `cyavkat-dao-keep-aragon-admin-plugin.md`, never removed without an explicit ask) and wired by
`P3_03_DeployGovernanceCore`/`P3_04_ConfigureGate`. The 2-of-3 Safe is the sole caller of `linkProposal`/`reject` on
`CurveYieldProposalBond`.

---

## PART D: PHASE 4 — cyavKAT+ ECOSYSTEM (built, spec #20, #22–#25; `work/phase2/src/plus`, `leaderboard`)

### D1. cyavKAT+ vault — cloned by `P4_01_CreatePlusVault`
IPOR `FusionFactory` (`0xc29b8D591d6a3f109Ca7ba384F2e00162866D37B`) clone of cyavKAT itself: asset = cyavKAT,
"CurveYield Looped cyavKAT" / `cyavKAT+`, DAO fee package 2 (0.5% management / 0% performance to the IPOR DAO).
Private: only `CurveYieldPlusDepositRouter` holds the IPOR whitelist role (800).

### D2. CurveYieldPlusLoopController — `CurveYieldPlusLoopController.sol` (spec #20)
Owner: deployer → governance gate (`setProfitSplit`/`setAdminReceiver` protected: fee authority only).
`targetLtvBps` (default 7,000) / `deleverLtvBps` (7,220) both ≤ `MAX_LTV_BPS` 7,500 (Morpho's own limit is
86% LLTV × 88% haircut = 75.68%); profit split `specialRewardsBps`/`compoundBps`/`boosterBps`/`adminBps` sums to
10,000 (default 40/40/10/10).

| Function | Access | Parameters / ranges | What it does | Interacts with |
|---|---|---|---|---|
| `cyPrice()` | view | — | avKAT per whole cyavKAT, net of cyavKAT's pending performance fee (via `CurveYieldNetPps`, no fee manager = gross). | `CurveYieldNetPpsPriceFeed` |
| `planWindup()` | view | — | Flash size to reach target LTV (idle cyavKAT supplied first) and the profit to send out since the last checkpoint. | — |
| `planUnwind(cyOut)` | view | — | Debt to repay / wrapped collateral to withdraw for a given cyavKAT payout. | — |
| `planDelever()` | view | only above `deleverLtvBps` | De-lever back to target. | — |
| `mainLiquidAvkat()` | view | — | avKAT the main cyavKAT vault can pay out instantly right now (idle − reserved for released requests, net of its instant fee) — bounds `maxInstantOut`. | main WM |

### D3. CurveYieldPlusStepFuse / CurveYieldPlusLoopFuse — `CurveYieldPlusLoopFuses.sol` (spec #20) — **superseded 2026-09-27**
No swaps anywhere: avKAT↔cyavKAT via the main vault's own `deposit`/`withdraw`, cyavKAT↔wcyavKAT via the wrapper.
`StepFuse.windupStep`/`unwindStep` run **inside** the Morpho flash-loan callback in the cyavKAT+ vault's own
context. `LoopFuse.windup()`/`unwind(cyOut)`/`delever()` are the public entry points (via `CurveYieldPlusExecutor`);
`instantWithdraw(params)` never reverts (runs the unwind through `executeInternal` with try/catch).

**Fuse standardization**: both deleted. Since this loop was already "IPOR fuse + wrapper" shaped (no custom swaps),
it drops straight onto IPOR's own audited fuses per `P4_02_DeployPlusStack`: `MorphoFlashLoanFuse` (market 19,
`ZeroBalanceFuse` valuation), `Erc4626SupplyFuse` (cyavKAT then wcyavKAT, markets 100001/100002
`ERC4626_0001`/`ERC4626_0002`, `ZeroBalanceFuse` valuation), `MorphoCollateralFuse`/`MorphoBorrowFuse` (market 14,
`MorphoBalanceFuse` valuation), plus `CallbackHandlerMorpho` and `CurveYieldBundleGuardFuse`. The public entry points
(`windup`/`unwind`/`delever`) are unchanged on `CurveYieldPlusExecutor` — only the fuse bundle it assembles changed.
`instantWithdraw` moves to `CurveYieldPlannedInstantWithdrawFuse` (same never-revert contract). See PART G for the
100001/100002 markets.

### D4. CurveYieldPlusExecutor — `CurveYieldPlusExecutor.sol` (spec #20)
Owner: deployer. Holds ALPHA on cyavKAT+ and is its withdraw manager's controller. `windup()`/`delever()`/`fulfill()`
(all public, settle the owed fee split first); `fulfill()` unwinds only what the main vault can supply instantly
(`maxInstantOut`), then releases whatever idle covers including the fee-split payout, so every released holder can
redeem.

### D5. CurveYieldPlusDepositRouter — `CurveYieldPlusDepositRouter.sol` (spec #20)
Owner: deployer → governance gate (fee settings protected: fee authority only). The vault's only depositor.
`depositFeeBps` ≤ `MAX_DEPOSIT_FEE_BPS` (5,000; default 3,500), `splitBps[4]` (admin/rewards-manager/special/booster,
default 20/25/25/30, sum 10,000). The fee is taken from the depositor's cyavKAT (never minted as extra shares, so it
never dilutes existing holders); whitelisted depositors (contributors, `ContributorsRewardFuse`, partners) pay none.

### D6. CurveYieldPlusYieldBooster — `CurveYieldPlusYieldBooster.sol` (spec #20)
Owner: deployer. `dripBps` (default 1,000 = 10%), `interval` (default 1 day, 1h–30d). `boost()` (public, rate
limited) sends `dripBps` of its held cyavKAT to the cyavKAT+ RewardsClaimManager and starts its vesting so PPS rises
smoothly rather than in jumps.

### D7. CurveYieldNetPpsPriceFeed / CurveYieldNetPps — `CurveYieldNetPpsPriceFeed.sol` (spec #20)
Library + IPOR `IPriceFeed`. `netRate(vault, feeManager)` = the vault's raw `convertToAssets` rate, backed out for
IPOR's pending performance-fee mint at the next crystallisation (`rate² / (rate + (rate − hwm) × perf / 10,000)`), so
crystallising cyavKAT's fee never moves cyavKAT+'s own share price.

### D8. CurveYieldSpecialRewards — `CurveYieldSpecialRewards.sol` (spec #22)
Owner: deployer → gate (`setAdmin` protected). `adminBps` ≤ 2,000 (default 1,000), `callerBps` 1–400 (0.01–4%,
default 10), `callerRewardCap` ≤ 20e20 cyavKAT, `exemptShares` ≤ 20e22, `minInterval` 1–90 days (default 7),
`forwarderFee`/`forwarderMin` ≤ 500e22 / 10,000e22, `MAX_FORWARDERS` 10. Eligible = leaderboard-registered (current
season) or an engagement-token holder; weight = `min(balance now, balance at previous snapshot) − exemptShares`,
including cyavKAT+ attributed through registered forwarder contracts (e.g. LP tokens) pro rata to the user's share
of the forwarder's supply. `openEpoch`/`processEpoch`/`claim` follow the same epoch pattern as `EngagementRewards`.

### D9. CurveYieldContributorsRewardFuse — `CurveYieldContributorsRewardFuse.sol` (spec #23)
Owner: deployer. Custody only — reports no vault accounting (funds have already left the vault's books: the loop
splitter's contributors share, the wrapper fee splitter's 30%, the proposal bond's slash third). `convert()`
(public): avKAT → cyavKAT (main vault deposit) → cyavKAT+ (whitelisted router deposit, no fee).
`distributeLeaderboard(bps)`/`distributeGovernance(bps)` (owner): pays the distributable cyavKAT+ to the current
top-100 pro rata to points, or to `CurveYieldEngagementRewards`. `setGrandPrize(bps, unlock)` (owner, only when none
pending) reserves a share for a timelocked `grandPrizeEvent()` (public) payout to the top-100.

### D10. Leaderboard — `leaderboard/` (spec #24)
- **CurveYieldLeaderboard**: owner deployer → gate (`setAdminReceiver`/`setBuySplit` protected). One
  `CySeasonParams` per season (frozen for its duration): earning ramp (`initialRateBps`, ≤3 cliffs, 100% at `end`),
  holding points (2-week `EPOCH`, ≤8 tranches, `longHoldBonusBps` per consecutive epoch), 2-tier referral credit
  (`tier1Bps` ≤ 4,000 / `tier2Bps` ≤ 2,000, both tiered against the referrer's own points via `CyTiers`), buying
  points (`buyRate`, spend split 4-way `buySplitBps`), and admin allocation capped at `adminCapBps` (500–3,000) of
  all points. `register()` (min balance + optional fee), `buyPoints(amount)`, `adminAllocate` (points-allocator
  only), permissionless paginated accounting (`accountArray`/`accountAll`/`accountLeaderboard`/`accountRange`).
- **CurveYieldSeasonPoints**: one non-transferable points token minted per season, leaderboard-only mint.
- **CurveYieldReferrals**: owner deployer. `claim(targets)` (pre-deposit referral claims, fee ≤ 100e20 cyavKAT,
  ≤ `MAX_OPEN` 10 open per referrer), `setMyReferrer(r)` (one-time, free, after depositing), `adminSetReferrer`
  (owner override).

### D11. CurveYield DEX LP fuse set — spec #25
**Not built.** Waits for the CurveYield DEX (Balancer V3 / ReClamm fork) to be live on Katana — see
`never-edit-pure-balancer-forks.md`; the vendored DEX source must stay 100% upstream and is a separate deployment
track (`CurveYield DEX/KATANA_DEPLOYMENT.md`).

---

## PART E: WRAPPER, MARKET-41 LENDING & KATANA QUEST SIGNING (LIVE)

### E1. CurveYieldWrappedCyavKat (wcyavKAT) — `wrapper/CurveYieldWrappedCyavKat.sol` — **Live** `0x10dF0e197bc1FEF44D1D1a648C2874c9cdC34692`
Owner: deployer → gate (`setFees` protected: fee authority only, so the DAO can never touch these admin fees).
Immutable OpenZeppelin-5 ERC-4626 over cyavKAT, 20 decimals, no pause, no upgrade.
`managementFeeBps` ≤ `MAX_MANAGEMENT_FEE_BPS` 500 (default 200, 2%/yr), `performanceFeeBps` ≤
`MAX_PERFORMANCE_FEE_BPS` 1,500 (default 800, 8% above a rising high watermark). `accrue()` (public, runs before
every deposit/mint/withdraw/redeem) sends fees to `FEE_SPLITTER` in cyavKAT; `totalAssets()` is always net of
accrued-but-untaken fees, so the rate never jumps.

### E2. CurveYieldWrapperFeeSplitter — `wrapper/CurveYieldWrapperFeeSplitter.sol` — **Live** `0xB53787F6b85E1bE7FEDabCfB6BBcd8bf6b1a8799`
Owner: deployer → gate (`setAdminReceiver` protected). Fixed split: `ADMIN_BPS` 4,000 / `CONTRIBUTORS_BPS` 3,000 /
remaining 3,000 burned (sent to the vault's withdraw manager, burned via IPOR's `BurnRequestFeeFuse`). `distribute()`
public.

### E3. IporVaultHaircutOracle12 — `oracles/IporVaultHaircutOracle12.sol` — **Live** `0x2926dD048e1571DA8fc26BF6CB15cB9cA8135137`
No owner, fully immutable. `price()` = `vault.convertToAssets(wrapper.convertToAssets(1 wcyavKAT))`, one 12%
haircut (`HAIRCUT_BPS`), scaled to `1e36` — same construction as the live 5%/15% haircut oracles in PART A, with one
extra ERC-4626 hop (wcyavKAT → cyavKAT → avKAT). Feeds Morpho market 41's collateral valuation.

### E4. Market-41 lending migration — `L1_InstallLendingV1`, `L9_LendingToMarket41` (+ `L2`/`L3`/`L5`/`L5b`/`L6` amount/pause steps)
Moved the vault's avKAT lending from a market-14 sub-market (which priced wcyavKAT collateral and broke the IPOR
front end's Morpho card) to IPOR's own registered **market 41** (`MORPHO_LIQUIDITY_IN_MARKETS`, "Lend Only"):
supply-only valuation via IPOR's audited `MorphoOnlyLiquidityBalanceFuse` (never prices the collateral token).
**Live** supply fuse (IPOR `MorphoSupplyFuse`, market 41): `0x1af82A748cd81958f419F7aCD0D12Ec2372BEa98` (from
`katana-lending-v1.json`; live since `L9`, 2026-09-25). Market 14's substrates were restored to loop-only in the
same migration.

### E5. cyavKAT / wcyavKAT price feeds — `L7_CyavkatPriceFeed`
Deploys IPOR's audited `ERC4626PriceFeed` for wcyavKAT (`cyavKAT per wcyavKAT`) and, if missing, for cyavKAT itself
(`avKAT per cyavKAT`), and registers both with the vault's price oracle middleware — accounting hygiene only, no
vault-balance change (the vault holds neither token). The cyavKAT feed has been live since 2026-09-25
(`0xf9f3…c3Ea`).

### E6. CurveYieldVaultBase1271 / CurveYieldSignatureFuse — `katana/` — **Live since 2026-09-26**
- **CurveYieldVaultBase1271** `0x0a9eA25C827Ec0C6B2619C231B7566846619B365`: wraps the vault's `PLASMA_VAULT_BASE`.
  `isValidSignature(hash, signature)` accepts only an EIP-191 personal-sign message that (a) starts with the
  configured domain-bound prefix (`"app.katana.network wants you to sign in with your Ethereum account:\n<vault>\n"`)
  and (b) is ECDSA-signed by an authorized signer — so the vault can sign Katana Quests SIWE logins as itself and
  nothing else (no permits, no approvals). Every other call falls through unchanged to `ORIGINAL_BASE`
  (`0x6D73E66A5486C8Aa7DD8a3231F89087CE1D74b49`).
- **CurveYieldSignatureFuse** `0x4a94978F67C071e357158b55C64d867dFb69AeEb`: executor-only vault fuse —
  `install()`/`uninstall()` swap `PLASMA_VAULT_BASE` in and out, `setSigner(addr, bool)` authorizes wallets,
  `setPrefix(bytes)` sets/clears the required message prefix. Market 7 (ERC20_VAULT_BALANCE) only because IPOR
  refreshes a fuse's market after `execute`; touches no balances. Deployed by `K1_QuestSigning`. Per
  `katana-dex-deployer-admin-temporary.md`, remember to revoke the deployer's other DAO-admin powers once Phase 3
  handover is complete — this signer registry is unaffected either way.

---

Maintenance: this file and the short list are regenerated at the end of each phase; this update (2026-09-27) folds
in the finished Phase 2/3/4 stack, the wrapper, the market-41 lending migration and Katana quest signing.
**Refreshed again 2026-09-27 (later the same day)** for the fuse standardization refactor (PART B/D/F annotations,
new PART G). They are the spec #12 deliverable. Last updated: 2026-09-27 (fuse standardization pass). Next
regeneration: end of the audit, or whenever the standardization's remaining code (test suite, IPOR/GitHub publishing
decisions) lands.

## Part F: Protocol-owned liquidity + buyback-and-burn (#25 revised, POL_SPEC.md) — built 2026-09-27, not deployed; fuses standardized same day

| Contract | File | Deploy | What it does |
|---|---|---|---|
| CurveYieldPolController (now a planner) | pol/CurveYieldPolController.sol | P5_01 | Position A (vault-owned Gyro E-CLP cyavKAT/avKAT, IPOR market 36): cap 3%, triggers (300/100 bps), cooldown 12 h, 0.5% withdrawal floor (`minPolProfitBps`, default 50, `POL_SPEC.md` §3c), yield fee 10% on real profit only (fee authority). `planDeploy`/`planReduce`/`planPolWithdraw`/`planInstantWithdraw`/`planBuyback`/`planBurnHeld` return `FuseAction[]`. Reserve-class set in the allocation controller. Values cyavKAT at the vault's ACTUAL share deposit rate (`convertToAssets`) everywhere — caps, sale floors, buyback pricing — never an oracle or market price (2026-09-27 decision, resolving the earlier open question in `FUSE_STANDARDIZATION_SPEC.md`'s decisions list). |
| CurveYieldPolFuse | pol/CurveYieldPolFuse.sol | P5_01 | Market 36 fuse (vault context): buy cyavKAT in the POL pool (<= deposit rate), add/exit proportionally (BPT sized from the *guaranteed* swap minimum, not the quoted amount — leftover cyavKAT is burned, a 2026-09-27 behaviour note), sell the cyavKAT leg only above its floor else burn it, buyback-and-burn, burn vault-held cyavKAT, instant-withdrawal hook. **Fuse standardization**: the sell-or-burn branch now runs through the generic `CurveYieldTryElseFuse` (try the market sale, fallback to burn) and the burn paths through the generic `CurveYieldBurnHeldSharesFuse` (a generalized `BurnRequestFeeFuse` that burns whatever cyavKAT the vault itself holds, not just withdraw-manager fee shares — IPOR's own fuse is hard-wired to the fee-share source only, per `FUSE_INVENTORY.md` (c)); the instant-withdraw hook uses `CurveYieldPlannedInstantWithdrawFuse`. No fuse-side `msg.sender == executor` check any more (IPOR ALPHA-only norm). |
| CurveYieldPolBalanceFuse | *(superseded 2026-09-27 by the generic `CurveYieldRateAwareBalancerBalanceFuse`, `generic/CurveYieldRateAwareBalancerBalanceFuse.sol`)* | P5_01 | Market 36 valuation: BPT share of raw pool balances, cyavKAT at the net rate (never above). Per `FUSE_INVENTORY.md` (c): IPOR's own `BalancerBalanceFuse` was confirmed **not** to fit — its WITH_RATE-scaled-balance convention would double-apply the vault's own NetPps rate to the cyavKAT leg, since that leg is the vault's own share token; the generic fuse uses RAW balances plus oracle-middleware pricing for both legs instead, with IPOR's standard `BalancerSubstrateLib` POOL/GAUGE substrate typing otherwise unchanged. |
| CurveYieldPolCustody | pol/CurveYieldPolCustody.sol | P5_01 | Position B, off the vault's books: our Charm Alpha Vault on the Sushi V3 0.3% cyavKAT/WETH pool; buys cyavKAT (POL pool) + WETH (best of two Sushi routes, TWAP-guarded); exits to avKAT via the cheaper of sale-above-NAV or burn-only instant redemption. Never burns. Owner functions fee-authority protected. Not a fuse; unaffected by the standardization. |
| CurveYieldPolFeeder (incoming) | pol/CurveYieldPolFeeder.sol | P5_01 | Loop profit splitter growth leg -> 20% POL custody, rest profit custody 0xe7D1. Consumed downstream by the loop cycle fuse's per-cycle `CurveYieldErc20TransferFuse` calls (see B2.2/B1.3), not a fuse itself. |
| CurveYieldPolFeeder (yield) | pol/CurveYieldPolFeeder.sol | P5_01 / P3_05 | Profit custody fee share -> 15% POL custody, rest previous fee recipient. setConfig fee-authority protected. |
| CurveYieldWrapperBurnForwarder | wrapper/CurveYieldWrapperBurnForwarder.sol | L10 | Turns the live wrapper fee split 40/30/30 into the approved 40 admin / 40 contributors / 20 burned. |
| WM v2 additions | withdraw/CurveYieldWithdrawalManagerV2.sol | P2_01 | `burnOnlyFee[account]` mapping (POL custody redemptions: whole fee burned, `NotBurnOnlyAccount` guard), `chargeRequest(requester, shares)` (controller-only; fulfillFor POL charge, burned). |
| Executor additions | executor/CurveYieldVaultExecutor.sol | P2_01 | POL deploy/reduce/maintenance (`deployGuardDropBps` default 0, owner-settable 0–100 bps — no deploy bundle or POL maintenance step may lower PPS), PPS-based loss reference, POL withdrawal step (0.5% floor per §3c), `fulfillFor(requester, shares, maxChargeShares)` (bounded requester charge for the POL shortfall, `ChargeAboveMaximum` guard). |

Venues created manually by the operator (POL pool, cyavKAT/WETH 0.3% pool, Alpha Vault): addresses are inputs to P5_01 or the owners' setVenues.

## PART G: Market-substrate layout after the fuse standardization (2026-09-27) — spec #12 deliverable

Every market id used anywhere in the system post-refactor, and what its substrates hold. Type tags are
`CurveYieldSubstrateTypes` (`generic/CurveYieldSubstrateTypes.sol`), encoded `bytes32(type << 160 | address)`:
`READER`=1, `COMPONENT`=2, `RECIPIENT`=3, `HOLDER`=4, `HOOK`=5, `PLANNER`=6, `BASE_1271`=7, `TRANSFER_TOKEN`=8. Type 0
(untagged, IPOR's own convention) is unchanged for every pre-existing plain-address grant.

| Market | Kind | Substrates after the refactor |
|---|---|---|
| **7** (ERC20_VAULT_BALANCE) | IPOR standard, `MARKET_ERC20` in `Phase2Base.s.sol` | Plain ERC-20 token addresses (type 0, unchanged). Balance fuse `CurveYieldPositionReaderBalanceFuse` reads those *plus* typed `READER` (1) entries — but those readers, and every other generic fuse's typed entry, are granted in market **54** (`MARKET_SUBSTRATES`), not market 7 itself. `P2_01_Deploy` also registers the loop cycle/unwind, ve set, transfer, guard and planned-instant-withdraw fuses under market 7 (their "home" market for IPOR's fuse-support bookkeeping), even though their *substrates* live in 54. |
| **14** (MORPHO) | IPOR standard | The loop's Morpho market id (`0x80e6…83e9`) only — `P2_02_ConfigureVault` asserts `getMarketSubstrates(14).length == 1`. `CurveYieldLoopCycleFuse`/`CurveYieldLoopUnwindFuse` do not read their component fuse addresses from market 14 substrates; those live as typed `COMPONENT` (2) entries in market 54 instead. Also used, unchanged, by cyavKAT+'s `MorphoCollateralFuse`/`MorphoBorrowFuse` (`MorphoBalanceFuse` valuation). |
| **19** (MORPHO_FLASH_LOAN) | IPOR standard, **cyavKAT+ only** | `P4_02_DeployPlusStack`'s `MorphoFlashLoanFuse` for the cyavKAT+ loop (`ZeroBalanceFuse` valuation). **Not** used for the Sushi LP set: `FUSE_INVENTORY.md`'s (d) table had speculated market 19 for the LP holder pattern, but the shipped `Phase2Base.s.sol` carries no LP-specific market constant — every Phase-2 generic fuse (holder, ve, transfer, guard, planned-instant, position-reader) registers under market 7 instead, with substrates in market 54. |
| **36** (BALANCER, POL) | IPOR standard, custom balance fuse | Standard `BalancerSubstrateLib` POOL/GAUGE typing for the Gyro E-CLP pool, read by `CurveYieldRateAwareBalancerBalanceFuse`. |
| **41** (MORPHO_LIQUIDITY_IN_MARKETS, "Lend Only") | IPOR standard, live | Unchanged: the lending Morpho market id, IPOR's own `MorphoSupplyFuse` + its paired balance fuse. No CurveYield-specific fuse or substrate here at all once `CurveYieldAvkatLendReduceFuse` is gone. `P2_02_ConfigureVault` asserts it's already installed (`L1`/`L9` must run first). |
| **54** (substrate-only registry) | Extended 2026-09-27 | **Before**: gauge-vote grants only (`isSubstrateAsAssetGranted(54, gauge)`, plain type-0 addresses — the ve contracts' escrow/NFT/gauges, unchanged by the refactor). **After**: the single shared typed-entry registry for every generic fuse in the system — `READER` (position readers for market 7), `COMPONENT` (loop collateral/borrow/flash/swap fuse addresses), `RECIPIENT` (profit-split / transfer-fuse payees — growth custody, contributors recipient, rewards-claim manager, executor), `HOLDER` (the LP holder), `HOOK` (holder checkpoint/rebalance callers), `PLANNER` (planned-instant-withdraw planner addresses), `BASE_1271` (the ERC-1271 signer fuse), `TRANSFER_TOKEN` (the transfer fuse's token, avKAT). Wired by `P2_02_ConfigureVault._substrates54` in one batch of 20 entries. **This is the resolution to `FUSE_INVENTORY.md`'s (d) open item** — "new veToken market, not numbered yet" — the implementation reused market 54 with type tags rather than registering a new market id, and folded in what that same table had proposed as separate market-7/market-14 substrate-typing extensions. |
| **100001** / **100002** (`ERC4626_0001` / `ERC4626_0002`) | IPOR standard, new for cyavKAT+ | cyavKAT and wcyavKAT respectively, each `Erc4626SupplyFuse` + `ZeroBalanceFuse` (the ERC-4626 legs the cyavKAT+ loop steps through net to zero at rest; the loop's real Morpho collateral/debt is still valued on market 14, and its flash-loan leg on market 19). Deployed by `P4_02_DeployPlusStack`. |
