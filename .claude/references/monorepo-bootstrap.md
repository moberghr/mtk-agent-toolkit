---
name: monorepo-bootstrap
description: Per-package CLAUDE.md generation for monorepos — template, generation rules, and the root Monorepo Layout block. Read on-demand by setup-bootstrap STEP 4.5 only when a monorepo is confirmed.
globs: [".claude/skills/setup-bootstrap/**"]
alwaysApply: false
---

# Monorepo Bootstrap — Per-Package CLAUDE.md

Read this companion only after `setup-bootstrap` STEP 4.5 has **confirmed a
monorepo** and **enumerated the package directories** (capped at 20). It covers
what to write into each package and how to update the root file.

## Generate per-package CLAUDE.md

**For each package**, create `<package-path>/CLAUDE.md` **only if it doesn't
already exist** (never overwrite — these may be hand-authored).

Each file targets **15–30 lines**. It should contain the **local delta** — what
Claude needs to know here that isn't already in root CLAUDE.md. No repeated
rules, no general guidance.

Template:

```markdown
# [Package Name] — Local Context

> This package lives in a monorepo. See root `CLAUDE.md` for team-wide standards.
> This file only documents what's specific to this package.

## What this is
[One or two sentences. Inferred from README, package.json description, .csproj description, or directory name.]

## Framework / runtime
[From package.json dependencies, .csproj TargetFramework, pyproject.toml requires-python, etc. Only note if it differs from the root default.]

## Build / test (local)
[Only if commands differ from root. Otherwise omit this section.]
```bash
[package-specific commands, if any]
```

## Local conventions
[Only patterns unique to this package. Examples:
 - "No I/O — this is a pure domain package"
 - "Client-only — no server imports"
 - "Public API package — changes require version bump"
 - "This service owns the <X> database schema"
]

## Dependencies / boundaries
[Only if there are notable dependency rules:
 - "Imports from ../core only — never from ../web"
 - "This package is consumed by the SDK — breaking changes require a major bump"
]
```

**Rules for per-package generation:**
- **Mixed-stack packages (F11):** when a package's own markers indicate a different stack than the repo primary (per `setup-detect.sh`'s package enumeration), name that stack explicitly in "Framework / runtime" and give its build/test commands (from that stack's `tech-stack-{stack}` skill `## Build & Test Commands`) in "Build / test (local)" — still within the 15–30-line budget.
- **Omit any section you can't fill with something specific.** An empty "Local conventions" section is worse than no section.
- If a package has no notable local delta (e.g., a trivial shared `types/` package), generate a 5-line stub:
  ```markdown
  # [Name] — Local Context

  > See root `CLAUDE.md`. No package-specific conventions beyond the root standards.
  ```
- Never duplicate rules from root. If a rule appears in root, do not re-state it locally.
- Never overwrite an existing per-package `CLAUDE.md` — skip with a note.

## Update root CLAUDE.md

Add a short **Monorepo Layout** block to the root CLAUDE.md (inside the 120-line
cap — this earns its place because it helps Claude navigate):

```markdown
## Monorepo Layout

This is a monorepo with [N] packages. Each package has its own `CLAUDE.md` with local context.

- `apps/api/` — [one-line purpose]
- `apps/web/` — [one-line purpose]
- `packages/core/` — [one-line purpose]
- ...

Claude loads package-level `CLAUDE.md` files automatically when working in that directory.
```

If the root is already near 120 lines, collapse each entry to a single line and
skip the one-line purpose.
