---
description: Delta-spec model — feature specs as deltas against a living per-area baseline, synced back on archive into an auditable specified-vs-built trail
globs: ["docs/specs/**", ".claude/skills/spec-driven-development/**", ".claude/skills/spec-drift-detection/**"]
alwaysApply: false
---

# Delta-Spec Model (Baseline + Archive)

> Source-of-truth for how feature specs relate to a living baseline and how the
> auditable specified-vs-built trail is produced.

## Why

A per-feature spec captures what *one change* intended. Over many changes the
question "what is the system *supposed* to be, and does the code match?" gets
lost across dozens of dated spec files. The delta-spec model keeps a **living
baseline** per area and treats each feature spec as a **delta** against it. On
archive — only after the drift check passes — the delta is **synced back** into
the baseline and an audit record is appended. The result is a durable
specified-vs-built trail, which matters in regulated/finance contexts.

## The three artifacts

| Artifact | Path | Role |
|---|---|---|
| Feature spec (delta) | `docs/specs/<date>-<slug>.md` + `.json` | One change, as today |
| Baseline (canonical) | `docs/specs/baseline/<area>.json` + `.md` | Accumulated current intended state for an area |
| Audit trail | `docs/specs/baseline/<area>.audit.jsonl` | One line per archived delta: slug, date, drift verdict, what changed |

`<area>` is the slice/subsystem the change belongs to, declared as
`baseline_area` in the spec JSON sidecar (e.g. `payments`, `toolkit-workflow`).

## Sidecar fields (added to the JSON manifest)

```jsonc
{
  "baseline_area": "payments",          // required to participate in baseline
  "delta": {                             // optional; if absent, derived from
    "adds":     ["public_contracts[] or files[] added vs baseline"],
    "modifies": ["... changed vs baseline"],
    "removes":  ["... removed from baseline"]
  }
}
```

If `delta` is omitted, `spec-archive.sh` folds the whole `change_manifest` and
`public_contracts` into the baseline (every entry treated as add/modify).
Removals must be explicit in `delta.removes` — archiving never deletes from the
baseline by inference.

## Archive procedure

1. **Only after `spec-drift-detection` returns a clean PASS.** Archiving drifted
   work would record a baseline that the code does not match — the exact failure
   the trail exists to prevent.
2. Run `bash scripts/spec-archive.sh docs/specs/<date>-<slug>.json`.
   - Merges `public_contracts` / `change_manifest` (or the explicit `delta`) into
     `docs/specs/baseline/<area>.json`.
   - Applies `delta.removes` (drops those keys from the baseline).
   - Appends an audit record to `docs/specs/baseline/<area>.audit.jsonl`.
   - Regenerates the human-readable `docs/specs/baseline/<area>.md`.
3. **Idempotent.** Re-running for an already-archived `slug` is a no-op (detected
   via the audit trail). Safe to re-run after a crash or resume.

## Reading the trail

- `docs/specs/baseline/<area>.md` — the current intended contracts/files for the
  area, with the slug that last touched each.
- `docs/specs/baseline/<area>.audit.jsonl` — chronological "what was specified,
  when, and did it pass drift" — answer to "show me the spec history for X".

## Rules

- Baseline is derived, not hand-edited — edit the feature spec and re-archive.
- Never archive on drift `NEEDS_CHANGES`.
- An area's baseline is the union of archived deltas minus explicit removes — it
  is not a re-statement of the whole system written from scratch.
