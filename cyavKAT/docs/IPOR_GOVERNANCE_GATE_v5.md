# IPOR governance control gate — V5 required deployment authority

## Purpose and non-negotiable architecture

The factory IPOR Vault, PlasmaVaultBase, IporFusionAccessManager, and factory fee contracts
remain deployed, unchanged, and operational. Normal vault calls still use the Quest ERC-1271
wrapper and original factory base. The mandatory Quest **v2** source at
`upgrade/src/katana/CurveYieldQuestSignerConfigFuse.sol` is the only supported configuration
fuse; do not substitute legacy Quest fuses or precompiled bytecode.

The Gate is NEW and IMMUTABLE. Do not use an existing V2/V3 gate address with these scripts.
Existing operating roles OWNER (1), ATOMIST (100), GUARDIAN (2), and all IPOR technical
roles stay in the **original IPOR Access Manager**. One deliberately isolated dedicated
`ADMIN_FEE` role lives in the Gate, because IPOR `ADMIN_ROLE` (0) can override role admins
even when `setRoleAdmin(role,role)` is used. This isolation is necessary for the strong
self-admin-only requirement. It is NOT a second copy of operating governance.

### Default holder and role rotation

Initial holder: **the existing admin-fee receiver Safe**
`0x47623C62f281807D615eeb4A2CEee9d97F9D3C49`. The gate constructor's
`adminReceiver()` remains the initial payout reference; changing ADMIN_FEE membership
**does not** change a recipient address or fee percentage.

The only role reassignment entrypoint is
`gate.transferAdminFeeRole(successor)`; only `gate.adminFeeRoleHolder()` may call it.
There is no IPOR OWNER or admin rescue. Do not assign the role to an address unable
to submit transactions; verify the successor's control first.

### What fee administration can change

- Gate fee-class configuration values via `setConfigs()`; ranges via `setConfigRange()`;
  registered fee arguments via `setArgRange()`; within initial immutable hard limits and rules
- Fee-sensitive `addr.revenueCustody` and `addr.loopProfitSplitter` wiring
- Approved target+selector pairs through `executeAdminFee(target,data)`; all ordinary
  `execute` and `executeGuardian` paths reject protected fee setters
- Admin-fee receivers, percentages, splits, routing and distribution functions in
  factory/custom vault-stack contracts where the Gate actually possesses the target permission

`registerAdminFeeCalls(target,selectors)` is ADMIN_FEE-only and accepts known fee-function
selectors, not arbitrary delegatecall, execute, role management, or ownership selectors.
Every fee-bearing Ownable target must be owned by the Gate for dispatch. For ownerless IPOR
AccessManaged contracts, the **actual factory Access Manager** still decides whether
Gate calls succeed. Roles 901/902 are granted to Gate and removed from initial Safe and
deployer; roles 7/400/500 are technical and must not be granted.

### Preserved Safe OWNER role; factory fee-permission scope

**Required V5 invariant:** the fee-receiving Safe
`0x47623C62f281807D615eeb4A2CEee9d97F9D3C49` retains the native IPOR
Access Manager `OWNER` (role 1) with immediate execution throughout and after
P3_05. P3_03 grants it if missing, P3_05 must preserve and verify it, and P9
independently verifies it. The Safe remains the initial holder of the gate-local
self-administered `ADMIN_FEE` role. This does **not** mean the Safe retains
`owner()` of the custom Ownable modules: those must still transfer to the Gate.

**V5 removes the factory-fee bypass preflight and terminal blocking conditions.**
The IPOR Access Manager can still authorize the Safe or other admins to call
fee setters on the unchanged factory Vault/FeeManager **directly**, outside the
Gate's `executeAdminFee` method. P9 now prints a NOTICE when native permissions
are observed, but does not revert on them. **Therefore exclusive control of
ALL factory fee changes by the Gate cannot be guaranteed while this original
IPOR OWNER permission remains.** The gate-local ADMIN_FEE role remains
self-managed and enforces all fee changes **sent through the Gate**; custom
Ownable fee-bearing modules remain gate-owned. This limitation cannot be fixed
by editing the Gate while leaving the factory contracts and Access Manager
unchanged. Never claim otherwise.

Roles 901/902 remain gate-only after handover; any pre-existing native IPOR
roles beyond that are not automatically revoked. Review actual `canCall`
results and other role holders on a live chain for operational understanding;
they no longer block P3_05 or P9. This version is intentionally an owner-retention
upgrade, **not** a proof of factory-wide fee exclusivity.

### Exact V5 deployment order (existing V4 gate implementation)

Work only from `cyavKAT/upgrade/`; use environment `KATANA_RPC_URL` and the pre-existing
`PRIVATE_KEY`/`DEPLOYER` authorization. The scripts assume the existing fee receiver is a Safe
with the deployer as an owner and threshold **1**; they check this rather than inventing
a signer. Never disclose keys in logs or in the ZIP.

1. `P0_00_DeployGateConfig`: deploy NEW V4 Gate using the current IPOR Access Manager
   and initial fee receiver, register existing fee-config defaults, seal registration
   (seal blocks new fee keys, **not updates to existing FEE values**).
   Default record `deployments/katana-gate-v4.json`.
2. `K1_QuestSigning` with `QUEST_DETACH_INSTALL=true`: the revised V2 signing code,
   keeps wrapper installed, deletes legacy installer fuse, deploys config-only fuse.
3. `P2_00_VerifyQuestSigning`: mandatory read-only live postcondition, repeat as necessary.
4. `P2_01_Deploy` → `P2_02_ConfigureVault` → `P2_03_Cutover` →
   `P2_04_RemoveV1Fuses` where applicable to the actual chain state.
5. `P3_03_DeployGovernanceCore`: verify existing factory roles and the initial fee holder.
6. `P3_04_ConfigureGate`: register hard-denied ordinary selectors and allowlisted
   **ADMIN_FEE** selectors for factory vault, fee manager, old/new withdraw managers,
   custom router/splitter, live custody and wrappers, and both POL feeders.
7. `P5_01_DeployPol`, when required, BEFORE handover: register POL controller/yield feeder
   and new custody fee setters with `ADMIN_FEE` lane.
8. **Verify the fee Safe holds IPOR OWNER (role 1)**. P3_03 grants the role if
   missing; P3_05 also preserves and validates it. An informational factory-fee
   permission review is recommended but is **not an upgrade-blocking preflight**.
9. `P3_05_Handover`: transfer **all** identified fee-capable Ownable custom/live contracts
   to Gate; only Gate receives native IPOR fee roles 901/902; revoke Safe/deployer's role
   901/902. Leave technical IPOR roles unchanged.
10. `P6_01_CustodyV2Migration` if applicable; it routes fee operations through
    `executeAdminFee` and non-fee maintenance through the native IPOR-owned gate lanes.
    The discontinued `P6_02` full-unwind script is not supplied; the current migration preserves the live loop.
11. `P9_FinalizeFeeAuthority` read-only postconditions: validates fee Safe retains
    IPOR OWNER, native fee roles 901/902 are held by Gate, and logs any direct
    fee permissions of the Safe without failing the upgrade.

Example mandatory commands (run from `cyavKAT/upgrade/`):

```bash
forge script script/P0_00_DeployGateConfig.s.sol:P0_00_DeployGateConfig --rpc-url "$KATANA_RPC_URL" --broadcast --slow
QUEST_DETACH_INSTALL=true forge script script/K1_QuestSigning.s.sol:K1_QuestSigning --rpc-url "$KATANA_RPC_URL" --broadcast --slow
forge script script/P2_00_VerifyQuestSigning.s.sol:P2_00_VerifyQuestSigning --rpc-url "$KATANA_RPC_URL"
forge script script/P2_01_Deploy.s.sol:P2_01_Deploy --rpc-url "$KATANA_RPC_URL" --broadcast --slow
forge script script/P2_02_ConfigureVault.s.sol:P2_02_ConfigureVault --rpc-url "$KATANA_RPC_URL" --broadcast --slow
forge script script/P2_03_Cutover.s.sol:P2_03_Cutover --rpc-url "$KATANA_RPC_URL" --broadcast --slow
forge script script/P2_04_RemoveV1Fuses.s.sol:P2_04_RemoveV1Fuses --rpc-url "$KATANA_RPC_URL" --broadcast --slow
forge script script/P3_03_DeployGovernanceCore.s.sol:P3_03_DeployGovernanceCore --rpc-url "$KATANA_RPC_URL" --broadcast --slow
forge script script/P3_04_ConfigureGate.s.sol:P3_04_ConfigureGate --rpc-url "$KATANA_RPC_URL" --broadcast --slow
# If required, run P5_01_DeployPol BEFORE P3_05, with POL preconditions.
forge script script/P3_05_Handover.s.sol:P3_05_Handover --rpc-url "$KATANA_RPC_URL" --broadcast --slow
# Only if required and preconditions met: P6_01_CustodyV2Migration
forge script script/P9_FinalizeFeeAuthority.s.sol:P9_FinalizeFeeAuthority --rpc-url "$KATANA_RPC_URL"
```

Scripts are NOT atomic as a group. Confirm receipts and on-chain state between stages.
A legacy V3 gate cannot be repurposed simply by changing a JSON record; existing consumers
must be migrated explicitly after fork validation. This ZIP does not contain evidence
of any live on-chain migration or successful Solidity compile.
