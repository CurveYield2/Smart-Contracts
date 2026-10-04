# cyvbWBTC verification result v1

- Commit tested: 96d54600e310fef7d5be568b6af74deb23d3447c
- Build exit code: 1
- Focused test exit code: 0
- Live Katana preflight exit code: 1
- Production CurveYield routes currently installed: 0

## Build
~~~text
Compiling 38 files with Solc 0.8.30
Solc 0.8.30 finished in 1.54s
Error: Compiler run failed:
Error: Compiler error (/solidity/libsolidity/codegen/LValue.cpp:50): Stack too deep. Try compiling with `--via-ir` (cli) or the equivalent `viaIR: true` (standard JSON) while enabling the optimizer. Otherwise, try removing local variables.
   --> cyvbWBTC/script/DeployCyvbWBTC_v4.s.sol:275:13:
    |
275 |             keeper,
    |             ^^^^^^
~~~

## Tests
~~~text
Compiling 34 files with Solc 0.8.30
Solc 0.8.30 finished in 2.00s
Compiler run successful with warnings:
Warning (2018): Function state mutability can be restricted to pure
   --> cyvbWBTC/contracts/CyvbWbtcGateway_v1.sol:164:5:
    |
164 |     function previewNetDeposit(uint256 grossAssets_) external view returns (uint256 netAssets, uint256 estimatedShares) {
    |     ^ (Relevant source part starts here and spans across multiple lines).


Ran 6 tests for cyvbWBTC/test/CyvbWbtcCoreTest_v2.t.sol:CyvbWbtcCoreTest_v2
[PASS] test_configBindsVaultAndRecordsOnePosition() (gas: 146899)
[PASS] test_configDefaultsAndRelativeRanges() (gas: 114850)
[PASS] test_finalShareExitWaivesFeeAndLeavesNoOrphanAssets() (gas: 307157)
[PASS] test_gateRejectsDirectVaultUserAndAllowsGateway() (gas: 64401)
[PASS] test_instantExitFeeReturnsToVaultForRemainingHolders() (gas: 420373)
[PASS] test_onboardingFeeIsRetainedInVaultAndAccretesPps() (gas: 321019)
Suite result: ok. 6 passed; 0 failed; 0 skipped; finished in 1.57ms (957.30µs CPU time)

Ran 5 tests for cyvbWBTC/test/CyvbWbtcCoreTest_v1.t.sol:CyvbWbtcCoreTest_v1
[PASS] test_configBindsVaultAndRecordsOnePosition() (gas: 146899)
[PASS] test_configDefaultsAndRelativeRanges() (gas: 114850)
[PASS] test_gateRejectsDirectVaultUserAndAllowsGateway() (gas: 64401)
[PASS] test_instantExitFeeReturnsToVaultForRemainingHolders() (gas: 419860)
[PASS] test_onboardingFeeIsRetainedInVaultAndAccretesPps() (gas: 321032)
Suite result: ok. 5 passed; 0 failed; 0 skipped; finished in 1.98ms (1.08ms CPU time)

Ran 2 test suites in 8.83ms (3.56ms CPU time): 11 tests passed, 0 failed, 0 skipped (11 total tests)
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
grep: cyvbWBTC/script/DeployCyvbWBTC_v3.s.sol: No such file or directory
grep: cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v3.sol: No such file or directory
~~~
