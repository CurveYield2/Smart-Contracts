# cyavKAT v21 test entry points

The **only packaged test suite** is `../upgrade/test/`, using `../upgrade/foundry.toml` and `../upgrade/run-tests.sh`. It targets the V2 source at `../upgrade/src/`.

The discontinued `archive/test/` suites and broken `deployed/test/` imports have been removed; neither qualifies this deployment. Unversioned `test-conf-*` dry-run files and outdated Phase 2 deployment manifests have likewise been removed. Tests must use fresh isolated deployment records and must never trust an old address as proof of successful deployment.

No compilation, dependency installation, RPC call, fork simulation or live transaction was performed for the v21 ZIP cleanup. Run the relevant tests and fork qualification in the intended GitHub / Foundry environment before any on-chain use.
