# Spec: Four Borrowed Mechanisms

> Date: 2026-06-01 · Slug: `borrowed-mechanisms` · Scope: feature (multi-file, toolkit-internal)

## Goal

Borrow four mechanisms from the May-2026 agentic-toolkit landscape into MTK, each as a **delta on existing infrastructure** (not greenfield):

1. **Delta-spec model** — feature specs become deltas against a living per-area baseline; on archive the delta syncs back into the baseline, producing an auditable specified-vs-built trail.
2. **Constitution-cited-input** — architecture principles + Critical Rules become an explicit *cited* input to planning and spec phases, not ambient context. Closes the loop with the existing S1.15 principle-drift check.
3. **Skill-eval sprawl/coverage report** — build a coverage + overlap report on top of the *existing* eval harness (`run-evals.sh`, `scripts/skill-eval/`) to combat sprawl across 38 skills. Seed evals for 2 high-value uncovered skills as worked examples.
4. **Rule taxonomy + token-budgeted wake-up layer** — tag `.claude/rules/*.md` on three axes, generate a fixed-budget always-on "wake-up" index, fetch full rules on demand.

## Constitution Check (which principles constrain this design)

- **C0.2 / S1.1** — every new file must be in `manifest.json`; every manifest path must exist. (All 4 features add files.)
- **C0.3 / S2.x** — any new skill content follows skill anatomy. (Feature 1 adds skill sections, not a new skill.)
- **C0.5 / S3.x** — new bash scripts use `set -euo pipefail`, are `chmod +x`. (Features 1, 2, 3, 4 add scripts.)
- **C0.8** — `validate-toolkit.sh` must pass before completion.
- **S1.14** — scripts that walk the repo honor `.mtkignore`.
- Global rule "Fix ONLY the specific issue; minimal scope" — features are additive; no refactor of existing skills beyond the cited insertion points.

## Non-Goals (out of scope)

- Writing evals for all 34 currently-uncovered skills (only 2 seed examples this PR).
- Auto-learning rules from sessions (the "~46% noise" finding from prior art — deliberately excluded).
- Cost/model-tiering routing (already partially present via `## Model Routing`; not expanded here).
- Changing how references load (`applyTo` stays as-is); feature 4 touches `.claude/rules/` only.
- Migrating existing specs to the baseline format retroactively.

## Design

### Feature 1 — Delta-spec model

- **Baseline store:** `docs/specs/baseline/<area>.json` (canonical living spec per slice/area) + `docs/specs/baseline/<area>.md` (human view). Created lazily on first archive.
- **Sidecar fields:** spec JSON sidecar gains `baseline_area` (string) and `delta` (object: `adds`, `modifies`, `removes` of public_contracts / files relative to baseline).
- **Archive script:** `scripts/spec-archive.sh <spec.json>` — run *after* drift check passes. Merges the delta into the baseline JSON, appends an audit record (date, slug, what changed, drift verdict) to `docs/specs/baseline/<area>.audit.jsonl`, regenerates the baseline `.md`. Idempotent (re-archiving the same slug is a no-op).
- **Reference:** `.claude/references/delta-spec-model.md` — the model, fields, archive procedure, audit-trail format.
- **Skill wiring:** add `## Delta & Baseline` to `spec-driven-development`; add `## Phase 7.5: Archive (Delta Sync-Back)` to `implement`; add an archive note to `spec-drift-detection` (archive only on clean PASS).

### Feature 2 — Constitution-cited-input

- **Digest script:** `scripts/constitution-digest.sh` — emits a compact citable list: Critical Rules (C0.x from CLAUDE.md) + tagged principles from `architecture-principles.md` (id, one-line, tag). Honors MTK file resolution. Read-only.
- **Spec wiring:** `spec-driven-development` gains a mandatory **Constitution Check** section (this spec demonstrates it above).
- **Plan wiring:** `planning-and-task-breakdown` — each batch declares a `Governing constraints:` line citing the rule/principle ids it must satisfy. Empty is allowed only with an explicit "none apply" note.
- Closes loop with existing S1.15 drift: cited at plan time → verified at drift time.

### Feature 3 — Skill-eval sprawl/coverage report

- **Coverage script:** `scripts/skill-eval/coverage.sh` — lists all skills under `.claude/skills/`, marks which have an `evals/<skill>/` directory, computes coverage %, and flags **overlap candidates** (skills whose `description` trigrams overlap above a threshold — a cheap sprawl signal). `--json` for CI. Honors `.mtkignore` is N/A (operates on skills dir).
- **Seed evals:** add `evals/fix/` and `evals/spec-drift-detection/` with one grader + 2 scenarios each (a do-the-right-thing and a rationalization-trap), matching the existing eval file shape.
- **Wiring:** `validate-toolkit.sh` gains a non-blocking coverage line (warn only); `toolkit-health` skill references the new report.

### Feature 4 — Rule taxonomy + wake-up layer

- **Taxonomy frontmatter:** each `.claude/rules/*.md` gains `axes:` with `decision` (e.g. structure|process|security|authoring), `topic` (e.g. manifest|hooks|git|skills), `scope` (global|project). Existing `paths:` frontmatter preserved.
- **Index script:** `scripts/build-rule-index.sh` — generates `.claude/rules/INDEX.md`: a fixed-budget (~target 60 lines / ~800 tokens) always-on "wake-up" layer = one line per rule (title, axes, line-count, one-line summary) + a "fetch full rule on demand" instruction. `--check` mode fails if INDEX is stale vs. sources (for CI).
- **Wiring:** `context-engineering` gains `## Rule Taxonomy & Wake-Up Layer` — read INDEX.md first; pull a full rule file only when its axes match the active task. Generated INDEX listed in manifest.

## Change Manifest

| Path | Action | Purpose |
|---|---|---|
| `.claude/references/delta-spec-model.md` | create | F1 reference |
| `scripts/spec-archive.sh` | create | F1 archive/sync-back |
| `.claude/skills/spec-driven-development/SKILL.md` | modify | F1 delta section + F2 constitution check |
| `.claude/skills/spec-drift-detection/SKILL.md` | modify | F1 archive-on-pass note |
| `.claude/skills/implement/SKILL.md` | modify | F1 Phase 7.5 archive |
| `scripts/constitution-digest.sh` | create | F2 digest |
| `.claude/skills/planning-and-task-breakdown/SKILL.md` | modify | F2 governing-constraints per batch |
| `scripts/skill-eval/coverage.sh` | create | F3 coverage/sprawl report |
| `evals/fix/grader.md`, `evals/fix/eval-01-*.md`, `evals/fix/eval-02-*.md` | create | F3 seed evals |
| `evals/spec-drift-detection/grader.md` + 2 scenarios | create | F3 seed evals |
| `scripts/validate-toolkit.sh` | modify | F3 non-blocking coverage line |
| `.claude/skills/toolkit-health/SKILL.md` | modify | F3 reference the report |
| `.claude/rules/*.md` (4 files) | modify | F4 taxonomy frontmatter |
| `scripts/build-rule-index.sh` | create | F4 wake-up index generator |
| `.claude/rules/INDEX.md` | create (generated) | F4 wake-up layer |
| `.claude/skills/context-engineering/SKILL.md` | modify | F4 wake-up usage |
| `.claude/manifest.json` | modify | register all new files; bump version |
| `.claude-plugin/plugin.json` | modify | version bump (match manifest) |

## Test / Verification Manifest

- `bash scripts/validate-toolkit.sh` → "Toolkit validation passed" (C0.8).
- Each new script: `bash -n` parse check + a smoke run on real repo data.
- `scripts/spec-archive.sh` on a throwaway sidecar → baseline JSON + audit.jsonl created; second run is a no-op (idempotency test).
- `scripts/build-rule-index.sh --check` passes after generation; fails when a rule is edited without regenerating (staleness test).
- `scripts/skill-eval/coverage.sh --json` parses as valid JSON and reports 6/38 covered (4 existing + 2 seeds).
- `scripts/constitution-digest.sh` emits ≥1 Critical Rule and (if principles file exists) ≥1 principle.
- New seed evals listed by `scripts/run-evals.sh --list`.
- `bash scripts/run-benchmarks.sh` still passes (no hook regressions).

## Implementation Batches

- **Batch 1 — F4 rule taxonomy + wake-up** (rules frontmatter, `build-rule-index.sh`, INDEX.md, context-engineering wiring). Self-contained, no deps.
- **Batch 2 — F2 constitution-cited-input** (`constitution-digest.sh`, spec + planning skill wiring).
- **Batch 3 — F1 delta-spec** (`delta-spec-model.md`, `spec-archive.sh`, spec/drift/implement wiring).
- **Batch 4 — F3 skill-eval sprawl** (`coverage.sh`, seed evals, validate-toolkit + toolkit-health wiring).
- **Batch 5 — manifest + version bump + full validation.**

## Assumptions & Risks

- **A1:** `architecture-principles.md` may be absent in this repo (it's a target-repo artifact) — `constitution-digest.sh` degrades gracefully to Critical Rules only. (Confirmed: not present here.)
- **A2:** Generated `INDEX.md` is committed (like other derived artifacts, e.g. AGENTS.md) and validated via `--check`, not gitignored.
- **R1:** Manifest drift — every new file must be added or `validate-toolkit.sh` fails. Mitigated by Batch 5 + the validation gate.
- **R2:** Overlap detection (F3) is a heuristic; reported as advisory only, never blocking.
