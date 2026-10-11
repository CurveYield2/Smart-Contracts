# Current cyavKAT contract inventory — v21

**Active implementation authority:** `../upgrade/src/` and `../upgrade/script/`. This summary lists source kept for the V2 upgrade; code presence alone does **not** prove deployment. The live-phase snapshots retained under `../deployed/phase1-*` are original contract sources, not new deployment entrypoints.

| Function | Contract(s) / source |
|---|---|
| Vault operations and four-way loop-profit allocation | `upgrade/src/executor/CurveYieldVaultExecutor.sol` |
| Delegated vault strategy planning | `upgrade/src/morpho/`, `upgrade/src/lend/`, `upgrade/src/allocation/`, `upgrade/src/pol/` |
| Revenue, farming, POL B and loss coverage | `upgrade/src/protection/CurveYieldRevenueCustodyV2.sol` |
| Original loop and independently configured profit distribution | `deployed/phase1-controller/CurveYieldProfitCustody.sol` (unchanged) |
| Protected Sushi/Balancer routing | `upgrade/src/router/CurveYieldSwapRouterV2.sol` |
| Withdrawals / fee-share requests | `upgrade/src/withdraw/` |
| POL A balance and liquidity operations | `upgrade/src/generic/` and official IPOR Balancer fuses |
| Governance/fee permissions | `upgrade/src/governance/` |
| Wrapper fees | `upgrade/src/wrapper/` (retains existing splitter) |
| Vault and official fuses | `ipor-fusion/` (pinned upstream source) |

The executor's existing split remains **35% growth / 20% admin fee receiver / 20% vault retention / 25% rewards manager** by default. The growth destination switches once to V2 Revenue Custody in Phase 6; the original Profit Custody's own fee split and direct fee recipient remain untouched. The pre-existing wrapper split remains 40/30/30 after L10.

For a detailed current interface inventory, see `CURRENT_V2_CONTRACT_FUNCTION_REGISTER.md` and `V2_CONTRACT_REFERENCE.md`. Do not use removed pre-V2 deployments or obsolete fork manifests to prepare transactions.
