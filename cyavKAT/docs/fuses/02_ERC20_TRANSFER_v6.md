# Outbound ERC20 transfer fuse — v6

**Source** `upgrade/src/generic/CurveYieldErc20TransferFuse.sol`; **exception E1/E6** (outbound transfer and typed substrate in zero-balance market). Installed in accounting market 7; its typed permission data resides in IPOR's `ZERO_BALANCE_MARKET`. Only `TRANSFER_TOKEN`, `TRANSFER_RECIPIENT`, and `TRANSFER_CAP` entries grant an outbound transfer. Plain token substrates in market 7 remain untyped so the official ERC20 balance fuse can value them correctly.

`enter((address token,address to,uint256 amount))` returns actual amount sent: zero returns 0, amount must not exceed both granted and absolute cap (1,000,000e18 base units), actual output is capped to vault balance. It emits a versioned transfer event. Unsupported exit and exitTransient revert. `enterTransient()` consumes `[token,to,amount]` and yields `[actualSent]`.

**Fork acceptance:** ungranted token, recipient and cap each revert; zero is no-op; balance cap and accounting market 7 after execution; approved operational recipient only. No `owner()` or executeInternal.
