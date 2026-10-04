# cyavKAT IPOR Vault

Source for the cyavKAT vault stack on Katana (chain 747474): the contracts live today plus every contract planned
for the next upgrade phase (cyavKAT vault upgrade and the cyavKAT+ vault).

- **cyavKAT**: IPOR Fusion PlasmaVault `0xEd83daf48429cfb2C650Fd721b9241e180fd4548` (asset avKAT).
- **cyavKAT+**: a second IPOR vault (asset cyavKAT) with its loop, deposit router, yield booster and reward layer.

Nothing here has been audited, and nothing in this folder broadcasts a transaction by itself. Scripts dry-run unless
run with `--broadcast`.

## Layout
| Folder | Contents |
|---|---|
| `deployed-stack/` | Sources of the contracts live today (Phase 1): `phase1-controller/` (vault controller v1/v2, strategy and flash-loan fuses, profit custody, withdrawal manager v1, Merkl harvest fuse), `phase1-router/` (Sushi V3 fee router), `phase1-vkat-fuses/` (vKAT voting, conversion, merge and accounting contracts). Addresses are in `docs/CONTRACTS_SHORT_LIST.md`. |
| `next-phase/` | Foundry project for the next phase: `src/` (executor, withdraw manager v2, planner controllers, generic fuses, governance gate and DAO contracts, swap router v2, POL, revenue custody v2 and custody farm, cyavKAT+ stack, wrapper, leaderboard), `script/` (deployment scripts P0 to P9, plus the L* and K1 scripts that built the live lending and quest setup), `test/`, `deployments/` (live address records only). It also contains the live lending, wrapper and quest-signing contracts. |
| `ipor-fusion/` | The IPOR Fusion files `next-phase` compiles, pinned (see `docs/SOURCE_PROVENANCE.md`), plus pinned npm dependencies and forge-std. |
| `docs/` | Design specs, contract lists, fuse inventory, provenance, test plan and test handoff. |

## Build
Foundry, solc 0.8.30, via-IR, `optimizer_runs = 1`, EVM prague.
```
cd next-phase
forge build
FOUNDRY_PROFILE=size forge build src/executor/CurveYieldVaultExecutor.sol src/withdraw/CurveYieldWithdrawalManagerV2.sol
```
The executor and withdraw manager v2 deploy from the `size` profile (EIP-170); everything else from the default profile.

## Tests
`forge test` runs the unit tests. Fork suites need a Katana RPC: `KATANA_RPC_URL=<rpc> bash run-tests.sh [match]`
(or a `.env` next to the script, which is git-ignored). `docs/TEST_HANDOFF.md` lists which tests are written, which
have been run, and which are still missing.

## Deployment order (Katana)
1. `P0_00_DeployGateConfig`, then the size build, then `P2_01_Deploy`, `P2_02_ConfigureVault`, `P2_03_Cutover`, `P2_04_RemoveV1Fuses`.
2. `P3_01` to `P3_04` (governance tokens, DAO, gate core, gate configuration).
3. `P4_01` to `P4_04` (cyavKAT+ vault, stack, rewards), `P5_01_DeployPol` (before P3_05).
4. `P3_05_Handover`, `P4_05_GovernPhase4`, then `P6_01_CustodyV2Migration`, a 15-day delay, `P6_02_CustodyV2Finish`, `P9_FinalizeFeeAuthority`.

## Core invariants
- Vault PPS never drops except for the IPOR management fee.
- Admin fees and fee receivers change only through the fee authority (the fee Safe), never the DAO.
- Every numerical setting lives in the governance gate with an immutable hard cap.
- Every vault swap goes through swap router v2 with a manipulation-resistant minimum.
