> **V21 current authority:** `CHANGELOG_v21.md`, `docs/CONTRACTS_SHORT_LIST.md` and current `upgrade/src`/`upgrade/script`. Executor four-way 35/20/20/25 split retained: contributors go to existing `ADMIN_FEE_SAFE`; growth goes to V2 Revenue Custody after a single Phase 6 repoint. Original Profit Custody keeps its internal split and existing fee recipient. The existing wrapper 40/30/30 splitter remains. Discontinued contracts, unsafe legacy migration scripts and stale dry-run manifests have been removed. No compile/fork/broadcast was performed during this cleanup.

# cyavKAT IPOR Vault — mandatory V2/Quest upgrade with V6 fuse-conformance controls and V5 Safe-owner-preserving governance

Existing Katana IPOR Fusion PlasmaVault: `0xEd83daf48429cfb2C650Fd721b9241e180fd4548` (avKAT).
**Every original IPOR factory-deployed contract remains deployed, unmodified and in use.** The existing CurveYield
ERC-1271 wrapper remains the vault's active base, and forwards ordinary base calls to the original IPOR base.

## Actual package layout

| Path | Purpose |
|---|---|
| `upgrade/` | **ACTIVE** Foundry project: revised signing fuse, V2 scripts, contracts, tests and deployment records |
| `deployed/` | Original retained live-stack source snapshots; **NOT** V2 deployment scripts or test root |
| `ipor-fusion/` | Pinned original IPOR source and dependencies; never modified by these edits |
| `docs/QUEST_SIGNING_LAYER_v2.md` | **Authoritative required signing step**, commands, failure conditions, on-chain postconditions |
| `docs/IPOR_GOVERNANCE_GATE_v5.md` | **Authoritative V5 Safe OWNER role, fee authority and deployment guide** |
| `docs/IPOR_FUSE_CONFORMANCE_SPEC.md` | IPOR fuse conformance and migration acceptance criteria (V6 work status at end) |
| `docs/fuses/` | Six custom-fuse family implementation/exception READMEs |
| `upgrade/scripts/merkl_preflight_v6.py` | M3 claimability gate: queries both cyavKAT and RCM, issues anchored receipt |
| `docs/PROVENANCE_VERIFICATION_v6.md` | Source pin and live bytecode equivalence verification steps |
| `CHANGELOG_v6.md` | Implemented v6 changes and unfulfilled runtime acceptance criteria |

Foundry root: **`cyavKAT/upgrade/`**. No deployment command should be run from `deployed/`; retired `archive/` is not packaged.

## REQUIRED Katana V2 sequence (Quest signing is NOT optional)

1. **`P0_00_DeployGateConfig` (V4 gate implementation, V5 handover), required for this migration.** Only reuse a gate if
   live checks prove it is the NEW IPOR-role-backed implementation and its fee registry is sealed.
   V2 gate contracts are not upgradeable in place; do NOT point this V5 package at an old gate.
2. **`K1_QuestSigning` using the REVISED source at `upgrade/script/K1_QuestSigning.s.sol`, with
   `QUEST_DETACH_INSTALL=true` for this already-wrapped cyavKAT**. It deploys/retains the **V2**
   `CurveYieldQuestSignerConfigFuse` (version marker `QUEST_SIGNING_LAYER_VERSION() == 2`), preserves
   the existing `CurveYieldVaultBase1271` and original factory base, and unregisters the legacy
   `CurveYieldSignatureFuse` installation fuse. This step is **mandatory before P2_01**.
3. **`P2_00_VerifyQuestSigning`** — required read-only chain-state gate. It checks the on-chain V2
   config fuse, active wrapper, original IPOR base, nonempty prefix, authorized signer, and detached
   legacy installer. It does NOT accept a JSON record without matching live code and configuration.
4. `P2_01_Deploy`, `P2_02_ConfigureVault`, `P2_03_Cutover`. **Before `P2_04`, run the new mandatory
   M3 Merkl preflight**, confirm neither vault nor RewardsClaimManager has claimable rewards and export the
   block-anchored `MERKL_PREFLIGHT_RECEIPT_PATH`. Only then run `P2_04_RemoveV1Fuses`. A stale / wrong-chain
   receipt is rejected. `MERKL_ACK_PENDING=true` acknowledges pending but *not yet claimable* rewards only.
5. **Required V5 governance order:** `P3_03` (verify native IPOR roles and initial ADMIN_FEE holder),
   `P3_04` (register every fee setter for gate-only fee execution), `P5_01` if applicable (POL
   deployment plus ADMIN_FEE registration), `P3_05` (transfer all fee-capable Ownable contracts
   to gate and IPOR fee roles 901/902 exclusively to gate), then `P6_01` if applicable,
   followed by `P9` (read-only on-chain fee-role verification). `P6_02` was removed from this package for the
   no-unwind custody migration and MUST NOT be part of the default deployment.
   Each post-Quest script independently enforces the mandatory Quest verification.
   Any additional dependent phase not supplied in `upgrade/script/` requires its own separately
   reviewed deployment instructions. **Archived P3/P4 scripts are not an implicit authorization to run them.**

**On-chain prerequisite:** the executing account must still have vault-local `ALPHA` (200) and
`FUSE_MANAGER` (300) rights for the K1 migration. No IPOR DAO approval is needed if those roles are
held, but governance handover may have changed who controls them. Do **not** start V2 if that prerequisite
or the signing gate fails. P3_05 handover must happen only after signing is verified.

### Exact commands for the existing wrapped vault

Set `KATANA_RPC_URL` to a working Katana RPC endpoint and `PRIVATE_KEY` to the intended existing
`DEPLOYER` key, with the required vault-local roles. Do not place the private key in the ZIP.

```bash
cd cyavKAT/upgrade
# Step 1: REQUIRED NEW V4 gate. NEVER reuse the V2 or V3 fee-isolation gate.
forge script script/P0_00_DeployGateConfig.s.sol:P0_00_DeployGateConfig \
  --rpc-url "$KATANA_RPC_URL" --broadcast --slow
# Step 2: MUST use the REVISED K1 script from this ZIP (do not use older/deployed copies).
QUEST_DETACH_INSTALL=true forge script script/K1_QuestSigning.s.sol:K1_QuestSigning \
  --rpc-url "$KATANA_RPC_URL" --broadcast --slow

# Step 3: REQUIRED read-only on-chain gate AFTER the signing transactions are confirmed.
forge script script/P2_00_VerifyQuestSigning.s.sol:P2_00_VerifyQuestSigning \
  --rpc-url "$KATANA_RPC_URL"

# This package defaults to deployments/katana-gate-v4.json (NOT the old V2/V3 file).
# Keep PHASE0_DEPLOYMENTS consistently unset or set to the SAME absolute V4 JSON path
# for every script. Reusing a legacy V2/V3 gate is unsupported; do not reuse its address.
# Step 4: V2 migration. Every script independently re-checks REQUIRED signing on chain.
forge script script/P2_01_Deploy.s.sol:P2_01_Deploy --rpc-url "$KATANA_RPC_URL" --broadcast --slow
forge script script/P2_02_ConfigureVault.s.sol:P2_02_ConfigureVault --rpc-url "$KATANA_RPC_URL" --broadcast --slow
forge script script/P2_03_Cutover.s.sol:P2_03_Cutover --rpc-url "$KATANA_RPC_URL" --broadcast --slow
# M3 is REQUIRED, fail-closed on API/RPC errors or immediately claimable rewards.
python3 scripts/merkl_preflight_v6.py --rpc-url "$KATANA_RPC_URL" --out deployments/merkl-preflight-v6.json
export MERKL_PREFLIGHT_RECEIPT_PATH=deployments/merkl-preflight-v6.json
# If pending Merkl rewards are reported, review and explicitly export MERKL_ACK_PENDING=true.
forge script script/P2_04_RemoveV1Fuses.s.sol:P2_04_RemoveV1Fuses --rpc-url "$KATANA_RPC_URL" --broadcast --slow

# Governance V5 (P3_04 and applicable P5_01 fee allowlisting MUST precede P3_05):
forge script script/P3_03_DeployGovernanceCore.s.sol:P3_03_DeployGovernanceCore --rpc-url "$KATANA_RPC_URL" --broadcast --slow
forge script script/P3_04_ConfigureGate.s.sol:P3_04_ConfigureGate --rpc-url "$KATANA_RPC_URL" --broadcast --slow
# If using POL: run P5_01_DeployPol (requires its separately configured venue prerequisites).
forge script script/P3_05_Handover.s.sol:P3_05_Handover --rpc-url "$KATANA_RPC_URL" --broadcast --slow
# If using new revenue custody: run P6_01_CustodyV2Migration after handover.
forge script script/P9_FinalizeFeeAuthority.s.sol:P9_FinalizeFeeAuthority --rpc-url "$KATANA_RPC_URL"
```

**Not a single atomic upgrade:** each `forge script` is a separate series of transactions; confirm
successful receipts and postconditions before the next step. Run the full V2 upgrade on a fork
first. `P2_03_Cutover` has additional withdrawal-manager and vKAT preconditions and MUST NOT be
broadcast just because the signing gate passes. `P2_00` is read-only and does not need `--broadcast`.

**No precompiled `upgrade/out/` or `upgrade/cache/` artifacts are shipped in this v6 ZIP.**
Forge must compile the revised signer-config code from `upgrade/src/katana/`, not a stale binary.
Do not add `--skip` or manually supply old JSON bytecode artifacts. No compilation is performed
when preparing this ZIP; compilation is an operator prerequisite before live deployment.

The older `upgrade/deployments/katana-quests.json` intentionally has **no** `configFuse` until K1
completes. Its existing `base1271`, `originalBase` and `signatureFuse` identify the **existing live**
wrapper, original IPOR factory base and **legacy** installer; these are NOT substitute addresses for
new `CurveYieldQuestSignerConfigFuse`. The K1 script writes the new config address to this record;
then `P2_00` verifies its actual state on chain. If an earlier config fuse is recorded, K1 replaces
it with the revised version and unregisters the old one. Back up JSON before broadcasting: Forge
may write JSON during the simulation phase even if later broadcasts fail; **only chain-state checks
and confirmed receipts establish successful deployment**.

`QUEST_UNINSTALL=true` is **emergency rollback ONLY** and makes the V2 Quest gate fail, disabling
signatures at the vault address. For this vault, **do not** run default K1 install, `QUEST_FINISH`,
`QUEST_UNINSTALL`, or any legacy deployment script as part of the normal V2 upgrade.

## Build and tests

`upgrade/foundry.toml`: Solidity 0.8.30; optimized via IR. The default build profile is used for the executor and withdraw manager V2;
there is no separate `size` profile in the supplied `foundry.toml`. Both must
remain below EIP-170's 24,576-byte limit at the actual compiler settings. Build and test against the supplied
pinned source, e.g., `forge test --match-contract QuestSigningLayerTest` inside `upgrade/`.
No build, fork test, or live broadcast has been executed as part of preparing this archive. The new v6 source checks are not a substitute for those tests.

## Core invariants and limits of V5

- IPOR factory PlasmaVault, original `PlasmaVaultBase`, Access Manager and Fee Manager are unchanged.
- **Quest signing V2 remains mandatory**, using the revised `K1_QuestSigning` migration and independent
  `P2_00_VerifyQuestSigning` gate. Never run the old installer or uninstall the signing wrapper.
- Original IPOR roles remain under their original Access Manager; the **one new `ADMIN_FEE`
  authority is a single, self-managed gate role**, because the IPOR Access Manager's `ADMIN_ROLE`
  can override a role's declared administrator. Its default holder is the existing
  `ADMIN_FEE_SAFE` address (`0x47623C62f281807D615eeb4A2CEee9d97F9D3C49`).
- **Only `transferAdminFeeRole(newHolder)` called by the current role holder can replace it.**
  This does not change the payout recipient. No IPOR OWNER, ATOMIST, guardian, or admin can
  reassign that gate-local role. Protect the fee Safe; there is no forced recovery of a lost role.
- Fee-class `setConfigs`, `setConfigRange`, fee-class `setArgRange`, fee-sensitive wiring
  and explicitly registered fee setters use only the `ADMIN_FEE` lane. Ordinary gate operators
  cannot execute fee selectors. All rate and split changes remain bounded by fixed hard caps.
- Fee-capable `Ownable` modules (including live router and custody) must be **owned by the gate**,
  not directly by the fee Safe. IPOR fee roles 901 and 902 move to the gate and are revoked from
  Safe/deployer. IPOR technical roles 7, 400, 500 are never granted to the gate.
  **The fee Safe retains IPOR OWNER role 1 (zero delay), before and after P3_05**;
  it does not retain `owner()` of custom modules being transferred to the gate.
- **Factory-level exclusivity is not enforced when native IPOR OWNER is retained.**
  The fee Safe keeps its IPOR OWNER authority, including any direct factory fee-setter
  permissions already granted to that role. P3_05 no longer blocks on such permissions;
  P9 reports them as informational notices instead of reverting. The separate self-managed
  gate ADMIN_FEE role still restricts calls *through the gate*, and the gate still owns
  fee-bearing custom contracts. **Do not describe native factory fee functions as
  exclusively gate-controlled while this Safe retains any direct native permissions.**
- New or unsupported contract fee setters MUST be security-reviewed and added to the gate
  selector allowlist before handover. The allowlist protects only known registered methods.
- A deployed V2/V3 gate cannot be rewritten in place; replacing an installed gate requires
  a separate consumer-by-consumer `configGate` and ownership migration with fork tests.

Full required deployment guidance: [`docs/IPOR_GOVERNANCE_GATE_v5.md`](docs/IPOR_GOVERNANCE_GATE_v5.md)

No local compilation, fork simulation, or transaction broadcast was performed while
assembling this version. Existing on-chain contracts are unchanged.

## V6 conformance scope and Windows PowerShell migration step

The V6 fuse code adds `enterTransient` / `exitTransient` to the custom guard,
request-fee escrow and generic new-vault ERC-1271 fuses; adds explicit unsupported
exit-transient paths to transfer/burn fuses; and enforces `MARKET_ID != 0` for
the custom Balancer balance fuse. The **live** Quest signature configuration remains
`CurveYieldQuestSignerConfigFuse` V2 (mandatory and unchanged). These changes do
not replace the original IPOR factory contracts or alter the Safe's IPOR OWNER role.

For Windows PowerShell, run from `cyavKAT\upgrade` immediately after P2_03:

```powershell
python scripts/merkl_preflight_v6.py --rpc-url $env:KATANA_RPC_URL --out deployments/merkl-preflight-v6.json
$env:MERKL_PREFLIGHT_RECEIPT_PATH = 'deployments/merkl-preflight-v6.json'
forge script script/P2_04_RemoveV1Fuses.s.sol:P2_04_RemoveV1Fuses --rpc-url $env:KATANA_RPC_URL --broadcast --slow
```

Merkl claimability is `amount - claimed` (**not** `pending`). If positive for
**either** account, the script stops without creating a receipt: claim first
through the existing supported reward path, rerun preflight, then proceed. The
receipt is valid for at most 200 Katana blocks; the M4 script checks the actual
canonical hash on chain. Do not bypass this check or use a fork-created fixture
in production. An API response can change between preflight and broadcast;
re-run the preflight as close to the transaction as possible.

**Outstanding release blockers:** the live v1 withdrawal manager has had open
requests, so `P2_03` will not pass until they are fulfilled; missing runtime
bytecode equivalence proof; compilation and fork tests of the v6 changes; and the
full conformance/economic equivalence scenarios listed at the end of
`IPOR_FUSE_CONFORMANCE_SPEC.md`. These are not silently cleared by this ZIP.

## V17 wrapper fee routing — current V2 deployment authority

Keep deployed `CurveYieldWrappedCyavKat`, `CurveYieldWrapperFeeSplitter`, the live 12% haircut oracle and current Morpho lending market.
**Do not deploy a second wrapper splitter, burn forwarder, replacement wrapper or replacement Morpho market.**
The deployed fee splitter is fixed at **40% admin, 30% V2 revenue custody, 30% WM V2 for burning**.
Run `P5_01_DeployPol` BEFORE the `P3_04`/`P3_05` governance handover so the new custody is gate-owned, and run
`L10_RouteWrapperFeesToCustodyV2.s.sol` AFTER `P2_03_Cutover`, P5_01, P3_04 and P3_05.
The script uses the fee Safe's ADMIN_FEE lane, validates on-chain custodian/WM addresses and preserves admin receiver.
The custody receives **cyavKAT shares**, not avKAT. They are **not** fed to any IPOR balance fuse or counted in the
main vault's PPS; unredeemed shares are also excluded from custody farm allocation calculations. An operator may
`redeemWrapperRevenue(shares, minimumAvkatOut)` into custody-held avKAT (ordinary vault liquidity/withdrawal fees apply).
`deployAll()` then deploys available avKAT into the existing loop/farm. Alternatively, call
`reserveAvkatForPolBps(bps)` to earmark avKAT for off-books POL B and then `polDeploy()`.
No new wrapper, splitter, market, or vault accounting channel is created.
The original 40/40/20 distribution is **not** feasible with the unchanged splitter and has been superseded by 40/30/30.
No live transaction has been broadcast.
