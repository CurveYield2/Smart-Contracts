# cyavKAT v21 — discontinued-contract ZIP cleanup

**Baseline:** `cyavKAT_signing_layer_v20.zip`. **Scope:** package hygiene and deployment safety; no Solidity source in `upgrade/src/`, retained live `deployed/phase1-*`, pinned upstream IPOR, or active retained `upgrade/script/` was changed.

- Dropped the entire discontinued `archive/` tree (governance/leaderboard/Plus sources, scripts and old tests).
- Dropped `deployed/test/`, a legacy test tree with unresolved imports to retired sources; current tests remain under `upgrade/test/`.
- Removed runnable retired `P6_02_CustodyV2Finish.s.sol` to avoid an accidental original-custody full unwind. The retained P6_01 custody integration remains unmodified.
- Removed stale `upgrade/deployments/katana-phase2.json` and four `test-conf-*` simulated/dry-run records. The current P2_01 deploy script writes the new Phase 2 manifest at run time; do not use historical addresses. Kept original live `katana-quests.json` and `katana-lending-v1.json` records.
- Replaced misleading historical contract inventory, fee/config reference and custody-farm docs with current-source guidance; deleted obsolete Phase 1–4 design-only specs. Revised V2 reference, POL, conformance, and README routing notes.
- Removed superseded changelog/handoff versions and stale v6 checksum list; `SHA256SUMS_v21.txt` enumerates the retained package files.
- Preserved executor's internal 35/20/20/25 allocation (growth V2 custody after Phase 6; contributors admin fee Safe), original Profit Custody's independent configurable internal split, and existing wrapper's 40/30/30 split. No new splitter, feeder or contributor address.

**Verification:** File-integrity comparison for retained Solidity and scripts; static discontinued-symbol/import/config scans; ZIP CRC and checksum verification. No local compilation, dependency installation, RPC, fork test or deployment.
