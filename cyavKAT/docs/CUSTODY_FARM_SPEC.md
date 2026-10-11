# Current V2 Revenue Custody and farm integration — v21

`CurveYieldRevenueCustodyV2` is the V2 asset-management custody at `../upgrade/src/protection/CurveYieldRevenueCustodyV2.sol`. Its assets are held outside IPOR vault PPS accounting. The original live `CurveYieldProfitCustody` at `../deployed/phase1-controller/CurveYieldProfitCustody.sol` keeps its Morpho position and its original configurable internal profit split.

- V2 custody manages Charm farm positions, POL position B, Merkl reward collection, idle-asset allocation and authorized backstop coverage. These are native to V2 custody; there is no separate custody-farm deployment in the current source.
- The V2 custody is deployed through `P5_01_DeployPol.s.sol` and configured for existing-live-custody integration through `P6_01_CustodyV2Migration.s.sol`. **No P6_02 full-unwind transaction exists in this package**.
- The vault executor's growth portion is repointed to V2 custody in Phase 6, once. Its contributors portion uses the existing admin-fee receiver. The executor's four-way split remains independent of the original Profit Custody's own payout split.
- V2's POL budget comes from its explicit `reserveAvkatForPolBps()` operation, not from a per-receipt feeder or external splitter.
- V2 swaps use `CurveYieldSwapRouterV2` with the router's pool-oracle protections. The original Profit Custody uses its retained live routing.
- Fees, ownership, recipients, approved venues and role-specific changes remain subject to the current governance gate and actual deployed configuration; do not trust obsolete addresses or design sketches.

For callable entrypoints and invariants, see `V2_CONTRACT_REFERENCE.md`, `CURRENT_V2_CONTRACT_FUNCTION_REGISTER.md` and the implementation itself. This is source documentation, not a live-chain verification or instruction to broadcast.
