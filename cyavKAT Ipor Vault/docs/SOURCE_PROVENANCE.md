# Source provenance

`workspace/ipor-fusion/` holds only the files the phase2 build compiles (the union of the default and `size`
profile build sources), exported byte-exact from their pinned commits (LF, as on GitHub):

| Component | Version / commit | Files | How exported |
|---|---|---|---|
| IPOR Fusion (`contracts/`) | commit `9fb9e80613f55e4fac1a6120012ebb38ae7943a6` | 91 | `git show <commit>:<path>` — all unmodified |
| forge-std (`lib/forge-std`) | v1.7.6, `b6a506db2262cad5ff982a87789ee6d1558ec861` (IPOR submodule) | 25 | `git show <commit>:<path>` |
| @openzeppelin/contracts | 5.0.2 | 48 | npm package, as installed by IPOR's lockfile |
| @openzeppelin/contracts-upgradeable | 5.0.2 | 8 | npm |
| @morpho-org/morpho-blue | 1.0.0 | 16 | npm |
| @uniswap/v3-core | 1.0.1 | 1 | npm |

No IPOR file is modified and no local file was added to the IPOR tree. CurveYield code that derives from IPOR lives
in `workspace/phase2/src` and is flagged in CONTRACT_CLASSIFICATION_AND_ROLES.md (`CurveYieldWithdrawalManagerV2`
+ `CurveYieldWithdrawalManagerV2StorageLib` from IPOR `WithdrawManager`; `CurveYieldRateAwareBalancerBalanceFuse`
from IPOR `BalancerBalanceFuse`).

Other on-chain code the stack calls but does not ship (integration context, verified on Katana explorers): the live
cyavKAT PlasmaVault and its IPOR managers, Morpho Blue, Sushi V3 (factory `0x203e8740894c8955cB8950759876d7E7E45E04c1`,
NPM `0x2659C6085D26144117D904C46B48B6d180393d27`), Katana SushiStaker `0xbe12e1b5C4859a3d141412748279B67458F729E9`,
Charm AlphaProVault vbWBTC/vbUSDC `0xBC2AE38CE7127854b08eC5956F8A31547f6390ff`, Merkl distributor
`0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae`, the CurveYield DEX (separate audit package), Aragon OSx.

Path layout: `workspace/phase2/foundry.toml` remaps `contracts/`, `@openzeppelin/`, `@morpho-org/morpho-blue/`,
`@uniswap/v3-core/`, `forge-std/` into `../ipor-fusion/`. The only change against the development tree is that path.
`SHA256SUMS.txt` covers every file in the package.
