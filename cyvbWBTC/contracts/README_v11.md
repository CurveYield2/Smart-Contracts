# cyvbWBTC contracts manifest v11

Current production-candidate set for CurveYield vbWBTC on Katana:

- `CyvbWbtcLtvConfig_v3.sol`
- `CyvbWbtcGateway_v5.sol`
- `CyvbWbtcGatewayGatePreHook_v3.sol`
- `FxMintCyvbWbtcFuse_v8.sol`
- `FxMintCyvbWbtcBalanceFuse_v3.sol`
- `FxMintVbWbtcPriceFeed_v1.sol`

Current deployment and simulation:
- `../script/DeployCyvbWBTC_v11.s.sol`
- `../script/SimulateCyvbWBTC_v8.s.sol`

Current verification:
- `../../.github/workflows/cyvbWBTC_verify_v10.yml`
- `../../.github/workflows/cyvbWBTC_anvil_live_fork_v16.yml`
- `../test/CyvbWbtcCoreTest_v3.t.sol`

Live f(x) facts verified during the fork work:
- debt-ratio range: 0.01% to 86.6666666666666666%
- configured target 50% is valid
- live pool does not expose a callable `getOpenFeeRatio()`
- official pool configuration `getPoolFeeRatio()` supplies the opening/supply fee and previously matched the actual 0.3% deduction made by `operate()`

Strategy v8 therefore opens/adds collateral and target debt atomically using the live-compatible configured supply fee source.

Accounting uses official IPOR ERC20 vault-balance market ID 7. Historical custom market 7001 is not used.
