# cyvbWBTC verification result v11

- Commit tested: 657568ec5bfd040164e5e058346219cd1cdbc067
- Build exit code: 0
- Focused test exit code: 0
- Live Katana preflight exit code: 0
- Production CurveYield routes currently installed: 0

## Build
~~~text
    │
593 │ ┏         IFxPoolManagerCyvbWBTCV9(POOL_MANAGER).operate(
594 │ ┃             FX_POOL,
595 │ ┃             position_,
596 │ ┃             type(int256).min,
597 │ ┃             0
598 │ ┃         );
    │ ┗━━━━━━━━━┛
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v10.sol:602:13
    │
602 │ ┏             IERC4626FxMintCyvbWBTCV9(CYVBUSDC).redeem(
603 │ ┃                 nestedShares,
604 │ ┃                 address(this),
605 │ ┃                 address(this)
606 │ ┃             );
    │ ┗━━━━━━━━━━━━━┛
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v10.sol:621:9
    │
621 │ ┏         IFxPoolManagerCyvbWBTCV9(POOL_MANAGER).operate(
622 │ ┃             FX_POOL,
623 │ ┃             position_,
624 │ ┃             -_toInt(grossAmount_),
625 │ ┃             0
626 │ ┃         );
    │ ┗━━━━━━━━━┛
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[divide-before-multiply]: division before multiplication may lose precision
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v10.sol:652:16
    │
652 │         return (safeGrossToken * (FEE_PRECISION - withdrawFee)) / FEE_PRECISION;
    │                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/divide-before-multiply

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v10.sol:634:13
    │
634 │             IFxPriceOracleCyvbWBTCV9(IFxLongPoolCyvbWBTCV9(FX_POOL).priceOracle()).getPrice();
    │             ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[divide-before-multiply]: division before multiplication may lose precision
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v10.sol:660:16
    │
660 │         return (tokenAmount * (FEE_PRECISION - withdrawFee)) / FEE_PRECISION;
    │                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/divide-before-multiply

warning[divide-before-multiply]: division before multiplication may lose precision
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v10.sol:674:16
    │
674 │         return (collateralUsd * targetBps_) / BPS;
    │                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/divide-before-multiply

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v10.sol:672:13
    │
672 │             IFxPriceOracleCyvbWBTCV9(IFxLongPoolCyvbWBTCV9(FX_POOL).priceOracle()).getPrice();
    │             ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v10.sol:680:13
    │
680 │             IFxPriceOracleCyvbWBTCV9(IFxLongPoolCyvbWBTCV9(FX_POOL).priceOracle()).getPrice();
    │             ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[block-timestamp]: usage of `block.timestamp` in a comparison may be manipulated by validators
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v10.sol:779:13
    │
779 │         if (deadline_ < block.timestamp) revert InvalidDeadline();
    │             ━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/block-timestamp

warning[unsafe-typecast]: typecast can truncate values
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v10.sol:787:22
    │
787 │         if (value_ > uint256(type(int256).max)) revert AmountTooLargeForInt256();
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
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v10.sol:788:16
    │
788 │         return int256(value_);
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

Ran 6 tests for cyvbWBTC/test/CyvbWbtcFuseV10Test_v1.t.sol:CyvbWbtcFuseV10Test_v1
[PASS] testBalanceFuseRejectsWrongNestedAsset() (gas: 236386)
[PASS] testBalanceFuseValuesNestedAndResidualInUsdWad() (gas: 173509)
[PASS] testDefaultPolicyIsStoredImmutably() (gas: 37355)
[PASS] testPolicyOrderingReverts() (gas: 23856)
[PASS] testPolicyOutOfRangeReverts() (gas: 23857)
[PASS] testStrategyCallsOutsideVaultContextRevert() (gas: 92019)
Suite result: ok. 6 passed; 0 failed; 0 skipped; finished in 1.61ms (1.99ms CPU time)

Ran 1 test suite in 8.60ms (1.61ms CPU time): 6 tests passed, 0 failed, 0 skipped (6 total tests)
~~~

## Live preflight
~~~text
chain_id=747474
dao_packages=[(5, 1000, 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569), (30, 200, 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569), (50, 0, 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569)]
fx_pool_collateral=0x0913DA6Da4b42f538B445599b46Bb4622342Cf52
fx_pool_fxusd=0x4c03ff0f44A55e7098a09016E02a01d3cdC2FDF9
fx_pool_manager=0x27b3eE81DF2Dd7356D5ac282e2416991A616f96a
fx_pool_oracle=0x8244bDfb7E7fA52E05b725e6D5fbc2bcAEAfC52B
fx_pool_debt_ratio_range=100000000000000 [1e14]
670000000000000000 [6.7e17]
fxbase_stable=0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36
fxusd_vbusdc_pool=0x2D43e7931329dbB709F33d7049C937c6794Bae10
vbusdc_vbwbtc_pool=0x744676B3CeD942D78F9b8e9cd22246Db5c32395c
route_0x4c03ff0f44A55e7098a09016E02a01d3cdC2FDF9_to_0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36=0x
route_0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36_to_0x4c03ff0f44A55e7098a09016E02a01d3cdC2FDF9=0x
route_0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36_to_0x0913DA6Da4b42f538B445599b46Bb4622342Cf52=0x
~~~
