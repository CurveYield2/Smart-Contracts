# CurveYield USDC / cyvbUSDC — Katana — v2

This directory contains the current implementation and deployment tooling for the CurveYield USDC IPOR Fusion vault on Katana.

## Current status

The current code tree is compile-clean in GitHub Actions and the focused reward-fuse test suite passes 6/6.

Verified live on Katana:
- Chain ID: `747474`
- Official IPOR Fusion factory: `0xc29b8D591d6a3f109Ca7ba384F2e00162866D37B`
- IPOR Middle Way DAO fee package: index `1` = 0.30% management + 2.00% performance
- Existing CurveYield Sushi V3 fee router owner: `0x47623C62f281807D615eeb4A2CEee9d97F9D3C49`
- CurveYield Safe threshold: `1`
- Direct Sushi V3 KAT/vbUSDC 0.05% pool: `0x10045367E619Caae6f60CC80046c43c6cD55f629`

The KAT -> vbUSDC route is **not installed on the existing router yet**. Run the route configuration script before the vault deployment script.

No production vault deployment or router mutation has been broadcast by this repository work yet.

## Vault specification

- Name: `CurveYield USDC`
- Symbol: `cyvbUSDC`
- Underlying / deposit asset: vbUSDC `0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36`
- vbUSDC price treatment: static USD 1.00 through IPOR USDPriceFeed
  `0x64518f821Cd07A9471711Eba5D8fEF9c75063B01`
- Morpho: `0xD50F2DffFd62f94Ee4AEd9ca05C61d0753268aBc`

### Allowed Morpho supply markets

The keeper can choose any allocation among these three markets at deployment/rebalance time. No fixed ratio is stored in the vault.

- avKAT / vbUSDC
  `0xbd48214a2f12e951da20ad0b8fd83b611c693b5bbaa280b68ba4075678f2a138`
- siUSD / vbUSDC
  `0xf7fc5cc82200ddf8f23188ddbd6727eda2c8bc41863e91fb767bbc6e4f71890e`
- weETH / vbUSDC
  `0x76e311d4b0e2e6ae88ad9bab18063452a6d39837d7104c430ff62457b91cb2cb`

The strategy is intentionally **supply-only**. No Morpho borrow or collateral fuse is installed.

All three markets use the official IPOR market-41 Morpho supply fuse as an instant-withdraw path.

## Fees

### IPOR share — Middle Way

The deployment script resolves and verifies live factory package index `1` before cloning:

- IPOR management: 0.30% / 30 bps
- IPOR performance: 2.00% / 200 bps
- IPOR recipient: factory-configured DAO recipient

### CurveYield share

All non-IPOR fees go to:

`0x47623C62f281807D615eeb4A2CEee9d97F9D3C49`

Additional CurveYield fees:
- Management / TVL: 0.50% / 50 bps
- Performance: 8.00% / 800 bps

Configured vault totals:
- Management: 0.80% / 80 bps
- Performance: 10.00% / 1000 bps

## Rewards

KAT:
`0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d`

Official IPOR MerklClaimFuse:
`0xF4278e62a6B5A45E378e6692C7Aa9C7291E7ce36`

Merkl Distributor:
`0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae`

Reward flow:

1. Keeper calls the installed IPOR MerklClaimFuse through RewardsClaimManager.
2. KAT must be included in MerklClaimFuse's `doNotTransferToRewardManager_` list so KAT lands on the Plasma Vault.
3. Keeper executes `KatRewardSwapAndSplitFuse_v3.sweepKatRewards(minNetAmountOut, deadline)` through RewardsClaimManager.
4. The fuse swaps the vault's KAT through the existing CurveYield Sushi V3 fee router into vbUSDC.
5. The fuse measures and verifies the exact newly-created vbUSDC delta.
6. That delta is split:
   - 70% -> IPOR RewardsClaimManager
   - 30% -> `0x47623C62f281807D615eeb4A2CEee9d97F9D3C49`
7. RewardsClaimManager `updateBalance()` starts/rebases the normal 15-day IPOR vesting schedule for the 70% user share.

Pre-existing vault vbUSDC principal is excluded from the split by construction.

If a reward swap is skipped or fails, residual KAT is accounted in the vault through ERC20 balance market 7 and the reference-vault KAT price source.

## Existing CurveYield swap infrastructure

Reference vault:
`0xEd83daf48429cfb2C650Fd721b9241e180fd4548`

Existing verified CurveYield router:
`0x01F9894f92ea9224fECc8C35482E20a05De13582`

Router contract:
`CurveYieldSushiV3FeeRouter`

The old reference-vault `RouterSwapFuse` deployment is vault-bound and cannot safely be reused for cyvbUSDC. Its existing router is reusable and is used by the new reward-only fuse.

The new direct route is:

`KAT | fee 500 | vbUSDC`

Encoded path:

`0x7f1f4b4b29f5058fa32cc7a97141b8d7e5abdc2d0001f4203a662b0bd271a6ed5a60edfbd04bfce608fd36`

Route configuration:
- route-specific CurveYield router fee: 0 bps
- TWAP window: 900 seconds
- maximum TWAP deviation: 200 bps

## Current files

### Contract

`contracts/KatRewardSwapAndSplitFuse_v3.sol`

Current production candidate reward fuse.

### Deployment / operations

`script/ConfigureKatVbUsdcRoute_v1.s.sol`

Configures the direct KAT -> vbUSDC route on the existing CurveYield router through its threshold-1 Safe owner, sets route fee to zero, and installs the 900-second / 200-bps TWAP guard.

`script/DeployCyvbUSDC_v4.s.sol`

Clones and configures the vault through the official IPOR factory. It refuses to deploy unless the KAT -> vbUSDC route is already present.

`script/RebalanceCyvbUSDC_v3.s.sol`

Keeper/ALPHA strategy deployment and rebalance script. Allocation is supplied at runtime with:

- `ALLOC_AVKAT_BPS`
- `ALLOC_SIUSD_BPS`
- `ALLOC_WEETH_BPS`

The values must total 10,000 bps.

With `FULL_REBALANCE=true`, it exits all three permitted Morpho markets first, reads the resulting idle vbUSDC balance, and redeploys it according to the supplied ratios.

### Tests

`test/KatRewardSwapAndSplitFuseV3Test_v2.t.sol`

Focused checks:
- exact 70/30 split
- pre-existing vbUSDC principal remains untouched
- rounding dust goes to RewardsClaimManager/users
- missing route skips without moving funds
- router revert skips and clears allowance
- direct calls outside reward context revert
- expired deadlines revert

Current result: 6 passed / 0 failed.

### Verification workflow

`.github/workflows/cyvbUSDC_verify_v4.yml`

Performs:
- Solidity compile of current contract and scripts
- focused Foundry tests
- Katana chain check
- live IPOR Middle Way package check
- existing router/Safe ownership check
- direct Sushi V3 KAT/vbUSDC pool check
- route readiness check

A missing KAT -> vbUSDC route is reported as a deployment prerequisite rather than a code failure.

## Deployment order

### 1. Configure the existing router

Run:

`ConfigureKatVbUsdcRoute_v1.s.sol`

This must complete before the vault deploy script. It requires a private key belonging to the threshold-1 Safe owner controlling `0x47623C62...3C49`.

### 2. Deploy and configure cyvbUSDC

Run:

`DeployCyvbUSDC_v4.s.sol`

Required:
- `PRIVATE_KEY`

Optional:
- `KEEPER` — defaults to deployer
- `FINAL_OWNER` — defaults to deployer

The deployment script performs post-deployment assertions before treating the configuration as valid.

### 3. Allocate fresh capital / rebalance

Run:

`RebalanceCyvbUSDC_v3.s.sol`

Required:
- `VAULT`
- `PRIVATE_KEY` for an immediate ALPHA-role keeper

Optional:
- `FULL_REBALANCE=true|false`
- `ALLOC_AVKAT_BPS`
- `ALLOC_SIUSD_BPS`
- `ALLOC_WEETH_BPS`

## Recovery provenance

The previous CurveYield deployment's original `src/` directory was unavailable. The implementation was reconstructed from:
- the supplied Foundry `broadcast/`, `out/`, and `script/` archives
- live reference-vault reads
- KatanaScan verified CurveYield router/reward-fuse source
- current IPOR Fusion source and Katana deployment registry
- live Katana contract and pool checks

The uploaded artifacts recovered the original Safe/router operational conventions, including the threshold-1 prevalidated Safe execution flow and the 900-second / 200-bps route TWAP guard.
