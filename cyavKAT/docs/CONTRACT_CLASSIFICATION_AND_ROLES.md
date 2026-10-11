# Current contract classification and roles — v21

| Category | Source of truth | Role |
|---|---|---|
| Existing IPOR PlasmaVault | `../ipor-fusion/contracts/vaults/` | Vault asset/share accounting and IPOR execution |
| Custom vault executor | `../upgrade/src/executor/` | Plans and executes approved vault actions, including its existing four-way profit split |
| Original live Profit Custody | `../deployed/phase1-controller/CurveYieldProfitCustody.sol` | Original Morpho position and independent reward/fee-recipient allocation; source unchanged |
| V2 Revenue Custody | `../upgrade/src/protection/` | Receives executor growth after Phase 6 and wrapper share after L10; operates Charm farms / POL B and loss cover outside PPS |
| Vault POL A | `../upgrade/src/pol/` and `../upgrade/src/generic/` | POL planning, IPOR delegated pool actions, balance valuation |
| Protected routing | `../upgrade/src/router/` and official IPOR UTS | Route storage, pool-oracle checks and vault-context permissions |
| Withdrawals | `../upgrade/src/withdraw/` | Request, settlement and vault-side share escrow |
| Fee/operating governance | `../upgrade/src/governance/` | Gate-owned modules and dedicated ADMIN_FEE execution lane |
| Existing wrapper/splitter | `../upgrade/src/wrapper/` | Existing 40/30/30 fee distribution; recipient wiring only where authorized |
| Original live source snapshots | `../deployed/phase1-*` | Deployment history / compatibility; never a V2 script source |

Retired governance, leaderboard, Plus stack, external loop splitter, both POL feeders, and obsolete test/deployment scripts are excluded from this package. On-chain state must be verified separately.
