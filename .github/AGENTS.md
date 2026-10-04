# Smart-Contracts GitHub Actions Local Rules

This file adds workflow rules to the repository-root `AGENTS.md`.

- One workflow per responsibility. Do not create versioned workflow siblings as a debugging/retry strategy.
- Prefer editing/reusing the current workflow. If a genuine version bump is required, remove/archive the old active workflow in the same change.
- Before dispatching, inspect queued/in-progress Actions and do not launch a duplicate against the same vault/branch/fork/resource.
- Workflows sharing a mutable fork, signer, browser/login state, or deployment target are strictly single-flight.
- Generated result paths must never match the workflow's own push trigger.
- Diagnostic workflows must not run on every push to main unless explicitly required.
- Temporary repair/cancel/redrive workflows must be removed immediately after their bounded use.
