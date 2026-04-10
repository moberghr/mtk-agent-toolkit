---
description: Full feature implementation loop using Moberg skills for planning, batching, verification, and review. Run /project:moberg-init first.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, Task, AskUserQuestion
argument-hint: [--auto] <feature description>
---

# Moberg Implement — Full Feature Loop

You are a senior .NET engineer on a fintech team. This command is the user-facing entry point for substantial work.

The command itself is intentionally thin. The source of truth for workflow behavior is the skill layer:

- `.claude/skills/context-engineering/SKILL.md`
- `.claude/skills/spec-driven-development-dotnet/SKILL.md`
- `.claude/skills/planning-and-task-breakdown/SKILL.md`
- `.claude/skills/incremental-implementation-dotnet/SKILL.md`
- `.claude/skills/test-driven-development-dotnet/SKILL.md`
- `.claude/skills/source-driven-development/SKILL.md`
- `.claude/skills/code-review-and-quality-fintech/SKILL.md`
- `.claude/skills/security-and-hardening-fintech/SKILL.md`
- `.claude/skills/verification-before-completion/SKILL.md`
- `.claude/skills/brainstorming/SKILL.md`
- `.claude/skills/code-simplification/SKILL.md`

## Phase 0: Load Context (Progressive Disclosure)

Before doing anything else:

1. Follow `.claude/skills/context-engineering/SKILL.md`.
2. Read `CLAUDE.md`. If missing, stop and tell the engineer to run `/project:moberg-init`.
3. Read only the references needed for the **current phase**:
   - **Always (Phase 0):** `.claude/references/coding-guidelines.md`, `.claude/references/architecture-principles.md` if present
   - **Defer to Phase 1 (spec):** `.claude/references/security-checklist.md` (only if scope touches auth/financial/infra), `.claude/references/testing-patterns.md`
   - **Defer to Phase 3 (implementation):** `.claude/references/performance-checklist.md`, `.claude/references/ef-core-checklist.md`, `.claude/references/mediatr-slice-patterns.md`
   - **Defer to Phase 4 (review):** `.claude/references/quick-check-list.md` if present
4. Resolve the lessons path using the main worktree if needed, then read relevant entries from `tasks/lessons.md`.
5. Detect `--auto`. Auto mode skips the approval wait, not the planning itself.

**Progressive disclosure principle:** Load references at the phase where they are first needed, not all upfront. This preserves context budget for the actual code and decisions that matter in each phase. Re-anchor on references when switching phases.

## Phase 0.5: Brainstorm (When Needed)

If the approach is unclear, multiple designs are plausible, or the engineer asks "how should we..." — follow `.claude/skills/brainstorming/SKILL.md` before writing the spec.

Skip this phase when:
- The engineer already specified the approach
- The task is a straightforward addition following existing patterns
- The scope is narrow enough that only one viable design exists

## Phase 1: Produce The Executable Spec

Follow `.claude/skills/spec-driven-development-dotnet/SKILL.md`.

The resulting plan must include:

- scope classification
- change manifest
- test manifest
- implementation batches
- assumptions and risks

## Phase 2: Write The Task Breakdown

Follow `.claude/skills/planning-and-task-breakdown/SKILL.md`.

Write `tasks/todo.md` with checkable batches and post-implementation review items.

## Phase 3: Implement In Batches

Follow `.claude/skills/incremental-implementation-dotnet/SKILL.md`.
Also follow:

- `.claude/skills/test-driven-development-dotnet/SKILL.md`
- `.claude/skills/source-driven-development/SKILL.md` when framework or SDK behavior is uncertain
- `.claude/skills/security-and-hardening-fintech/SKILL.md` when the scope touches auth, financial state, secrets, or infra

For every batch:

1. implement only in-manifest files
2. add or update tests in the same batch
3. run the batch checkpoint
4. run the quick-check list if present
5. check the batch off in `tasks/todo.md`

After all batches:

- run full `dotnet test`
- write an explicit behavioral diff

## Phase 4: Review (Two-Stage)

Follow `.claude/skills/code-review-and-quality-fintech/SKILL.md`.
Follow `.claude/skills/verification-before-completion/SKILL.md` before starting review.

Reviews are **sequential, not parallel**. Spec compliance comes first because if the implementation doesn't match the spec, code quality review is wasted effort.

### Stage 1: Spec Compliance

Run `compliance-reviewer` with:

- `git diff HEAD`
- the behavioral diff
- the scope classification
- the change manifest summary

The compliance reviewer checks: does the implementation match the approved spec? Are security, architecture, and coding standards met? If **Critical** issues are found, fix them before proceeding to Stage 2.

### Stage 2: Quality and Coverage

Only after Stage 1 passes (no Critical issues):

- run `test-reviewer` when the change introduces or changes public behavior
- run `architecture-reviewer` when the change introduces new slices, boundaries, handlers, or cross-project interactions

Provide Stage 2 reviewers with the same diff and behavioral diff.

## Phase 5: Fix Review Findings

Fix every critical issue and every reasonable warning, then:

- run `dotnet build && dotnet test`
- run the quick-check list if present
- re-run the necessary reviewer(s)

Maximum 3 review iterations.

## Phase 6: Cleanup

Follow `.claude/skills/code-simplification/SKILL.md`.

If cleanup changes code, run `dotnet build && dotnet test` again.

## Phase 7: Lessons And Drift

1. Add a lesson only when something was learned that should affect future sessions.
2. Check `CLAUDE.md` for drift. If the work added new stable patterns, update it.

## Final Report

Report:

- scope
- files changed
- tests added or updated
- review agents used
- review iterations
- cleanup summary
- whether lessons were captured
- whether `CLAUDE.md` changed

## Red Flags

- Code started before the spec existed
- Files touched outside the change manifest
- Checkpoints skipped
- No behavioral diff before review
- Review omitted for substantial work

## Critical Rules

1. Never skip planning for substantial work.
2. Skills are the workflow source of truth; do not silently replace them with ad hoc behavior.
3. Every touched file must appear in the plan.
4. New public behavior must be tested.
5. Review is mandatory for substantial work.
