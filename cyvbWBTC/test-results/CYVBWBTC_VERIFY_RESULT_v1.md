# cyvbWBTC verification result v1

- Commit tested: 7b44a6bf1ac61a8fd823ee0647081b209c5cf4aa
- Build exit code: 1
- Focused test exit code: 1
- Live Katana preflight exit code: 1
- Production CurveYield routes currently installed: 0

## Build
~~~text
Warning: dynamic test linking disabled for 6 files: error: invalid checksummed address
Compiling 45 files with Solc 0.8.30
Solc 0.8.30 finished in 423.59ms
Error: Compiler run failed:
Error (9429): This looks like an address but has an invalid checksum. Correct checksummed address: "0xE32B9b4C8f776687Ec54B4b6B62DbD9ce5fd4b99". If this is not used as an address, please prepend '00'. For more information please see https://docs.soliditylang.org/en/develop/types.html#address-literals
SyntaxError: This looks like an address but has an invalid checksum. Correct checksummed address: "0xE32B9b4C8f776687Ec54B4b6B62DbD9ce5fd4b99". If this is not used as an address, please prepend '00'. For more information please see https://docs.soliditylang.org/en/develop/types.html#address-literals
   --> cyvbWBTC/script/DeployCyvbWBTC_v1.s.sol:124:41:
    |
124 |     address internal constant FX_POOL = 0xe32b9b4c8f776687ec54b4b6b62dbd9ce5fd4b99;
    |                                         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Error (9429): This looks like an address but has an invalid checksum. Correct checksummed address: "0xb4fB797338B5cA45Ce9aF43bfca9e873BdAc8C7B". If this is not used as an address, please prepend '00'. For more information please see https://docs.soliditylang.org/en/develop/types.html#address-literals
SyntaxError: This looks like an address but has an invalid checksum. Correct checksummed address: "0xb4fB797338B5cA45Ce9aF43bfca9e873BdAc8C7B". If this is not used as an address, please prepend '00'. For more information please see https://docs.soliditylang.org/en/develop/types.html#address-literals
   --> cyvbWBTC/script/DeployCyvbWBTC_v2.s.sol:133:49:
    |
133 |     address internal constant FX_PRICE_ORACLE = 0xB4Fb797338b5CA45CE9aF43BfcA9E873BDac8C7B;
    |                                                 ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Error (9429): This looks like an address but has an invalid checksum. Correct checksummed address: "0xb4fB797338B5cA45Ce9aF43bfca9e873BdAc8C7B". If this is not used as an address, please prepend '00'. For more information please see https://docs.soliditylang.org/en/develop/types.html#address-literals
SyntaxError: This looks like an address but has an invalid checksum. Correct checksummed address: "0xb4fB797338B5cA45Ce9aF43bfca9e873BdAc8C7B". If this is not used as an address, please prepend '00'. For more information please see https://docs.soliditylang.org/en/develop/types.html#address-literals
   --> cyvbWBTC/script/DeployCyvbWBTC_v3.s.sol:133:49:
    |
133 |     address internal constant FX_PRICE_ORACLE = 0xB4Fb797338b5CA45CE9aF43BfcA9E873BDac8C7B;
    |                                                 ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
~~~

## Tests
~~~text
Compiling 39 files with Solc 0.8.30
Solc 0.8.30 finished in 1.14s
Error: Compiler run failed:
Error: Compiler error (/solidity/libsolidity/codegen/LValue.cpp:50): Stack too deep. Try compiling with `--via-ir` (cli) or the equivalent `viaIR: true` (standard JSON) while enabling the optimizer. Otherwise, try removing local variables.
   --> cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v2.sol:362:33:
    |
362 |                     _repayExact(position, rawDebts - maxPostDebt, 0, block.timestamp);
    |                                 ^^^^^^^^
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
