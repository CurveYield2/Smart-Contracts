# cyvbWBTC verification result v6

- Commit tested: d724e30c3cafdc1940c608d9ef873c2a72453380
- Build exit code: 1
- Focused test exit code: 1
- Live Katana preflight exit code: 0
- Production CurveYield routes currently installed: 0

## Build
~~~text
Compiling 40 files with Solc 0.8.30
Solc 0.8.30 finished in 73.91ms
Error: Compiler run failed:
Error (2314): Expected ';' but got 'uint256'
   --> cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v5.sol:244:9:
    |
244 |         uint256 vbUsdcDeposited;
    |         ^^^^^^^
~~~

## Tests
~~~text
Compiling 30 files with Solc 0.8.30
Solc 0.8.30 finished in 67.36ms
Error: Compiler run failed:
Error (2314): Expected ';' but got 'uint256'
   --> cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v5.sol:244:9:
    |
244 |         uint256 vbUsdcDeposited;
    |         ^^^^^^^
~~~

## Live preflight
~~~text
chain_id=747474
dao_packages=[(5, 1000, 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569), (30, 200, 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569), (50, 0, 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569)]
fx_pool_collateral=0x0913DA6Da4b42f538B445599b46Bb4622342Cf52
fx_pool_fxusd=0x1364b238C668A2dec1294174e4798E8c09979f86
fx_pool_manager=0xFae375C9eA6636c40deB92DD91B7dbbF51BD3C68
fx_pool_oracle=0xeDA71e4ab642e97FBAA04beB3a7c4Bd6139a23C5
fxbase_stable=0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36
fxusd_vbusdc_pool=0xe1578cEF06331d77bC99273d5f1aF48eC2de92db
vbusdc_vbwbtc_pool=0x744676B3CeD942D78F9b8e9cd22246Db5c32395c
route_0x1364b238C668A2dec1294174e4798E8c09979f86_to_0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36=0x
route_0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36_to_0x1364b238C668A2dec1294174e4798E8c09979f86=0x
route_0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36_to_0x0913DA6Da4b42f538B445599b46Bb4622342Cf52=0x
~~~
