# Current IPOR fuse inventory — v21

Only the `../upgrade/src/` and official pinned `../ipor-fusion/contracts/fuses/` sources are in the new executable path. The old pre-standardization fuse mapping has been retired.

**Retained custom fuse families** in `../upgrade/src/` include:

- `CurveYieldBundleGuardFuse`: enforces price/asset and LTV constraints on authorized action bundles.
- `CurveYieldErc20TransferFuse`: transfers authorized vault tokens to allowed recipients.
- `CurveYieldBurnHeldSharesFuse`: burns vault-held cyavKAT shares.
- `CurveYieldRequestFeeSharesFuse`: vault-context fee-share movement / manager allowance configuration.
- `CurveYieldRateAwareBalancerBalanceFuse`: position-A Gyro E-CLP BPT valuation.
- Revised mandatory Quest signing configuration fuse and retained wrapper (in `../upgrade/src/katana/`).

**Official IPOR paths** include UniversalTokenSwapperFuse (and its IPOR SwapExecutor helper), Balancer proportional liquidity, Morpho actions and flash loans, ERC-4626 supply/balance, UpdateMarketsBalances, transient storage and balance-validation fuses. The deployment scripts in `../upgrade/script/` determine exact instances and registration; POL liquidity deployment is conditional on configured venue prerequisites.

The `SwapExecutor` helper is **not** a registered fuse; it remains part of the official UniversalTokenSwapperFuse path. No proposed replacement/removal of it has been implemented in this cleanup.

Refer to `IPOR_FUSE_CONFORMANCE_SPEC.md` and `fuses/` for implementation conditions, but verify current `upgrade/src` and deployment scripts before using any older design assumptions.
