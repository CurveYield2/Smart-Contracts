# cyvbWBTC contracts manifest v8

Current production candidates:
- CyvbWbtcLtvConfig_v3.sol
- CyvbWbtcGateway_v5.sol
- CyvbWbtcGatewayGatePreHook_v3.sol
- FxMintCyvbWbtcFuse_v4.sol
- FxMintCyvbWbtcBalanceFuse_v3.sol
- FxMintVbWbtcPriceFeed_v1.sol
- ../script/DeployCyvbWBTC_v8.s.sol
- ../script/SimulateCyvbWBTC_v5.s.sol

Current verification:
- ../../.github/workflows/cyvbWBTC_verify_v7.yml
- ../../.github/workflows/cyvbWBTC_anvil_live_fork_v13.yml
- ../test/CyvbWbtcCoreTest_v3.t.sol

Verified before this clean run:
- build PASS
- focused tests 7/7 PASS
- live Katana topology PASS
- Anvil setup PASS through router configuration, fork funding, IPOR factory clone, and vault configuration

Deployment v8 uses the current official IPOR governance API `isBalanceFuseSupported(marketId,fuse)` rather than the nonexistent direct `getBalanceFuse` getter.

Accounting uses official IPOR market ID 7. The historical custom market 7001 is not used.
