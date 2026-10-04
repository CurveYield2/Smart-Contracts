# cyvbWBTC verification result v7

- Commit tested: d9ba5f9f3a8f262fb4106819c441664555a95c57
- Build exit code: 0
- Focused test exit code: 0
- Live Katana preflight exit code: 1
- Production CurveYield routes currently installed: 0

## Build
~~~text
    │
553 │ ┏         IFxPoolManagerCyvbWBTCV7(POOL_MANAGER).operate(
554 │ ┃             FX_POOL,
555 │ ┃             position_,
556 │ ┃             type(int256).min,
557 │ ┃             0
558 │ ┃         );
    │ ┗━━━━━━━━━┛
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v7.sol:562:13
    │
562 │ ┏             IERC4626FxMintCyvbWBTCV7(CYVBUSDC).redeem(
563 │ ┃                 nestedShares,
564 │ ┃                 address(this),
565 │ ┃                 address(this)
566 │ ┃             );
    │ ┗━━━━━━━━━━━━━┛
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v7.sol:581:9
    │
581 │ ┏         IFxPoolManagerCyvbWBTCV7(POOL_MANAGER).operate(
582 │ ┃             FX_POOL,
583 │ ┃             position_,
584 │ ┃             -_toInt(grossAmount_),
585 │ ┃             0
586 │ ┃         );
    │ ┗━━━━━━━━━┛
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[divide-before-multiply]: division before multiplication may lose precision
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v7.sol:612:16
    │
612 │         return (safeGrossToken * (FEE_PRECISION - withdrawFee)) / FEE_PRECISION;
    │                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/divide-before-multiply

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v7.sol:594:13
    │
594 │             IFxPriceOracleCyvbWBTCV7(IFxLongPoolCyvbWBTCV7(FX_POOL).priceOracle()).getPrice();
    │             ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[divide-before-multiply]: division before multiplication may lose precision
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v7.sol:620:16
    │
620 │         return (tokenAmount * (FEE_PRECISION - withdrawFee)) / FEE_PRECISION;
    │                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/divide-before-multiply

warning[divide-before-multiply]: division before multiplication may lose precision
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v7.sol:634:16
    │
634 │         return (collateralUsd * targetBps_) / BPS;
    │                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/divide-before-multiply

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v7.sol:632:13
    │
632 │             IFxPriceOracleCyvbWBTCV7(IFxLongPoolCyvbWBTCV7(FX_POOL).priceOracle()).getPrice();
    │             ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v7.sol:640:13
    │
640 │             IFxPriceOracleCyvbWBTCV7(IFxLongPoolCyvbWBTCV7(FX_POOL).priceOracle()).getPrice();
    │             ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[block-timestamp]: usage of `block.timestamp` in a comparison may be manipulated by validators
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v7.sol:714:13
    │
714 │         if (deadline_ < block.timestamp) revert InvalidDeadline();
    │             ━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/block-timestamp

warning[unsafe-typecast]: typecast can truncate values
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v7.sol:722:22
    │
722 │         if (value_ > uint256(type(int256).max)) revert AmountTooLargeForInt256();
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
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v7.sol:723:16
    │
723 │         return int256(value_);
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

Ran 7 tests for cyvbWBTC/test/CyvbWbtcCoreTest_v3.t.sol:CyvbWbtcCoreTest_v3
[PASS] test_configBindsVaultAndRecordsOnePosition() (gas: 146877)
[PASS] test_configDefaultsAndRelativeRanges() (gas: 114828)
[PASS] test_finalShareExitWaivesFeeAndLeavesNoOrphanAssets() (gas: 307135)
[PASS] test_gateRejectsDirectVaultUserAndAllowsGateway() (gas: 64401)
[PASS] test_instantExitFeeReturnsToVaultForRemainingHolders() (gas: 420396)
[PASS] test_onboardingFeeIsRetainedInVaultAndAccretesPps() (gas: 321019)
[PASS] test_previewFinalRedeemWaivesExitFee() (gas: 161956)
Suite result: ok. 7 passed; 0 failed; 0 skipped; finished in 1.68ms (1.87ms CPU time)

Ran 1 test suite in 9.14ms (1.68ms CPU time): 7 tests passed, 0 failed, 0 skipped (7 total tests)
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
grep: cyvbWBTC/script/DeployCyvbWBTC_v9.s.sol: No such file or directory
grep: cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v6.sol: No such file or directory
~~~
