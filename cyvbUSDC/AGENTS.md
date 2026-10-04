# cyvbUSDC Local Agent Rules

This file adds vault-specific rules to the repository-root `AGENTS.md`.

- Work only inside this vault unless the task explicitly requires a shared repository change.
- Inspect the existing folder layout before creating anything; follow existing `contracts`, `test`, `script`/`scripts`, `handoffs`, and results directories.
- Keep one live implementation per contract/test/script responsibility. Do not create a new numbered sibling to retry a failed approach.
- If a real replacement is needed, remove/archive the superseded active file in the same change.
- Reuse official/proven upstream protocol code and identifiers where available; make minimal modifications rather than reimplementing protocol behavior from scratch.
- Run one simulation/test/deployment lane at a time for this vault when executions share the same branch, fork, signer, or mutable environment.
- After two materially identical failures, stop rerunning and diagnose the cause before another execution.
- Do not create repeated analysis/status/test-result files for unchanged evidence. Use the existing canonical result/handoff when one exists.

- Solidity/source belongs under `contracts/`; tests under `test/`; deployment scripts under `script/`.
- Do not create extra top-level result/status files in `cyvbUSDC/`; use workflow artifacts or the established test structure unless durable evidence is required.
