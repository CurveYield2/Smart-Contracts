# CurveYield ETH / cyvbETH — Katana — v1

This directory contains the cyvbETH IPOR Fusion vault contracts, deployment tooling, route configuration, focused tests, and verification workflow.

## Strategy

cyvbETH accepts vbETH and preserves the live cyvbWBTC fee, LTV, keeper, nested-cyvbUSDC, earn-pool, withdrawal, and administration model.

The keeper controls fresh-capital allocation between:

1. **Morpho lending** — supply vbETH as the loan token to the exact Katana vbETH/yvvbUSDC market:
   `0x2c4f26c76b4de51d3c9260c15a796cd2a35efab17786d0aa78ca2e638b0f8ba8`
2. **f(x)/fxMINT strategy** — convert vbETH to weETH, use the live f(x) weETH collateral pool, borrow fxUSD at the same configured LTV policy as cyvbWBTC, convert fxUSD to vbUSDC, and deposit the stable leg into cyvbUSDC.
3. **Idle vbETH** — capital not selected by the keeper remains idle in the vault.

There is no fixed allocation ratio. The keeper chooses how much deployable idle vbETH goes to each strategy.

## Verified Katana dependencies

- Chain ID: `747474`
- vbETH: `0xEE7D8BCFb72bC1880D0Cf19822eB0A2e6577aB62`
- weETH: `0x9893989433e7a383Cb313953e4c2365107dc19a7`
- vbUSDC: `0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36`
- Current cyvbUSDC PlasmaVault: `0xDf9CbCB8b57A031e91CAe673a6A5786d85Ce2eC5`
- IPOR FusionFactory: `0xc29b8D591d6a3f109Ca7ba384F2e00162866D37B`
- CurveYield Sushi router: `0x01F9894f92ea9224fECc8C35482E20a05De13582`
- Official Chainlink Katana ETH/USD proxy: `0x7BdBDB772f4a073BadD676A567C6ED82049a8eEE`

### f(x)

No live f(x) vbETH collateral pool exists. The verified ETH-side pool uses weETH:

- Pool: `0x6776cE77f47aAB00405fD5776c4BaAdc68C8Ce3D`
- Pool manager: `0x27b3eE81DF2Dd7356D5ac282e2416991A616f96a`
- Collateral: weETH
- fxUSD: `0x4c03ff0f44A55e7098a09016E02a01d3cdC2FDF9`
- Price oracle: `0x849b9e3119B7c4E4Dd0DdfaD1E0DFe587158692d`
- fxBASE: `0xdE2E0736Ee813C425b0eE1a6e0627233B3B1EeF8`
- Earn gauge: `0x76A84525c5f61136Cf562dC1bD5aBB19FB8B53fC`

The custom f(x) fuse therefore routes vbETH -> weETH before opening/increasing the position and weETH -> vbETH when collateral is released.

### Morpho

- Morpho core: `0xD50F2DffFd62f94Ee4AEd9ca05C61d0753268aBc`
- IPOR Morpho market ID: `14`
- Official IPOR Morpho SupplyFuse: `0xC66c3F5cC5e1550A0Ff960c06D630A2FBB80E19d`
- Official IPOR Morpho BalanceFuse: `0x83790D83C23461cd22429276406C4f09DB885A85`
- Approved market key: `0x2c4f26c76b4de51d3c9260c15a796cd2a35efab17786d0aa78ca2e638b0f8ba8`
- Loan token: vbETH
- Collateral token: yvvbUSDC `0x80c34BD3A3569E126e7055831036aa7b212cB159`
- LLTV: 77%

`CyvbEthMorphoAllocatorFuse_v1` wraps IPOR's official Morpho SupplyFuse instead of reimplementing Morpho. This preserves the cyvbWBTC onboarding-fee-share burn before freshly deposited capital can be deployed.

Only the exact requested Morpho market is granted as market-14 substrate.

## Fees and LTV policy

The deployment script retains the cyvbWBTC settings:

- IPOR management: 0.30%
- IPOR performance: 2.00%
- CurveYield management: 1.00%
- CurveYield performance: 8.00%
- Total management: 1.30%
- Total performance: 10.00%
- Onboarding fee: 0.75%, burned as shares
- Scheduled-withdraw request fee: 0.50%, burned as shares
- Instant-withdraw fee: 1.00%, burned as shares
- Target LTV: 50%
- High trigger/reset: 60% / 58%
- Low trigger/reset: 45% / 50%
- Instant-withdraw post-withdraw ceiling: 55%
- Withdrawal window: 7 days

## Withdrawal ordering

Instant withdrawal fuses are configured in this order:

1. cyvbETH Morpho allocator — withdraw supplied vbETH first.
2. cyvbETH f(x) strategy — satisfy only the remaining vbETH requirement.

Scheduled withdrawals use the same liquidity order. The withdraw manager releases available Morpho vbETH first and then recomputes the remaining requirement before the f(x) strategy unwinds.

## Routes

`script/ConfigureCyvbEthRoutes_v1.s.sol` installs:

- fxUSD -> vbUSDC, 0.01%
- vbUSDC -> fxUSD, 0.01%
- vbUSDC -> vbETH, 0.05%
- vbETH -> weETH, 0.05%
- weETH -> vbETH, 0.05%

All routes use the existing CurveYield router's 15-minute TWAP guard and 200-bps maximum deviation with zero route-specific router fee.

Route configuration is a production action and is **not** performed by the verification workflow.

## Deployment

`script/DeployCyvbETH_v1.s.sol`

Required environment:
- `PRIVATE_KEY`
- `CURVEYIELD_USDC_VAULT` — current cyvbUSDC address

Optional:
- `KEEPER`
- `FINAL_OWNER`

The deployment script refuses to complete unless required routes and live protocol topology match the verified constants.

## Testing

`test/CyvbEthFuseV1Test_v1.t.sol` covers:
- cyvbWBTC-equivalent LTV policy
- vbETH/weETH topology binding
- exact Morpho market binding
- keeper-facing strategy vault-context protection
- official Morpho fuse binding
- vbETH price-feed scaling
- 18-decimal weETH collateral indicator behavior

`.github/workflows/cyvbETH_verify_v1.yml` compiles and runs focused tests in GitHub, verifies current Katana dependencies, and is extended with a fork-only deployment lifecycle simulation before completion.

No production cyvbETH vault deployment or production router mutation is performed by the test stack.
