# Current governance-gate configuration authority — v21

The former 2026-09-29 gate design included deprecated DAO, leaderboard, LP and feeder settings and must not be used to configure this V2 deployment.

**Use instead:**

- [`IPOR_GOVERNANCE_GATE_v5.md`](IPOR_GOVERNANCE_GATE_v5.md) for the gate's self-administered `ADMIN_FEE` role, fee-Safe ownership and handover rules.
- [`IPOR_FUSE_CONFORMANCE_SPEC.md`](IPOR_FUSE_CONFORMANCE_SPEC.md) for vault fuse/substrate requirements.
- `../upgrade/script/P0_00_DeployGateConfig.s.sol` for actual supported numeric keys, hard caps and registered access lanes.
- `../upgrade/src/governance/CurveYieldGovernanceGate.sol` for the enforced selector and role semantics.
- `../upgrade/script/P3_04_ConfigureGate.s.sol` / `P3_05_Handover.s.sol` for configuration and transfer conditions.
- `../upgrade/script/P6_01_CustodyV2Migration.s.sol` for the **single** fee-authority growth destination change to V2 custody.

No removed POL feeder, legacy external splitter, Plus, leaderboard, or Aragon configuration may be reintroduced. The original Profit Custody's internal payout logic is unchanged.
