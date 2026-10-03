# CurveYield USDC / cyvbUSDC — Katana — v1

This directory contains the first implementation pass for the CurveYield USDC IPOR Fusion vault on Katana.

## Canonical vault parameters

- Chain: Katana (chain id 747474)
- Vault factory: IPOR FusionFactory proxy `0xc29b8D591d6a3f109Ca7ba384F2e00162866D37B`
- Name: `CurveYield USDC`
- Symbol: `cyvbUSDC`
- Underlying / deposit asset: vbUSDC `0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36`
- vbUSDC valuation: static USD 1.00 using IPOR USDPriceFeed `0x64518f821Cd07A9471711Eba5D8fEF9c75063B01`
- Morpho: `0xD50F2DffFd62f94Ee4AEd9ca05C61d0753268aBc`

### Allowed Morpho supply markets

- avKAT / vbUSDC: `0xbd48214a2f12e951da20ad0b8fd83b611c693b5bbaa280b68ba4075678f2a138`
- siUSD / vbUSDC: `0xf7fc5cc82200ddf8f23188ddbd6727eda2c8bc41863e91fb767bbc6e4f71890e`
- weETH / vbUSDC: `0x76e311d4b0e2e6ae88ad9bab18063452a6d39837d7104c430ff62457b91cb2cb`

Allocation between these markets is intentionally not hard-coded. The keeper/Alpha chooses amounts when deploying fresh capital and when rebalancing.

### Fees

The factory clone must use IPOR's live “Middle Way” DAO fee package. The deployment tooling resolves and verifies the package against the live Katana factory before broadcast instead of hard-coding an assumed index.

Additional CurveYield fees:
- Management / TVL fee: 0.50% (50 bps)
- Performance fee: 8.00% (800 bps)
- All non-IPOR fee revenue: `0x47623C62f281807D615eeb4A2CEee9d97F9D3C49`

IPOR's own cut remains routed to the factory-configured IPOR fee recipient.

### Rewards

- Merkl Distributor: `0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae`
- Official current Katana MerklClaimFuse: `0xF4278e62a6B5A45E378e6692C7Aa9C7291E7ce36`
- KAT is claimed to the Plasma Vault by putting KAT in MerklClaimFuse's `doNotTransferToRewardManager_` list.
- `KatRewardSwapAndSplitFuse_v1.sol` then reuses the configured Universal Token Swapper path to convert KAT -> vbUSDC.
- Only the newly-created vbUSDC balance delta is distributed:
  - 70% -> the vault's RewardsClaimManager
  - 30% -> `0x47623C62f281807D615eeb4A2CEee9d97F9D3C49`
- Existing vbUSDC principal is never included in the rewards split.

### Reference deployment

Existing CurveYield Katana vault used as the configuration reference:
`0xEd83daf48429cfb2C650Fd721b9241e180fd4548`

The deployment probe reads this reference vault and the live IPOR factory before a production broadcast so swap-fuse/router configuration and the Middle Way fee package are not guessed.

## v1 files

- `contracts/KatRewardSwapAndSplitFuse_v1.sol`
- `script/DeployCyvbUSDC_v1.s.sol`
- `scripts/katana_probe_v1.py`
- `.github/workflows/cyvbUSDC_probe_v1.yml`

No production deployment is performed by the verification workflow.
