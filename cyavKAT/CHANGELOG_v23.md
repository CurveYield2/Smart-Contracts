# cyavKAT signing layer v23 — fee module registration repair

- Fix `upgrade/script/P5_01_DeployPol.s.sol`: after deploying the POL controller and RevenueCustodyV2, register their fee setter selectors using the existing fee Safe through `CurveYieldGovernanceGate.registerAdminFeeCalls`.
- Verify the new registration and `isAdminFeeCall` entries before the ownership handover; keep all fail-closed role and fee checks enabled.
- No modifications to any implementation contract or IPOR library; all other files preserved.
- Supersedes the v22 script that failed P3_05 due to unregistered fee-bearing POL controller.
