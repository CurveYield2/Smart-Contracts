# cyvbWBTC verification result v4

- Commit tested: e477e98233df6dc33213124473e68a9a9f17d4a7
- Build exit code: 0
- Focused test exit code: 0
- Live Katana preflight exit code: 0
- Production CurveYield routes currently installed: 0

## Build
~~~text
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

warning[divide-before-multiply]: division before multiplication may lose precision
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcBalanceFuse_v3.sol:102:33
    │
102 │                 collateralUsd = (collateralUsd * (FEE_PRECISION - withdrawFee)) / FEE_PRECISION;
    │                                 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/divide-before-multiply

warning[uninitialized-local]: local variable is read before being initialized
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcBalanceFuse_v3.sol:117:13
    │
117 │             grossAssetsUsd += _toWad(
    │             ━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/uninitialized-local

warning[unused-return]: return value of an external call is not used
   ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcBalanceFuse_v3.sol:94:17
   │
94 │                 IFxOracleBalanceCyvbWBTCV3(IFxLongPoolBalanceCyvbWBTCV3(FX_POOL).priceOracle()).getPrice();
   │                 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   │
   ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcBalanceFuse_v3.sol:98:41
    │
 98 │               (, uint256 withdrawFee,,) = IFxPoolConfigurationBalanceCyvbWBTCV3(
    │ ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
 99 │ ┃                 IFxLongPoolBalanceCyvbWBTCV3(FX_POOL).configuration()
100 │ ┃             ).getPoolFeeRatio(FX_POOL, msg.sender);
    │ ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

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
Suite result: ok. 7 passed; 0 failed; 0 skipped; finished in 1.38ms (1.85ms CPU time)

Ran 1 test suite in 8.37ms (1.38ms CPU time): 7 tests passed, 0 failed, 0 skipped (7 total tests)
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
