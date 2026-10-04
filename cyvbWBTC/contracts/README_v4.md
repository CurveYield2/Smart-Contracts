# cyvbWBTC contracts manifest v4

Current production-candidate set for CurveYield vbWBTC on Katana:

- `CyvbWbtcLtvConfig_v3.sol` — configurable target/high/low LTV policy with the approved governance bounds and a 55% instant-withdraw ceiling.
- `CyvbWbtcGateway_v5.sol` — mandatory gateway. The 0.55% onboarding fee and 0.35% non-final instant-exit fee remain in the vault and accrete PPS; final-share exits waive the operational fee to prevent orphaned assets.
- `CyvbWbtcGatewayGatePreHook_v3.sol` — blocks direct user bypass of the gateway.
- `FxMintCyvbWbtcFuse_v4.sol` — f(x) collateral/borrow strategy, nested cyvbUSDC deployment, LTV maintenance, deleveraging instant withdrawal, and full unwind.
- `FxMintCyvbWbtcBalanceFuse_v3.sol` — accounting on official IPOR ERC20 vault-balance market ID 7.
- `FxMintVbWbtcPriceFeed_v1.sol` — vbWBTC price adapter.

Deployment candidate: `../script/DeployCyvbWBTC_v6.s.sol`
Simulation candidate: `../script/SimulateCyvbWBTC_v3.s.sol`

Verification:
- compile/test/live-preflight: `../../.github/workflows/cyvbWBTC_verify_v5.yml`
- isolated Katana Anvil fork: `../../.github/workflows/cyvbWBTC_anvil_live_fork_v10.yml`
- focused tests: `../test/CyvbWbtcCoreTest_v3.t.sol`

Latest completed compile/test/live-preflight:
- build PASS
- focused tests 7/7 PASS
- live Katana topology PASS
- live production CurveYield swap routes required by deployment are not yet installed

The historical custom market ID 7001 is not used. The current strategy and balance fuses use official IPOR market ID 7.
