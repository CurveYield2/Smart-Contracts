# cyvbWBTC verification result v1

- Commit tested: 5acaed4c7f98743b6424c25d82fe67a1d660557b
- Build exit code: 0
- Focused test exit code: 0
- Live Katana preflight exit code: 1
- Production CurveYield routes currently installed: 0

## Build
~~~text
    │
502 │         (, uint256 rawDebts) = IFxLongPoolCyvbWBTCV4(FX_POOL).getPosition(position_);
    │                                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v4.sol:508:9
    │
508 │ ┏         IFxPoolManagerCyvbWBTCV4(POOL_MANAGER).operate(
509 │ ┃             FX_POOL,
510 │ ┃             position_,
511 │ ┃             type(int256).min,
512 │ ┃             0
513 │ ┃         );
    │ ┗━━━━━━━━━┛
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v4.sol:517:13
    │
517 │ ┏             IERC4626FxMintCyvbWBTCV4(CYVBUSDC).redeem(
518 │ ┃                 nestedShares,
519 │ ┃                 address(this),
520 │ ┃                 address(this)
521 │ ┃             );
    │ ┗━━━━━━━━━━━━━┛
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v4.sol:536:9
    │
536 │ ┏         IFxPoolManagerCyvbWBTCV4(POOL_MANAGER).operate(
537 │ ┃             FX_POOL,
538 │ ┃             position_,
539 │ ┃             -_toInt(grossAmount_),
540 │ ┃             0
541 │ ┃         );
    │ ┗━━━━━━━━━┛
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[divide-before-multiply]: division before multiplication may lose precision
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v4.sol:567:16
    │
567 │         return (safeGrossToken * (FEE_PRECISION - withdrawFee)) / FEE_PRECISION;
    │                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/divide-before-multiply

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v4.sol:549:13
    │
549 │             IFxPriceOracleCyvbWBTCV4(IFxLongPoolCyvbWBTCV4(FX_POOL).priceOracle()).getPrice();
    │             ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[divide-before-multiply]: division before multiplication may lose precision
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v4.sol:575:16
    │
575 │         return (tokenAmount * (FEE_PRECISION - withdrawFee)) / FEE_PRECISION;
    │                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/divide-before-multiply

warning[divide-before-multiply]: division before multiplication may lose precision
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v4.sol:589:16
    │
589 │         return (collateralUsd * targetBps_) / BPS;
    │                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/divide-before-multiply

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v4.sol:587:13
    │
587 │             IFxPriceOracleCyvbWBTCV4(IFxLongPoolCyvbWBTCV4(FX_POOL).priceOracle()).getPrice();
    │             ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[block-timestamp]: usage of `block.timestamp` in a comparison may be manipulated by validators
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v4.sol:648:13
    │
648 │         if (deadline_ < block.timestamp) revert InvalidDeadline();
    │             ━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/block-timestamp

warning[unsafe-typecast]: typecast can truncate values
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v4.sol:656:22
    │
656 │         if (value_ > uint256(type(int256).max)) revert AmountTooLargeForInt256();
    │                      ━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ├ note: consider disabling this lint if you're certain the cast is safe
    │       
    │       // casting to 'uint256' is safe because [explain why]
    │       // forge-lint: disable-next-line(unsafe-typecast)
    │       
    │       
    ╰ help: https://getfoundry.sh/forge/linting/unsafe-typecast

warning[unsafe-typecast]: typecast can truncate values
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v4.sol:657:16
    │
657 │         return int256(value_);
    │                ━━━━━━━━━━━━━━
    │
    ├ note: consider disabling this lint if you're certain the cast is safe
    │       
    │       // casting to 'int256' is safe because [explain why]
    │       // forge-lint: disable-next-line(unsafe-typecast)
    │       
    │       
    ╰ help: https://getfoundry.sh/forge/linting/unsafe-typecast

~~~

## Tests
~~~text
No files changed, compilation skipped

Ran 6 tests for cyvbWBTC/test/CyvbWbtcCoreTest_v2.t.sol:CyvbWbtcCoreTest_v2
[PASS] test_configBindsVaultAndRecordsOnePosition() (gas: 146899)
[PASS] test_configDefaultsAndRelativeRanges() (gas: 114850)
[PASS] test_finalShareExitWaivesFeeAndLeavesNoOrphanAssets() (gas: 307157)
[PASS] test_gateRejectsDirectVaultUserAndAllowsGateway() (gas: 64401)
[PASS] test_instantExitFeeReturnsToVaultForRemainingHolders() (gas: 420373)
[PASS] test_onboardingFeeIsRetainedInVaultAndAccretesPps() (gas: 321019)
Suite result: ok. 6 passed; 0 failed; 0 skipped; finished in 1.64ms (2.15ms CPU time)

Ran 1 test suite in 9.18ms (1.64ms CPU time): 6 tests passed, 0 failed, 0 skipped (6 total tests)
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
