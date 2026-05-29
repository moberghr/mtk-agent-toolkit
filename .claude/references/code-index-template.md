---
description: Template for CODE_INDEX.md — repo-root capability index seeded by setup-bootstrap, consumed by code-simplification --audit-duplicates
globs: ["CODE_INDEX.md"]
alwaysApply: false
---

# CODE_INDEX.md — Capability Index

> CODE_INDEX is a capability-oriented index of the codebase, organized by **what the code does** rather than by **where it lives**. Its purpose is to make duplication visible before new code is written.

`setup-bootstrap` generates an initial CODE_INDEX.md at the repo root during first-time setup. `code-simplification` (in `--audit-duplicates` mode) refreshes it and surfaces near-duplicate capabilities for consolidation.

## Format

Each entry is one row in a capability table. Group rows by domain (auth, billing, persistence, http, observability, etc.).

The rows below are **ILLUSTRATIVE ONLY** — they show the format using fictional paths. When seeding a real CODE_INDEX.md, NEVER copy these rows: populate from the repo's actual capabilities (every `path:Symbol` must resolve on disk), or write an explicitly-empty index. See `setup-bootstrap` STEP 4.95.

```markdown
# Code Index

> Capability index — what the codebase can do, not where files live.
> Refresh: `bash scripts/build-code-index.sh` (or `/mtk audit duplicates`).
> Last built: <ISO date>

## Authentication & Authorization  <!-- EXAMPLE — fictional paths, replace or delete -->

| Capability | Entry point | Notes |
|---|---|---|
| <verb phrase> | `<path/to/file>:<Symbol>` | <non-obvious constraint or "use this — don't reimplement"> |

## Persistence  <!-- EXAMPLE — fictional paths, replace or delete -->

| Capability | Entry point | Notes |
|---|---|---|
| <verb phrase> | `<path/to/file>:<Symbol>` | <constraint / footgun> |

…
```

## Required columns

- **Capability** — verb phrase describing what it does ("issue access token", not "TokenService").
- **Entry point** — `path/to/file:Symbol` so a reader can jump straight to the canonical implementation.
- **Notes** — non-obvious constraints, the "use this — don't reimplement" hint, or known footguns.

## When to add an entry

- Any new public API, handler, exported function, or service method that future work might be tempted to re-implement.
- Any utility that has been re-invented twice — consolidate first, then index.

## When to consult

- Before writing a new feature: scan the relevant section to see if the capability already exists.
- During spec review: `+C #13` (prior work checked) is partly satisfied by a CODE_INDEX scan.
- During simplification: `--audit-duplicates` mode greps the index for near-duplicate capability names.

## What NOT to put here

- Internal helpers with single call-sites — not capabilities, just locality.
- Test fixtures and mocks.
- Generated code (migrations, gRPC stubs, OpenAPI bindings).
- Anything that would rot faster than the index can be refreshed.

## Drift handling

If the index is older than 30 days OR the repo has had >50 commits since the last build, treat it as stale: refresh before relying on it, and surface a one-line "stale index" note in any review that cites it.
