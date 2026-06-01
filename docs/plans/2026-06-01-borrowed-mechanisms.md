# Plan: Four Borrowed Mechanisms

Spec: `docs/specs/2026-06-01-borrowed-mechanisms.md` · Sidecar: same path `.json`

Each batch ends with a checkpoint: `bash -n` on new scripts, smoke run, and (final) `validate-toolkit.sh`.

## Batch 1 — F4 Rule taxonomy + wake-up layer
**Governing constraints:** S1.x (rules are toolkit assets), C0.5 (bash hygiene), C0.2 (new INDEX in manifest).
- Add `axes:` frontmatter (decision/topic/scope) to the 4 `.claude/rules/*.md`, preserving `paths:`.
- Write `scripts/build-rule-index.sh` (`set -euo pipefail`, `--check` mode).
- Generate `.claude/rules/INDEX.md`.
- Add `## Rule Taxonomy & Wake-Up Layer` to `context-engineering`.
- Checkpoint: `build-rule-index.sh` then `--check` passes; edit-a-rule staleness test.

## Batch 2 — F2 Constitution-cited-input
**Governing constraints:** C0.5, C0.7 (don't overwrite CLAUDE.md — read-only digest), S1.15 (drift loop closure).
- Write `scripts/constitution-digest.sh` (graceful degrade if principles file absent).
- Add **Constitution Check** requirement to `spec-driven-development`.
- Add per-batch `Governing constraints:` requirement to `planning-and-task-breakdown`.
- Checkpoint: digest emits ≥1 Critical Rule.

## Batch 3 — F1 Delta-spec
**Governing constraints:** C0.3 (skill anatomy for new sections), C0.5, audit-trail integrity (finance domain).
- Write `.claude/references/delta-spec-model.md`.
- Write `scripts/spec-archive.sh` (idempotent merge + `audit.jsonl`).
- Wire `## Delta & Baseline` into `spec-driven-development`; archive-on-PASS note into `spec-drift-detection`; `## Phase 7.5` into `implement`.
- Checkpoint: archive a throwaway sidecar twice → second is no-op.

## Batch 4 — F3 Skill-eval sprawl/coverage
**Governing constraints:** C0.5, S1.10 (tests location), advisory-only (R2).
- Write `scripts/skill-eval/coverage.sh` (`--json`, overlap heuristic).
- Seed `evals/fix/` and `evals/spec-drift-detection/` (grader + 2 scenarios each), matching existing shape.
- Add non-blocking coverage line to `validate-toolkit.sh`; reference report in `toolkit-health`.
- Checkpoint: `coverage.sh --json | jq .` valid; `run-evals.sh --list` shows new evals.

## Batch 5 — Manifest + version + full validation
**Governing constraints:** C0.1, C0.2, S1.4, S4.6/S4.7.
- Add every new file to `manifest.json` `files` (with source/target/action/description, S1.2/S1.3).
- Bump version in `manifest.json` + `plugin.json` (minor: new skills/scripts → 7.11.0); update `manifest.updated`.
- Run `validate-toolkit.sh`, `run-benchmarks.sh`, drift check.

## Post-implementation review items (tasks/todo.md)
- compliance-reviewer (Stage 1 spec compliance)
- spec-drift-detection (Phase 3.5)
- self-archive the delta (dogfood Phase 7.5)
