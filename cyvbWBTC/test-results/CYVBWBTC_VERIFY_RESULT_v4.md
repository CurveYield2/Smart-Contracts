# cyvbWBTC verification result v4

- Commit tested: 06c547f3dc75ce7d4b7806359b7b25a12a9687b2
- Build exit code: 1
- Focused test exit code: 0
- Live Katana preflight exit code: 0
- Production CurveYield routes currently installed: 0

## Build
~~~text
Compiling 32 files with Solc 0.8.30
Solc 0.8.30 finished in 1.51s
Error: Compiler run failed:
Error: Compiler error (/solidity/libsolidity/codegen/LValue.cpp:50): Stack too deep. Try compiling with `--via-ir` (cli) or the equivalent `viaIR: true` (standard JSON) while enabling the optimizer. Otherwise, try removing local variables.
   --> cyvbWBTC/script/SimulateCyvbWBTC_v2.s.sol:166:27:
    |
166 |         vm.startBroadcast(privateKey);
    |                           ^^^^^^^^^^
~~~

## Tests
~~~text
Compiling 28 files with Solc 0.8.30
Solc 0.8.30 finished in 1.32s
Compiler run successful!

Ran 7 tests for cyvbWBTC/test/CyvbWbtcCoreTest_v3.t.sol:CyvbWbtcCoreTest_v3
[PASS] test_configBindsVaultAndRecordsOnePosition() (gas: 146877)
[PASS] test_configDefaultsAndRelativeRanges() (gas: 114828)
[PASS] test_finalShareExitWaivesFeeAndLeavesNoOrphanAssets() (gas: 307135)
[PASS] test_gateRejectsDirectVaultUserAndAllowsGateway() (gas: 64401)
[PASS] test_instantExitFeeReturnsToVaultForRemainingHolders() (gas: 420396)
[PASS] test_onboardingFeeIsRetainedInVaultAndAccretesPps() (gas: 321019)
[PASS] test_previewFinalRedeemWaivesExitFee() (gas: 161956)
Suite result: ok. 7 passed; 0 failed; 0 skipped; finished in 1.42ms (1.70ms CPU time)

Ran 1 test suite in 9.01ms (1.42ms CPU time): 7 tests passed, 0 failed, 0 skipped (7 total tests)
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
