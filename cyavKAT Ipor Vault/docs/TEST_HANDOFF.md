# cyavKAT test package: successor handoff (2026-10-03)

## What is in this zip
| Folder | Stack | Contents |
|---|---|---|
| `deployed-stack-pre-standardization/test/` | **Current stack** (live on Katana, `deployments/katana-phase2.json`, built from the pre-standardization src of 2026-09-27) | The old fork, governance, wrapper, quest, migration, Plus and leaderboard tests. They compile against `_pre-standardization-2026-09-27/src`, **not** against the current `phase2/src`. |
| `next-stack-phase2/test/` (+ `foundry.toml`, `run-tests.sh`) | **Soon-to-be-deployed stack** (current `phase2/src`: standardized fuses, planners, guard fuse, gate wiring) | Everything written or adapted since the standardization. |
| `specs/` | n/a | TEST_PLAN, CUSTODY_FARM_SPEC, POL_SPEC, FUSE_STANDARDIZATION_SPEC, GATE_CONFIG_SPEC, PPS_PROTECTION_SPEC, SWAP_ROUTING_SPEC. |

The StakeDaoHarvester suite (`stakedao-harvester/contracts/test/`, 23/23 passing) is a separate project and is not in this zip.

To use: drop `test/` back into the matching repo (`work\phase2\test` for the next stack; for the deployed stack the tests need the pre-standardization src and scripts alongside them).

## Rules (unchanged)
- Never broadcast. Never read `Documents\Codex\deployer_key.txt`. Never print keys from `.env`.
- RPC is `KATANA_RPC_URL` from `Desktop\Claude\.env` (private dRPC). Runner: `bash run-tests.sh [match] [trace]` from `work\phase2`.
- Never edit `src/` or `script/` to make a test pass. A test that exposes a contract bug is reported with the test name and trace.
- Executor and WM v2 are deployed from the size profile: `FOUNDRY_PROFILE=size forge build src/executor/CurveYieldVaultExecutor.sol src/withdraw/CurveYieldWithdrawalManagerV2.sol` before any fork setup that runs P2_01.
- PPS invariant everywhere: assets per share never drops except for the IPOR management fee (treat it as a flat one-off allowance, not time-proportional).
- Tests write only to `deployments/test-*.json`, never `katana-*.json`.

## Next stack (`next-stack-phase2/test`): status

### Written by me this session, and run
| File | Tests | Last result |
|---|---|---|
| `governance/GovernanceGate.t.sol` | 24 | passed (includes the new revoke/renounce-targeting-the-gate test) |
| `governance/GateConfigRegistry.t.sol` | 32 | passed |
| `governance/GateConfigBase.t.sol` | 4 | passed |
| `router/SwapRouterV2.t.sol` (+ mocks) | 17 | passed |
| `withdraw/WithdrawalManagerV2.t.sol` (+ mocks) | 24 in file | passed in Job 1 (102/102 total for Job 1 when it was run on 2026-09-30) |

These were last run before the 2026-10-03 src changes. **Re-run them**, no fork needed: `forge test --match-path "test/governance/*" ` and the router / withdraw folders.

### Written by me, run only partially
- `plus/PlusFork.t.sol` (15 scenarios, one test `test_plus`, Katana fork). Last full run was 12/15. After that I made three fixes and did not complete a re-run (a run started 2026-10-03 was stopped by the user after more than 10 minutes):
  1. renamed scenario 5f and fixed the stale driver selector (`s5f_windupSettlesTheAccruedSplitFirst`);
  2. scenario 6 now compares the **equity** drop with `maxInstantOut()` (gross collateral is about 3.3x larger at 70% LTV);
  3. scenario 9 pps check has a flat 0.1% allowance for the management fee.
  Scenario 3 tolerates up to 5 bps of idle cyavKAT left after windup (preview-vs-actual rounding of two chained ERC4626 previews) and 0.1% PPS drop (management fee). Run it with `RAYON_NUM_THREADS=2`; it takes more than 10 minutes, so run it in the background.
- A src ABI-encoding bug (flat args encoded for a tuple with a dynamic `bytes` field) was found by this suite and fixed in src by the peer session. Sites: `_flash` in `CurveYieldPlusLoopController`, `CurveYieldBundleGuardFuse.wrap/wrapWithGain`, and three Balancer enter/exit sites plus TryElse enter in `CurveYieldPolController`. Only the Plus `_flash` site is exercised by a test today (see gaps).

### Written by the peer session (status unknown to me, I did not run these)
`fork/Phase2Fork.t.sol` (about 27 scenarios, covers Job 2 items 1 to 7), `fork/Phase2GovFork.t.sol` (g1 to g7), `fork/UsdcSupplyLoopFork.t.sol` (u0 to u7), `governance/GateWiring.t.sol` (9), `withdraw/OnboardingFee.t.sol` (10), `leaderboard/Leaderboard.t.sol` (29), `Referrals.t.sol` (14), `TieredFuzz.t.sol` (2). Helpers: `helpers/Phase2ForkBase.sol`, `helpers/LendingForkSetup.sol`, `leaderboard/LbBase.sol`.

## Still to RUN
1. Next stack: every file above, in this order: unit (no fork) first, then `Phase2Fork`, `Phase2GovFork`, `UsdcSupplyLoopFork`, `PlusFork`. Report pass/fail counts and any behaviour that contradicts the specs.
2. Deployed stack: the whole `deployed-stack-pre-standardization/test` set as a regression check against the live stack. I have no record of when these last ran. They include `Phase2Fork`, `Phase2EdgeFork`, `MigrationFork`, `MigrationEdgeFork`, `LendingV1Fork`, `QuestSigningFork`, `WrapperFork`, the governance, Engagement, Voter, Proposal-bond and Voting-lock tests, `plus/PlusFork`, `PlusRewardsFork` and `Phase4GovernanceFork`.
3. Check which deployed-stack tests are still needed after the cutover and port those that cover contracts that survive in the next stack (see below).

## Still to MAKE (nothing below exists yet)
Job 2 (main-vault fork suite, TEST_PLAN):
1. **Guarded executor bundle, end to end**: deploy and rebalance through `snapshot -> generic fuses -> guard` (`CurveYieldBundleGuardFuse`), including the guard's failure paths (PPS drop, LTV, min idle, min profit). Required by the peer because of the ABI-encoding bug class.
2. **POL end to end (after `P5_01`)**: enter, exit, buyback (only if PPS strictly rises by at least `minGain`), lifetime budget, POL-funded fulfilment. This also exercises the three fixed Balancer/TryElse encoding sites in `CurveYieldPolController`.
3. Job 2 item 3: `MerklClaimFuse` added as a reward fuse, and the swap-fuse-v2 sweep with a token that has no route (`RewardSweepSkipped`). Check whether `Phase2Fork` s3 already covers them before writing.
4. Job 2 item 9 gaps: confirm `Phase2GovFork` covers router v2 `setFeeRecipient` as protected, and that guardian ranges are enforced for executor and controllers; add what is missing.
5. Job 2 item 1: confirm keeper reward is also bounded by the PPS gain on deploy (`s1b` checks the gate cap).

Job 3 (cyavKAT+, Plus stack `P4_*`):
6. **Custody v2 and custody farm fork tests** per `CUSTODY_FARM_SPEC.md`: loop target `custody.loopTargetBps` (30 to 80%, default 60%), `deployAll()` order (top up the loop, then spread the remainder over active farm positions in proportion to value, swaps through router v2 with protected minimums), Charm `deposit`, Sushi V3 `increaseLiquidity` with unstake and restake, operator and allowlist rules (fee-authority-only), Merkl claims, custody as the emergency backstop.
7. Plus emergency-fee arm fuse (D3: cyavKAT+ exempt from the cyavKAT instant fee only while deleveraging above its LTV).
8. Plus executor and rewards: `PlusRewardsFork` and `Phase4GovernanceFork` exist only for the old stack and need porting.
9. Leaderboard and referrals: confirm the tests cover "buy split locked during a season".

Unit tests for the new generic fuses (no fork, mocks, fast; these would have caught the encoding bug):
10. `CurveYieldBundleGuardFuse`, `CurveYieldPlannedInstantWithdrawFuse` (params `[amount, planner]`, clamp to `maxInstantOut()`, try/catch never reverts), `BurnHeldSharesFuse`, the Ve fuse set, `CurveYieldPolController` and `CurveYieldPlusLoopController` plan builders. Assert the ENCODED calldata against the real fuse struct (decode it with the struct type), not only that the call succeeds.
11. `CurveYieldCustodyFarm` unit tests (allowlists, operator rules, accounting).

## Traps already hit (do not repeat)
- `vm.prank` / `vm.expectRevert` are consumed by the next call, including a nested view call used to build an argument. Compute arguments into locals first and use literal constants instead of `gate.CLASS_FEE()`-style getters.
- `releaseActiveShares(timestamp_)` needs `request time < timestamp_ < block.timestamp`: warp **2** seconds, not 1.
- `abi.encodeWithSignature("fn((T1,T2))", a, b)` gets the selector right but encodes flat args; wrong for tuples with dynamic fields. Use `abi.encodeCall` with the struct.
- Mocks must match the real selector: a single-field struct argument changes the selector (`enter((uint256))` vs `enter(uint256)`).
- Fork gas is path-dependent: after a sub-call reverts, later calls pay cold costs again, so a "both succeed" gas probe under-measures calls that follow a reverted one.
- Never call a state-changing view-looking function (Curve gauge `claimable_tokens`) as a probe before a real harvest on a fork, and not through a `view` interface (it reverts with `StateChangeDuringStaticCall`).
- Fork runs are slow: use `RAYON_NUM_THREADS=2`, run in the background, and let `run-tests.sh` pick `FORK_BLOCK = head - 30`.
- `phase2` has no `.env`; `run-tests.sh` reads `KATANA_RPC_URL` from `Desktop\Claude\.env` itself.
