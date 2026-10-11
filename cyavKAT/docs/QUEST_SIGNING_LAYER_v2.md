# REQUIRED cyavKAT V2 Quest Signing Layer — v2

> **Mandatory deployment prerequisite — never skip.** The Quest ERC-1271 signing layer is a
> required component of the cyavKAT V2 upgrade. Do not deploy or configure Phase 2 contracts
> until this migration succeeds and the read-only V2 gate passes against live Katana state.

## Existing factory-deployed contracts: unchanged

```text
Existing original IPOR PlasmaVault (vault address 0xEd83...4548)
  -> its PLASMA_VAULT_BASE remains EXISTING CurveYieldVaultBase1271 wrapper (0x0a9e...b365)
       -> ERC-1271 isValidSignature / isQuestSigner / questSignPrefix
       -> all other fallback selectors delegate to ORIGINAL factory PlasmaVaultBase (0x6D73...4b49)

Existing vault-local ALPHA -> vault.execute -> NEW revised config-only Quest fuse (persistent)
Existing vault-local FUSE_MANAGER -> addFuses / removeFuses
Legacy signing INSTALL/UNINSTALL fuse -> UNREGISTERED on completion, not destroyed
```

**Do not replace the existing on-chain signing wrapper.** It was already deployed and is identified
in `upgrade/deployments/katana-quests.json`. The changes in THIS archive upgrade the **fuse-based
administration layer**, not the original IPOR vault or the already-installed wrapper. Restoring the
vault's base pointer to the original factory base disables vault-address ERC-1271; that operation is
NOT part of V2.

Quest signing is **EIP-191 / ERC-1271 login message validation only**, with a domain/vault-bound
prefix. It is **not** general EIP-712 token permit / Permit2 approval capability.

## REQUIRED source-of-truth file paths — reject older copies

| Exact path in the ZIP | V2 responsibility |
|---|---|
| `upgrade/src/katana/CurveYieldQuestSignerConfigFuse.sol` | **REVISED V2** persistent management fuse. It exposes `QUEST_SIGNING_LAYER_VERSION() == 2`; only its newly compiled deployed address is accepted |
| `upgrade/src/katana/CurveYieldVaultBase1271.sol` | Existing ACTIVE signing wrapper implementation; same on-chain wrapper stays |
| `upgrade/src/katana/CurveYieldSignatureFuse.sol` | **LEGACY** install/emergency rollback code; never leave this fuse registered after migration |
| `upgrade/script/K1_QuestSigning.s.sol` | **REVISED V2** migration and future config script. Old scripts are not V2 inputs |
| `upgrade/script/Phase2Base.s.sol` | Shared mandatory `_requireQuestSigningV2()` preflight checks, imported by deployment stages |
| `upgrade/script/P2_00_VerifyQuestSigning.s.sol` | Separate read-only post-migration acceptance gate |
| `upgrade/deployments/katana-quests.json` | Historic addresses + NEW config-fuse address written by V2 K1; NOT by the old K1 script |

This ZIP deliberately omits `upgrade/out/` and `upgrade/cache/`, so the operator's Foundry
build must use the modified source files. Do not supply cached binaries or `--skip` builds from
older ZIPs. The V2 gate validates the versioned on-chain config fuse even if a stale address
is accidentally recorded in JSON.

There is **no alternate signing deployment path** inside the V2 upgrade. Do not invoke old scripts
in `archive/` or reuse `signatureFuse` as `configFuse`.

## Required ordered process for the EXISTING wrapped cyavKAT (Katana 747474)

Prerequisites: the deployer `0x11b78837cadC8E894F1c6e13fA9f3A085a75FA35` must still hold
vault-local **ALPHA (200)** and **FUSE_MANAGER (300)**, or the deployment must be formally adjusted
for the authorized holder. No IPOR DAO approval is needed. Use a working `KATANA_RPC_URL` and a
`PRIVATE_KEY` matching that deployer; use a fork for rehearsal, not an uncontrolled live broadcast.

1. Run `P0_00_DeployGateConfig` if this gate has not yet been deployed.
2. From **`cyavKAT/upgrade/`**, run the **revised** K1 migration command exactly as shown.
   `QUEST_DETACH_INSTALL=true` is REQUIRED for the vault that already has the wrapper.
3. Inspect transaction receipts; read `katana-quests.json` and ensure its NEW `configFuse` key was
   written. A file change alone does **not** demonstrate on-chain success.
4. Run `P2_00_VerifyQuestSigning`. This checks the active wrapper, unchanged original IPOR base,
   new version-2 config-fuse code and immutable bindings, registration, signer, prefix, invalid-
   signature rejection, and removed legacy installation fuse. If it fails, **stop V2 deployment**.
5. Run `P2_01`, then `P2_02`, then `P2_03`, then `P2_04` as separate scripts/transactions, checking
   the full independent cutover preconditions. These scripts re-run the Quest gate themselves.
6. Follow the remaining ACTIVE V2 scripts in `upgrade/script/`; each configured governance/POL/
   custody/finalization script also re-runs the Quest gate. The governance handover is not permitted
   before signing is in place.

```bash
cd cyavKAT/upgrade
# Only if Phase 0 gate is not deployed yet:
# forge script script/P0_00_DeployGateConfig.s.sol:P0_00_DeployGateConfig --rpc-url "$KATANA_RPC_URL" --broadcast --slow
QUEST_DETACH_INSTALL=true forge script script/K1_QuestSigning.s.sol:K1_QuestSigning \
  --rpc-url "$KATANA_RPC_URL" --broadcast --slow
forge script script/P2_00_VerifyQuestSigning.s.sol:P2_00_VerifyQuestSigning \
  --rpc-url "$KATANA_RPC_URL"
forge script script/P2_01_Deploy.s.sol:P2_01_Deploy --rpc-url "$KATANA_RPC_URL" --broadcast --slow
forge script script/P2_02_ConfigureVault.s.sol:P2_02_ConfigureVault --rpc-url "$KATANA_RPC_URL" --broadcast --slow
forge script script/P2_03_Cutover.s.sol:P2_03_Cutover --rpc-url "$KATANA_RPC_URL" --broadcast --slow
forge script script/P2_04_RemoveV1Fuses.s.sol:P2_04_RemoveV1Fuses --rpc-url "$KATANA_RPC_URL" --broadcast --slow
```

**Why the version identity matters:** previously deployed `CurveYieldSignatureFuse` and any older
`CurveYieldQuestSignerConfigFuse` are not permitted substitutes for the revised version. On an
existing vault with a pre-recorded pre-V2 config, the updated `QUEST_DETACH_INSTALL` migration
installs a NEW version-2 config and unregisters the old config; it preserves current on-chain signer
and prefix storage. If the state doesn't match, the operation reverts rather than silently
reinstalling a new signing wrapper.

`QUEST_REQUIRED_SIGNER` optionally identifies the actual authorized signer **for the gate** when
`katana-quests.json` records an earlier signer that has since been revoked. By default the gate
checks the recorded `signer`; do not set this to an unverified address. The gate rejects a blank
prefix or inactive signer. `QUEST_DEPLOYMENTS` optionally overrides the location of the
`katana-quests.json` record **in both the K1 script and the V2 gate**.

## Exact acceptance requirements (all mandatory)

- Vault `PLASMA_VAULT_BASE()` equals `base1271` recorded in deployments JSON.
- Wrapper's immutable `ORIGINAL_BASE()` equals the live original IPOR base in that record.
- Both original base and wrapper still have contract code; the original factory code is unchanged
  by this deployment.
- New `configFuse` has code, differs from `signatureFuse`, returns
  `QUEST_SIGNING_LAYER_VERSION() == 2`, targets this exact vault/wrapper/base, has market ID 7,
  and is supported by the vault.
- Old `signatureFuse` address is verified as the legacy installation fuse and is **not supported**.
- A named required wallet is an authorized quest signer; prefix is nonempty; the vault implements
  ERC-1271 and rejects invalid signatures. A positive signature check is also included in the
  standalone tests; rehearsal should test one real accepted Katana login signature on the fork.
- IPOR vault/source/baseline is untouched; the wrapper delegates normal base functionality.

## Signer management after V2

Still run the revised `upgrade/script/K1_QuestSigning.s.sol` (no legacy installers):

```bash
QUEST_SET_SIGNER=true QUEST_SIGNER=0xREPLACEME QUEST_SIGNER_ENABLED=true \
  forge script script/K1_QuestSigning.s.sol:K1_QuestSigning --rpc-url "$KATANA_RPC_URL" --broadcast --slow
QUEST_SET_SIGNER=true QUEST_SIGNER=0xREPLACEME QUEST_SIGNER_ENABLED=false \
  forge script script/K1_QuestSigning.s.sol:K1_QuestSigning --rpc-url "$KATANA_RPC_URL" --broadcast --slow
QUEST_SET_PREFIX=true QUEST_PREFIX='domain and vault-bound message prefix' \
  forge script script/K1_QuestSigning.s.sol:K1_QuestSigning --rpc-url "$KATANA_RPC_URL" --broadcast --slow
```

Signer permissions can be revoked or rotated without re-registering the old install fuse. If the
recorded default signer is revoked, update the check to the current signer with
`QUEST_REQUIRED_SIGNER`. Only one Quest mode may be true in a single invocation.

## DO NOT RUN during the normal V2 upgrade

- **Default K1 install**: attempts to install a second wrapper; NOT for this live vault.
- `QUEST_FINISH=true`: old partially installed legacy path; NOT for active wrapped vault.
- `QUEST_UNINSTALL=true`: emergency rollback only; restores base pointer and **disables ERC-1271**.
- Any `K1_QuestSigning` or other deployment path from `archive/`, `deployed/`, a previously
  extracted ZIP, or an old compiled artifact without this versioned config source.

The deployment JSON may be written during Forge's local pre-broadcast simulation; failure during
broadcast can leave stale JSON. Always check successful receipts **and** run `P2_00` against the
live chain after the migration. When governance permissions have already moved away from the
recorded deployer, STOP rather than silently substituting an arbitrary signer.

## Verification status

Source/import/ordering checks: performed for this v2 package. Solidity compilation, Foundry
unit tests, live Katana fork tests, and live deployment/broadcast were NOT executed here.
