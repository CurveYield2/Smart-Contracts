# wcyavKAT wrapper + fee: spec addendum (APPROVED 2026-09-25)

## Why
- **Collateral:** it's the collateral token for the new avKAT lending market (12% haircut oracle). It avoids a Morpho market whose collateral is the vault's own share, which may be what breaks IPOR's indexer.
- **Revenue:** it gives CurveYield a cut of that market's collateral yield.

## Contracts
1. **CurveYieldWrappedCyavKat (`wcyavKAT`):** an immutable ERC-4626 over cyavKAT (OpenZeppelin 5), with 20 decimals, no admin, no pause.
   - **Management fee:** 2% a year on the cyavKAT held.
   - **Performance fee:** 8% of the cyavKAT share-price gain above a global high watermark (the avKAT value of 1 cyavKAT).
   - **Accrual:** `accrue()` is callable by anyone and runs before every deposit, mint, withdraw and redeem. Fees move out as cyavKAT to the fee splitter; the watermark then rises to the current price. If the price dips, no performance fee is taken until it recovers.
   - **Net pricing:** `totalAssets()` = cyavKAT held − fees accrued but not yet taken. The wrapper's exchange rate, and therefore the oracle, is always net of fees, so accruing never makes the price jump.
2. **CurveYieldWrapperFeeSplitter:** receives the fee cyavKAT. `distribute()` is callable by anyone:
   - **40%** to the admin fee receiver (fee Safe `0x4762…`), in cyavKAT;
   - **40%** to the contributors reward sink, in cyavKAT;
   - **20% burned with the IPOR burn fuse:** the splitter sends it to the vault's withdraw manager. The vault's `BurnRequestFeeFuse` (IPOR, audited) then burns the withdraw manager's cyavKAT through the vault's `_update` pipeline. Shares go down and assets stay the same, so PPS rises for every holder. There's no redeem and no fee.
     - Live: the deployer (ALPHA) runs the burn with a fresh `BurnRequestFeeFuse`. The live `0x44D3` reads the wrong withdraw-manager slot.
     - Phase 2: the executor's harvest burns the withdraw manager's balance.
   - The two recipient addresses can be set by the owner (the deployer until the Phase 3 handover to the DAO). The split is fixed.
3. **IporVaultHaircutOracle12 (wrapper version):** price = wcyavKAT → cyavKAT → avKAT × 0.88. With 86% LLTV, the maximum borrow is 75.7% of collateral value.

## Market
Loan avKAT, collateral wcyavKAT, oracle as above, AdaptiveCurveIrm, LLTV 86%. The vault lends into it as a market 14 (MORPHO) substrate.
