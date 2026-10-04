# cyvbWBTC contracts manifest v10

Current production-candidate set for CurveYield vbWBTC on Katana:

- `CyvbWbtcLtvConfig_v3.sol`
- `CyvbWbtcGateway_v5.sol`
- `CyvbWbtcGatewayGatePreHook_v3.sol`
- `FxMintCyvbWbtcFuse_v7.sol`
- `FxMintCyvbWbtcBalanceFuse_v3.sol`
- `FxMintVbWbtcPriceFeed_v1.sol`

Current deployment and simulation:
- `../script/DeployCyvbWBTC_v10.s.sol`
- `../script/SimulateCyvbWBTC_v7.s.sol`

Current verification:
- `../../.github/workflows/cyvbWBTC_verify_v9.yml`
- `../../.github/workflows/cyvbWBTC_anvil_live_fork_v15.yml`
- `../test/CyvbWbtcCoreTest_v3.t.sol`

Strategy v7 opens/adds f(x) collateral and required target debt atomically. It uses the live f(x) opening fee and debt-ratio range, rounds borrowing upward at the 50% minimum, and keeps the approved LTV policy subject to live protocol bounds.

Previously verified:
- gateway/config focused tests 7/7 PASS
- live Katana topology PASS
- Anvil fork bootstrap, route configuration, funding, official IPOR factory clone, and vault configuration PASS

Accounting uses official IPOR ERC20 vault-balance market ID 7. Historical custom market 7001 is not used.
