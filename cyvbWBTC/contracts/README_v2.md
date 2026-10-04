# cyvbWBTC contracts manifest v2

Current production-candidate contract set for the CurveYield vbWBTC vault on Katana.

- `CyvbWbtcLtvConfig_v3.sol` — configurable target/high/low LTV policy with ±10% relative governance bounds and a fixed 55% instant-withdraw ceiling.
- `CyvbWbtcGateway_v5.sol` — mandatory user gateway; 0.55% onboarding and 0.35% non-final instant-exit fees remain in the vault to accrete PPS. Final-share exits waive the operational exit fee rather than orphaning assets.
- `CyvbWbtcGatewayGatePreHook_v3.sol` — IPOR pre-hook that blocks direct user deposit/mint/withdraw/redeem bypasses while allowing the gateway.
- `FxMintCyvbWbtcFuse_v4.sol` — f(x) collateral/borrow strategy, nested cyvbUSDC deployment, LTV rebalancing, and deleveraging/full-unwind instant withdrawals.
- `FxMintCyvbWbtcBalanceFuse_v3.sol` — strategy accounting bound to official IPOR `ERC20_VAULT_BALANCE` market ID 7.
- `FxMintVbWbtcPriceFeed_v1.sol` — vbWBTC price adapter.

Deployment candidate:
- `../script/DeployCyvbWBTC_v6.s.sol`

Current live topology asserted by the deployment/verification path:
- f(x) vbWBTC pool: `0xE32B9b4C8f776687Ec54B4b6B62DbD9ce5fd4b99`
- f(x) pool oracle: `0xeDA71e4ab642e97FBAA04beB3a7c4Bd6139a23C5`
- f(x) pool manager: `0xFae375C9eA6636c40deB92DD91B7dbbF51BD3C68`
- CurveYield Sushi router: `0x01F9894f92ea9224fECc8C35482E20a05De13582`

Accounting rule:
- The historical custom market ID 7001 is not valid for this implementation.
- Current strategy and balance fuses use official IPOR market ID 7.

Verification:
- focused core tests are in `../test/CyvbWbtcCoreTest_v3.t.sol`;
- compile/test/live-topology verification is in `../../.github/workflows/cyvbWBTC_verify_v5.yml`;
- isolated Katana Anvil live-fork testing is in `../../.github/workflows/cyvbWBTC_anvil_live_fork_v7.yml`.
