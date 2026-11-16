# Batch: skipped closing phases and guard-test drift — 2026-11-16

Source: field run report from another repo (implement run, 2026-11-16).
Scope: no new public contract; no architectural change. Instruction text only — the
`workflow-artifact.sh` gate CLI keeps `pass|fail`.

## Findings

1. **A skipped Phase 6/7 is recorded as "lessons captured".** (behavioral, instruction text)
   `implement` closes with a hard-coded `gate memory_sync_gate pass --reason "lessons captured"`,
   and Phase 6 (cleanup) leaves no record at all. Fix: `pass` only when Phase 7 ran, with the
   real outcome as the reason; a phase that did not run leaves the gate `pending` and records a
   `phase_skipped` event with the reason. Final report states ran/skipped for both.
   Files: `.claude/skills/implement/SKILL.md`, `.claude/skills/workflow-artifacts/SKILL.md`,
   `.claude/references/orchestration-gates.md`.
2. **An implementer can relax a guard test and the drift check auto-accepts it.** (behavioral, instruction text)
   An extra in-package file is "auto-fixable" even when the edit raises a threshold in a
   convention test. Fix: implementer prompt rule (do not relax an existing assertion, threshold
   or guard test; return `blocked` or a `test-relaxed` deviation without making the edit), and
   the drift micro-check treats a relaxed existing test as not auto-fixable.
   Files: `.claude/references/subagent-implementer-prompt.md`,
   `.claude/skills/subagent-implementation/SKILL.md`.

Approval: engineer answered "yes" to this two-item list on 2026-11-16 (gate satisfied).
