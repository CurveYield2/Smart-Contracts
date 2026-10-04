# Configurable values — full stack (2026-09-29)

Every value that can be changed after deployment, by contract. Source: `phase2/src` (setters) plus the live IPOR vault
and withdraw manager. "Default" = the value the deploy scripts / comments use; "live" = read on Katana 2026-09-29.
Wiring-only setters (addresses of other contracts) are listed separately per contract.

## 1. IPOR vault cyavKAT `0xEd83…4548` (IPOR roles / fee authority)
| Value | Where set | Live |
|---|---|---|
| Management fee | IPOR FeeManager | 0.5%/yr (recipient `0xfEa3…45eB`) |
| Performance fee | IPOR FeeManager | 10% (recipient `0xe402…A321`) |
| Market substrates (markets 7, 14, 19, 36, 41, 54, 100001/2) | `grantMarketSubstrates` | — |
| Balance fuse per market, supported fuses | `addBalanceFuse`, `addFuses` | — |
| Instant-withdrawal fuse list + params | `configureInstantWithdrawalFuses` | lend → vKAT → LP → POL |
| Price oracle middleware + asset feeds | IPOR price oracle | — |
| Access-manager roles (ALPHA, 1000, 1100 …) | IPOR access manager | — |

## 2. Withdraw manager v2 (fee authority for fees; template permission)
| Value | Setter | Bounds | Live / default |
|---|---|---|---|
| Instant withdraw fee | `updateWithdrawFee` | ≤ 100% | **1.25%** |
| Request fee | `updateRequestFee` | ≤ 100% | **8.75%** |
| Withdraw window | `updateWithdrawWindow` | — | 120 days |
| Fee split (3 recipients + bps, split request fee flag) | `setFeeSplit` | each ≤ 50%, total ≤ 75% | off (cyavKAT), on (cyavKAT+) |
| Profit custody (instant-fee custody cut) | `setProfitCustody` | custody's `revenueShareBps` ≤ 35% | `0xe7D1…` |
| Burn-only accounts | `setBurnOnlyFee` | — | POL custody |
| Emergency-fee-exempt accounts (new) | `setEmergencyFeeExempt` | — | cyavKAT+ vault |
| Controller / burn fuse / request-fee fuse | `setDependencies` | — | executor |
| Plasma vault address | `updatePlasmaVaultAddress` | — | — |

## 3. Vault executor
| Value | Setter | Bounds | Default |
|---|---|---|---|
| Keeper rewards (deploy / fulfil / harvest) | gate `exec.*` keys | 0–1% / 0–10 avKAT | 0.2% / 10, 0.2% / 10, 0.2% / 5 |
| PPS backstops (ordered) | `setBackstops` | — | revenue custody v2 |
| Dependencies (allocation, WM, RCM, Merkl claim fuse, swap fuse v2, transfer fuse, KAT, guard fuse, withdrawal request fuse) | `setDependencies` | — | — |

## 4. Caller Reward Fuse `0x70a2…41Ec` (live; no longer used by cyavKAT from Phase 2 — cyavKAT+ only)
| Value | Setter | Bounds | Default |
|---|---|---|---|
| Reward bps + cap per action (deploy, harvest, fulfil, emergency) | `setCallerRewardConfig` | ≤ 3%, ≤ 100 avKAT | 0.2% / 10 (deploy), 0.2% / 5 (harvest), 0.2% / 10 (fulfil) |
| Extra wind-up reward bps | `setExtraWindupCallerRewardBps` | ≤ 10% | 5% |
| Source fuse per action | `setSourceFuse` | — | — |
| Controller / withdraw manager | `setController`, `setWithdrawManager` | — | executor / WM |

## 5. Allocation controller
| Value | Setter | Bounds | Default |
|---|---|---|---|
| Vault floor (idle kept, share of reserve target) | `setVaultFloorBps` | deploy-time bound | — |
| Seasoning days (wind-up cap on seasoned avKAT) | `setSeasoningDays` | — | 7 |
| Strategy sets (loop, vKAT, lend, LP, POL) | `setSets` | — | — |
| Legacy vKAT fuse | `setLegacyVkatFuse` | — | — |
| Executor | `setExecutor` | — | — |

## 6. Morpho loop controller (`setParams`, Guardian single-field `setAllocationBps`)
| Value | Bounds (P2_01) | Default |
|---|---|---|
| allocationBps | 0–80% | 75% |
| rampZoneBps | 0–50% | 40% |
| baseWindupProfitBps / rampStart / rampEnd | 0–10% | 2.25% / 3% / 7% |
| minUnwindProfitBps | 0–10% | 0.4% |
| lossBufferBps | 0–10% | 8.35% |
| targetLtvBps | 50–76% | 75% |
| emergencyLtvBps | 50.01–76.9% | 76.6% |
| emergencyTargetLtvBps | 50–76.8% | 76.2% |
| ltvRebalanceToleranceBps | 0–5% | 0.25% |
| reduceLossBps | 0 (fixed, PPS A3) | 0 |
| maxCycles | 1–16 | 8 |
| Wiring: fuses (once), executor, allocation | `setFuses`, `setExecutor`, `setAllocation` | |

## 7. vKAT controller
| Value | Setter | Default |
|---|---|---|
| allocationBps (bot sets from gauge real yield) | `setParams` / `setAllocationBps` | — |
| nativeExitMaxLtvBps | `setParams` | 76.2% |
| deployWindow (lock only this close to vote end) | `setParams` | — |
| Vote gauges + weights | `setVoteTargets` | 1 gauge, 100% |
| Wiring: fuses (once), executor | `setFuses`, `setExecutor` | |

## 8. Lending controller (market 41)
| Value | Setter | Default |
|---|---|---|
| capBps | `setParams` / `setCapBps` | 20% |
| ownershipTriggerBps | `setParams` | 20% |
| decayBps / decayInterval | `setParams` / `setDecayBps` | 10% / 12 h |
| liquidityFloorBps | `setParams` | 3% |
| ownershipExemptAvkat | `setParams` | 10,000 avKAT |
| Wiring: supply fuse, executor | `setFuses`, `setExecutor` | |

## 9. Sushi LP controller (holder)
| Value | Setter | Default |
|---|---|---|
| minBps / maxBps | `setParams` / `setMaxBps` | 2% / 5% |
| advantageStartBps / advantageFullBps | `setParams` | +30% / +100% |
| minKatBps | `setParams` | 5% |
| standardLossBps / scheduledLossBps | `setParams` | 1% / 4% |
| targetLtvBps / emergencyLtvBps / emergencyTargetLtvBps | `setParams` | 75% / 76.6% / 76.2% |
| slippageBps | `setParams` | 0.3% |
| yieldWindow | `setParams` | 7 days |
| Wiring: executor | `setExecutor` | |

## 10. Loop profit splitter
| Value | Setter | Bounds | Default |
|---|---|---|---|
| growth / contributors / vault / rewards-manager bps | `setSplit` | each ≤ 50%, sum 100% | — |
| Growth custody, contributors sink | `setGrowthCustody`, `setContributorsSink` | — | POL feeder / Phase 4 sink |

## 11. POL controller (position A)
| Value | Setter | Bounds | Default |
|---|---|---|---|
| capBps | `setParams` / `setCapBps` | ≤ 10% | 3% |
| triggerBps | `setParams` | 0.5–20% | 3% |
| minGainBps | `setParams` | ≤ 10%, ≤ trigger | 1% |
| maxPerRunBps | `setParams` | ≤ 100% | 25% |
| cooldown | `setParams` | 1 h–7 d | 12 h |
| minPolProfitBps | `setParams` | ≤ 5% | 0.5% |
| maxChargeDiscountBps | `setParams` | ≤ 30% | 10% |
| maxSlippageBps | `setParams` | 0.1–5% | 1% |
| maxPremiumBps | `setParams` | ≤ 2% | 0 |
| twapWindow | `setParams` | 5 min–24 h | 30 min |
| idleBuyback / maxIdleBps | `setParams` | ≤ 5% | off / 1% |
| addHaircutBps | `setParams` | ≤ 0.5% | 0.01% |
| Admin yield fee bps + receiver | `setYieldFee` (fee authority) | ≤ 20% | — |
| Market reference routes (WETH→avKAT) | `setMarketRoutes` | — | — |
| Wiring: venues, fuses, executor | `setVenues`, `setFuses`, `setExecutor` | | |

## 12. POL custody (position B) and POL feeder
| Value | Setter | Default |
|---|---|---|
| twapWindow / maxSlippageBps / maxPremiumBps | custody `setParams` | 30 min / 1% / 0 |
| Routes avKAT↔WETH | custody `setRoutes` | — |
| Operators, venues | custody `setOperator`, `setVenues` | — |
| polBps (share of growth leg to POL custody), destination | feeder `setConfig` | 20% |

## 13. Revenue custody v2 (backstop)
| Value | Setter | Bounds | Default |
|---|---|---|---|
| revenueShareBps (instant-fee custody cut) | `setRevenueShareBps` | ≤ 35% | 30% |
| Wind-up distribution (rewards manager / fee recipient) | `setWindupDistributionBps` | 10–30% / 5–20% | 16% / 9% |
| Fee recipient | `setFeeRecipient` | — | — |
| Guardians, coverers (executor) | `setGuardian`, `setCoverer` | — | — |
| Full unwind (15-day delay) | `scheduleFullUnwind` / `cancelFullUnwind` | — | — |

## 14. cyavKAT+ (Plus) stack
| Contract | Value | Setter | Bounds / default |
|---|---|---|---|
| Plus loop controller | targetLtv / deleverLtv / windupBand | `setParams` | 70% / 72.2% / — |
| | profit split special / compound / booster / admin | `setProfitSplit` (fee authority) | 40 / 40 / 10 / 10% |
| | admin receiver, destinations, main WM, main fee manager, emergency arm fuse, fuses, executor | setters | — |
| Plus WM v2 | withdraw fee / request fee / fee split | as §2 | 15% / 15% / 20-25-30 split |
| Deposit router | depositFeeBps + 4-way split | `setDepositFee` | ≤ max, split sums 100% |
| | whitelist, admin receiver, destinations, WM | setters | — |
| Yield booster | dripBps / interval / rewards manager | `setParams` | 0–100% / 1 h–30 d |
| Special rewards | callerBps, callerRewardCap, exemptShares, minInterval, forwarderFee, forwarderMin | `setParams` | 0.01–4%, …, 1–90 d |
| | admin + adminBps | `setAdmin` | ≤ 20% |
| Contributors reward fuse | grand prize bps + unlock (once) | `setGrandPrize` | — |
| | engagement rewards | `setEngagementRewards` | — |
| Plus executor | withdraw manager | `setWithdrawManager` | — |

## 15. Wrapper (wcyavKAT) and its splitters
| Value | Setter | Bounds | Live |
|---|---|---|---|
| Management fee / performance fee | `setFees` | ≤ max | 2%/yr / 8% above HWM |
| Fee splitter admin receiver, destinations (40/40/20) | `setAdminReceiver`, `setDestinations` | — | — |
| Burn forwarder destinations | `setDestinations` | — | — |

## 16. Governance
| Contract | Values | Setter |
|---|---|---|
| Governance gate | DAO, guardian, fee authorities, access managers, protected calls / roles, guardian calls | `setDao`, `setGuardian`, `setFeeAuthority`, `setAccessManager`, `setProtectedCalls`, `setProtectedRoles`, `setGuardianCall` |
| Optimization guardian | allowed actions (target, selector, min, max), operator, owners, closed targets | `setAction`, `setOperator`, `setOwner`, `updateTargetClosed` |
| Proposal bond | bond amount, proposer reward, intake window (1–30 d); params (target, selector, min, max); receivers | `setTerms`, `setParam`, `setDestinations`, `setAdminReceiver` |
| Voter rewards | voter pool, delegator haircut, delegatee cut | `setParams` |
| Engagement rewards | min epoch interval (1–90 d), minting paused, reward tokens | `setMinEpochInterval`, `setMintingPaused`, `setRewardToken` |
| Engagement token | distributor, minters, minting paused | `setDistributor`, `setMinter`, `setMintingPaused` |

## 17. Leaderboard, referrals, Katana signing
| Contract | Values | Setter |
|---|---|---|
| Leaderboard | buy split (4-way, each ≤ 50%), buy destinations, points allocator, admin receiver | `setBuySplit`, `setBuyDestinations`, `setPointsAllocator`, `setAdminReceiver` |
| Referrals | claim fee + receiver (≤ max) | `setClaimFee` |
| Signature fuse (quests) | message prefix, signers | `setPrefix`, `setSigner` |

## Notes
- **Resolved 2026-09-29:** keeper rewards are the gate's `exec.*` keys (GATE_CONFIG_SPEC §9); the executor has no
  reward settings and cyavKAT no longer uses the Caller Reward Fuse.
- Fee-affecting values (WM fees, fee splits, POL yield fee, Plus profit split admin share, wrapper fees, custody
  revenue share) are fee-authority only via the governance gate (admin-fees rule).
