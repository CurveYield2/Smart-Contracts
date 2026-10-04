# cyvbWBTC verification result v2

- Commit tested: ed52b364b2665f383a39dfaac14f4d573bb60856
- Build exit code: 1
- Focused test exit code: 0
- Live Katana preflight exit code: 1
- Production CurveYield routes currently installed: 0

## Build
~~~text
Warning: dynamic test linking disabled for 4 files: error: unresolved symbol `Vm`
Compiling 32 files with Solc 0.8.30
Solc 0.8.30 finished in 166.36ms
Error: Compiler run failed:
Error (7920): Identifier not found or not unique.
   --> cyvbWBTC/script/SimulateCyvbWBTC_v1.s.sol:207:9:
    |
207 |         Vm.Log[] memory entries_,
    |         ^^^^^^
~~~

## Tests
~~~text
Compiling 28 files with Solc 0.8.30
Solc 0.8.30 finished in 1.29s
Compiler run successful!

Ran 6 tests for cyvbWBTC/test/CyvbWbtcCoreTest_v2.t.sol:CyvbWbtcCoreTest_v2
[PASS] test_configBindsVaultAndRecordsOnePosition() (gas: 146899)
[PASS] test_configDefaultsAndRelativeRanges() (gas: 114850)
[PASS] test_finalShareExitWaivesFeeAndLeavesNoOrphanAssets() (gas: 307157)
[PASS] test_gateRejectsDirectVaultUserAndAllowsGateway() (gas: 64401)
[PASS] test_instantExitFeeReturnsToVaultForRemainingHolders() (gas: 420373)
[PASS] test_onboardingFeeIsRetainedInVaultAndAccretesPps() (gas: 321019)
Suite result: ok. 6 passed; 0 failed; 0 skipped; finished in 1.62ms (1.73ms CPU time)

Ran 1 test suite in 8.44ms (1.62ms CPU time): 6 tests passed, 0 failed, 0 skipped (6 total tests)
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
grep: cyvbWBTC/script/DeployCyvbWBTC_v4.s.sol: No such file or directory
~~~
