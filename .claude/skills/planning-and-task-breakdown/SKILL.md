---
name: planning-and-task-breakdown
description: Use after a spec is approved and before multi-file implementation begins, to break work into verifiable batches with checkpoints.
type: skill
license: MIT
compatibility:
  - claude-code
  - cursor
  - codex
trigger: spec-approved|multi-file-implementation|batch-planning
skip_when: single-file-fix|quick-fix-scope
user-invocable: false
---

# Planning And Task Breakdown

## Overview

Convert the approved plan into small, executable tasks that can be verified one at a time. Good task breakdown reduces hidden coupling, scope drift, and fake progress.

## When To Use

- After spec approval
- Before any multi-file implementation
- When implementation needs explicit checkpoints or re-planning boundaries

### When NOT To Use

- Tiny single-file work already small enough to execute safely
- Exploratory debugging before the root cause is known

## Workflow

1. Start from the approved change manifest and test manifest.
1a. **Prior-work freshness check.** If the spec's `## Prior Work Check`
   section is missing OR was generated more than one session ago (different
   branch HEAD, different day), re-run `prior-work-check` against the
   current branch state. Risk profiles and lessons can shift between
   approval and planning. A BLOCK verdict here means planning stops until
   the spec is amended and re-approved.
2. Break work into batches of 2-4 related files, dependency-ordered.
3. For each task, write:
   - task description
   - acceptance criteria
   - verification step
   - files in scope
   - **Boundary:** what this task owns and must not leak into (e.g., "handler only — no controller changes")
   - **Depends:** which prior tasks or existing code this task assumes is complete (e.g., "requires Batch 1 entity to exist")
   - **Governing constraints:** the Critical Rule / principle ids that constrain
     this batch, cited from the spec's Constitution Check (run
     `bash scripts/constitution-digest.sh` if absent).
     Each batch states which rules it must satisfy, not just what it builds —
     so the implementer and `spec-drift-detection` (S1.15) check the same set.
     An empty list is allowed only with an explicit "no rule constrains this
     batch" note.
4. Prefer vertical slices where possible so each batch leaves the system in a working state.
5. Mark tasks that can run in parallel and tasks that must stay sequential.
6. Write `tasks/todo.md` with:
   - task title
   - scope and branch
   - batches with checkboxes
   - post-implementation review items
7. If a spec file exists in `docs/specs/`, persist the plan alongside it:
   - Use the **full filename stem of the active spec**, including any version suffix (e.g., `-v2`, `-v3`). If the spec was written as `docs/specs/2026-04-23-foo-v2.md`, the plan is `docs/plans/2026-04-23-foo-v2.md`.
   - If no spec path is available (standalone planning run), use `YYYY-MM-DD-<feature-slug>.md` with no suffix.
   - Create `docs/plans/` if it does not exist.
   - Add `docs/plans/` to `.gitignore` if not already present.
   - This enables session recovery and plan reuse across sessions.
8. **Append the `plan` section to the existing JSON handoff artifact** at
   `docs/specs/<date>-<slug>.json` (created by spec-driven-development).
   Schema: `.claude/schemas/handoff.schema.json`. Required keys:
   ```json
   "plan": {
     "batches": [
       { "id": "B1", "files": ["src/X.cs"], "acceptance": "...",
         "verification": "...", "boundary": "...", "depends": [],
         "governing_constraints": ["C0.2", "S1.15"],
         "parallel_safe": false }
     ]
   }
   ```
   Every `files` entry must already exist in the top-level `change_manifest`.
   If it does not, re-plan first — don't quietly widen scope here.
9. Keep the task list synchronized with reality. If a new file is needed, re-plan before continuing.
10. Record the plan/todo paths on the workflow artifact and leave `plan_trust_gate` at `pending` — only the engineer's Phase 2.5 approval flips it to `pass`. See `.claude/references/orchestration-gates.md`.
11. **Anti-anchored gap check.** Before surfacing the plan to the engineer, dispatch the `plan-gap-reviewer` agent with the original user request and the saved plan path (and the spec path if it exists). The agent runs in a forked context and is forbidden from reading lessons, prior reviewer output, or the workflow artifact — its job is to challenge the plan against the repo with no anchors. Surface every `BLOCKING` finding back to the planner and revise before the approval gate. Surface `ADVISORY` findings unchanged at the approval gate so the engineer decides.

## Rules

- Every touched file must already exist in the change manifest.
- Every batch must be buildable.
- Every behavior change must have an associated test task.
- No task should require changing more than a small handful of files without justification.
- Re-planning is mandatory if the task grows beyond the approved manifest.

## Common Rationalizations

See `.claude/skills/context-engineering/SKILL.md` for the shared table. Planning-specific traps: "I'll just keep the tasks in my head" (hidden plans drift fastest — write the list so implementation and review can check reality against it), "this batch is a bit large, but it saves time" (oversized batches hide breakage and make checkpoints meaningless), and "I'll add verification steps later" (a task without verification is not a task, it's a wish).

## Red Flags

- Batches too large to verify quickly
- Checkpoints omitted
- `tasks/todo.md` drifting from actual implementation
- Tasks ordered by convenience rather than dependency
- Missing Boundary or Depends annotations — without them, task scope is ambiguous
- Circular dependencies between tasks

## Verification

- [ ] `tasks/todo.md` exists and is actionable
- [ ] Batches are dependency-ordered
- [ ] Each task has acceptance and verification
- [ ] Each batch ends with a concrete checkpoint
- [ ] Each task has Boundary and Depends annotations
- [ ] No circular dependencies exist between tasks
