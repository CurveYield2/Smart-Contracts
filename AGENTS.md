# Smart-Contracts Agent Policy

Policy version: v1

## Repository hygiene and execution discipline — mandatory

- Before creating any file, inspect this repository and the nearest local `AGENTS.md` for the owning vault/subsystem.
- Reuse or edit the current canonical contract, test, script, deployment helper, handoff, or workflow before creating another file with the same responsibility.
- Do not create retry/version trash such as `foo-v2`, `foo-v3`, `foo-fixed`, `foo-final`, `foo-new`, or `foo-copy` merely because an attempt failed.
- If a genuine version bump is necessary, keep only the new live version in the active location and remove/archive the superseded one in the same change.
- Put contracts in the vault's contract source directory, tests in its test directory, deployment scripts in its established script directory, handoffs only in its handoff directory, and generated test results only in the established results/artifact location.
- Do not place vault-specific files at repository root.
- Prefer exact official/proven upstream protocol contracts, interfaces, fuses, substrates, market IDs, and patterns whenever they exist. Custom code should be the smallest necessary modification to the closest proven implementation.
- Before starting a GitHub Actions workflow, fork simulation, deployment test, browser session, or other long-running operation, inspect existing queued/in-progress work. Never run multiple same-kind executions against the same vault/branch/fork/browser state in parallel.
- If an equivalent run is active, observe/reuse it. If it is stale/hung, cancel/retire it before launching exactly one replacement.
- Do not execute the same failed test/simulation three times with materially unchanged code, inputs, and environment. After two identical failures, diagnose and change something relevant before another run.
- Do not repeatedly analyze the same unchanged logs or source. Re-analysis requires new evidence or a changed implementation/environment.
- Temporary diagnostics and generated data should use runtime/artifact storage, not permanent source files, unless durable evidence is explicitly required.
- A workflow that writes results must never watch those result paths with a push trigger.
- Do not compile or download dependencies in a local model/container environment. GitHub-hosted execution may compile and install dependencies when required.

## Completion cleanup

Before finishing:

- remove superseded same-purpose files and temporary helpers;
- verify only one live version of each operational file family remains;
- verify no duplicate same-kind workflow/simulation/browser run is active;
- verify every new file is in the correct vault/subsystem directory;
- leave one clear current implementation and one clear handoff/state when a handoff is required.
