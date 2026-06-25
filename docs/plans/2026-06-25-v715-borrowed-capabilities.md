# Plan: v7.15.0 — Seven Borrowed Capabilities

> Spec: `docs/specs/2026-06-25-v715-borrowed-capabilities.md` · 8 batches · Rigor: MAX (subagent path)

Each batch is independently buildable and ends with `bash scripts/validate-toolkit.sh` (the toolkit's build/test command) plus any batch-local test. Batches B1–B7 are feature-additive; B8 is the release wrap. Several files are touched by more than one batch (different sections) — that is expected; the change manifest is the union.

## Batch B1 — F1 per-phase model routing
- **Files:** NEW `.claude/references/model-routing.md`; EDIT `context-engineering/SKILL.md`, `subagent-implementation/SKILL.md`, `planning-and-task-breakdown/SKILL.md`, `code-review-and-quality/SKILL.md`, `research-context/SKILL.md`; EDIT `.claude/manifest.json` (reference entry).
- **Acceptance:** reference has S2.13 frontmatter; each skill cites `model-routing.md`; subagent model question defaults from policy; manifest path exists; validate-toolkit passes.
- **Boundary:** no agent-frontmatter `model:` values changed; advisory table in context-engineering not moved, only pointer added.

## Batch B2 — F2 context-budget 60% checkpoint
- **Files:** EDIT `hooks/context-budget.sh`, `tests/hooks/test-context-estimator.sh`, `handoff/SKILL.md`, `context-engineering/SKILL.md`.
- **Acceptance:** hook warns once when est. tokens ≥ `MTK_CONTEXT_BUDGET_PCT`% (default 60) of `MTK_CONTEXT_WINDOW_TOKENS` (default 200000); message labels the figure an estimate and points at `handoff`; test scenarios (cross / below / env-override) pass; `set -euo pipefail` intact; still `chmod +x`.
- **Boundary:** advisory only — never blocks; existing op-count thresholds untouched.

## Batch B3 — F3 circuit-breaker + plateau
- **Files:** EDIT `scripts/workflow-artifact.sh`, `.claude/references/orchestration-gates.md`, `.claude/references/workflow-artifact-schema.md`, `code-review-and-quality/SKILL.md`, `verification-before-completion/SKILL.md`; NEW `tests/hooks/test-remediation-tracker.sh`.
- **Acceptance:** `workflow-artifact.sh remediation <uuid> <trigger> [--score N]` increments iterations, flags plateau on non-improving scores, prints `ESCALATE` at ≥ `MTK_MAX_REMEDIATION_ITERS` (default 3) or plateau; schema documents `results.remediation`; test passes.
- **Boundary:** re-arm mechanism and existing gates unchanged; new field is additive.

## Batch B4 — F4 smoke-boot evidence channel
- **Files:** EDIT `verification-before-completion/SKILL.md`, `spec-driven-development/SKILL.md`, `workflow-artifact-schema.md`.
- **Acceptance:** `smoke-boot` appears in the channel taxonomy, the `evidence_channel` enum, and the schema enum, described as "service/artifact boots and responds live"; counts as a real execution surface.
- **Boundary:** text-only; no code consumes the new name beyond documentation.

## Batch B5 — F5 docdrift linter pack
- **Files:** NEW `hooks/linter-patterns/core/docdrift.txt`; EDIT `.claude/manifest.json`, `.claude/references/ai-failure-modes.md`; NEW `tests/hooks/test-docdrift-pack.sh`.
- **Acceptance:** pack is valid TSV (5 fields), all `warning` severity; a seeded smell matches and clean docs do not; manifest entry present; F12/F3 cross-ref added.
- **Boundary:** no change to `pre-commit-linters.sh` (core packs auto-discovered).

## Batch B6 — F6 phase-locked tool limits
- **Files:** EDIT `brainstorming/SKILL.md`, `research-context/SKILL.md` (add `required-toolsets: [read-only]`); EDIT `spec-driven-development/SKILL.md`, `planning-and-task-breakdown/SKILL.md` (Tool-discipline note); EDIT `.claude/rules/skill-authoring.md` (S2.20 note).
- **Acceptance:** toolset names resolve (validator); pure-read skills locked read-only; artifact-writing skills carry the discipline note; rule file stays ≤120 lines.
- **Boundary:** no read-only lock on artifact-writing skills.

## Batch B7 — F7 stack/domain guard packs
- **Files:** EDIT `hooks/linter-patterns/domain-finance/patterns.txt`, `hooks/linter-patterns/stack-dotnet/patterns.txt`; NEW `.claude/references/guard-packs.md`; EDIT `.claude/manifest.json` (reference entry).
- **Acceptance:** new patterns are valid TSV and conservative (no false positive on a clean sample); `guard-packs.md` documents layout/format/discovery/authoring with S2.13 frontmatter; manifest entry present.
- **Boundary:** existing pattern lines unchanged; only additions.

## Batch B8 — Release wrap
- **Files:** EDIT `.claude/manifest.json` (version 7.15.0, updated 2026-06-25, + all new file entries reconciled), `.claude-plugin/plugin.json` (version 7.15.0), `CHANGELOG.md`; regenerate `.claude/references.index`, `.claude/rules/INDEX.md`, `.claude/triggers.index`, then `checksums.sha256` (last).
- **Acceptance:** SC1–SC3, SC7 all green; `generate-checksums.sh --verify` clean.
- **Boundary:** checksums regenerated as the final step (S4.11).

## Post-implementation review items
- [ ] Spec-drift check (Phase 3.5) clean against the JSON sidecar.
- [ ] Stage 1 compliance-reviewer (adversarial, separate context).
- [ ] Stage 2 (MAX): test-reviewer + architecture-reviewer + silent-failure-hunter, in parallel.
- [ ] Confirm no skill/rule file exceeds its line budget.
- [ ] Confirm no false positives from new linter packs on the MTK repo itself.
