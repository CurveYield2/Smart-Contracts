# v25: factory IPOR fee authority verification repair

- Correct `P9_FinalizeFeeAuthority` to verify the *actual* IPOR fee path: ADMIN_FEE Safe -> gate -> FeeManager role 100 -> vault technical roles 400/500.
- Confirm factory role mappings, FeeManager technical permissions, and forbid direct gate access to vault's technical fee setters.
- Stop registering unusable direct vault technical fee setters in `P3_04_ConfigureGate`; all FeeManager role-100 selectors remain registered in the gate's dedicated ADMIN_FEE lane.
- Keep all other guard checks, original Safe IPOR OWNER authority, and v23/v24 handover repairs. No core contracts or upstream IPOR sources modified.
