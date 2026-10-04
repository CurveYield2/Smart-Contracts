# cyvbWBTC contracts manifest v1

Current production-candidate contract set for the CurveYield vbWBTC vault on Katana.

- `CyvbWbtcLtvConfig_v3.sol` — configurable target/high/low LTV policy with ±10% relative governance bounds and a fixed 55% instant-withdraw ceiling.
- `CyvbWbtcGateway_v5.sol` — mandatory user gateway; 0.55% onboarding and 0.35% non-final instant-exit fees remain in the vault to accrete PPS. Final-share exits waive the operational exit fee rather than orphaning assets.
- `CyvbWbtcGatewayGatePreHook_v3.sol` — IPOR pre-hook that blocks direct user deposit/mint/withdraw/redeem bypasses while allowing the gateway.
- `FxMintCyvbWbtcFuse_v4.sol` — f(x) collateral/borrow strategy, nested cyvbUSDC deployment, LTV rebalancing, and deleveraging/full-unwind instant withdrawals.
- `FxMintCyvbWbtcBalanceFuse_v3.sol` — strategy accounting bound to official IPOR `ERC20_VAULT_BALANCE` market ID 7.
- `FxMintVbWbtcPriceFeed_v1.sol` — vbWBTC price adapter using the live f(x) oracle configured by deployment.

The deployment candidate is `../script/DeployCyvbWBTC_v6.s.sol`.

The repository intentionally does not treat the historical custom market ID 7001 as valid. The current strategy and balance fuses use official IPOR market ID 7.
