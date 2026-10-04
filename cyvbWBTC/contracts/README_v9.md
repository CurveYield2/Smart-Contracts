# cyvbWBTC contracts manifest v9

Current production-candidate set for CurveYield vbWBTC on Katana:

- `CyvbWbtcLtvConfig_v3.sol`
- `CyvbWbtcGateway_v5.sol`
- `CyvbWbtcGatewayGatePreHook_v3.sol`
- `FxMintCyvbWbtcFuse_v6.sol`
- `FxMintCyvbWbtcBalanceFuse_v3.sol`
- `FxMintVbWbtcPriceFeed_v1.sol`

Current deployment and simulation:
- `../script/DeployCyvbWBTC_v9.s.sol`
- `../script/SimulateCyvbWBTC_v6.s.sol`

Current verification:
- `../../.github/workflows/cyvbWBTC_verify_v8.yml`
- `../../.github/workflows/cyvbWBTC_anvil_live_fork_v14.yml`
- `../test/CyvbWbtcCoreTest_v3.t.sol`

Important integration correction in strategy v6:
- the live f(x) pool enforces a minimum debt ratio on every `operate()`;
- collateral-only creation therefore reverts;
- strategy v6 calculates the live f(x) opening fee, derives net raw collateral, rounds target debt upward at the 50% floor, and adds collateral + target debt atomically;
- configured borrowing/reset targets are checked against the live pool debt-ratio range.

Previously verified:
- Solidity build PASS
- focused gateway/config tests 7/7 PASS
- live Katana topology PASS
- Anvil fork bootstrap, route setup, funding, IPOR factory clone and vault configuration PASS

Accounting uses official IPOR ERC20 vault-balance market ID 7. Historical custom market 7001 is not used.
