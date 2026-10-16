---
description: Delta-spec model (extended spec mode only) — feature specs as deltas against a living per-area baseline, synced back on archive into an auditable specified-vs-built trail
globs: ["docs/specs/**", ".claude/skills/spec-driven-development/**", ".claude/skills/spec-drift-detection/**"]
alwaysApply: false
---

# Delta-Spec Model (Baseline + Archive)

Opt-in: only specs written in **extended spec mode** (`spec-driven-development`) set
`baseline_area`. A spec without it is never archived; Phase 7.5 skips it with a one-line note.

| Artifact | Path | Role |
|---|---|---|
| Feature spec (delta) | `docs/specs/<date>-<slug>.md` + `.json` | One change |
| Baseline | `docs/specs/baseline/<area>.json` + `.md` | Accumulated intended state for an area |
| Audit trail | `docs/specs/baseline/<area>.audit.jsonl` | One line per archived delta: slug, date, drift verdict, what changed |

## Sidecar fields

```jsonc
{
  "baseline_area": "payments",   // required to participate in a baseline
  "delta": { "adds": [], "modifies": [], "removes": [] }   // optional
}
```

Without `delta`, `spec-archive.sh` folds the whole `change_manifest` and `public_contracts` into
the baseline. Removals must be explicit in `delta.removes` — archiving never infers deletion.

## Archive

1. **Only after `spec-drift-detection` returns a clean PASS** — archiving drifted work records a
   baseline the code does not match.
2. `bash scripts/spec-archive.sh docs/specs/<date>-<slug>.json` merges the delta into the
   baseline, applies `delta.removes`, appends the audit record, and regenerates `<area>.md`.
   It is idempotent per slug (detected via the audit trail).

## Rules

- The baseline is derived, never hand-edited — edit the feature spec and re-archive.
- Never archive on drift `NEEDS_CHANGES`.
