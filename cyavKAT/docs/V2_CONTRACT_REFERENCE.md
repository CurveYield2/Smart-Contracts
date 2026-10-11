> **V21 live-source correction:** The external loop splitter and both POL feeders are absent. The executor retains its internal four-way split (growth to RevenueCustodyV2 after P6, contributors to ADMIN_FEE_SAFE); the original Profit Custody keeps its own separate payout rules. The historical contract lists have been replaced with v21 current-source inventories.

# cyavKAT v2: every contract and function (2026-10-10)

One sentence per contract and per function. Scope: external and public functions of the contracts that make up the v2 vault
(IPOR_FUSE_CONFORMANCE_SPEC). Part A is new or rewritten code in `upgrade/src`, Part B is the live code kept unchanged, Part C
is the official IPOR code the vault runs. Internal and private functions are not listed. "Gate" means `CurveYieldGovernanceGate`.
Nothing here has been run on-chain yet (see spec Part 10).

---

## Part A. New or rewritten contracts (`upgrade/src`)

### A1. Fuses that run inside the vault (delegatecall; stateless)

**CurveYieldBundleGuardFuse** (ZERO_BALANCE market) — first and last action of a bundle: reverts the whole bundle unless the share price held.
- `enter(markets)` — revalues the listed markets through IPOR's `PlasmaVaultMarketsLib` and pushes a snapshot of gross assets and supply on a transient stack.
- `exit(markets, maxPpsDropBps, minAssetsPerShareDelta, minIdleAssets, morphoMarkets)` — pops the snapshot, revalues, and reverts if the price dropped beyond the granted ceiling, the required gain or bounded loss is missed, idle is too low, or a Morpho market's LTV is above its granted ceiling.

**CurveYieldErc20TransferFuse** (market 7) — pays a token out of the vault, bounded by granted substrates.
- `enter(token, to, amount)` — sends at most the vault balance, after checking the granted token, recipient, per-call cap and the absolute ceiling.
- `enterTransient()` — same action with inputs read from IPOR transient storage, for chaining.
- `exit(bytes)` — always reverts; there is nothing to undo.

**CurveYieldBurnHeldSharesFuse** (ZERO_BALANCE market) — burns cyavKAT shares the vault itself holds.
- `enter(maxShares)` — burns the vault's own shares (all, or up to the cap) through the base's `updateInternal`, never lowering the share price.
- `enterTransient()` — same with transient-storage inputs.
- `exit(bytes)` — always reverts.

**CurveYieldRequestFeeSharesFuse** (ZERO_BALANCE market) — vault-side half of the withdraw manager's request-fee escrow; only the manager may call it.
- `moveRequestFeeShares(from, to, amount)` — moves fee shares between a requester and the manager.
- `configureManagerAssetAllowance(previousManager)` — gives the manager an unlimited asset allowance and clears the previous manager's.

**CurveYieldRateAwareBalancerBalanceFuse** (market 36) — values the vault's Balancer pool position.
- `balanceOf()` — returns USD (WAD) value of the vault's pool and gauge shares from raw balances, valuing the vault's own shares at the share rate.

**CurveYieldErc1271InstallFuse** (new vaults only, not installed on cyavKAT)
- `enter(base1271)` — replaces the vault's PlasmaVaultBase with a granted ERC-1271 wrapper.
- `exit(base1271)` — restores the original base exactly.

**CurveYieldErc1271ConfigFuse** (new vaults only)
- `enter(signer, enabled, updatePrefix, prefix)` — sets a log-in signer and/or the accepted message prefix while a granted wrapper is installed.
- `exit(bytes)` — always reverts.

**CurveYieldSignatureFuse** (legacy deployed installer; no longer permitted on the V2 fuse allowlist) — originally installed ERC-1271 base. V2 requires it to be unregistered after `K1_QuestSigning` migration; its deployed code and the existing ERC-1271 wrapper remain intact. **CurveYieldQuestSignerConfigFuse** (revised V2, version marker 2) is the permanent signer/prefix administrator. See `QUEST_SIGNING_LAYER_v2.md`.
- `install()` — switches PLASMA_VAULT_BASE from the original to the wrapper.
- `uninstall()` — switches it back to the original.
- `setSigner(signer, enabled)` — authorises or removes a wallet that may sign log-ins.
- `setPrefix(prefix)` — sets the message prefix every signed log-in must start with.

### A2. Planners and the executor (outside the vault; they build and run bundles)

**CurveYieldVaultExecutor** — the public keeper contract holding vault ALPHA; every decision is made on-chain here.
- `setDependencies(deps)` — owner sets the allocation controller, withdraw manager, rewards manager, transfer fuse and guard fuse.
- `setBackstops(backstops)` — owner sets the ordered contracts that pay for an emergency loss.
- `backstops()` — returns that list.
- `dependencies()` — returns the wiring.
- `deployAssets()` — settles vesting and fees, runs the loop's wind-up cycles, the allocation deploy bundle, the POL step and the reduces, and pays the keeper reward from the gain; with pending requests it only re-levers and releases.
- `rebalance()` — re-levers the loop, tops up its collateral, rebalances the USDC strategy's LTV and runs the reduce plans, each as its own guarded step.
- `fulfillAll()` — frees avKAT from the withdrawal sources in order and releases as many requested shares as it covers.
- `fulfillFor(requester, shares)` — the same for one requester.
- `fulfillFor(requester, shares, maxChargeShares)` — as above, and may fund part of it from POL, charging the requester up to the cap.
- `executeSelf(actions)` — self-call used for `try/catch` steps; runs a bundle on the vault and is callable only by the executor.
- `pruneExpiredRequests()` — drops expired requests from the manager's queue in a bounded batch.
- `emergencyRepay(repayKat, maxCallerPayAvkat)` — de-leverages the loop above the emergency LTV and has the backstops, then the caller, pay the measured loss.

**CurveYieldAllocationController** — decides how managed avKAT is split between the strategies.
- `setSets(sets)` — owner registers the loop, USDC, lending and POL planners.
- `setExecutor(executor)` — owner sets the executor.
- `REWARDS_CLAIM_MANAGER()` — returns the rewards manager wired in the gate.
- `vaultFloorBps()` — returns the share of the reserve class kept idle.
- `seasoningDays()` — returns how long a deposit waits before it counts for loop wind-ups.
- `checkpoint()` — records today's low of managed avKAT.
- `seasonedManagedAvkat()` — returns managed avKAT counted for wind-ups (lowest over the seasoning window).
- `sets()` — returns the registered planners.
- `managedAvkat()` — returns idle plus rewards manager plus every strategy's value.
- `strategicBps()` — returns the combined target share of the loop and the USDC strategy.
- `budgets()` — returns managed, idle, reserve target, vault floor and the strategic budget.
- `planDeploy()` — returns the USDC and lending deploy bundle, the POL bundle, idle, and the avKAT the loop will draw.
- `planReduces()` — returns each strategy's reduce plan.
- `withdrawSources()` — returns the withdrawal source order (lending, USDC, loop).
- `reserveBudget(idle, floor, consumed)` — returns idle available to the reserve class.

**CurveYieldMorphoLoopController** — planner for the avKAT/KAT Morpho loop (market 14).
- `setExecutor(executor)` / `setAllocation(allocation)` — owner wiring.
- `env()` — returns the loop's addresses.
- `params()` — reads all loop settings from the gate.
- `allowedLossBps()` — returns the unwind loss a scheduled fulfilment may take (request fee minus the kept profit).
- `snapshot()` — returns collateral, debt, LTV and net equity.
- `managedAvkat()` — returns the loop's net equity in avKAT.
- `allocationBps()` — returns the loop's target share.
- `requiredWindupProfitBps(equity, limit)` — returns the profit one wind-up cycle must clear at that equity.
- `hasScheduledRequests()` — true while withdrawal requests wait.
- `windupLimit()` — returns the seasoned cap on loop equity.
- `planDeploy(budget, managed)` — returns how much avKAT the loop will draw (the cycles themselves are run by the executor).
- `planReduce(managed)` — always empty; an over-target loop shrinks through withdrawals.
- `planWithdraw(needed, scheduled)` — builds a guarded flash-loan unwind that frees avKAT within the loss allowance.
- `planCycle(supply)` — builds one guarded wind-up cycle (supply, borrow, buy avKAT) and its required gain, or nothing if it cannot clear the profit.
- `needsRelever()` — true when LTV drifted below target by more than the tolerance.
- `planCollateralTopUp()` — builds the swap-free de-leverage (repay with idle KAT, add idle avKAT).
- `planEmergency(repayKat)` — builds the unguarded emergency de-leverage above the emergency LTV.

**CurveYieldUsdcStrategyController** — planner for borrowing vbUSDC against avKAT and depositing it into cyvbUSDC.
- `setExecutor(executor)` — owner wiring.
- `env()` — returns the strategy's addresses.
- `params()` — returns the TVL cap and target LTV from the gate.
- `allowedLossBps()` — returns the loss a scheduled unwind may take.
- `position()` — returns collateral, debt, cyvbUSDC position, oracle price and LTV.
- `managedAvkat()` — returns equity in avKAT (collateral plus cyvbUSDC minus debt, converted at the Morpho oracle).
- `allocationBps()` — returns the TVL cap as the strategy's target share.
- `planDeploy(budget, managed)` — builds the guarded bundle: collateral, borrow vbUSDC, deposit into cyvbUSDC, with an LTV ceiling check.
- `planReduce(managed)` — always empty; the strategy shrinks through withdrawals.
- `planWithdraw(needed, scheduled)` — builds a guarded proportional exit (withdraw, repay, release collateral), buying any shortfall with idle avKAT or shrinking the exit if the router cannot quote it.
- `shortfallInput(shortfall, maxAvkat)` — quotes the avKAT needed to buy a vbUSDC shortfall (external so the plan can try it).
- `planRebalance()` — builds a guarded repayment from cyvbUSDC when LTV exceeds target plus tolerance.

**CurveYieldPolController** — planner for protocol-owned liquidity in the CurveYield DEX pool (market 36).
- `setVenues(venues)` / `setFuses(fuses)` / `setExecutor(executor)` / `setMarketRoutes(routes)` — owner wiring.
- `setAdminReceiver(receiver)` — fee authority sets who receives the admin yield fee.
- `params()` — reads the POL settings from the gate.
- `yieldFeeBps()` — returns the admin share of real POL profit.
- `buybackBudgetLeftBpt()` — returns the pool tokens still convertible into buybacks.
- `syncBpt(buyback)` — the executor books a change of the pool position as entry, exit or buyback.
- `recordBuyback()` — the executor starts the buyback cooldown.
- `position()` — returns the vault's pool tokens and its share of each pool balance.
- `depositRate()` / `marketRate()` — return the vault share's deposit rate and its market rate.
- `buybackTriggered()` — true when the market price is far enough below the deposit rate.
- `netValue(shares)` — values vault shares in avKAT at the net rate.
- `managedAvkat()` / `allocationBps()` — return the position's value and its target share.
- `bptFor(avkat)` — returns the pool tokens worth that much avKAT.
- `planDeploy(budget, managed)` — builds the entry: buy cyavKAT, add liquidity, burn leftovers.
- `planReduce(managed)` — builds the "sell, else burn" exit bundle for the excess over the cap.
- `planReduceFallback(managed)` — builds the burn-only version used when the sale reverts.
- `planWithdraw(needed, scheduled)` — always empty; withdrawals use `planPolStep`.
- `planPolStep(needed, requestFeeBps, charged)` — builds the exit plus its sale and burn alternatives for a fulfilment, with the sale floor from the fee headroom.
- `settlePolStep(provided, cost, requestFeeBps)` — computes the vault's minimum, what the requester must be charged, or the admin yield fee.
- `planBuyback()` — builds the guarded buyback of cyavKAT below the deposit rate and its guaranteed gain.
- `planBurnHeld()` — builds the burn of any cyavKAT the vault holds.
- `withdrawYieldFee(profit)` — returns the admin fee on a withdrawal's profit.
- `yieldFeeAction(amount)` — builds the transfer paying the admin fee.

**CurveYieldAvkatLendController** — planner for lending avKAT on Morpho (market 41).
- `setExecutor(executor)` / `setFuses(supplyFuse)` — owner wiring.
- `params()` — reads lending settings from the gate.
- `recordReduction(amount)` — the executor records an amount withdrawn so decay tracks it.
- `marketState()` — returns the lending market's supply, liquidity and utilisation.
- `managedAvkat()` / `allocationBps()` — return the lent value and its target share.
- `planDeploy(budget, managed)` — builds the supply bundle within the cap and liquidity floor.
- `planReduce(managed)` — builds a withdrawal when over the (decaying) cap.
- `planWithdraw(needed, scheduled)` — builds a withdrawal of lent avKAT.

### A3. Libraries

**CurveYieldMorphoLoopLib** — loop maths and bundle builders.
- `snapshot` — collateral, debt, LTV, net equity. `oraclePrice` / `lltv` — Morpho market parameters. `repayRequiredForWithdrawal` — debt to repay for a collateral withdrawal. `bookedUnwindLoss` — loss of a sale on the conversion basis.
- `planUnwind` / `planDeleverage` / `planPartialRepay` — size the three unwind kinds using the router's protected quotes. `clampRepay` — limits a partial repay to what reaches the target LTV.
- `unwindActions` — builds the flash-loan unwind. `collateralAction` / `borrowAction` / `swapAction` — build single official-fuse calls.

**CurveYieldQuoteLib** — `minimumOut` returns the router's protected minimum output; `requiredInput` searches for the smallest input that reaches a required output.

**CurveYieldUtsLib** — `swapAction` builds the IPOR UniversalTokenSwapper call with swap router v2 as the only target.

**CurveYieldBundleLib** — `wrap`, `wrapWithGain`, `wrapWithLoss`, `wrapWithLtv`, `wrapFull` bracket actions with guard enter/exit; `concat` joins two action lists.

**CurveYieldSubstrateLib** — `encode`, `encodeAddress`, `encodeCap`, `encodeMaxLtv` build typed substrates; `typeOf`, `payloadOf` decode them; `isGranted`, `capOf`, `maxPpsDropBps`, `maxLtvBps` read the granted values from the config market.

**CurveYieldPolPriceLib** — `oneShare`, `depositRate`, `marketRate`, `netValue` price the vault's own share.

**CurveYieldSwapLib** — `twapOut`, `twapOutRoute`, `bestRoute`, `swapBest`, `permit2Approve`, `balancerSwap` are the swap helpers custody v2 uses.

**CurveYieldBounds** — `validate` and `check` enforce construction-time min/max ranges.

### A4. Router, withdraw manager, gate

**CurveYieldSwapRouterV2** — the only router the vault's swapper may call; Sushi V3 and CurveYield DEX routes, 0.1% fee, protected minimum.
- `setFeeRecipient(recipient)` — fee authority sets the fee receiver.
- `setBalancer(vault, router)` — owner wires the CurveYield DEX once.
- `setRoute(tokenIn, tokenOut, hops)` / `removeRoute` / `routeHops` — owner manages and reads multi-hop routes.
- `protection()` — reads protection bps and TWAP window from the gate.
- `protectedQuote(tokenIn, tokenOut, amountIn)` — returns expected net output and the protected minimum.
- `twapMinimumOut(...)` — returns just the protected minimum.
- `swapExactInput(tokenIn, tokenOut, amountIn, minNetOut, recipient, deadline)` — swaps along the route, takes the fee, and reverts below max(protected minimum, caller minimum).
- `uniswapV3SwapCallback(...)` — pays the active Sushi pool during a hop.

**CurveYieldWithdrawalManagerV2** — the vault's withdraw manager: request queue, fee escrow, instant withdrawal fee.
- `proxyInitialize(accessManager)` — initialises it behind a proxy.
- `requestShares(grossShares)` — a holder requests a withdrawal and escrows the request fee.
- `canWithdrawFromRequest(account, shares)` — vault hook: consumes a released request.
- `canWithdrawFromUnallocated(shares)` — vault hook: returns the instant-withdraw fee shares to burn.
- `setFeeSplit(...)` / `feeSplit()` / `settleSplit()` — optional instant-fee split to recipients, and its payout.
- `setBurnOnlyFee(account, enabled)` / `armBurnOnlyFee()` — let an account (custody v2) redeem with the fee burned in full.
- `pruneExpiredRequests(maxEntries)` / `hasMoreStaleEntries()` — refund and drop expired requests in batches.
- `releaseActiveShares(timestamp, shares)` / `releaseFor(requester, timestamp, shares)` — controller releases requested shares and burns the earned fee, returning the burned amount.
- `chargeRequest(requester, shares)` / `chargeRequestForAssets(requester, assets, maxShares)` — controller burns shares from a request to keep the vault at its minimum profit.
- `assetsNeededFor(shares)` / `releasableShares()` — assets needed for released plus extra shares, and shares idle can release now.
- `pendingOnboardingFeeShares()` / `settleOnboardingFee()` / `setOnboardingAdmin(admin)` — deposit-fee shares waiting, their 70/30 payout, and the admin receiver.
- `activeUnreleasedShares()` / `activeRequestedShares()` / `reservedSharesOf` / `availableSharesOf` / `earnedFeeShares()` — request accounting views.
- `setDependencies(controller, burnFuse, requestFeeFuse, previousManager)` — sets the controller and fuses and rotates the allowance.
- `controller()` / `setProfitCustody` / `profitCustody()` — controller and the profit custody address.
- `requestInfo` / `rawRequestInfo` / `getLastReleaseFundsTimestamp` / `getSharesToRelease` — request views.
- `updateWithdrawWindow` / `getWithdrawWindow` / `updateWithdrawFee` / `getWithdrawFee` / `updateRequestFee` / `getRequestFee` — fee and window settings (fees come from the gate when wired).
- `setConfigGate(gate)` / `retainedWithdrawFeeBps()` — gate wiring and the instant fee the vault keeps.
- `updatePlasmaVaultAddress` / `getPlasmaVaultAddress` — vault pointer.

**CurveYieldWithdrawalManagerStorageLib** — `layout`, `push`, `peek`, `pop`, `queueLength` implement the manager's namespaced storage and expiry queue.

**CurveYieldGovernanceGate** — owner of record of every CurveYield contract and holder of the vault's IPOR roles; `dao` is the fee Safe.
- `execute(target, data)` — the dao forwards a call unless it is protected.
- `executeProtected(target, data)` — a fee authority forwards any call except to the gate.
- `executeGuardian(...)` / `setGuardian` / `setGuardianCall` — unused guardian lane (guardian is zero).
- `isProtected(target, data)` — true if the dao may not make the call.
- `setFeeAuthority` / `setProtectedCalls` / `setAccessManager` / `setProtectedRoles` / `setDao` / `setAdminReceiver` — fee-authority administration.
- `addr` / `addrOrZero` / `addrKeys` / `registerAddr` / `setAddr` — wiring registry for stack contracts.
- `registerConfig` / `addRule` / `setConfigs` / `setConfigByGuardian` / `setConfigRange` / `setGuardianRange` / `getMany` / `getConfig` / `configKeys` / `rule` — numeric settings with hard caps, classes and group rules.
- `registerArgRange` / `setArgRange` / `passRead` — ranges on setter arguments of other contracts and plain reads.
- `setSubstrateVault` / `setStaticSubstrates` / `addSubstrateBinding` / `clearSubstrateBindings` — fee authority defines which substrates the gate writes into the vault.
- `previewSubstrates(market)` / `syncSubstrates(market)` — return, and write to the vault, the static entries plus the bound settings' current values.
- `staticSubstrates` / `substrateBindings` — read the definitions.

**CurveYieldGateConfig** (base) — `setConfigGate` moves a contract to a new gate; internal `_config`, `_config1`, `_addr` read settings and wiring. Libraries `CurveYieldConfigKeys` / `CurveYieldAddrKeys` hold the key names.

### A5. Revenue custody v2

**CurveYieldRevenueCustodyV2** — the layer on top of the live loop custody: allocation, Charm farm, POL position B, Merkl, cover.
- `ROUTER()` / `REWARDS_CLAIM_MANAGER()` / `revenueShareBps()` / `loopTargetBps()` / `windupDistributionBps()` — gate-wired addresses and settings.
- `setOperator` / `setCoverer` / `setFeeRecipient` / `setCharmVaultAllowed` / `setPolVenues` — owner configuration.
- `tokens()` / `charmVaults()` / `idleAvkat()` / `loopEquityAvkat()` / `farmValueAvkat()` / `polDepositRate()` / `polPosition()` — holdings and valuation views.
- `deployAll()` — sends the loop's share to the live custody (running its `deployAll`) and spreads the rest over the Charm vaults.
- `cover(loss)` — pays the vault's measured loss from idle avKAT, then the farm.
- `scheduleFullUnwind` / `cancelFullUnwind` / `executeFullUnwind` — 15-day delayed exit of everything to a successor.
- `swap(...)` / `charmDeposit(...)` / `charmWithdraw(...)` — operator trades and Charm deposits/withdrawals through router v2.
- `harvestMerkl(tokens, amounts, proofs)` — claims Charm rewards, converts them to avKAT and splits them like a loop gain.
- `reserveAvkatForPolBps(bps)` — reserves a specified portion of custody-held avKAT for POL B (no feeder).
- `polDeploy(avkatIn)` / `polExitToAvkat(shares, receiver)` — operator enters, and owner exits, position B.
- `sellCyavkatSelf` / `swapToAvkatSelf` / `charmExitSelf` — self-calls that let the contract try a step without reverting.

### A6. Lending wrapper and oracle (live, kept)

**CurveYieldWrappedCyavKat** — ERC-4626 wrapper of cyavKAT used as lending collateral.
- `pendingFees()` / `accrue()` / `setFees(mgmt, perf)` — fee accrual and its owner setting.
- `totalAssets()` — assets net of pending fees.
- `deposit` / `mint` / `withdraw` / `redeem` — standard ERC-4626 entry and exit with fees accrued first.

**CurveYieldWrapperFeeSplitter** — `setAdminReceiver`, `setDestinations`, `distribute` route wrapper fee shares to the admin, contributors and the withdraw manager.
**Wrapper routing in V2** — existing `CurveYieldWrapperFeeSplitter` only; `L10_RouteWrapperFeesToCustodyV2` routes 30% directly to `CurveYieldRevenueCustodyV2` and 30% to WM V2. No burn forwarder is deployed; the existing 40/30/30 ratio remains unchanged.
**IporVaultHaircutOracle12** — `price()` returns the Morpho collateral price of wcyavKAT with a 12% haircut.

### A7. ERC-1271 base (live, kept)

**CurveYieldVaultBase1271** — wraps the vault's PlasmaVaultBase.
- `isValidSignature(hash, signature)` — accepts only prefixed personal-sign log-in messages from an authorised signer.
- `isQuestSigner(signer)` / `questSignPrefix()` — read the signer set and prefix.
- fallback — delegates everything else unchanged to the original base.

---

## Part B. Live contracts kept unchanged

**CurveYieldProfitCustody** `0xe7D1…5ADf` — the loop custody.
- `setGuardian(guardian, enabled)` — owner lets an account (custody v2) run operator actions.
- `setRevenueShareBps` / `setWindupDistributionBps` / `setFeeRecipient` — fee-authority revenue split settings.
- `deployAll()` — operator deploys idle avKAT into the Morpho loop.
- `balanceLtv()` — operator rebalances the loop's LTV.
- `scheduleFullUnwind` / `cancelFullUnwind` / `executeFullUnwind` — 15-day delayed exit to a recipient.
- `positionSnapshot()` — returns collateral, debt, value and LTV.
- `onMorphoFlashLoan(assets, data)` — Morpho flash-loan callback.

**CurveYieldSushiV3FeeRouter** `0x01F9…3582` — Sushi V3 router with a fee, used by cyvbUSDC's reward swaps and the live custody.
- `transferOwnership` / `setFeeRecipient` / `setFeeBps` / `setRoute` / `removeRoute` / `setRouteFeeBps` / `clearRouteFee` / `setRouteTwapGuard` — owner configuration.
- `routeFor` / `routeTwapGuard` — read a route and its TWAP guard.
- `twapMinimumOut(...)` — minimum output from the pool TWAP.
- `swapExactInput(...)` — swaps along the route and takes the fee.
- `uniswapV3SwapCallback(...)` — pays the active pool.

---

## Part C. Official IPOR code the vault runs (commit `a1f79d6`)

- **PlasmaVault / PlasmaVaultBase / PlasmaVaultMarketsLib** — the ERC-4626 vault, its governance and ERC-20 base, and the library that revalues markets.
- **UniversalTokenSwapperFuse** (market 12) — `enter(tokenIn, tokenOut, amountIn, minAmountOut, targets, data)` swaps through allowlisted targets with USD slippage and minimum checks; `enterTransient()` is the chained form.
- **MorphoCollateralFuse / MorphoBorrowFuse** (market 14) — `enter` and `exit` supply or withdraw collateral and borrow or repay on Morpho; transient forms for chaining.
- **MorphoFlashLoanFuse** (market 19) — `enter(token, amount, callbackActions)` takes a Morpho flash loan and runs the callback actions.
- **MorphoSupplyFuse** (market 41) and **MorphoOnlyLiquidityBalanceFuse** — supply, withdraw and `instantWithdraw` for the lending market, and its balance.
- **MorphoBalanceFuse** (market 14) — `balanceOf()` values collateral minus debt of the granted Morpho markets.
- **Erc4626SupplyFuse / Erc4626BalanceFuse** (market 100_001) — deposit into and withdraw from cyvbUSDC with min-shares and max-burn bounds, and value the position.
- **Erc20BalanceFuse** (market 7) — `balanceOf()` values the vault's plain token balances.
- **ZeroBalanceFuse** — returns zero for utility and config markets.
- **BalancerLiquidityProportionalFuse** (market 36) — `enter` and `exit` add or remove proportional liquidity in the CurveYield DEX pool.
- **UpdateMarketsBalancesFuse** — `enter(marketIds)` revalues the listed markets (and their dependants).
- **TransientStorageMapperFuse / TransientStorageSetInputsFuse** — copy outputs between fuses and set inputs in transient storage, for chained bundles.
- **PlasmaVaultBalanceAssetsValidationFuse** — checks balances stay within bounds inside a bundle.
- **BurnRequestFeeFuse** — burns the withdraw manager's fee shares.
- **UpdateWithdrawManagerMaintenanceFuse** — one-time switch of the vault's withdraw manager.
- **CallbackHandlerMorpho** — routes Morpho's flash-loan callback into the vault's actions.
- **RewardsClaimManager** — vests the avKAT it holds and releases it to the vault (`transferVestedTokensToVault`, `updateBalance`).
- **PriceOracleMiddleware / ERC4626PriceFeed / FixedValuePriceFeed** — USD prices for every vault token, including cyavKAT, wcyavKAT and vbUSDC.
- **FeeManager / IporFusionAccessManager** — performance, management and deposit fees, and the role system.
