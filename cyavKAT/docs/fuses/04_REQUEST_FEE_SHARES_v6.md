# Request-fee share escrow — v6

**Source** `upgrade/src/withdraw/CurveYieldRequestFeeSharesFuse.sol`. Utility `ZERO_BALANCE_MARKET`; this is a limited compatibility exception to the pure one-action-per-fuse rule, because the live IPOR withdrawal-manager interface needs two entrypoints. The existing external entrypoints remain ABI-compatible with WM v2.

`enter((address from,address to,uint256 amount))` and legacy `moveRequestFeeShares` escrow/refund shares via the original IPOR base. Only the current IPOR vault withdraw manager can call, and one side must be that manager. Zero is a no-op. `exit((address previousManager))` and legacy `configureManagerAssetAllowance` clear the previous manager's asset approval and approve the current manager. Both operations require that same manager caller. `enterTransient()` inputs `[from,to,amount]`, output `[amountMoved]`; `exitTransient()` input `[previousManager]`, output `[]`. This explicitly retains the two operations that cannot safely be split without changing WM v2.

**Fork acceptance:** requests/escrow, refunds, allowance rotation and manager-only execution. Both the legacy manager calls and new transient paths must pass. No external role or fee recipient is written.
