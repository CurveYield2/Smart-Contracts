# Contract classification and roles (authoritative for this package)

Categories:
- **IPOR (unmodified)** — IPOR Fusion at commit `9fb9e806`, byte-identical (see SOURCE_PROVENANCE). Out of scope except
  as integration context; used as-is (e.g. PlasmaVault, MorphoCollateral/Borrow/Supply fuses, BurnRequestFeeFuse,
  MerklClaimFuse, BalancerBalanceFuse, price-oracle middleware).
- **Adapted IPOR fork** — IPOR logic extended by CurveYield (review the delta and the whole).
- **CurveYield custom** — new code, in scope.
- **Live** — already deployed on Katana (address given); included because the new code integrates with it.

All paths are under `workspace/phase2/src/`.

## Vault core (cyavKAT)
| Contract | Category | Role |
|---|---|---|
| `executor/CurveYieldVaultExecutor` | custom | Public keeper entry points (deploy, rebalance, fulfil, harvest, emergencies, native-exit lane). Holds vault ALPHA; controller of WM v2. Only executes: plans come from controllers, numbers from the gate. Deployed from the `size` profile. |
| `withdraw/CurveYieldWithdrawalManagerV2` (+ `StorageLib`) | adapted IPOR fork | IPOR WithdrawManager derivative: enumerable expiry queue, exact request-fee escrow / refund / earn, fee split, gate-read fees, burn-only and emergency-exempt arming. `size` profile. |
| `withdraw/CurveYieldWithdrawalRequestFuse` | custom | Request-fee share moves (WM's requestFeeFuse); fulfilment phase 1 (sources, POL sale) and phase 2 (settlement: profit, keeper reward, split legs). |
| `allocation/CurveYieldAllocationController` | custom | Strategy sets, deploy / reduce plans, withdraw source order, vault floor. |
| `morpho/CurveYieldMorphoLoopController`, `CurveYieldMorphoLoopLib` | custom | avKAT/KAT Morpho loop planning (wind-up, unwind, LTV, collateral top-up). |
| `morpho/CurveYieldLoopProfitSplitter` | custom | Profit split legs (growth / contributors / vault / rewards manager; FEE-class gate keys). |
| `vkat/CurveYieldVkatController` | custom | vKAT allocation and the native-exit lane. |
| `lend/CurveYieldAvkatLendController` | custom | avKAT lending in Morpho (cap, decay, ownership trigger). |
| `lp/CurveYieldSushiLpController`, `CurveYieldSushiLpHolder` | custom | Sushi V3 avKAT/KAT LP held off-vault with its own Morpho position. |
| `accounting/CurveYieldPositionReaders` | custom | Off-vault position readers for the balance fuse. |
| `generic/*` | custom (IPOR-style stateless fuses) | Bundle guard, burn held shares, ERC-20 transfer, holder fuses, loop fuses, planned instant withdraw, position-reader balance, TryElse, voting-escrow fuses, substrate types; `CurveYieldRateAwareBalancerBalanceFuse` is an **adapted IPOR fork** (raw balances priced by the oracle). |
| `router/CurveYieldSwapRouterV2` | custom | Multi-hop Sushi V3 + CurveYield DEX routes, flat 0.1% fee, router-wide protected minimum (TWAP / DEX hook oracle). Owned by the gate. |
| `router/CurveYieldRouterSwapFuseV2` | custom | Vault swaps through router v2; harvest sweep (reward tokens → avKAT, keeper reward, rest to the RCM). |
| `libraries/*`, `interfaces/*` | custom | Bounds, profit-split lib, shared interfaces (FuseAction is ABI-identical to IPOR's). |

## Governance
| Contract | Category | Role |
|---|---|---|
| `governance/CurveYieldGovernanceGate` | custom | Owner of record of every CurveYield contract and holder of the vault's IPOR roles; config registry (values, ranges, immutable hard caps, classes FEE / DAO / GUARDIAN, group rules, arg-range passthroughs); protected calls (fee authority only). |
| `governance/CurveYieldGateConfig` | custom | Base for gate-read settings; `CurveYieldConfigKeys` key catalogue. |
| `governance/CurveYieldOptimizationGuardian` | custom | The maintenance bot's handle (guardian ranges / calls). |
| `governance/CurveYieldVotingLock`, `EngagementToken`, `EngagementRewards`, `VoterRewards`, `ProposalBond`, `AragonInterfaces` | custom | DAO voting token, engagement rewards, proposal bond (Aragon OSx DAO with TokenVoting + Admin plugin). |

## POL and revenue custody
| Contract | Category | Role |
|---|---|---|
| `pol/CurveYieldPolController`, `PolCustody`, `PolFeeder`, `PolPriceLib`, `SwapLib`, `PolInterfaces` | custom | Protocol-owned liquidity: feeders divert avKAT, custody buys cyavKAT / WETH, buybacks only if PPS strictly rises, lifetime budget. |
| `protection/CurveYieldRevenueCustodyV2` | custom | Revenue custody v2: Morpho loop at `custody.loopTargetBps` (30–80%, default 60%) of its value + the farm; PPS backstop `cover()` (idle → farm → loop), executor only. Replaces live `0xe7D1…5ADf`. |
| `protection/CurveYieldCustodyFarm` | custom | The custody's "everything else": allowlisted Sushi V3 positions (+ Katana SushiStaker), Charm vaults, Merkl rewards (→ avKAT, split like loop gains); pro-rata deploy of new funds; cover pull. Operators: user wallet, fee Safe, deployer. |
| `protection/CurveYieldCustodyFarmPlanner` | custom | View-only valuation and pro-rata sizing for the farm. |

## cyavKAT+ (Plus stack)
| Contract | Category | Role |
|---|---|---|
| `plus/CurveYieldPlusLoopController`, `PlusExecutor`, `PlusDepositRouter`, `PlusYieldBooster` | custom | cyavKAT+ loop, keeper entry points, the only depositor (private vault), booster. |
| `plus/CurveYieldEmergencyFeeArmFuse` | custom | Arms the main WM's instant-fee exemption for cyavKAT+ emergency de-leverage only. |
| `plus/CurveYieldNetPpsPriceFeed` | custom | cyavKAT price net of its pending performance fee. |
| `plus/CurveYieldSpecialRewards`, `CurveYieldContributorsRewardFuse` | custom | Epoch rewards; contributors' custody. |
| `leaderboard/CurveYieldLeaderboard`, `Referrals`, `SeasonPoints` | custom | Seasons, points, buy split (locked during a season), referrals. |
| `withdraw/CurveYieldCallerRewardFuse` | custom, **live** `0x70a2…41Ec` (verbatim copy) | Request-fee / caller-reward fuse; cyavKAT+ deploys its own instance; cyavKAT no longer uses the live one (P2_04 removes it). |

## Live, already deployed (integration context)
| Contract | Address |
|---|---|
| `wrapper/CurveYieldWrappedCyavKat` (wcyavKAT) | `0x10dF0e197bc1FEF44D1D1a648C2874c9cdC34692` |
| `wrapper/CurveYieldWrapperFeeSplitter` | `0xB53787F6b85E1bE7FEDabCfB6BBcd8bf6b1a8799` |
| `wrapper/CurveYieldWrapperBurnForwarder` | (L10) |
| `oracles/IporVaultHaircutOracle12` | `0x2926dD048e1571DA8fc26BF6CB15cB9cA8135137` |
| `katana/CurveYieldSignatureFuse`, `CurveYieldVaultBase1271` | `0x4a94978F67C071e357158b55C64d867dFb69AeEb`, `0x0a9eA25C827Ec0C6B2619C231B7566846619B365` |
| IPOR `MerklClaimFuse` (reused) | `0xc6d024E53204CADa27a3c60C77dA4de2e7eb5166` |
