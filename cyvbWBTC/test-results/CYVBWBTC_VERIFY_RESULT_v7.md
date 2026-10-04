# cyvbWBTC verification result v7

- Commit tested: fa855cd9de44fae2119b022d437d1a92124cd116
- Build exit code: 1
- Focused test exit code: 1
- Live Katana preflight exit code: 1
- Production CurveYield routes currently installed: 0

## Build
~~~text
Compiling 32 files with Solc 0.8.30
Solc 0.8.30 finished in 875.00ms
Error: Compiler run failed:
Error: Compiler error (/solidity/libsolidity/codegen/LValue.cpp:50): Stack too deep. Try compiling with `--via-ir` (cli) or the equivalent `viaIR: true` (standard JSON) while enabling the optimizer. Otherwise, try removing local variables.
   --> cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v6.sol:433:20:
    |
433 |             _toInt(amount_),
    |                    ^^^^^^^
~~~

## Tests
~~~text
Compiling 28 files with Solc 0.8.30
Solc 0.8.30 finished in 813.65ms
Error: Compiler run failed:
Error: Compiler error (/solidity/libsolidity/codegen/LValue.cpp:50): Stack too deep. Try compiling with `--via-ir` (cli) or the equivalent `viaIR: true` (standard JSON) while enabling the optimizer. Otherwise, try removing local variables.
   --> cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v6.sol:433:20:
    |
433 |             _toInt(amount_),
    |                    ^^^^^^^
~~~

## Live preflight
~~~text
chain_id=747474
dao_packages=[(5, 1000, 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569), (30, 200, 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569), (50, 0, 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569)]
Error: server returned an error response: error code 3: execution reverted
fx_pool_collateral=0x0913DA6Da4b42f538B445599b46Bb4622342Cf52
fx_pool_fxusd=0x1364b238C668A2dec1294174e4798E8c09979f86
fx_pool_manager=0xFae375C9eA6636c40deB92DD91B7dbbF51BD3C68
fx_pool_oracle=0xeDA71e4ab642e97FBAA04beB3a7c4Bd6139a23C5
fx_pool_debt_ratio_range=100000000000000 [1e14]
866666666666666666 [8.666e17]
fx_pool_open_fee_ratio=
fxbase_stable=0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36
fxusd_vbusdc_pool=0xe1578cEF06331d77bC99273d5f1aF48eC2de92db
vbusdc_vbwbtc_pool=0x744676B3CeD942D78F9b8e9cd22246Db5c32395c
route_0x1364b238C668A2dec1294174e4798E8c09979f86_to_0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36=0x
route_0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36_to_0x1364b238C668A2dec1294174e4798E8c09979f86=0x
route_0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36_to_0x0913DA6Da4b42f538B445599b46Bb4622342Cf52=0x
~~~
