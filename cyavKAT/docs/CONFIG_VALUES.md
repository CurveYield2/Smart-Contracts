# Current V2 configurable values — v21

The former all-phase registry listed retired vKAT, Plus, POL feeder, DAO and LP settings as current. Do not use those values for transaction construction. The **enforced configuration** comes from:

1. `../upgrade/script/P0_00_DeployGateConfig.s.sol`: gate key defaults, hard caps, rule groups and authorization classes.
2. `../upgrade/src/governance/CurveYieldGovernanceGate.sol`: role restrictions and allowed changes.
3. `../upgrade/script/P3_04_ConfigureGate.s.sol`: gate substrate / selector configuration.
4. `../upgrade/script/P6_01_CustodyV2Migration.s.sol`: post-deployment V2 custody destination configuration.
5. Original live Profit Custody `../deployed/phase1-controller/CurveYieldProfitCustody.sol`: unchanged independent wind-up / fee-recipient settings.

The executor retains its four-way default split **35/20/20/25** (growth/admin receiver/vault retention/rewards manager). Growth is repointed **once** in P6 after V2 custody deployment, not separately in Phase 2. V2 custody has no external POL feeder. The wrapper retains its existing **40/30/30** shares and L10 routes the contributors-labelled portion to V2 custody.

Read on-chain state before submitting changes; a source default or old deployment receipt is not live state.
