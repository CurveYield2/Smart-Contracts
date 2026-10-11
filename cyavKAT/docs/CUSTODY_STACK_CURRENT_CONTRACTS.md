# cyavKAT V21 — Current custody-connected contract list

Only contracts retained for V2 or defined in present executable V21 scripts. No retired contributor reward custody, wrapper burn forwarder, or proposed replacement wrapper/market.

| Contract | Status | Current function / integration |
|---|---|---|
| `CurveYieldRevenueCustodyV2` | Deploy in P5, migrate in P6 | Receives wrapper fee shares, redeems into avKAT, allocates to existing loop, farms, reserves POL BPS of its direct avKAT balance, operates off-books POL B and covers permitted losses. |
| `CurveYieldProfitCustody` | Live retained | Owns original Morpho avKAT/KAT loop; V2 custody delegates its loop operations rather than opening another loop. |
| `CurveYieldWrappedCyavKat` | Live retained | Wraps cyavKAT shares into collateral and accrues wrapper fees. |
| `CurveYieldWrapperFeeSplitter` | Live retained | Fixed 40% admin, 30% V2 revenue custody (following L10), 30% WM V2; owner can reconfigure destinations, not proportions. |
| `CurveYieldPolController` | V2 POL deployment | Main vault's distinct, on-books POL position A controller. |
| `CurveYieldSwapRouterV2` | V2 deployment | Approved Sushi/Balancer swaps for V2 custody strategies and POL. |
| `CurveYieldSushiV3FeeRouter` | Live retained | Still serves the old profit custody's existing swap paths. |
| `CurveYieldVaultExecutor` | V2 deployment | Computes the original four-way vault-loop split internally and constructs fuse legs and orchestrates vault strategies and custody backstop calls. |
| `CurveYieldWithdrawalManagerV2` | V2 deployment | Receives wrapper-fee burn leg and handles withdrawal / burn-only fee-share flows. |
| `CurveYieldGovernanceGate` | V2 deployment | Protects fee changes, destination wiring, control handovers and gated executor calls. |
| `CurveYieldErc20TransferFuse` | V2 deployment | Executes allowlisted, approved transfers of avKAT from vault to authorized recipients. |
| `PlasmaVault` (cyavKAT) | Live IPOR retained | Supplies cyavKAT share accounting and withdraw/redeem operations; V2 custody balances are never added to the vault's PPS. |

**External protocol dependencies:** Morpho Blue, Charm AlphaProVault farms and POL, Balancer V3 routes, Sushi V3, Merkl, and the original IPOR RewardsClaimManager. These are not duplicate custody implementations.

**Note (v21):** The executor keeps its configurable four-way split; its contributors allocation goes to the existing admin-fee receiver, and growth goes to V2 custody after P6. The original Profit Custody's separate internal configurable wind-up split is unchanged, and 100% of its `feeRecipient` portion is paid directly. V19 eliminated the external loop-profit splitter and both POL feeders; the existing wrapper 40/30/30 splitter is retained.
