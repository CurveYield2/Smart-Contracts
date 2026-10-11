# Burn held vault shares — v6

**Source** `upgrade/src/generic/CurveYieldBurnHeldSharesFuse.sol`. Kept because IPOR `BurnRequestFeeFuse` only burns request-manager fee shares. Configured as a utility at `ZERO_BALANCE_MARKET` and delegates to the original IPOR base `updateInternal` for actual share accounting. Shares must already be held by the vault; no external holder can be burned.

`enter((uint256 maxShares))` returns number burned. `maxShares=0` means burn all shares held by the vault; otherwise burn up to that amount, capped to available vault-held shares. Zero balance returns zero. `enterTransient()` consumes `[maxShares]` and returns `[burned]`. Both `exit(bytes)` and `exitTransient()` revert `...ExitNotSupported`.

**Fork acceptance:** burn held shares, verify supplies decrease and PPS does not drop; non-vault balances unchanged; zero-balance/partial caps; standard IPOR base still delegated through mandatory Quest signing wrapper.
