# cyvbWBTC contracts manifest v3

Current production-candidate set for CurveYield vbWBTC on Katana:

- `CyvbWbtcLtvConfig_v3.sol` — configurable 50% target LTV with governance-adjustable target/triggers/reset points constrained to the approved relative ranges; instant withdrawal ceiling remains 55%.
- `CyvbWbtcGateway_v5.sol` — mandatory deposit/instant-exit gateway. The 0.55% onboarding fee and 0.35% non-final instant-exit fee remain in the vault and accrete PPS. A true final-share exit waives the operational fee so no assets are orphaned.
- `CyvbWbtcGatewayGatePreHook_v3.sol` — prevents direct user bypass of the gateway.
- `FxMintCyvbWbtcFuse_v4.sol` — f(x) collateral/borrow strategy, nested cyvbUSDC deployment, LTV maintenance, deleveraging instant withdrawal, and full unwind.
- `FxMintCyvbWbtcBalanceFuse_v3.sol` — accounting bound to official IPOR ERC20 vault-balance market ID 7.
- `FxMintVbWbtcPriceFeed_v1.sol` — vbWBTC price adapter.

Deployment candidate:
- `../script/DeployCyvbWBTC_v6.s.sol`

Simulation candidate:
- `../script/SimulateCyvbWBTC_v3.s.sol`

Verification:
- current compile/test/live-preflight workflow: `../../.github/workflows/cyvbWBTC_verify_v5.yml`
- current isolated Katana Anvil workflow: `../../.github/workflows/cyvbWBTC_anvil_live_fork_v9.yml`
- focused tests: `../test/CyvbWbtcCoreTest_v3.t.sol`

Latest completed compile/test/live-preflight result:
- build: pass
- focused tests: 7/7 pass
- live Katana topology: pass
- live production CurveYield swap routes required by deployment: not yet installed

The historical custom market ID 7001 is not used. The current strategy and balance fuses use official IPOR market ID 7.
