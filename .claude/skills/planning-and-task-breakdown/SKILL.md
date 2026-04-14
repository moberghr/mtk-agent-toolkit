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
2. Break work into batches of 2-4 related files, dependency-ordered.
3. For each task, write:
   - task description
   - acceptance criteria
   - verification step
   - files in scope
   - **Boundary:** what this task owns and must not leak into (e.g., "handler only — no controller changes")
   - **Depends:** which prior tasks or existing code this task assumes is complete (e.g., "requires Batch 1 entity to exist")
4. Prefer vertical slices where possible so each batch leaves the system in a working state.
5. Mark tasks that can run in parallel and tasks that must stay sequential.
6. Write `tasks/todo.md` with:
   - task title
   - scope and branch
   - batches with checkboxes
   - post-implementation review items
7. If a spec file exists in `docs/specs/`, persist the plan alongside it:
   - Save to `docs/plans/YYYY-MM-DD-<feature-slug>.md` using the same date and slug.
   - Create `docs/plans/` if it does not exist.
   - Add `docs/plans/` to `.gitignore` if not already present.
   - This enables session recovery and plan reuse across sessions.
8. Keep the task list synchronized with reality. If a new file is needed, re-plan before continuing.

## Rules

- Every touched file must already exist in the change manifest.
- Every batch must be buildable.
- Every behavior change must have an associated test task.
- No task should require changing more than a small handful of files without justification.
- Re-planning is mandatory if the task grows beyond the approved manifest.

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "I'll just keep the tasks in my head" | Hidden plans drift fastest. Write the task list so implementation and review can check reality against it. |
| "This batch is a bit large, but it saves time" | Oversized batches hide breakage and make checkpoints meaningless. |
| "I'll add verification steps later" | A task without verification is not a task. It's a wish. |

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
