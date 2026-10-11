# Unreleased V17 working change — POL BPS reserve (not tested or uploaded)

- `CurveYieldRevenueCustodyV2.reserveAvkatForPolBps(uint16 bps)` replaces the absolute-amount reservation. The base is **the full avKAT ERC-20 balance held by V2 custody**, including amounts already budgeted for POL, not just idle avKAT.
- The call replaces the discretionary POL budget instead of adding another reserve; `0` releases discretionary allocation, but not unspent third-party feeder funding.
- `feederPolBudgetAvkat` tracks those protected feeder deposits separately, and is debited when `polDeploy` consumes POL budget.
- This is an operator-applied snapshot percentage, not a perpetual automatic target. Every new balance-adjustment requires a new call to reset the discretionary reserve. It does not unwind farm or legacy-loop positions.
- V2 does **not** run an independent Morpho loop: it only reads `positionSnapshot()` from, transfers avKAT to, and calls `deployAll()` on the retained live `CurveYieldProfitCustody` via immutable `LOOP_CUSTODY`. No duplication of loop positions or Morpho logic in V2.
- Existing unmodified live custody, IPOR vault code, and accounting balance fuses remain unchanged.
- Relevant unit test source was updated but **not run**, per user instruction. No ZIP repacked, no GitHub action or upload executed for this working change.
