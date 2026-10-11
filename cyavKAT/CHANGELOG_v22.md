# v22: verified Katana fuse reuse

- `upgrade/script/P2_01_Deploy.s.sol`: reuse existing `ZeroBalanceFuse` for `MARKET_ZERO` (`uint256.max`) at `0xE3E28F04499470bAc1dAc842aEe424a185d14D42` instead of redeploying.
- Tested in Contract-Automation Katana Anvil fork including `P2_02_ConfigureVault`, GitHub run 38144542830.
- No other Solidity or configuration changes from v21.
- See the full end-to-end workflow results for completion status; source-only v22 is not a production-deployment endorsement.
