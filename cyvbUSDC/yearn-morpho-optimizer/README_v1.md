# Yearn V3 Direct Morpho Market Optimizer — v1

Status: **implementation candidate, NOT production qualified or deployed.**
This new subsystem is independent of the existing cyvbUSDC IPOR Fusion vault.
No files in the existing IPOR deployment, fee split, routes, or accounting were changed.

## The two selected proven source bases

1. **Master:** Yearn's canonical `Base4626Compounder.sol` at
   https://github.com/yearn/tokenized-strategy-periphery/blob/master/src/Bases/4626Compounder/Base4626Compounder.sol
   - Reuse the single-child ERC-4626 deposit, redemption, and share-to-underlying accounting patterns.
   - Adapt only the child-selection/management logic for up to **10 Yearn tokenized strategies**.
   - Inherit official Yearn `BaseStrategy`, because `Base4626Compounder` contains an immutable single `vault` and cannot be directly subclassed into a dynamic 10-child manager without rewriting its internals.

2. **Child:** Yelay's audited-by-inspection-only (NOT independently verified as audited) real deployed-family `MorphoBlueStrategy.sol`:
   https://github.com/YieldLayer/yelay-lite/blob/main/src/strategies/MorphoBlueStrategy.sol
   - Reuse direct Morpho `supply(marketParams, amount, 0, this, "")`, `withdraw`, and `MorphoBalancesLib.expectedSupplyAssets`.
   - Adapt to official Yearn `BaseStrategy` and add direct Merkl `claim` + CurveYield KAT/vbUSDC router reward conversion.
   - Each child is locked to **one Morpho market ID**, not a MetaMorpho vault.

## Exact optimizeFunds execution order

1. Keeper calls master `optimizeFunds(ClaimBundle[])`. Exactly one claim bundle per installed child, in order.
2. Master reads each child `pricePerShare()` **before** any claims.
3. Master calls that child's `claimAndCompound` with Merkl proof arrays; child can only claim rewards whose recipient is itself and whose token is the configured KAT address.
4. Child converts KAT rewards into vbUSDC through the existing CurveYield router using an explicitly supplied `minNetAmountOut` and `deadline`, checks balance changes, and supplies any loose vbUSDC to its dedicated direct Morpho market.
5. Master invokes that child's authorized Yearn `report()`, reads the child's **post-report PPS**, stores the observation and calculates a signed per-cycle percentage return. It repeats 2-5 for every child.
6. Master ranks children by observed PPS percentage gain (not absolute PPS), highest first; the tie-breaker is the existing child registration order.
7. Master withdraws overweight child positions, then deposits to underweight child strategies according to owner-configured ordinal rank weights. All operations are one atomic transaction; any revert undoes claims, swaps, reports and reallocation.

## Default and owner controls

- Maximum **10** children. Owner/Yearn management adds and removes independently, with no one allowed to remove a child while the master still owns shares.
- Default ranked weights: **70% best / 30% second**, with 0% for remaining; 1 installed child receives 100%.
- `setRankWeights` accepts 1-10 percentages in basis points totaling exactly **10,000**. Examples: [10000], [7000, 3000], [6000, 3000, 1000], [4000, 3000, 2000, 1000].
- `setMinimumInterval`: owner may set 1 hour through 30 days; default 1 hour.
- `setProbeBps`: default **0**, enforcing exact 70/30. Optional probing gives each configured child 0-1% minimum exposure *before* assigning the remainder by performance rank. Without probes or other seeded capital, unallocated children may not generate enough yield to compete.
- Child management must call `setKeeper(masterAddress)` and `setProfitMaxUnlockTime(0)` before `master.addChild(child)`. All child and master strategies should use consistent fee schedules when comparing returns. Prefer matching fee arrangements for unbiased selection.
- Yearn management is the owner for configuration; the master keeper may execute optimization.
- No Merkl API inputs, price predictions, claimed rewards APR, or keeper-supplied scores control ranking.

## Important correctness and security boundaries

- This exact PPS-before/after-report strategy **requires** children to use the default report-boundary `_strategyTotalAssets`, not live pricing. Any child using live accrual will show yield before `report()` and be underscored.
- It also **requires** `profitMaxUnlockTime() == 0`. The master checks this at registration and every optimization; post-report profit lock would conceal yield from immediate PPS.
- The scoring interval measures all unreported interest and realized incentive profit **since each child's previous report**. Different report times, deposits, dilution, losses or discretionary reports bias comparisons. The master rejects changes to `lastReport` that occur outside its own cycles; first cycles for newly added children still require controlled seeding.
- PPS changes can still be influenced economically by donations, trade execution, early campaign expiry, incentive volatility, price distortion and changes in utilization. They are on-chain observations, NOT intrinsically manipulation-proof APR signals.
- Reports with zero unlocking have immediate PPS effects; assess deposit / withdrawal timing, MEV, first-depositor and profit-capture risk before using actual funds.
- Failed withdrawal or missing Morpho liquidity **reverts the entire optimization**. No loss is silently written off.
- Reward router defaults must be explicitly configured on Katana; this source treats its address as a constructor parameter. Verify TWAP/slippage protection and KAT/vbUSDC route before deployment. The Merkl distributor is also a constructor parameter.
- The upstream Yearn `BaseStrategy` embeds a **specific TokenizedStrategy implementation address**. The current upstream reference may refer to the deterministic test address `0x2e234DAe75C793f67A35089C9d99245E1C58470b`. **Deployment is blocked** until verified against the actual official TokenizedStrategy implementation deployed on Katana. Do not deploy without matching the correct bytecode and upstream version.
- Child and master are separately tokenized Yearn ERC-4626 strategies. The upstream Yearn factory/protocol fee configuration must be verified; `0` performance fees in tests do not imply production fee settings.
- A single child with no liquidity cannot be fully withdrawn; owner must consider liquidity locks and possibly keep an idle balance to satisfy redemptions.
- Reverts on one Merkl claim or swap block the complete cycle. For production, support controlled retry/skip policies with event evidence and explicit safety assumptions only after testing.

## Implementation files

- `contracts/YearnMorphoRankedMaster_v1.sol` — ranked Yearn tokenized master.
- `contracts/YearnMorphoMarketChild_v1.sol` — direct Morpho market Yearn tokenized child, KAT Merkl claim and compound.
- `test/YearnMorphoRankedMasterTest_v1.t.sol` — real Yearn V3 accounting mocks test 70/30, optional three ranks, single winner, rejected profit locks, rejected external reports.
- `.github/workflows/yearn_morpho_optimizer_verify_v1.yml` — isolated GitHub-hosted Foundry compile/test using pinned OpenZeppelin 4.9.6; installs no dependencies and runs no compiler in the local model environment.

## Deployment inputs still required

- Katana direct Morpho Blue core contract address and approved market IDs matching each child loan token (vbUSDC).
- Official active Yearn TokenizedStrategy implementation address **on Katana** plus an audited deployment/factory configuration.
- CurveYield router, distributor and reward-token contracts validated against the configured production network.
- Authorized keeper and governance setup and required Yearn management handoffs.
- End-to-end GitHub-hosted Katana fork tests covering rewards, scoring, Morpho accrual, withdrawal liquidity, paused strategies, hostile donations and reentrancy.

This code is a development candidate; no deployment or fork qualification is asserted.
