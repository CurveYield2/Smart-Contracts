# v24: live Ownable / Ownable2Step compatibility at handover

- Fix `P3_05_Handover` to recognize immediate `transferOwnership` completion on live Ownable router/custody contracts.
- Only call gate-mediated `acceptContractOwnership` on two-step implementations with verified `pendingOwner() == gate`.
- Preserve all final postconditions requiring the gate own every fee-bearing module and preserve ADMIN_FEE role exclusivity.
- Retain v23 POL and RevenueCustodyV2 fee-selector registration repair. No core Solidity contract changes.
