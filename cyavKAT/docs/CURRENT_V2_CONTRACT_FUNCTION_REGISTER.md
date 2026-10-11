# cyavKAT V2 — Current Active Contract & Callable Function Register

**Source:** `cyavKAT_signing_layer_v18.zip` (locally prepared, not tested), actual Solidity in `cyavKAT/upgrade/src/`, the exact V2 phase scripts, original IPOR contracts and retained deployed sources.

**Scope:** Only contracts that remain operational after V2 or that V2 is designed to install. Superseded V1 controllers/fuses, retired vKAT and Merkl claim fuses, one-time Quest installer, uninstalled generic Quest fuses, test mocks, deployment scripts, internal libraries and protocol externalities (Sushi pools, tokens, Morpho core, etc.) are intentionally excluded.

**Deployment status:** “Existing” means referenced as live/retained by the source and deployment records, **not** a freshly verified read of current Katana bytecode. “V2 deployment” means created by the intended scripts, not evidence it has been broadcast on mainnet. POL Balancer liquidity fuse is conditional on venue configuration. The script also deploys cutover-only maintenance tooling that is intentionally not an ongoing V2 stack contract.

**ABI coverage:** Public/external functions declared on these classes; compiler-generated public state-variable getters; inherited Ownable2Step, ERC-20/ERC-4626, and AccessManager methods as relevant; and the inherited PlasmaVaultGovernance selectors that remain available through the original IPOR base. This is a source-derived interface register, not a compiler-produced selector manifest; overload signatures should be verified against compiled ABIs before transaction construction.

**Call context:** Fuses are ordinarily invoked by privileged `PlasmaVault.execute` / reward execution through `delegatecall`; their presence in an ABI does not mean users can call them directly with vault privileges. `fallback` on the ERC-1271 wrapper forwards calls using the vault’s state.

**Coverage:** 48 current contract types, 817 source-derived callable method entries (including inherited/generated getters).

## CurveYield V2 and retained custom

### CurveYieldGovernanceGate
**Status:** V2 deployment.
**Role:** IPOR-backed operating gate and self-administered ADMIN_FEE authority for protected fee changes.
**Source:** `upgrade/src/governance/CurveYieldGovernanceGate.sol`.

| Callable function | One-sentence summary |
|---|---|
| `activateFeeHandover()` | Finalizes the transition to self-managed ADMIN_FEE administration. |
| `transferAdminFeeRole()` | Lets the current ADMIN_FEE holder nominate its sole successor. |
| `registerAdminFeeCalls()` | Registers reviewed fee-changing target selectors for the restricted fee lane. |
| `executeAdminFee()` | Runs a registered fee-changing function as the ADMIN_FEE holder. |
| `execute()` | Forwards permitted operational calls using existing IPOR role authorization. |
| `executeRestricted()` | Forwards a restricted owner-operation only after validating its authorized execution path. |
| `acceptContractOwnership()` | Accepts a two-step ownership transfer on behalf of the gate. |
| `transferContractOwnershipToAdminSafe()` | Performs the specifically constrained Safe ownership recovery operation. |
| `executeGuardian()` | Runs an explicitly registered guardian action under its separate guarded permission check. |
| `setGuardianCall()` | Registers a guardian-call selector subject to the gate authorization rules. |
| `setProtectedCalls()` | Protects listed selectors from general-purpose forwarding. |
| `isProtected()` | Indicates whether the supplied target call is blocked from the ordinary gate lane. |
| `addr()` | Returns the required registered address for a configuration key. |
| `addrOrZero()` | Returns a registered dependency address or zero if absent. |
| `addrKeys()` | Lists registered address keys. |
| `registerAddr()` | Registers a dependency address for the first time. |
| `setAddr()` | Updates a governed dependency address under its role class. |
| `registerConfig()` | Registers a numeric config key with immutable hard bounds and an initial value. |
| `sealFeeConfiguration()` | Permanently closes the initial fee-key registration phase. |
| `addRule()` | Registers a cross-configuration validation rule. |
| `setConfigs()` | Updates numeric values atomically while enforcing their roles, bounds and group rules. |
| `setConfigByGuardian()` | Adjusts one guardian-class value within its approved range. |
| `setConfigRange()` | Adjusts permitted operating or fee ranges without exceeding hard bounds. |
| `setGuardianRange()` | Updates the constrained guardian adjustment range. |
| `getMany()` | Retrieves numeric settings for a set of keys in one call. |
| `getConfig()` | Returns the configuration record and current value for a key. |
| `configKeys()` | Lists registered numeric configuration keys. |
| `rule()` | Returns a registered inter-key validation rule. |
| `setSubstrateVault()` | Sets the vault receiving synchronized market substrate configurations. |
| `setStaticSubstrates()` | Records the fixed authorized tokens, targets and recipients for a market. |
| `addSubstrateBinding()` | Binds a numeric gate setting to a typed vault market substrate entry. |
| `clearSubstrateBindings()` | Removes a market's programmable substrate bindings. |
| `syncSubstrates()` | Writes approved static and dynamic substrate settings to the vault. |
| `previewSubstrates()` | Shows the exact substrates that would be synchronized now. |
| `staticSubstrates()` | Returns a market's fixed substrate values. |
| `substrateBindings()` | Lists a market's numeric-to-substrate bindings. |
| `registerArgRange()` | Registers hard bounds for a forwarded call's numeric parameter. |
| `setArgRange()` | Changes a forwarded parameter's allowed range without violating hard limits. |
| `passRead()` | Performs a view-only call against a configured external target. |
| `IPOR_OWNER_ROLE()` *(getter)* | Returns the current on-chain value of `IPOR_OWNER_ROLE` (including any configured indexed arguments). |
| `IPOR_GUARDIAN_ROLE()` *(getter)* | Returns the current on-chain value of `IPOR_GUARDIAN_ROLE` (including any configured indexed arguments). |
| `IPOR_ATOMIST_ROLE()` *(getter)* | Returns the current on-chain value of `IPOR_ATOMIST_ROLE` (including any configured indexed arguments). |
| `iporAccessManager()` *(getter)* | Returns the current on-chain value of `iporAccessManager` (including any configured indexed arguments). |
| `adminReceiver()` *(getter)* | Returns the current on-chain value of `adminReceiver` (including any configured indexed arguments). |
| `adminFeeRoleHolder()` *(getter)* | Returns the current on-chain value of `adminFeeRoleHolder` (including any configured indexed arguments). |
| `feeHandoverComplete()` *(getter)* | Returns the current on-chain value of `feeHandoverComplete` (including any configured indexed arguments). |
| `isFeeBearingTarget()` *(getter)* | Returns the current on-chain value of `isFeeBearingTarget` (including any configured indexed arguments). |
| `isProtectedCall()` *(getter)* | Returns the current on-chain value of `isProtectedCall` (including any configured indexed arguments). |
| `isGuardianCall()` *(getter)* | Returns the current on-chain value of `isGuardianCall` (including any configured indexed arguments). |
| `isAdminFeeCall()` *(getter)* | Returns the current on-chain value of `isAdminFeeCall` (including any configured indexed arguments). |
| `feeConfigRegistrationSealed()` *(getter)* | Returns the current on-chain value of `feeConfigRegistrationSealed` (including any configured indexed arguments). |
| `CLASS_DAO()` *(getter)* | Returns the current on-chain value of `CLASS_DAO` (including any configured indexed arguments). |
| `CLASS_GUARDIAN()` *(getter)* | Returns the current on-chain value of `CLASS_GUARDIAN` (including any configured indexed arguments). |
| `RULE_SUM_EQ()` *(getter)* | Returns the current on-chain value of `RULE_SUM_EQ` (including any configured indexed arguments). |
| `RULE_SUM_LE()` *(getter)* | Returns the current on-chain value of `RULE_SUM_LE` (including any configured indexed arguments). |
| `RULE_ORDER_LE()` *(getter)* | Returns the current on-chain value of `RULE_ORDER_LE` (including any configured indexed arguments). |
| `RULE_ORDER_LT()` *(getter)* | Returns the current on-chain value of `RULE_ORDER_LT` (including any configured indexed arguments). |
| `RULE_EACH_LE()` *(getter)* | Returns the current on-chain value of `RULE_EACH_LE` (including any configured indexed arguments). |
| `RULE_LOCK()` *(getter)* | Returns the current on-chain value of `RULE_LOCK` (including any configured indexed arguments). |
| `BIND_GUARD_MAX_PPS_DROP()` *(getter)* | Returns the current on-chain value of `BIND_GUARD_MAX_PPS_DROP` (including any configured indexed arguments). |
| `BIND_TRANSFER_CAP()` *(getter)* | Returns the current on-chain value of `BIND_TRANSFER_CAP` (including any configured indexed arguments). |
| `BIND_GUARD_MAX_LTV()` *(getter)* | Returns the current on-chain value of `BIND_GUARD_MAX_LTV` (including any configured indexed arguments). |
| `substrateVault()` *(getter)* | Returns the current on-chain value of `substrateVault` (including any configured indexed arguments). |

### CurveYieldQuestSignerConfigFuse
**Status:** Required V2 signing migration.
**Role:** Permanent vault-local Quest signer and domain-prefix administrator, replacing the detached one-time installer.
**Source:** `upgrade/src/katana/CurveYieldQuestSignerConfigFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `QUEST_SIGNING_LAYER_VERSION()` | Returns the mandatory Quest signer-controller implementation version. |
| `setSigner()` | Authorizes or revokes an account for the live vault's ERC-1271 Quest signatures. |
| `setPrefix()` | Changes the allowed Quest signed-message domain prefix. |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |
| `VAULT()` *(getter)* | Returns the current on-chain value of `VAULT` (including any configured indexed arguments). |
| `BASE_1271()` *(getter)* | Returns the current on-chain value of `BASE_1271` (including any configured indexed arguments). |
| `ORIGINAL_BASE()` *(getter)* | Returns the current on-chain value of `ORIGINAL_BASE` (including any configured indexed arguments). |

### CurveYieldVaultExecutor
**Status:** V2 deployment.
**Role:** Keeper entrypoint that coordinates allocation, rebalancing, fulfillment, and guarded asset movements.
**Source:** `upgrade/src/executor/CurveYieldVaultExecutor.sol`.

| Callable function | One-sentence summary |
|---|---|
| `setDependencies()` | Assigns the controllers and fuses the executor coordinates. |
| `setBackstops()` | Sets the ordered external custodians that can cover vault losses. |
| `backstops()` | Returns the configured PPS-loss backstop addresses. |
| `dependencies()` | Returns the configured controller and fuse addresses. |
| `profitSplit()` | Calculates the original vault-loop four-leg distribution from the existing gate; this does NOT split Profit Custody receipts. |
| `deployAssets()` | Deploys eligible idle avKAT through guarded strategies, fees and POL steps while observing withdrawal requests. |
| `rebalance()` | Rebalances loop and USDC positions through independently guarded action bundles. |
| `fulfillAll()` | Funds as many outstanding withdrawal requests as available safe liquidity allows. |
| `function fulfillFor(address requester_, uint256 shares_) external nonReentrant` | Funds one requester's withdrawal shares through the safe withdrawal plan. |
| `function fulfillFor(address requester_, uint256 shares_, uint256 maxChargeShares_) externa` | Fulfills one requester, optionally using POL liquidity and charging the requester for any permitted shortfall. |
| `executeSelf()` | Executes a guarded self-call bundle so an optional strategy step can be caught on failure. |
| `pruneExpiredRequests()` | Cleans up expired withdrawal requests in a bounded batch. |
| `emergencyRepay()` | Deleverages excessive Morpho debt, using approved backstops if required. |
| `MAX_PAY_AVKAT()` *(getter)* | Returns the current on-chain value of `MAX_PAY_AVKAT` (including any configured indexed arguments). |
| `VAULT()` *(getter)* | Returns the current on-chain value of `VAULT` (including any configured indexed arguments). |
| `AVKAT()` *(getter)* | Returns the current on-chain value of `AVKAT` (including any configured indexed arguments). |
| `owner()` *(inherited/delegated)* | Returns the contract’s current owner. |
| `pendingOwner()` *(inherited/delegated)* | Returns the nominated successor owner. |
| `transferOwnership()` *(inherited/delegated)* | Starts an Ownable2Step transfer by nominating a new owner. |
| `acceptOwnership()` *(inherited/delegated)* | Accepts a pending two-step ownership transfer. |
| `renounceOwnership()` *(inherited/delegated)* | Relinquishes contract ownership if allowed. |
| `configGate()` *(inherited/delegated)* | Returns the governance configuration gate address. |
| `setConfigGate()` *(inherited/delegated)* | Updates this contract’s gate pointer under its authorization policy. |

### CurveYieldAllocationController
**Status:** V2 deployment.
**Role:** Tracks vault allocation budgets, seasoning, liquidity floors, and withdrawal-source order.
**Source:** `upgrade/src/allocation/CurveYieldAllocationController.sol`.

| Callable function | One-sentence summary |
|---|---|
| `REWARDS_CLAIM_MANAGER()` | Resolves the rewards-manager address from governance wiring. |
| `setSets()` | Connects the loop, USDC, lending and POL strategy planners. |
| `setExecutor()` | Assigns the executor allowed to use the controller's plans. |
| `vaultFloorBps()` | Returns the required idle-asset floor as basis points. |
| `seasoningDays()` | Returns the configured deposit seasoning period. |
| `checkpoint()` | Stores the daily low of managed assets for deposit seasoning. |
| `seasonedManagedAvkat()` | Returns the amount eligible for leverage after seasoning. |
| `sets()` | Returns configured strategy planner addresses. |
| `managedAvkat()` | Totals idle assets, vested rewards and strategy-managed avKAT value. |
| `strategicBps()` | Returns the configured strategic allocation percentage. |
| `budgets()` | Calculates available budgets and minimum vault reserves. |
| `planDeploy()` | Builds allocation bundles within the available strategy budgets. |
| `planReduces()` | Builds the set of required over-allocation reduction plans. |
| `withdrawSources()` | Lists withdrawal liquidity sources in priority order. |
| `reserveBudget()` | Calculates reserve-class assets after the required vault floor and committed allocations. |
| `VAULT()` *(getter)* | Returns the current on-chain value of `VAULT` (including any configured indexed arguments). |
| `AVKAT()` *(getter)* | Returns the current on-chain value of `AVKAT` (including any configured indexed arguments). |
| `executor()` *(getter)* | Returns the current on-chain value of `executor` (including any configured indexed arguments). |
| `MAX_SEASONING_DAYS()` *(getter)* | Returns the current on-chain value of `MAX_SEASONING_DAYS` (including any configured indexed arguments). |
| `firstCheckpointDay()` *(getter)* | Returns the current on-chain value of `firstCheckpointDay` (including any configured indexed arguments). |
| `lastCheckpointDay()` *(getter)* | Returns the current on-chain value of `lastCheckpointDay` (including any configured indexed arguments). |
| `dailyLow()` *(getter)* | Returns the current on-chain value of `dailyLow` (including any configured indexed arguments). |
| `owner()` *(inherited/delegated)* | Returns the contract’s current owner. |
| `pendingOwner()` *(inherited/delegated)* | Returns the nominated successor owner. |
| `transferOwnership()` *(inherited/delegated)* | Starts an Ownable2Step transfer by nominating a new owner. |
| `acceptOwnership()` *(inherited/delegated)* | Accepts a pending two-step ownership transfer. |
| `renounceOwnership()` *(inherited/delegated)* | Relinquishes contract ownership if allowed. |
| `configGate()` *(inherited/delegated)* | Returns the governance configuration gate address. |
| `setConfigGate()` *(inherited/delegated)* | Updates this contract’s gate pointer under its authorization policy. |

### CurveYieldMorphoLoopController
**Status:** V2 deployment.
**Role:** Plans guarded Morpho collateral, leverage, repayments, and unwind operations.
**Source:** `upgrade/src/morpho/CurveYieldMorphoLoopController.sol`.

| Callable function | One-sentence summary |
|---|---|
| `setExecutor()` | Authorizes the orchestrating executor. |
| `setAllocation()` | Connects the allocation controller used for budgets. |
| `env()` | Returns configured addresses for the Morpho looping environment. |
| `params()` | Returns the governed loop risk and execution settings. |
| `allowedLossBps()` | Returns the strategy's permitted loss ceiling. |
| `snapshot()` | Reports current Morpho collateral, debt, equity and leverage. |
| `managedAvkat()` | Returns the strategy's managed equity denominated in avKAT. |
| `allocationBps()` | Returns the planned fraction of managed vault value allocated to the strategy. |
| `requiredWindupProfitBps()` | Returns the minimum required profitability for a windup action. |
| `hasScheduledRequests()` | Reports whether pending withdrawals constrain windups. |
| `windupLimit()` | Computes the maximum authorized next leverage expansion. |
| `planDeploy()` | Builds the next safe leveraged deployment actions. |
| `planReduce()` | Builds actions to reduce strategy exposure above its allocation. |
| `planWithdraw()` | Builds actions to recover avKAT for withdrawal liquidity. |
| `planCycle()` | Builds one bounded Morpho looping step and its swap legs. |
| `needsRelever()` | Checks whether Morpho LTV has fallen below its target. |
| `planCollateralTopUp()` | Plans adding free collateral to improve leverage safety. |
| `planEmergency()` | Builds urgent deleveraging actions for excessive LTV. |
| `MIN_BORROW_KAT()` *(getter)* | Returns the current on-chain value of `MIN_BORROW_KAT` (including any configured indexed arguments). |
| `executor()` *(getter)* | Returns the current on-chain value of `executor` (including any configured indexed arguments). |
| `allocation()` *(getter)* | Returns the current on-chain value of `allocation` (including any configured indexed arguments). |
| `owner()` *(inherited/delegated)* | Returns the contract’s current owner. |
| `pendingOwner()` *(inherited/delegated)* | Returns the nominated successor owner. |
| `transferOwnership()` *(inherited/delegated)* | Starts an Ownable2Step transfer by nominating a new owner. |
| `acceptOwnership()` *(inherited/delegated)* | Accepts a pending two-step ownership transfer. |
| `renounceOwnership()` *(inherited/delegated)* | Relinquishes contract ownership if allowed. |
| `configGate()` *(inherited/delegated)* | Returns the governance configuration gate address. |
| `setConfigGate()` *(inherited/delegated)* | Updates this contract’s gate pointer under its authorization policy. |

### CurveYieldUsdcStrategyController
**Status:** V2 deployment.
**Role:** Plans cyvbUSDC allocation and management of the USDC-linked Morpho strategy.
**Source:** `upgrade/src/morpho/CurveYieldUsdcStrategyController.sol`.

| Callable function | One-sentence summary |
|---|---|
| `setExecutor()` | Designates the strategy's authorized executor. |
| `env()` | Returns configured USDC-strategy protocol and token addresses. |
| `params()` | Returns the governed USDC strategy settings. |
| `allowedLossBps()` | Returns the configured maximum allowed execution loss. |
| `position()` | Reports current USDC-strategy collateral, debt and exposure. |
| `managedAvkat()` | Values the strategy's equity in avKAT. |
| `allocationBps()` | Returns its target share of managed vault assets. |
| `planDeploy()` | Constructs the allowed USDC strategy allocation steps. |
| `planReduce()` | Constructs actions to lower excessive USDC strategy exposure. |
| `planWithdraw()` | Constructs a liquidity recovery bundle for withdrawal fulfillment. |
| `shortfallInput()` | Quotes the avKAT needed to cover an outstanding USDC-side shortfall. |
| `planRebalance()` | Plans safe USDC-strategy debt and collateral rebalancing. |
| `MIN_DEPLOY_AVKAT()` *(getter)* | Returns the current on-chain value of `MIN_DEPLOY_AVKAT` (including any configured indexed arguments). |
| `DEPOSIT_TOLERANCE_BPS()` *(getter)* | Returns the current on-chain value of `DEPOSIT_TOLERANCE_BPS` (including any configured indexed arguments). |
| `REBALANCE_TOLERANCE_BPS()` *(getter)* | Returns the current on-chain value of `REBALANCE_TOLERANCE_BPS` (including any configured indexed arguments). |
| `executor()` *(getter)* | Returns the current on-chain value of `executor` (including any configured indexed arguments). |
| `owner()` *(inherited/delegated)* | Returns the contract’s current owner. |
| `pendingOwner()` *(inherited/delegated)* | Returns the nominated successor owner. |
| `transferOwnership()` *(inherited/delegated)* | Starts an Ownable2Step transfer by nominating a new owner. |
| `acceptOwnership()` *(inherited/delegated)* | Accepts a pending two-step ownership transfer. |
| `renounceOwnership()` *(inherited/delegated)* | Relinquishes contract ownership if allowed. |
| `configGate()` *(inherited/delegated)* | Returns the governance configuration gate address. |
| `setConfigGate()` *(inherited/delegated)* | Updates this contract’s gate pointer under its authorization policy. |

### CurveYieldAvkatLendController
**Status:** V2 deployment.
**Role:** Plans and accounts for avKAT lending positions on the established Morpho market.
**Source:** `upgrade/src/lend/CurveYieldAvkatLendController.sol`.

| Callable function | One-sentence summary |
|---|---|
| `setExecutor()` | Designates the strategy's authorized executor. |
| `setFuses()` | Connects the IPOR fuse handling Morpho lending transfers. |
| `params()` | Returns the lending allocation and risk settings. |
| `recordReduction()` | Records completion of a lending exposure reduction. |
| `marketState()` | Returns supplied liquidity and market position data. |
| `managedAvkat()` | Values the vault's supplied avKAT in the Morpho lending market. |
| `allocationBps()` | Returns the allocation target for the lending strategy. |
| `planDeploy()` | Plans a supply of excess avKAT to its authorized lending market. |
| `planReduce()` | Plans a reduction of lending exposure above target. |
| `planWithdraw()` | Plans recovery of loaned avKAT for withdrawal liquidity. |
| `VAULT()` *(getter)* | Returns the current on-chain value of `VAULT` (including any configured indexed arguments). |
| `MORPHO()` *(getter)* | Returns the current on-chain value of `MORPHO` (including any configured indexed arguments). |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |
| `executor()` *(getter)* | Returns the current on-chain value of `executor` (including any configured indexed arguments). |
| `supplyFuse()` *(getter)* | Returns the current on-chain value of `supplyFuse` (including any configured indexed arguments). |
| `lastReductionAt()` *(getter)* | Returns the current on-chain value of `lastReductionAt` (including any configured indexed arguments). |
| `owner()` *(inherited/delegated)* | Returns the contract’s current owner. |
| `pendingOwner()` *(inherited/delegated)* | Returns the nominated successor owner. |
| `transferOwnership()` *(inherited/delegated)* | Starts an Ownable2Step transfer by nominating a new owner. |
| `acceptOwnership()` *(inherited/delegated)* | Accepts a pending two-step ownership transfer. |
| `renounceOwnership()` *(inherited/delegated)* | Relinquishes contract ownership if allowed. |
| `configGate()` *(inherited/delegated)* | Returns the governance configuration gate address. |
| `setConfigGate()` *(inherited/delegated)* | Updates this contract’s gate pointer under its authorization policy. |

### CurveYieldWithdrawalManagerV2
**Status:** V2 deployment.
**Role:** Implements withdrawal requests, liquidity releases, share-fee escrow, fee burning, and onboarding-fee settlement.
**Source:** `upgrade/src/withdraw/CurveYieldWithdrawalManagerV2.sol`.

| Callable function | One-sentence summary |
|---|---|
| `proxyInitialize()` | Initializes the manager clone's access-controlled state. |
| `requestShares()` | Locks a user's share withdrawal request and escrows its request fee. |
| `canWithdrawFromRequest()` | Validates and consumes a released withdrawal request. |
| `canWithdrawFromUnallocated()` | Computes the fee due for an instant withdrawal outside the queue. |
| `setFeeSplit()` | Configures recipient distribution of eligible instant-withdrawal fees. |
| `setBurnOnlyFee()` | Configures recipients whose instant fee is burned without redistribution. |
| `armBurnOnlyFee()` | Activates the caller's authorized burn-only fee mode. |
| `settleSplit()` | Pays out accumulated distributable instant fee shares. |
| `feeSplit()` | Reads the recipient addresses and fee split percentages. |
| `pruneExpiredRequests()` | Refunds and deletes expired requests in bounded batches. |
| `hasMoreStaleEntries()` | Indicates whether more expired requests await cleanup. |
| `releaseActiveShares()` | Releases requested shares against available assets and realizes the earned fee. |
| `releaseFor()` | Releases a specific account's requested shares and burns earned fees. |
| `chargeRequest()` | Charges a request's shares against a permitted withdrawal loss. |
| `chargeRequestForAssets()` | Burns enough request shares to cover an approved asset shortfall within a cap. |
| `assetsNeededFor()` | Quotes assets required to release a specified number of shares. |
| `releasableShares()` | Reports the shares currently releasable from idle liquidity. |
| `pendingOnboardingFeeShares()` | Reports unpaid onboarding fee shares held in escrow. |
| `settleOnboardingFee()` | Sends earned onboarding fee shares to the configured recipients. |
| `setOnboardingAdmin()` | Sets the admin share recipient for onboarding fees. |
| `activeUnreleasedShares()` | Returns active shares requested but not yet released. |
| `reservedSharesOf()` | Returns the portion of an account's shares reserved for withdrawal. |
| `availableSharesOf()` | Returns the portion of an account's shares available outside reservations. |
| `setDependencies()` | Connects the executor, fee-burn fuse, share-fee fuse and preceding manager. |
| `activeRequestedShares()` | Returns total active requested shares. |
| `earnedFeeShares()` | Returns total earned withdrawal fee shares. |
| `controller()` | Returns the current withdrawal controller address. |
| `setProfitCustody()` | Changes the address receiving applicable profit fees. |
| `profitCustody()` | Returns the configured profit custody receiver. |
| `requestInfo()` | Returns the public status of a request. |
| `rawRequestInfo()` | Returns request fields without additional presentation processing. |
| `getLastReleaseFundsTimestamp()` | Returns the last withdrawal-release timestamp. |
| `getSharesToRelease()` | Returns shares ready for release. |
| `updateWithdrawWindow()` | Changes the period during which released withdrawals may be claimed. |
| `getWithdrawWindow()` | Returns the configured withdrawal window. |
| `updateWithdrawFee()` | Changes the instant withdrawal fee where permitted by governance. |
| `getWithdrawFee()` | Returns the current instant withdrawal fee. |
| `updateRequestFee()` | Changes the fee charged to queued withdrawals where permitted. |
| `getRequestFee()` | Returns the current queued withdrawal fee. |
| `setConfigGate()` | Sets the governance gate that supplies managed fee settings. |
| `retainedWithdrawFeeBps()` | Returns the instant-fee share retained for burning by the vault. |
| `updatePlasmaVaultAddress()` | Updates the manager's associated vault address. |
| `getPlasmaVaultAddress()` | Returns the managed vault's address. |
| `splitRequestFee()` *(getter)* | Returns the current on-chain value of `splitRequestFee` (including any configured indexed arguments). |
| `owedSplitShares()` *(getter)* | Returns the current on-chain value of `owedSplitShares` (including any configured indexed arguments). |
| `burnOnlyFee()` *(getter)* | Returns the current on-chain value of `burnOnlyFee` (including any configured indexed arguments). |
| `configGate()` *(getter)* | Returns the current on-chain value of `configGate` (including any configured indexed arguments). |
| `committedShares()` *(getter)* | Returns the current on-chain value of `committedShares` (including any configured indexed arguments). |
| `onboardingAdmin()` *(getter)* | Returns the current on-chain value of `onboardingAdmin` (including any configured indexed arguments). |
| `ONBOARDING_CUSTODY_BPS()` *(getter)* | Returns the current on-chain value of `ONBOARDING_CUSTODY_BPS` (including any configured indexed arguments). |
| `MAX_PRUNE_BATCH()` *(getter)* | Returns the current on-chain value of `MAX_PRUNE_BATCH` (including any configured indexed arguments). |
| `DEFAULT_REQUEST_FEE()` *(getter)* | Returns the current on-chain value of `DEFAULT_REQUEST_FEE` (including any configured indexed arguments). |
| `DEFAULT_WITHDRAW_FEE()` *(getter)* | Returns the current on-chain value of `DEFAULT_WITHDRAW_FEE` (including any configured indexed arguments). |
| `DEFAULT_WITHDRAW_WINDOW()` *(getter)* | Returns the current on-chain value of `DEFAULT_WITHDRAW_WINDOW` (including any configured indexed arguments). |
| `ROLE_TEMPLATE_MANAGER()` *(getter)* | Returns the current on-chain value of `ROLE_TEMPLATE_MANAGER` (including any configured indexed arguments). |

### CurveYieldSwapRouterV2
**Status:** V2 deployment.
**Role:** Executes guarded configured Sushi or Balancer swap routes, taking its configured swap fee.
**Source:** `upgrade/src/router/CurveYieldSwapRouterV2.sol`.

| Callable function | One-sentence summary |
|---|---|
| `setFeeRecipient()` | Changes the account receiving fees collected on swaps. |
| `setBalancer()` | Configures the Balancer vault/router used by Balancer route legs. |
| `setRoute()` | Registers or replaces a validated multi-hop swap route. |
| `removeRoute()` | Deletes a configured swap route. |
| `routeHops()` | Returns all configured hops for one input/output pair. |
| `protection()` | Returns configured TWAP window and protected slippage parameters. |
| `protectedQuote()` | Quotes net output and the protected minimum for a specified swap. |
| `twapMinimumOut()` | Computes the oracle-protected minimum net output for a route. |
| `swapExactInput()` | Executes a configured fixed-input swap subject to route and minimum-output protections. |
| `uniswapV3SwapCallback()` | Pays tokens owed to the currently executing validated Sushi V3 pool. |
| `SUSHI()` *(getter)* | Returns the current on-chain value of `SUSHI` (including any configured indexed arguments). |
| `BALANCER()` *(getter)* | Returns the current on-chain value of `BALANCER` (including any configured indexed arguments). |
| `FEE_BPS()` *(getter)* | Returns the current on-chain value of `FEE_BPS` (including any configured indexed arguments). |
| `SUSHI_FACTORY()` *(getter)* | Returns the current on-chain value of `SUSHI_FACTORY` (including any configured indexed arguments). |
| `SUSHI_POOL_INIT_CODE_HASH()` *(getter)* | Returns the current on-chain value of `SUSHI_POOL_INIT_CODE_HASH` (including any configured indexed arguments). |
| `balancerVault()` *(getter)* | Returns the current on-chain value of `balancerVault` (including any configured indexed arguments). |
| `balancerRouter()` *(getter)* | Returns the current on-chain value of `balancerRouter` (including any configured indexed arguments). |
| `feeRecipient()` *(getter)* | Returns the current on-chain value of `feeRecipient` (including any configured indexed arguments). |
| `owner()` *(inherited/delegated)* | Returns the contract’s current owner. |
| `pendingOwner()` *(inherited/delegated)* | Returns the nominated successor owner. |
| `transferOwnership()` *(inherited/delegated)* | Starts an Ownable2Step transfer by nominating a new owner. |
| `acceptOwnership()` *(inherited/delegated)* | Accepts a pending two-step ownership transfer. |
| `renounceOwnership()` *(inherited/delegated)* | Relinquishes contract ownership if allowed. |
| `configGate()` *(inherited/delegated)* | Returns the governance configuration gate address. |
| `setConfigGate()` *(inherited/delegated)* | Updates this contract’s gate pointer under its authorization policy. |

### CurveYieldBundleGuardFuse
**Status:** V2 deployment.
**Role:** Checks fee-neutral vault PPS, idle-asset floors, bounded loss and Morpho leverage around action bundles.
**Source:** `upgrade/src/generic/CurveYieldBundleGuardFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `enter()` | Saves a transaction-scoped asset and supply snapshot before an action bundle. |
| `exit()` | Rejects a bundle if its management-fee-neutral PPS, asset limits or leverage checks fail. |
| `enterTransient()` | Reads a market list from transaction-scoped inputs and records a PPS snapshot. |
| `exitTransient()` | Reads transaction-scoped guard limits and validates the matching action bundle. |
| `ROUNDING_DUST()` *(getter)* | Returns the current on-chain value of `ROUNDING_DUST` (including any configured indexed arguments). |
| `ABSOLUTE_MAX_PPS_DROP_BPS()` *(getter)* | Returns the current on-chain value of `ABSOLUTE_MAX_PPS_DROP_BPS` (including any configured indexed arguments). |
| `ABSOLUTE_MAX_LTV_BPS()` *(getter)* | Returns the current on-chain value of `ABSOLUTE_MAX_LTV_BPS` (including any configured indexed arguments). |
| `VERSION()` *(getter)* | Returns the current on-chain value of `VERSION` (including any configured indexed arguments). |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |
| `MORPHO()` *(getter)* | Returns the current on-chain value of `MORPHO` (including any configured indexed arguments). |

### CurveYieldErc20TransferFuse
**Status:** V2 deployment.
**Role:** Transfers allowlisted vault-held ERC-20 assets under market substrate and size limits.
**Source:** `upgrade/src/generic/CurveYieldErc20TransferFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `enter()` | Transfers an allowed token to an allowed recipient within hard and substrate caps. |
| `enterTransient()` | Performs the same bounded transfer using transaction-scoped input values. |
| `exitTransient()` | Always reverts because a transfer cannot be reversed by a fuse exit call. |
| `exit()` | Always reverts because the transfer fuse only supports entry actions. |
| `ABSOLUTE_MAX_PER_CALL()` *(getter)* | Returns the current on-chain value of `ABSOLUTE_MAX_PER_CALL` (including any configured indexed arguments). |
| `VERSION()` *(getter)* | Returns the current on-chain value of `VERSION` (including any configured indexed arguments). |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |

### CurveYieldBurnHeldSharesFuse
**Status:** V2 deployment.
**Role:** Burns cyavKAT shares held by the vault itself under the authorized fuse execution context.
**Source:** `upgrade/src/generic/CurveYieldBurnHeldSharesFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `enter()` | Burns the vault's own share tokens up to the authorized cap. |
| `enterTransient()` | Burns the vault's own shares using a transiently supplied limit. |
| `exitTransient()` | Rejects unsupported exit calls. |
| `exit()` | Rejects unsupported exit calls. |
| `VERSION()` *(getter)* | Returns the current on-chain value of `VERSION` (including any configured indexed arguments). |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |

### CurveYieldRequestFeeSharesFuse
**Status:** V2 deployment.
**Role:** Moves withdrawal-request fee shares inside the vault and configures manager allowances.
**Source:** `upgrade/src/withdraw/CurveYieldRequestFeeSharesFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `enter()` | Executes its configured request-fee share movement. |
| `moveRequestFeeShares()` | Moves escrowed withdrawal fee shares between a requester and the withdrawal manager. |
| `exit()` | Rejects unsupported reverse operations. |
| `configureManagerAssetAllowance()` | Replaces the manager's underlying asset allowance and clears the prior allowance. |
| `enterTransient()` | Reads request-fee inputs from transient storage to perform the authorized movement. |
| `exitTransient()` | Rejects unsupported transient exits. |
| `VERSION()` *(getter)* | Returns the current on-chain value of `VERSION` (including any configured indexed arguments). |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |

### CurveYieldPolController
**Status:** V2 POL deployment.
**Role:** Plans POL position management, share buybacks, withdrawal funding, and admin yield-fee transfers.
**Source:** `upgrade/src/pol/CurveYieldPolController.sol`.

| Callable function | One-sentence summary |
|---|---|
| `setVenues()` | Configures Balancer and related POL venues. |
| `setFuses()` | Wires the approved liquidity, swap, guard, burn and transfer fuses. |
| `setExecutor()` | Assigns the keeper executor allowed to settle POL operations. |
| `setAdminReceiver()` | Sets the admin account receiving realized POL yield fees. |
| `setMarketRoutes()` | Configures the protected swap route options for POL trades. |
| `params()` | Returns governed POL risk, timing and allocation settings. |
| `yieldFeeBps()` | Returns the admin yield fee percentage. |
| `buybackBudgetLeftBpt()` | Calculates remaining Balancer pool shares available for buybacks. |
| `syncBpt()` | Accounts for changes to POL BPT holdings after an action. |
| `recordBuyback()` | Records buyback execution time for cooldown enforcement. |
| `position()` | Reports BPT holdings and underlying assets of the POL position. |
| `depositRate()` | Returns the vault-share conversion rate used by POL. |
| `marketRate()` | Returns the current market conversion rate for vault shares. |
| `buybackTriggered()` | Indicates whether buyback conditions and cooldown permit execution. |
| `netValue()` | Computes the realizable avKAT value of a specified share amount. |
| `managedAvkat()` | Returns the POL position's managed value denominated in avKAT. |
| `allocationBps()` | Returns the POL target allocation. |
| `bptFor()` | Estimates BPT needed to realize a target avKAT amount. |
| `planDeploy()` | Builds an authorized POL liquidity deployment bundle. |
| `planReduce()` | Builds a POL reduction bundle respecting the minimum share sale price. |
| `planReduceFallback()` | Builds a reduction route that burns rather than sells shares when necessary. |
| `planWithdraw()` | Returns the strategy's standard withdrawal actions, which are intentionally separate from POL request funding. |
| `planPolStep()` | Builds a fee-aware POL-funded withdrawal settlement step. |
| `settlePolStep()` | Reconciles POL withdrawal proceeds and determines any requester-borne shortfall. |
| `planBuyback()` | Builds a cooldown- and budget-limited vault-share buyback bundle. |
| `planBurnHeld()` | Builds an action to burn vault-owned cyavKAT shares. |
| `withdrawYieldFee()` | Computes admin yield fees only on eligible realized withdrawal profit. |
| `yieldFeeAction()` | Builds the approved transfer action to pay the admin yield fee. |
| `VAULT()` *(getter)* | Returns the current on-chain value of `VAULT` (including any configured indexed arguments). |
| `AVKAT()` *(getter)* | Returns the current on-chain value of `AVKAT` (including any configured indexed arguments). |
| `FEE_MANAGER()` *(getter)* | Returns the current on-chain value of `FEE_MANAGER` (including any configured indexed arguments). |
| `venues()` *(getter)* | Returns the current on-chain value of `venues` (including any configured indexed arguments). |
| `fuses()` *(getter)* | Returns the current on-chain value of `fuses` (including any configured indexed arguments). |
| `adminReceiver()` *(getter)* | Returns the current on-chain value of `adminReceiver` (including any configured indexed arguments). |
| `netContributedBpt()` *(getter)* | Returns the current on-chain value of `netContributedBpt` (including any configured indexed arguments). |
| `convertedBpt()` *(getter)* | Returns the current on-chain value of `convertedBpt` (including any configured indexed arguments). |
| `lastBpt()` *(getter)* | Returns the current on-chain value of `lastBpt` (including any configured indexed arguments). |
| `executor()` *(getter)* | Returns the current on-chain value of `executor` (including any configured indexed arguments). |
| `lastBuybackAt()` *(getter)* | Returns the current on-chain value of `lastBuybackAt` (including any configured indexed arguments). |
| `owner()` *(inherited/delegated)* | Returns the contract’s current owner. |
| `pendingOwner()` *(inherited/delegated)* | Returns the nominated successor owner. |
| `transferOwnership()` *(inherited/delegated)* | Starts an Ownable2Step transfer by nominating a new owner. |
| `acceptOwnership()` *(inherited/delegated)* | Accepts a pending two-step ownership transfer. |
| `renounceOwnership()` *(inherited/delegated)* | Relinquishes contract ownership if allowed. |
| `configGate()` *(inherited/delegated)* | Returns the governance configuration gate address. |
| `setConfigGate()` *(inherited/delegated)* | Updates this contract’s gate pointer under its authorization policy. |

### CurveYieldRateAwareBalancerBalanceFuse
**Status:** V2 POL deployment.
**Role:** Values the vault’s rate-adjusted Balancer LP and gauge exposure.
**Source:** `upgrade/src/generic/CurveYieldRateAwareBalancerBalanceFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `balanceOf()` | Returns the vault's USD-denominated proportional Balancer pool and gauge position value at the current token/share rate. |
| `VERSION()` *(getter)* | Returns the current on-chain value of `VERSION` (including any configured indexed arguments). |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |

### CurveYieldRevenueCustodyV2
**Status:** V2 POL/custody deployment.
**Role:** Receives wrapper fee shares, redeems to avKAT, delegates to existing Morpho custody, and manages farms, BPS POL reserves and emergency cover.
**Source:** `upgrade/src/protection/CurveYieldRevenueCustodyV2.sol`.

| Callable function | One-sentence summary |
|---|---|
| `ROUTER()` | Resolves the approved swap router from gate wiring. |
| `REWARDS_CLAIM_MANAGER()` | Resolves the rewards manager from gate wiring. |
| `revenueShareBps()` | Returns the custody portion of distributable withdrawal revenue. |
| `loopTargetBps()` | Returns the target fraction allocated to the pre-existing loop custody. |
| `windupDistributionBps()` | Returns the distribution percentages for loop profits. |
| `setOperator()` | Authorizes or disables a custody operator. |
| `setCoverer()` | Authorizes or disables an executor that can request loss coverage. |
| `setFeeRecipient()` | Changes the custody's fee revenue recipient. |
| `setCharmVaultAllowed()` | Adds or removes a permitted Charm farming vault subject to balance checks. |
| `setPolVenues()` | Sets the approved Alpha and Balancer POL venues. |
| `tokens()` | Lists the custody's tracked asset tokens. |
| `charmVaults()` | Lists allowed Charm farm contracts. |
| `idleAvkat()` | Returns avKAT not reserved for the POL position's budget. |
| `loopEquityAvkat()` | Values the existing Morpho loop custody in avKAT. |
| `farmValueAvkat()` | Values idle farm tokens and Charm shares in avKAT. |
| `polDepositRate()` | Returns avKAT equivalent of one cyavKAT share. |
| `polPosition()` | Reports the custody's cyavKAT, WETH and Alpha vault shares. |
| `redeemWrapperRevenue()` | Exposes the contract’s `redeemWrapperRevenue` operation using its role restrictions and current configuration. |
| `reserveAvkatForPolBps()` | Exposes the contract’s `reserveAvkatForPolBps` operation using its role restrictions and current configuration. |
| `deployAll()` | Allocates unreserved avKAT between the existing loop custody and permitted Charm farms. |
| `cover()` | Contributes available idle/farm avKAT toward a verified vault loss. |
| `scheduleFullUnwind()` | Starts the delayed process to transfer all custody positions to a successor. |
| `cancelFullUnwind()` | Cancels a pending full-unwind schedule. |
| `executeFullUnwind()` | Transfers the custody's positions to the scheduled successor after the delay. |
| `swap()` | Swaps allowed farm tokens through the protected V2 router. |
| `charmDeposit()` | Deposits token balances into a permitted Charm vault. |
| `charmWithdraw()` | Redeems Charm vault shares into their underlying tokens. |
| `harvestMerkl()` | Claims eligible Merkl rewards, swaps proceeds and applies the governed revenue split. |
| `polDeploy()` | Converts POL budget into the configured cyavKAT/WETH Alpha position. |
| `polExitToAvkat()` | Exits position B and converts its proceeds to avKAT. |
| `sellCyavkatSelf()` | Executes the isolated cyavKAT sale leg with minimum-output checks. |
| `swapToAvkatSelf()` | Tries an isolated token-to-avKAT conversion without breaking other operations. |
| `charmExitSelf()` | Performs an isolated Charm share withdrawal for loss coverage. |
| `AVKAT()` *(getter)* | Returns the current on-chain value of `AVKAT` (including any configured indexed arguments). |
| `KAT()` *(getter)* | Returns the current on-chain value of `KAT` (including any configured indexed arguments). |
| `FULL_UNWIND_DELAY()` *(getter)* | Returns the current on-chain value of `FULL_UNWIND_DELAY` (including any configured indexed arguments). |
| `VAULT()` *(getter)* | Returns the current on-chain value of `VAULT` (including any configured indexed arguments). |
| `WETH()` *(getter)* | Returns the current on-chain value of `WETH` (including any configured indexed arguments). |
| `MERKL()` *(getter)* | Returns the current on-chain value of `MERKL` (including any configured indexed arguments). |
| `LOOP_CUSTODY()` *(getter)* | Returns the current on-chain value of `LOOP_CUSTODY` (including any configured indexed arguments). |
| `isOperator()` *(getter)* | Returns the current on-chain value of `isOperator` (including any configured indexed arguments). |
| `isCoverer()` *(getter)* | Returns the current on-chain value of `isCoverer` (including any configured indexed arguments). |
| `feeRecipient()` *(getter)* | Returns the current on-chain value of `feeRecipient` (including any configured indexed arguments). |
| `queuedRecipient()` *(getter)* | Returns the current on-chain value of `queuedRecipient` (including any configured indexed arguments). |
| `queuedExecuteAfter()` *(getter)* | Returns the current on-chain value of `queuedExecuteAfter` (including any configured indexed arguments). |
| `isCharmVaultAllowed()` *(getter)* | Returns the current on-chain value of `isCharmVaultAllowed` (including any configured indexed arguments). |
| `tokenRefs()` *(getter)* | Returns the current on-chain value of `tokenRefs` (including any configured indexed arguments). |
| `polVenues()` *(getter)* | Returns the current on-chain value of `polVenues` (including any configured indexed arguments). |
| `polBudgetAvkat()` *(getter)* | Returns the current on-chain value of `polBudgetAvkat` (including any configured indexed arguments). |
| `owner()` *(inherited/delegated)* | Returns the contract’s current owner. |
| `pendingOwner()` *(inherited/delegated)* | Returns the nominated successor owner. |
| `transferOwnership()` *(inherited/delegated)* | Starts an Ownable2Step transfer by nominating a new owner. |
| `acceptOwnership()` *(inherited/delegated)* | Accepts a pending two-step ownership transfer. |
| `renounceOwnership()` *(inherited/delegated)* | Relinquishes contract ownership if allowed. |
| `configGate()` *(inherited/delegated)* | Returns the governance configuration gate address. |
| `setConfigGate()` *(inherited/delegated)* | Updates this contract’s gate pointer under its authorization policy. |

### CurveYieldVaultBase1271
**Status:** Existing; retained.
**Role:** Preserves the original IPOR base through delegation while exposing ERC-1271 Quest login signature verification.
**Source:** `upgrade/src/katana/CurveYieldVaultBase1271.sol`.

| Callable function | One-sentence summary |
|---|---|
| `isValidSignature()` | Returns ERC-1271 approval for an authorized signer and a domain-bound Quest login message. |
| `isQuestSigner()` | Reports whether a signing account is approved. |
| `questSignPrefix()` | Returns the enforced signed-message prefix. |
| `fallback()` | Delegates every other vault selector to the original factory PlasmaVaultBase. |
| `ORIGINAL_BASE()` *(getter)* | Returns the current on-chain value of `ORIGINAL_BASE` (including any configured indexed arguments). |

### CurveYieldWrappedCyavKat
**Status:** Existing; retained.
**Role:** ERC-4626 wrapped cyavKAT collateral token with independently accrued wrapper-level fees.
**Source:** `upgrade/src/wrapper/CurveYieldWrappedCyavKat.sol`.

| Callable function | One-sentence summary |
|---|---|
| `pendingFees()` | Reports accrued management/performance fees not yet realized in the wrapper. |
| `accrue()` | Realizes outstanding wrapper fees into its share accounting. |
| `setFees()` | Updates the wrapper management and performance fee rates under owner authority. |
| `totalAssets()` | Returns the wrapper's net managed cyavKAT assets. |
| `deposit()` | Accepts cyavKAT and mints wrapped collateral shares after accrual. |
| `mint()` | Mints a requested number of wrapped shares for the required cyavKAT amount. |
| `withdraw()` | Burns wrapped shares to withdraw a requested cyavKAT asset amount. |
| `redeem()` | Redeems a requested number of wrapped shares for cyavKAT. |
| `BPS()` *(getter)* | Returns the current on-chain value of `BPS` (including any configured indexed arguments). |
| `MAX_MANAGEMENT_FEE_BPS()` *(getter)* | Returns the current on-chain value of `MAX_MANAGEMENT_FEE_BPS` (including any configured indexed arguments). |
| `MAX_PERFORMANCE_FEE_BPS()` *(getter)* | Returns the current on-chain value of `MAX_PERFORMANCE_FEE_BPS` (including any configured indexed arguments). |
| `YEAR()` *(getter)* | Returns the current on-chain value of `YEAR` (including any configured indexed arguments). |
| `managementFeeBps()` *(getter)* | Returns the current on-chain value of `managementFeeBps` (including any configured indexed arguments). |
| `performanceFeeBps()` *(getter)* | Returns the current on-chain value of `performanceFeeBps` (including any configured indexed arguments). |
| `FEE_SPLITTER()` *(getter)* | Returns the current on-chain value of `FEE_SPLITTER` (including any configured indexed arguments). |
| `ONE_SHARE()` *(getter)* | Returns the current on-chain value of `ONE_SHARE` (including any configured indexed arguments). |
| `highWatermark()` *(getter)* | Returns the current on-chain value of `highWatermark` (including any configured indexed arguments). |
| `lastAccrual()` *(getter)* | Returns the current on-chain value of `lastAccrual` (including any configured indexed arguments). |
| `owner()` *(inherited/delegated)* | Returns the contract’s current owner. |
| `pendingOwner()` *(inherited/delegated)* | Returns the nominated successor owner. |
| `transferOwnership()` *(inherited/delegated)* | Starts an Ownable2Step transfer by nominating a new owner. |
| `acceptOwnership()` *(inherited/delegated)* | Accepts a pending two-step ownership transfer. |
| `renounceOwnership()` *(inherited/delegated)* | Relinquishes contract ownership if allowed. |
| `name()` *(inherited/delegated)* | Returns the token name. |
| `symbol()` *(inherited/delegated)* | Returns the token symbol. |
| `decimals()` *(inherited/delegated)* | Returns the token decimal precision. |
| `totalSupply()` *(inherited/delegated)* | Returns total token shares outstanding. |
| `balanceOf()` *(inherited/delegated)* | Returns the token shares owned by an account. |
| `transfer()` *(inherited/delegated)* | Transfers token shares to a recipient. |
| `allowance()` *(inherited/delegated)* | Returns shares a spender is authorized to transfer. |
| `approve()` *(inherited/delegated)* | Authorizes a spender to transfer shares. |
| `transferFrom()` *(inherited/delegated)* | Transfers token shares using the caller’s allowance. |
| `asset()` *(inherited/delegated)* | Returns the underlying ERC-4626 asset token. |
| `convertToShares()` *(inherited/delegated)* | Converts an asset quantity to an estimated share quantity. |
| `convertToAssets()` *(inherited/delegated)* | Converts a share quantity to estimated underlying assets. |
| `maxDeposit()` *(inherited/delegated)* | Returns the current maximum deposit for an account. |
| `maxMint()` *(inherited/delegated)* | Returns the maximum share mint for an account. |
| `maxWithdraw()` *(inherited/delegated)* | Returns the maximum current asset withdrawal for an account. |
| `maxRedeem()` *(inherited/delegated)* | Returns the maximum shares currently redeemable by an account. |
| `previewDeposit()` *(inherited/delegated)* | Quotes shares from a deposit without executing it. |
| `previewMint()` *(inherited/delegated)* | Quotes assets needed to mint requested shares. |
| `previewWithdraw()` *(inherited/delegated)* | Quotes shares needed to withdraw a specified asset amount. |
| `previewRedeem()` *(inherited/delegated)* | Quotes assets received from redeeming shares. |

### CurveYieldWrapperFeeSplitter
**Status:** Existing; retained.
**Role:** Distributes wrapper fees at immutable 40/30/30 proportions to the admin, V2 Revenue Custody and WM V2 after L10 routing.
**Source:** `upgrade/src/wrapper/CurveYieldWrapperFeeSplitter.sol`.

| Callable function | One-sentence summary |
|---|---|
| `setAdminReceiver()` | Sets the admin recipient for its share of wrapper fees. |
| `setDestinations()` | Changes the contributors and withdrawal-fee recipient addresses. |
| `distribute()` | Splits the contract's accrued cyavKAT shares among configured recipients. |
| `BPS()` *(getter)* | Returns the current on-chain value of `BPS` (including any configured indexed arguments). |
| `ADMIN_BPS()` *(getter)* | Returns the current on-chain value of `ADMIN_BPS` (including any configured indexed arguments). |
| `CONTRIBUTORS_BPS()` *(getter)* | Returns the current on-chain value of `CONTRIBUTORS_BPS` (including any configured indexed arguments). |
| `CYAVKAT()` *(getter)* | Returns the current on-chain value of `CYAVKAT` (including any configured indexed arguments). |
| `adminReceiver()` *(getter)* | Returns the current on-chain value of `adminReceiver` (including any configured indexed arguments). |
| `contributorsReceiver()` *(getter)* | Returns the current on-chain value of `contributorsReceiver` (including any configured indexed arguments). |
| `burnWithdrawManager()` *(getter)* | Returns the current on-chain value of `burnWithdrawManager` (including any configured indexed arguments). |
| `owner()` *(inherited/delegated)* | Returns the contract’s current owner. |
| `pendingOwner()` *(inherited/delegated)* | Returns the nominated successor owner. |
| `transferOwnership()` *(inherited/delegated)* | Starts an Ownable2Step transfer by nominating a new owner. |
| `acceptOwnership()` *(inherited/delegated)* | Accepts a pending two-step ownership transfer. |
| `renounceOwnership()` *(inherited/delegated)* | Relinquishes contract ownership if allowed. |

### IporVaultHaircutOracle12
**Status:** Existing; retained.
**Role:** Reports lending collateral pricing for wrapped cyavKAT using a fixed 12-percent haircut.
**Source:** `upgrade/src/oracles/IporVaultHaircutOracle12.sol`.

| Callable function | One-sentence summary |
|---|---|
| `price()` | Returns a wrapped-cyavKAT collateral price including the fixed 12-percent haircut. |
| `ORACLE_PRICE_SCALE()` *(getter)* | Returns the current on-chain value of `ORACLE_PRICE_SCALE` (including any configured indexed arguments). |
| `HAIRCUT_BPS()` *(getter)* | Returns the current on-chain value of `HAIRCUT_BPS` (including any configured indexed arguments). |
| `BPS()` *(getter)* | Returns the current on-chain value of `BPS` (including any configured indexed arguments). |
| `WRAPPER()` *(getter)* | Returns the current on-chain value of `WRAPPER` (including any configured indexed arguments). |
| `VAULT()` *(getter)* | Returns the current on-chain value of `VAULT` (including any configured indexed arguments). |
| `LOAN_TOKEN()` *(getter)* | Returns the current on-chain value of `LOAN_TOKEN` (including any configured indexed arguments). |
| `ONE_WRAPPER()` *(getter)* | Returns the current on-chain value of `ONE_WRAPPER` (including any configured indexed arguments). |

### CurveYieldProfitCustody
**Status:** Existing; retained.
**Role:** Holds and runs the existing Morpho loop custody, later coordinated by revenue custody V2.
**Source:** `deployed/phase1-controller/CurveYieldProfitCustody.sol`.

| Callable function | One-sentence summary |
|---|---|
| `setGuardian()` | Enables or disables an approved custody operator. |
| `setRevenueShareBps()` | Changes the share of loop profits allocated to protocol revenue. |
| `setWindupDistributionBps()` | Configures loop windup reward and fee distributions. |
| `setFeeRecipient()` | Changes the recipient for the custody's fee distributions. |
| `deployAll()` | Deploys available custody avKAT into the established leveraged Morpho loop. |
| `balanceLtv()` | Rebalances Morpho collateral and debt toward the configured LTV. |
| `scheduleFullUnwind()` | Begins the delayed exit to a successor recipient. |
| `cancelFullUnwind()` | Cancels the scheduled exit. |
| `executeFullUnwind()` | Exits the custody's loop and transfers remaining assets to the successor. |
| `positionSnapshot()` | Returns collateral, debt, equity and current LTV. |
| `onMorphoFlashLoan()` | Handles the approved Morpho flash-loan callback and repayment. |
| `MORPHO()` *(getter)* | Returns the current on-chain value of `MORPHO` (including any configured indexed arguments). |
| `AVKAT()` *(getter)* | Returns the current on-chain value of `AVKAT` (including any configured indexed arguments). |
| `KAT()` *(getter)* | Returns the current on-chain value of `KAT` (including any configured indexed arguments). |
| `MORPHO_MARKET_ID()` *(getter)* | Returns the current on-chain value of `MORPHO_MARKET_ID` (including any configured indexed arguments). |
| `TARGET_LTV_BPS()` *(getter)* | Returns the current on-chain value of `TARGET_LTV_BPS` (including any configured indexed arguments). |
| `MAX_REVENUE_SHARE_BPS()` *(getter)* | Returns the current on-chain value of `MAX_REVENUE_SHARE_BPS` (including any configured indexed arguments). |
| `MIN_REWARD_MANAGER_BPS()` *(getter)* | Returns the current on-chain value of `MIN_REWARD_MANAGER_BPS` (including any configured indexed arguments). |
| `MAX_REWARD_MANAGER_BPS()` *(getter)* | Returns the current on-chain value of `MAX_REWARD_MANAGER_BPS` (including any configured indexed arguments). |
| `MIN_FEE_RECIPIENT_BPS()` *(getter)* | Returns the current on-chain value of `MIN_FEE_RECIPIENT_BPS` (including any configured indexed arguments). |
| `MAX_FEE_RECIPIENT_BPS()` *(getter)* | Returns the current on-chain value of `MAX_FEE_RECIPIENT_BPS` (including any configured indexed arguments). |
| `FULL_UNWIND_DELAY()` *(getter)* | Returns the current on-chain value of `FULL_UNWIND_DELAY` (including any configured indexed arguments). |
| `revenueShareBps()` *(getter)* | Returns the current on-chain value of `revenueShareBps` (including any configured indexed arguments). |
| `rewardManagerDistributionBps()` *(getter)* | Returns the current on-chain value of `rewardManagerDistributionBps` (including any configured indexed arguments). |
| `feeRecipientDistributionBps()` *(getter)* | Returns the current on-chain value of `feeRecipientDistributionBps` (including any configured indexed arguments). |
| `ROUTER()` *(getter)* | Returns the current on-chain value of `ROUTER` (including any configured indexed arguments). |
| `REWARDS_CLAIM_MANAGER()` *(getter)* | Returns the current on-chain value of `REWARDS_CLAIM_MANAGER` (including any configured indexed arguments). |
| `feeRecipient()` *(getter)* | Returns the current on-chain value of `feeRecipient` (including any configured indexed arguments). |
| `queuedRecipient()` *(getter)* | Returns the current on-chain value of `queuedRecipient` (including any configured indexed arguments). |
| `queuedExecuteAfter()` *(getter)* | Returns the current on-chain value of `queuedExecuteAfter` (including any configured indexed arguments). |
| `isGuardian()` *(getter)* | Returns the current on-chain value of `isGuardian` (including any configured indexed arguments). |
| `owner()` *(inherited/delegated)* | Returns the contract’s current owner. |
| `pendingOwner()` *(inherited/delegated)* | Returns the nominated successor owner. |
| `transferOwnership()` *(inherited/delegated)* | Starts an Ownable2Step transfer by nominating a new owner. |
| `acceptOwnership()` *(inherited/delegated)* | Accepts a pending two-step ownership transfer. |
| `renounceOwnership()` *(inherited/delegated)* | Relinquishes contract ownership if allowed. |

### CurveYieldSushiV3FeeRouter
**Status:** Existing; retained.
**Role:** Retained Sushi V3 fee-taking router used by existing reward swaps and the legacy custody layer.
**Source:** `deployed/phase1-router/CurveYieldSushiV3FeeRouter.sol`.

| Callable function | One-sentence summary |
|---|---|
| `transferOwnership()` | Nominates a successor owner of the retained Sushi V3 router. |
| `setFeeRecipient()` | Changes the recipient of fees collected by this legacy-compatible router. |
| `setFeeBps()` | Changes the configured swap fee basis points. |
| `setRoute()` | Adds or updates an approved Sushi route. |
| `removeRoute()` | Removes a route. |
| `routeFor()` | Returns the selected Sushi pool route for a token pair. |
| `setRouteFeeBps()` | Sets a token-pair-specific swap fee. |
| `clearRouteFee()` | Clears a route-specific fee override. |
| `setRouteTwapGuard()` | Changes the route-specific TWAP slippage protection settings. |
| `routeTwapGuard()` | Returns route-specific TWAP minimum-output configuration. |
| `twapMinimumOut()` | Calculates the protected minimum output of a swap. |
| `swapExactInput()` | Executes a guarded Sushi swap and sends proceeds after its fee. |
| `uniswapV3SwapCallback()` | Pays the authenticated Sushi pool during a swap. |
| `DEFAULT_TWAP_WINDOW()` *(getter)* | Returns the current on-chain value of `DEFAULT_TWAP_WINDOW` (including any configured indexed arguments). |
| `DEFAULT_TWAP_DEVIATION_BPS()` *(getter)* | Returns the current on-chain value of `DEFAULT_TWAP_DEVIATION_BPS` (including any configured indexed arguments). |
| `owner()` *(getter)* | Returns the current on-chain value of `owner` (including any configured indexed arguments). |

## IPOR factory and approved IPOR fuses

### PlasmaVault
**Status:** Existing IPOR; retained.
**Role:** The original factory ERC-4626 cyavKAT share vault and protocol action dispatcher.
**Source:** `ipor-fusion/contracts/vaults/PlasmaVault.sol`.

| Callable function | One-sentence summary |
|---|---|
| `fallback()` | Dispatches protocol callbacks, vote extensions or delegated base functionality. |
| `PLASMA_VAULT_BASE()` | Returns the currently installed delegatecall base address. |
| `PLASMA_VAULT_VOTES_PLUGIN()` | Returns the optional delegated vault votes extension address. |
| `proxyInitialize()` | Initializes the factory vault's assets, fee rules, plugins and access settings. |
| `onERC721Received()` | Accepts authorized ERC-721 positions transferred into the vault. |
| `execute()` | Runs a vault-local authorized array of fuse actions atomically. |
| `updateMarketsBalances()` | Revalues selected market positions using registered balance fuses. |
| `decimals()` | Returns decimal precision for cyavKAT shares. |
| `transfer()` | Moves vault shares while applying the configured transfer checks. |
| `transferFrom()` | Moves authorized shares on behalf of an owner. |
| `deposit()` | Takes underlying avKAT and mints corresponding cyavKAT shares. |
| `depositWithPermit()` | Deposits underlying assets using a supported permit authorization. |
| `mint()` | Mints a requested quantity of cyavKAT shares for underlying assets. |
| `withdraw()` | Withdraws underlying assets in exchange for cyavKAT shares, subject to manager rules. |
| `previewDeposit()` | Estimates cyavKAT shares from a specified avKAT deposit. |
| `previewMint()` | Estimates the avKAT required to mint a specified number of shares. |
| `previewRedeem()` | Estimates avKAT returned for a specified share redemption. |
| `previewWithdraw()` | Estimates shares consumed by a specified avKAT withdrawal. |
| `redeem()` | Burns cyavKAT shares to receive underlying avKAT under withdrawal rules. |
| `redeemFromRequest()` | Redeems shares that have been released from a queued withdrawal request. |
| `maxDeposit()` | Returns the maximum assets that may be deposited into the vault. |
| `maxMint()` | Returns the maximum shares that may be minted. |
| `maxWithdraw()` | Returns the maximum assets withdrawable by an account now. |
| `claimRewards()` | Executes the configured reward-claiming operations under vault authorization. |
| `totalAssets()` | Returns the current accounted vault assets across active markets. |
| `totalAssetsInMarket()` | Reports the accounted asset value assigned to one market. |
| `getUnrealizedManagementFee()` | Reports the management fee accrued but not yet realized as shares. |
| `updateInternal()` | Provides a controlled delegated hook to update share balances. |
| `executeInternal()` | Runs a privileged internal fuse action bundle from the approved execution context. |
| `DEFAULT_SLIPPAGE_IN_PERCENTAGE()` *(getter)* | Returns the current on-chain value of `DEFAULT_SLIPPAGE_IN_PERCENTAGE` (including any configured indexed arguments). |
| `isMarketSubstrateGranted()` *(inherited/delegated)* | Reports whether a market substrate is authorized. |
| `isFuseSupported()` *(inherited/delegated)* | Checks whether a fuse is on the vault allowlist. |
| `isBalanceFuseSupported()` *(inherited/delegated)* | Checks whether a balance fuse is approved for a market. |
| `isMarketsLimitsActivated()` *(inherited/delegated)* | Reports whether market exposure limits are active. |
| `getMarketSubstrates()` *(inherited/delegated)* | Returns approved substrates for a market. |
| `getFuses()` *(inherited/delegated)* | Lists the currently approved executable fuses. |
| `getPriceOracleMiddleware()` *(inherited/delegated)* | Returns the oracle middleware address. |
| `getPerformanceFeeData()` *(inherited/delegated)* | Returns vault performance-fee configuration. |
| `getManagementFeeData()` *(inherited/delegated)* | Returns vault management-fee configuration. |
| `getAccessManagerAddress()` *(inherited/delegated)* | Returns the original IPOR Access Manager address. |
| `getRewardsClaimManagerAddress()` *(inherited/delegated)* | Returns the reward manager address. |
| `getInstantWithdrawalFuses()` *(inherited/delegated)* | Lists the instant-withdrawal fuse sequence. |
| `getInstantWithdrawalFusesParams()` *(inherited/delegated)* | Returns input parameters for instant withdrawal fuses. |
| `getMarketLimit()` *(inherited/delegated)* | Returns configured market exposure limits. |
| `getDependencyBalanceGraph()` *(inherited/delegated)* | Returns the market valuation dependency graph. |
| `getTotalSupplyCap()` *(inherited/delegated)* | Returns the share supply cap. |
| `getActiveMarketsInBalanceFuses()` *(inherited/delegated)* | Lists markets registered with active balance fuses. |
| `addBalanceFuse()` *(inherited/delegated)* | Authorizes a market-specific balance fuse. |
| `removeBalanceFuse()` *(inherited/delegated)* | Removes a market-specific balance fuse. |
| `grantMarketSubstrates()` *(inherited/delegated)* | Replaces a market’s authorized substrates. |
| `updateDependencyBalanceGraphs()` *(inherited/delegated)* | Updates dependent-market valuation ordering. |
| `configureInstantWithdrawalFuses()` *(inherited/delegated)* | Sets the approved instant-withdrawal fuse sequence. |
| `addFuses()` *(inherited/delegated)* | Adds authorized execution fuses. |
| `removeFuses()` *(inherited/delegated)* | Unregisters execution fuses. |
| `setPriceOracleMiddleware()` *(inherited/delegated)* | Changes the configured oracle middleware. |
| `configurePerformanceFee()` *(inherited/delegated)* | Updates vault performance-fee settings via the authorized path. |
| `configureManagementFee()` *(inherited/delegated)* | Updates vault management-fee settings via the authorized path. |
| `setRewardsClaimManagerAddress()` *(inherited/delegated)* | Changes the rewards manager address. |
| `setupMarketsLimits()` *(inherited/delegated)* | Sets per-market exposure caps. |
| `activateMarketsLimits()` *(inherited/delegated)* | Enables configured market exposure caps. |
| `deactivateMarketsLimits()` *(inherited/delegated)* | Disables market exposure caps. |
| `updateCallbackHandler()` *(inherited/delegated)* | Sets a protocol callback selector’s handler. |
| `setTotalSupplyCap()` *(inherited/delegated)* | Updates vault share supply cap. |
| `convertToPublicVault()` *(inherited/delegated)* | Activates publicly permitted vault access when allowed. |
| `enableTransferShares()` *(inherited/delegated)* | Enables share transfers within the configured permissions. |
| `setMinimalExecutionDelaysForRoles()` *(inherited/delegated)* | Sets minimum delays for specified vault roles. |
| `setPreHookImplementations()` *(inherited/delegated)* | Configures per-selector pre-execution hooks. |
| `getPreHookSelectors()` *(inherited/delegated)* | Lists selectors with a configured pre-hook. |
| `getPreHookImplementation()` *(inherited/delegated)* | Returns a configured selector’s pre-hook address. |
| `name()` *(inherited/delegated)* | Returns the token name. |
| `symbol()` *(inherited/delegated)* | Returns the token symbol. |
| `totalSupply()` *(inherited/delegated)* | Returns total token shares outstanding. |
| `balanceOf()` *(inherited/delegated)* | Returns the token shares owned by an account. |
| `allowance()` *(inherited/delegated)* | Returns shares a spender is authorized to transfer. |
| `approve()` *(inherited/delegated)* | Authorizes a spender to transfer shares. |
| `asset()` *(inherited/delegated)* | Returns the underlying ERC-4626 asset token. |
| `convertToShares()` *(inherited/delegated)* | Converts an asset quantity to an estimated share quantity. |
| `convertToAssets()` *(inherited/delegated)* | Converts a share quantity to estimated underlying assets. |
| `maxRedeem()` *(inherited/delegated)* | Returns the maximum shares currently redeemable by an account. |
| `permit()` *(inherited/delegated)* | Approves spending through an ERC-2612 signature. |
| `nonces()` *(inherited/delegated)* | Returns an account’s current permit signature nonce. |
| `DOMAIN_SEPARATOR()` *(inherited/delegated)* | Returns the EIP-712 signing domain separator. |

### PlasmaVaultBase
**Status:** Existing IPOR; retained behind 1271 wrapper.
**Role:** Original delegatecall base for vault share accounting, permit, governance configuration, and internal hooks.
**Source:** `ipor-fusion/contracts/vaults/PlasmaVaultBase.sol`.

| Callable function | One-sentence summary |
|---|---|
| `init()` | Initializes delegated vault-base permit and governance storage. |
| `cap()` | Returns the factory vault's total-supply cap. |
| `transferRequestSharesFee()` | Moves withdrawal request fee shares within delegated vault accounting. |
| `updateInternal()` | Updates vault share balances through the delegated base hook. |
| `nonces()` | Returns the current ERC-2612 permit nonce for a signer. |
| `name()` *(inherited/delegated)* | Returns the token name. |
| `symbol()` *(inherited/delegated)* | Returns the token symbol. |
| `decimals()` *(inherited/delegated)* | Returns the token decimal precision. |
| `totalSupply()` *(inherited/delegated)* | Returns total token shares outstanding. |
| `balanceOf()` *(inherited/delegated)* | Returns the token shares owned by an account. |
| `transfer()` *(inherited/delegated)* | Transfers token shares to a recipient. |
| `allowance()` *(inherited/delegated)* | Returns shares a spender is authorized to transfer. |
| `approve()` *(inherited/delegated)* | Authorizes a spender to transfer shares. |
| `transferFrom()` *(inherited/delegated)* | Transfers token shares using the caller’s allowance. |
| `permit()` *(inherited/delegated)* | Approves vault share allowance using an ERC-2612 signature. |
| `DOMAIN_SEPARATOR()` *(inherited/delegated)* | Returns the permit signing domain separator. |

### IporFusionAccessManager
**Status:** Existing IPOR; retained.
**Role:** Single original IPOR Access Manager controlling operational roles and execution timelocks.
**Source:** `ipor-fusion/contracts/managers/access/IporFusionAccessManager.sol`.

| Callable function | One-sentence summary |
|---|---|
| `proxyInitialize()` | Initializes the factory-cloned IPOR authority. |
| `initialize()` | Initializes role management and redemption delay settings. |
| `canCallAndUpdate()` | Checks authorization and updates delayed-execution consumption state. |
| `updateTargetClosed()` | Enables or disables closure of a protected target. |
| `convertToPublicVault()` | Converts the vault to its configured public-access mode. |
| `enableTransferShares()` | Enables share transfer behavior under the configured role policy. |
| `setMinimalExecutionDelaysForRoles()` | Sets minimum enforced delays for specified operational roles. |
| `grantRole()` | Grants a role within the original IPOR authority and its delay rules. |
| `getMinimalExecutionDelayForRole()` | Returns a role's minimum execution delay. |
| `getAccountLockTime()` | Returns the configured lock time for a given account. |
| `isConsumingScheduledOp()` | Reports whether a scheduled operation is currently being consumed. |
| `MAX_REDEMPTION_DELAY_IN_SECONDS()` *(getter)* | Returns the current on-chain value of `MAX_REDEMPTION_DELAY_IN_SECONDS` (including any configured indexed arguments). |
| `REDEMPTION_DELAY_IN_SECONDS()` *(getter)* | Returns the current on-chain value of `REDEMPTION_DELAY_IN_SECONDS` (including any configured indexed arguments). |
| `canCall()` *(inherited/delegated)* | Checks whether a caller can execute a target selector and returns its delay. |
| `expiration()` *(inherited/delegated)* | Returns the expiration window of scheduled operations. |
| `minSetback()` *(inherited/delegated)* | Returns the minimum configured delay for reducing administrative delays. |
| `isTargetClosed()` *(inherited/delegated)* | Indicates whether a managed target is closed. |
| `getTargetFunctionRole()` *(inherited/delegated)* | Returns the role needed to call a target function. |
| `getTargetAdminDelay()` *(inherited/delegated)* | Returns the delay for changing target permissions. |
| `getRoleAdmin()` *(inherited/delegated)* | Returns the administrator role for a role. |
| `getRoleGuardian()` *(inherited/delegated)* | Returns the guardian role that can cancel scheduled operations. |
| `getRoleGrantDelay()` *(inherited/delegated)* | Returns the delay before new role grants take effect. |
| `getAccess()` *(inherited/delegated)* | Returns detailed role membership and delay data. |
| `hasRole()` *(inherited/delegated)* | Reports active role membership and required execution delay. |
| `labelRole()` *(inherited/delegated)* | Sets a human-readable role label. |
| `revokeRole()` *(inherited/delegated)* | Revokes a role under the configured administration rules. |
| `renounceRole()` *(inherited/delegated)* | Allows a holder to renounce their own role. |
| `setRoleAdmin()` *(inherited/delegated)* | Changes which role administers another role. |
| `setRoleGuardian()` *(inherited/delegated)* | Changes which role can cancel that role’s scheduled operations. |
| `setGrantDelay()` *(inherited/delegated)* | Updates the grant-delay setting of a role. |
| `setTargetFunctionRole()` *(inherited/delegated)* | Maps target selectors to required roles. |
| `setTargetAdminDelay()` *(inherited/delegated)* | Changes delay for target-level administration. |
| `setTargetClosed()` *(inherited/delegated)* | Closes or reopens a managed target. |
| `getSchedule()` *(inherited/delegated)* | Returns a scheduled operation’s execution timestamp. |
| `getNonce()` *(inherited/delegated)* | Returns the next nonce for scheduled operations. |
| `schedule()` *(inherited/delegated)* | Schedules a role-authorized delayed target call. |
| `execute()` *(inherited/delegated)* | Executes a previously scheduled or immediately authorized call. |
| `cancel()` *(inherited/delegated)* | Cancels a pending scheduled call if permitted. |
| `consumeScheduledOp()` *(inherited/delegated)* | Consumes the scheduled authorization of an in-progress target call. |
| `hashOperation()` *(inherited/delegated)* | Hashes a target call into its operation identifier. |
| `updateAuthority()` *(inherited/delegated)* | Changes the access authority of a target that permits it. |

### FeeManager
**Status:** Existing IPOR; retained.
**Role:** IPOR-native management, performance and deposit fee accounting and fee-recipient administration.
**Source:** `ipor-fusion/contracts/managers/fee/FeeManager.sol`.

| Callable function | One-sentence summary |
|---|---|
| `initialize()` | Initializes fee configuration, recipients and underlying vault linkage. |
| `harvestAllFees()` | Realizes available management and performance fees. |
| `harvestManagementFee()` | Realizes accrued management fees. |
| `harvestPerformanceFee()` | Realizes accrued performance fees. |
| `updateManagementFee()` | Updates management fee recipients and rate data under native IPOR authority. |
| `updatePerformanceFee()` | Updates performance fee recipient/rate data under native IPOR authority. |
| `setIporDaoFeeRecipientAddress()` | Updates the IPOR DAO's fee-recipient address. |
| `getManagementFeeRecipients()` | Returns management fee recipients and rates. |
| `getPerformanceFeeRecipients()` | Returns performance fee recipients and rates. |
| `getTotalManagementFee()` | Returns total configured management fee rate. |
| `getTotalPerformanceFee()` | Returns total configured performance fee rate. |
| `getIporDaoFeeRecipientAddress()` | Returns the configured IPOR DAO fee destination. |
| `updateHighWaterMarkPerformanceFee()` | Updates the performance fee high-water mark. |
| `updateIntervalHighWaterMarkPerformanceFee()` | Configures its high-water-mark performance fee interval. |
| `setDepositFee()` | Sets the native IPOR vault deposit fee rate. |
| `calculateAndUpdatePerformanceFee()` | Calculates accrued performance fees and updates state. |
| `calculateDepositFee()` | Calculates fee shares owed for a specified deposit. |
| `getDepositFee()` | Returns the native deposit fee rate. |
| `getPlasmaVaultHighWaterMarkPerformanceFee()` | Returns the vault's stored performance-fee high-water mark. |
| `PLASMA_VAULT()` *(getter)* | Returns the current on-chain value of `PLASMA_VAULT` (including any configured indexed arguments). |
| `PERFORMANCE_FEE_ACCOUNT()` *(getter)* | Returns the current on-chain value of `PERFORMANCE_FEE_ACCOUNT` (including any configured indexed arguments). |
| `MANAGEMENT_FEE_ACCOUNT()` *(getter)* | Returns the current on-chain value of `MANAGEMENT_FEE_ACCOUNT` (including any configured indexed arguments). |
| `IPOR_DAO_MANAGEMENT_FEE()` *(getter)* | Returns the current on-chain value of `IPOR_DAO_MANAGEMENT_FEE` (including any configured indexed arguments). |
| `IPOR_DAO_PERFORMANCE_FEE()` *(getter)* | Returns the current on-chain value of `IPOR_DAO_PERFORMANCE_FEE` (including any configured indexed arguments). |

### RewardsClaimManager
**Status:** Existing IPOR; retained.
**Role:** Manages vesting, reward balance accounting and transfers of vested avKAT to the vault.
**Source:** `ipor-fusion/contracts/managers/rewards/RewardsClaimManager.sol`.

| Callable function | One-sentence summary |
|---|---|
| `UNDERLYING_TOKEN()` | Returns the underlying reward asset token. |
| `PLASMA_VAULT()` | Returns the parent vault address. |
| `proxyInitialize()` | Initializes the rewards-manager contract. |
| `balanceOf()` | Returns managed reward token assets. |
| `isRewardFuseSupported()` | Checks whether a reward fuse remains authorized. |
| `getVestingData()` | Returns current reward vesting parameters and balances. |
| `getRewardsFuses()` | Lists authorized reward fuses. |
| `transfer()` | Transfers reward tokens under the manager's authorized conditions. |
| `claimRewards()` | Executes approved reward claim actions. |
| `updateBalance()` | Reconciles reward accounting after transfers or allocations. |
| `transferVestedTokensToVault()` | Releases vested reward assets into the plasma vault. |
| `addRewardFuses()` | Registers approved reward claim fuses. |
| `removeRewardFuses()` | Unregisters reward claim fuses. |
| `setupVestingTime()` | Changes the configured reward vesting duration. |
| `rescheduleVesting()` | Updates the vesting schedule of undistributed rewards. |

### PriceOracleMiddleware
**Status:** Existing IPOR; retained.
**Role:** Provides oracle prices for vault asset conversions and market balance accounting.
**Source:** `ipor-fusion/contracts/price_oracle/PriceOracleMiddleware.sol`.

| Callable function | One-sentence summary |
|---|---|
| `initialize()` | Initializes supported asset oracle feeds and their settings. |
| `getAssetPrice()` | Returns the configured normalized price for one token. |
| `getAssetsPrices()` | Returns normalized prices for a token array. |
| `getSourceOfAssetPrice()` | Returns the registered feed for a token. |
| `setAssetsPricesSources()` | Registers or replaces token price source contracts. |
| `QUOTE_CURRENCY()` *(getter)* | Returns the current on-chain value of `QUOTE_CURRENCY` (including any configured indexed arguments). |
| `QUOTE_CURRENCY_DECIMALS()` *(getter)* | Returns the current on-chain value of `QUOTE_CURRENCY_DECIMALS` (including any configured indexed arguments). |
| `CHAINLINK_FEED_REGISTRY()` *(getter)* | Returns the current on-chain value of `CHAINLINK_FEED_REGISTRY` (including any configured indexed arguments). |
| `owner()` *(inherited/delegated)* | Returns the contract’s current owner. |
| `pendingOwner()` *(inherited/delegated)* | Returns the nominated successor owner. |
| `transferOwnership()` *(inherited/delegated)* | Starts an Ownable2Step transfer by nominating a new owner. |
| `acceptOwnership()` *(inherited/delegated)* | Accepts a pending two-step ownership transfer. |
| `renounceOwnership()` *(inherited/delegated)* | Relinquishes contract ownership if allowed. |

### ERC4626PriceFeed
**Status:** Existing IPOR price feed; retained.
**Role:** Provides an ERC-4626 rate-derived feed for configured vault-share assets.
**Source:** `ipor-fusion/contracts/price_oracle/price_feed/ERC4626PriceFeed.sol`.

| Callable function | One-sentence summary |
|---|---|
| `decimals()` | Returns the oracle feed's expected decimal precision. |
| `latestRoundData()` | Returns the latest rate-derived ERC-4626 token price record. |
| `vault()` *(getter)* | Returns the current on-chain value of `vault` (including any configured indexed arguments). |

### FixedValuePriceFeed
**Status:** Existing IPOR price feed; retained.
**Role:** Provides a configured constant-value oracle feed.
**Source:** `ipor-fusion/contracts/price_oracle/price_feed/FixedValuePriceFeed.sol`.

| Callable function | One-sentence summary |
|---|---|
| `decimals()` | Returns the fixed-price feed's decimal precision. |
| `latestRoundData()` | Returns the preconfigured constant price in feed format. |
| `FIXED_PRICE()` *(getter)* | Returns the current on-chain value of `FIXED_PRICE` (including any configured indexed arguments). |

### PlasmaVaultMarketsLib
**Status:** Existing linked IPOR library; retained.
**Role:** Computes market asset valuations in the vault; exposes no independent user-callable functions.
**Source:** `ipor-fusion/contracts/vaults/lib/PlasmaVaultMarketsLib.sol`.

*No public/external callable functions; this is a linked internal library.*

### MorphoCollateralFuse
**Status:** Existing IPOR; retained.
**Role:** Supplies and withdraws authorized Morpho collateral through the vault.
**Source:** `ipor-fusion/contracts/fuses/morpho/MorphoCollateralFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `enter()` | Adds approved collateral to a Morpho borrowing position. |
| `exit()` | Withdraws permitted collateral from a Morpho borrowing position. |
| `enterTransient()` | Supplies collateral from transient-storage instructions. |
| `exitTransient()` | Withdraws collateral from transient-storage instructions. |
| `VERSION()` *(getter)* | Returns the current on-chain value of `VERSION` (including any configured indexed arguments). |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |
| `MORPHO()` *(getter)* | Returns the current on-chain value of `MORPHO` (including any configured indexed arguments). |

### MorphoBorrowFuse
**Status:** Existing IPOR; retained.
**Role:** Borrows or repays assets on the authorized Morpho market.
**Source:** `ipor-fusion/contracts/fuses/morpho/MorphoBorrowFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `enter()` | Borrows from an approved Morpho market within its limits. |
| `exit()` | Repays outstanding Morpho debt. |
| `enterTransient()` | Borrows using transient-storage parameters. |
| `exitTransient()` | Repays using transient-storage parameters. |
| `VERSION()` *(getter)* | Returns the current on-chain value of `VERSION` (including any configured indexed arguments). |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |
| `MORPHO()` *(getter)* | Returns the current on-chain value of `MORPHO` (including any configured indexed arguments). |

### MorphoBalanceFuse
**Status:** Existing IPOR; retained.
**Role:** Values net collateral minus debt for the vault’s Morpho borrowing positions.
**Source:** `ipor-fusion/contracts/fuses/morpho/MorphoBalanceFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `balanceOf()` | Reports the net valued equity of an authorized Morpho collateral/borrow position. |
| `VERSION()` *(getter)* | Returns the current on-chain value of `VERSION` (including any configured indexed arguments). |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |
| `MORPHO()` *(getter)* | Returns the current on-chain value of `MORPHO` (including any configured indexed arguments). |

### MorphoSupplyFuse
**Status:** Existing market-41 and/or newly deployed if missing.
**Role:** Supplies and withdraws assets in authorized Morpho lending markets.
**Source:** `ipor-fusion/contracts/fuses/morpho/MorphoSupplyFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `enter()` | Deposits underlying assets into an allowed Morpho supply market. |
| `exit()` | Withdraws assets from an allowed Morpho supply market. |
| `instantWithdraw()` | Withdraws Morpho liquidity through the instant-withdraw flow. |
| `enterTransient()` | Supplies assets using transient-storage inputs. |
| `exitTransient()` | Withdraws using transient-storage inputs. |
| `MORPHO()` *(getter)* | Returns the current on-chain value of `MORPHO` (including any configured indexed arguments). |
| `VERSION()` *(getter)* | Returns the current on-chain value of `VERSION` (including any configured indexed arguments). |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |

### MorphoOnlyLiquidityBalanceFuse
**Status:** Existing market-41; retained.
**Role:** Values the supply-only Morpho market as liquid lending exposure.
**Source:** `ipor-fusion/contracts/fuses/morpho/MorphoOnlyLiquidityBalanceFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `balanceOf()` | Values supplied assets in the authorized Morpho lending market. |
| `MORPHO()` *(getter)* | Returns the current on-chain value of `MORPHO` (including any configured indexed arguments). |
| `VERSION()` *(getter)* | Returns the current on-chain value of `VERSION` (including any configured indexed arguments). |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |

### ERC20BalanceFuse
**Status:** Existing IPOR market-7 accounting; retained.
**Role:** Values eligible idle ERC-20 assets held by the vault.
**Source:** `ipor-fusion/contracts/fuses/erc20/Erc20BalanceFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `balanceOf()` | Returns the combined USD value of approved non-underlying ERC-20 assets held by the vault. |
| `VERSION()` *(getter)* | Returns the current on-chain value of `VERSION` (including any configured indexed arguments). |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |

### UniversalTokenSwapperFuse
**Status:** V2 deployment (official IPOR).
**Role:** Calls the allowlisted swap router with vault assets and output/slippage enforcement.
**Source:** `ipor-fusion/contracts/fuses/universal_token_swapper/UniversalTokenSwapperFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `enter()` | Executes an approved swap from the vault through authorized targets and minimum-output checks. |
| `enterTransient()` | Executes the same swap using transaction-scoped inputs. |
| `VERSION()` *(getter)* | Returns the current on-chain value of `VERSION` (including any configured indexed arguments). |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |
| `EXECUTOR()` *(getter)* | Returns the current on-chain value of `EXECUTOR` (including any configured indexed arguments). |
| `DEFAULT_SLIPPAGE_WAD()` *(getter)* | Returns the current on-chain value of `DEFAULT_SLIPPAGE_WAD` (including any configured indexed arguments). |

### UpdateMarketsBalancesFuse
**Status:** V2 deployment (official IPOR).
**Role:** Recalculates configured market balances and their dependency graph.
**Source:** `ipor-fusion/contracts/fuses/update_balances/UpdateMarketsBalancesFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `enter()` | Updates selected market accounting through the vault's balance registry. |
| `exit()` | Invokes the supported balance-update exit route. |
| `VERSION()` *(getter)* | Returns the current on-chain value of `VERSION` (including any configured indexed arguments). |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |

### TransientStorageMapperFuse
**Status:** V2 deployment (official IPOR).
**Role:** Copies intermediate fuse outputs into following fuse inputs using transaction-scoped storage.
**Source:** `ipor-fusion/contracts/fuses/transient_storage/TransientStorageMapperFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `enter()` | Copies specified transaction-scoped outputs into the next fuse's transient input slots. |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |
| `MAX_ITEMS()` *(getter)* | Returns the current on-chain value of `MAX_ITEMS` (including any configured indexed arguments). |
| `MAX_DECIMAL_DIFF()` *(getter)* | Returns the current on-chain value of `MAX_DECIMAL_DIFF` (including any configured indexed arguments). |
| `VERSION()` *(getter)* | Returns the current on-chain value of `VERSION` (including any configured indexed arguments). |

### PlasmaVaultBalanceAssetsValidationFuse
**Status:** V2 deployment (official IPOR).
**Role:** Checks market asset values against declared minimum and maximum bounds.
**Source:** `ipor-fusion/contracts/fuses/PlasmaVaultBalanceAssetsValidationFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `enter()` | Verifies the vault's balance values meet the specified allowed asset limits. |
| `VERSION()` *(getter)* | Returns the current on-chain value of `VERSION` (including any configured indexed arguments). |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |

### Erc4626SupplyFuse
**Status:** V2 deployment (official IPOR).
**Role:** Deposits and withdraws vault-held assets into authorized ERC-4626 destinations such as cyvbUSDC.
**Source:** `ipor-fusion/contracts/fuses/erc4626/Erc4626SupplyFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `enter()` | Supplies underlying assets into a permitted ERC-4626 vault under minimum-shares limits. |
| `enterTransient()` | Supplies using transaction-scoped input data. |
| `exit()` | Withdraws or redeems position shares under the configured output constraints. |
| `exitTransient()` | Withdraws using transaction-scoped input data. |
| `instantWithdraw()` | Returns assets from an ERC-4626 position for approved instant withdrawal. |
| `VERSION()` *(getter)* | Returns the current on-chain value of `VERSION` (including any configured indexed arguments). |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |

### Erc4626BalanceFuse
**Status:** V2 deployment (official IPOR).
**Role:** Values ERC-4626 shares owned by the vault.
**Source:** `ipor-fusion/contracts/fuses/erc4626/Erc4626BalanceFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `balanceOf()` | Values the vault's balances in authorized ERC-4626 positions. |
| `VERSION()` *(getter)* | Returns the current on-chain value of `VERSION` (including any configured indexed arguments). |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |

### MorphoFlashLoanFuse
**Status:** V2 deployment (official IPOR).
**Role:** Enters a Morpho flash loan and dispatches the configured atomic repayment actions.
**Source:** `ipor-fusion/contracts/fuses/morpho/MorphoFlashLoanFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `enter()` | Starts a Morpho flash loan and executes its vault callback action sequence. |
| `enterTransient()` | Starts a flash loan using transient-storage inputs. |
| `VERSION()` *(getter)* | Returns the current on-chain value of `VERSION` (including any configured indexed arguments). |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |
| `MORPHO()` *(getter)* | Returns the current on-chain value of `MORPHO` (including any configured indexed arguments). |

### ZeroBalanceFuse
**Status:** V2 deployment (two market-specific instances).
**Role:** Returns zero for utility/config-only or flash-loan markets that do not hold independently valued assets.
**Source:** `ipor-fusion/contracts/fuses/ZeroBalanceFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `balanceOf()` | Returns zero value for a non-investment utility market. |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |

### BurnRequestFeeFuse
**Status:** V2 deployment (official IPOR).
**Role:** Burns withdrawal fee shares through the current withdraw manager configuration.
**Source:** `ipor-fusion/contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `enter()` | Burns accrued withdrawal request fee shares as an authorized vault action. |
| `enterTransient()` | Burns withdrawal fee shares from transient storage inputs. |
| `exit()` | Performs the fuse's supported reverse-phase action when requested. |
| `exitTransient()` | Performs the corresponding reverse-phase action from transient inputs. |
| `VERSION()` *(getter)* | Returns the current on-chain value of `VERSION` (including any configured indexed arguments). |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |

### CallbackHandlerMorpho
**Status:** V2 deployment (official IPOR).
**Role:** Dispatches Morpho protocol callbacks into the registered vault execution context.
**Source:** `ipor-fusion/contracts/handlers/callbacks/CallbackHandlerMorpho.sol`.

| Callable function | One-sentence summary |
|---|---|
| `onMorphoSupply()` | Dispatches an authenticated Morpho supply callback. |
| `onMorphoFlashLoan()` | Dispatches an authenticated Morpho flash-loan callback into the vault. |

### BalancerLiquidityProportionalFuse
**Status:** Conditional V2 POL deployment (only if venue configured).
**Role:** Adds or removes proportional Balancer liquidity using authorized vault assets.
**Source:** `ipor-fusion/contracts/fuses/balancer/BalancerLiquidityProportionalFuse.sol`.

| Callable function | One-sentence summary |
|---|---|
| `enter()` | Joins an authorized Balancer pool with proportional vault-held tokens. |
| `enterTransient()` | Joins a Balancer pool using transient-storage inputs. |
| `exit()` | Exits an authorized Balancer pool proportionally into vault-held tokens. |
| `exitTransient()` | Exits a Balancer pool with transaction-scoped parameters. |
| `VERSION()` *(getter)* | Returns the current on-chain value of `VERSION` (including any configured indexed arguments). |
| `MARKET_ID()` *(getter)* | Returns the current on-chain value of `MARKET_ID` (including any configured indexed arguments). |
| `BALANCER_ROUTER()` *(getter)* | Returns the current on-chain value of `BALANCER_ROUTER` (including any configured indexed arguments). |
| `PERMIT2()` *(getter)* | Returns the current on-chain value of `PERMIT2` (including any configured indexed arguments). |

## V18 architecture note

`CurveYieldWrapperBurnForwarder` has been removed from the deployment stack; the retained fee splitter continues to allocate 40/30/30, with its 30% contributors destination routed to V2 Revenue Custody by L10 after governance handover. V21 excludes the external vault-loop splitter and both feeder deployments; the original Profit Custody retains its unchanged internal configured split and 100% of its fee-recipient leg goes directly to `feeRecipient`. See `../CHANGELOG_v21.md`. `reserveAvkatForPolBps` acts on custody direct avKAT balance only.

## Source of deployment status

- `upgrade/script/K1_QuestSigning.s.sol`: required permanent Quest signer-config migration.
- `upgrade/script/P0_00_DeployGateConfig.s.sol`: new IPOR-backed governance gate.
- `upgrade/script/P2_01_Deploy.s.sol`: V2 controller, router, withdrawal manager and general fuses.
- `upgrade/script/P2_02_ConfigureVault.s.sol`: fuse and substrate configuration.
- `upgrade/script/P2_03_Cutover.s.sol`: replaces the manager and activates the executor.
- `upgrade/script/P2_04_RemoveV1Fuses.s.sol`: excludes legacy and obsolete fuses.
- `upgrade/script/P5_01_DeployPol.s.sol`: POL controller, rate-aware balance fuse, custody and two feeder instances pending simplification review, with optional Balancer liquidity fuse.
- `upgrade/script/P6_01_CustodyV2Migration.s.sol`: layers new custody over existing custody.
- `upgrade/script/Phase2Base.s.sol`: existing live addresses and external dependencies.

## Note on asset addresses and duplicate deployments

No `CurveYieldPolFeeder` is deployed in V21. `ZeroBalanceFuse` is deployed **twice** (distinct market IDs). The same implementation may also be deployed at different addresses if the migration script is rerun; this register lists one contract type once and identifies multiplicity.

The retained live vault address is `0xEd83daf48429cfb2C650Fd721b9241e180fd4548`; the retained original IPOR base is `0x6D73E66A5486C8Aa7DD8a3231F89087CE1D74b49` and the active Quest signing wrapper recorded in the archive is `0x0a9eA25C827Ec0C6B2619C231B7566846619B365`. The pre-existing live rewards manager is `0xA77470B748A8Fb50056Ca3c07375dC76Aa3A72Cb`. All other proposed V2 deployments still require verified deployment receipts and on-chain readback.
