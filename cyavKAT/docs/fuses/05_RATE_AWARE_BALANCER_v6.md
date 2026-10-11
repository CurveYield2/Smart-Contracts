# Rate-aware Balancer balance fuse — v6

**Source** `upgrade/src/generic/CurveYieldRateAwareBalancerBalanceFuse.sol`; **exception E2**: forked from the official IPOR Balancer balance fuse to prevent counting a pool's WITH_RATE token rate twice, particularly if that token is the vault's own shares.

One immutable market ID (market 36; zero rejected) and `VERSION=address(this)`. `balanceOf()` uses the pool's raw token balances, multiplies by vault-held LP fraction, converts a vault-share leg at `convertToAssets` to its underlying, then values tokens with IPOR's vault oracle into USD WAD. It returns zero for an empty substrate market. The exact substrates are the official Balancer POOL and GAUGE variants. There are no entry/exit actions because this is a balance fuse, not an action fuse.

**Fork acceptance:** POL position A, fee / share-rate movements, zero LP balance, nonzero LP supply, direct-with-rate and raw token accounting equivalence, and no oracle double counting.
