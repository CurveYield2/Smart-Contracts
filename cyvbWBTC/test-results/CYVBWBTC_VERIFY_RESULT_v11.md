# cyvbWBTC verification result v11

- Commit tested: 3103ad322771c6dda517a6d181564fa855772efb
- Build exit code: 0
- Focused test exit code: 0
- Live Katana preflight exit code: 0
- Production CurveYield routes currently installed: 0

## Build
~~~text
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v13.sol:861:32
    │
861 │         (, uint256 rawDebts) = IFxLongPoolCyvbWBTCV9(FX_POOL).getPosition(position_);
    │                                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v13.sol:867:13
    │
867 │ ┏             IERC4626FxMintCyvbWBTCV9(CYVBUSDC).redeem(
868 │ ┃                 nestedShares,
869 │ ┃                 address(this),
870 │ ┃                 address(this)
871 │ ┃             );
    │ ┗━━━━━━━━━━━━━┛
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v13.sol:886:9
    │
886 │ ┏         IFxPoolManagerCyvbWBTCV9(POOL_MANAGER).operate(
887 │ ┃             FX_POOL,
888 │ ┃             position_,
889 │ ┃             -_toInt(grossAmount_),
890 │ ┃             0
891 │ ┃         );
    │ ┗━━━━━━━━━┛
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[divide-before-multiply]: division before multiplication may lose precision
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v13.sol:917:16
    │
917 │         return (safeGrossToken * (FEE_PRECISION - withdrawFee)) / FEE_PRECISION;
    │                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/divide-before-multiply

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v13.sol:899:13
    │
899 │             IFxPriceOracleCyvbWBTCV9(IFxLongPoolCyvbWBTCV9(FX_POOL).priceOracle()).getPrice();
    │             ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[divide-before-multiply]: division before multiplication may lose precision
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v13.sol:925:16
    │
925 │         return (tokenAmount * (FEE_PRECISION - withdrawFee)) / FEE_PRECISION;
    │                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/divide-before-multiply

warning[divide-before-multiply]: division before multiplication may lose precision
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v13.sol:939:16
    │
939 │         return (collateralUsd * targetBps_) / BPS;
    │                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/divide-before-multiply

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v13.sol:937:13
    │
937 │             IFxPriceOracleCyvbWBTCV9(IFxLongPoolCyvbWBTCV9(FX_POOL).priceOracle()).getPrice();
    │             ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[unused-return]: return value of an external call is not used
    ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v13.sol:945:13
    │
945 │             IFxPriceOracleCyvbWBTCV9(IFxLongPoolCyvbWBTCV9(FX_POOL).priceOracle()).getPrice();
    │             ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/unused-return

warning[block-timestamp]: usage of `block.timestamp` in a comparison may be manipulated by validators
     ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v13.sol:1045:13
     │
1045 │         if (deadline_ < block.timestamp) revert InvalidDeadline();
     │             ━━━━━━━━━━━━━━━━━━━━━━━━━━━
     │
     ╰ help: https://getfoundry.sh/forge/linting/block-timestamp

warning[unsafe-typecast]: typecast can truncate values
     ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v13.sol:1053:22
     │
1053 │         if (value_ > uint256(type(int256).max)) revert AmountTooLargeForInt256();
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
     ╭▸ cyvbWBTC/contracts/FxMintCyvbWbtcFuse_v13.sol:1054:16
     │
1054 │         return int256(value_);
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

Ran 8 tests for cyvbWBTC/test/CyvbWbtcFuseV13Test_v1.t.sol:CyvbWbtcFuseV13Test_v1
[PASS] testDefaultPolicyIsStoredImmutably() (gas: 46055)
[PASS] testEarnSplitAbove100PercentReverts() (gas: 26887)
[PASS] testIndicatorsShowUsdUnitsAndAreNotTransferable() (gas: 194575)
[PASS] testOneWeiFeed() (gas: 7182)
[PASS] testOnlyTheVaultRegistersThePosition() (gas: 79524)
[PASS] testPolicyOrderingReverts() (gas: 26792)
[PASS] testPolicyOutOfRangeReverts() (gas: 26816)
[PASS] testStrategyCallsOutsideVaultContextRevert() (gas: 140437)
Suite result: ok. 8 passed; 0 failed; 0 skipped; finished in 1.37ms (2.99ms CPU time)

Ran 1 test suite in 8.63ms (1.37ms CPU time): 8 tests passed, 0 failed, 0 skipped (8 total tests)
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
