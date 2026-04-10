---
description: Lightweight fix/task using the Moberg debugging workflow. Use for 1-3 file changes that do not require feature planning.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
argument-hint: [--terse|--verbose] <description of fix or small task>
---

# Moberg Fix — Lightweight Task Loop

Use this for small, well-bounded work. The source of truth for the fix workflow is:

- `.claude/skills/context-engineering/SKILL.md`
- `.claude/skills/debugging-and-error-recovery/SKILL.md`
- `.claude/skills/test-driven-development-dotnet/SKILL.md` when behavior changes
- `.claude/skills/source-driven-development/SKILL.md` when framework behavior is uncertain
- `.claude/skills/security-and-hardening-fintech/SKILL.md` when the fix touches auth, financial state, secrets, or infra

## When To Use

- Bug fixes
- Validation tweaks
- Query fixes
- Small config changes
- Renames or narrow refactors that stay within 1-3 files

If the work grows beyond 3 files, introduces new architecture, or needs a formal change manifest, stop and switch to `/moberg:implement`.

## Load Context (Progressive Disclosure)

1. Follow `.claude/skills/context-engineering/SKILL.md`.
2. Read `CLAUDE.md`. If missing, stop and tell the engineer to run `/moberg:init`.
3. Read only what the fix needs:
   - **Always:** `.claude/references/coding-guidelines.md`
   - **If fix touches queries/EF:** `.claude/references/ef-core-checklist.md`
   - **If fix touches auth/secrets/financial:** `.claude/references/security-checklist.md`
   - **If adding tests:** `.claude/references/testing-patterns.md`
   - **Before commit:** `.claude/references/quick-check-list.md` if present
4. Resolve and scan relevant lessons from `tasks/lessons.md`.
5. Read the target file and its closest neighbors before editing.

**Progressive disclosure principle:** Small fixes do not need all references loaded. Load what's relevant to the specific fix, then load additional references if the scope shifts.

## Execute The Fix Workflow

Follow `.claude/skills/debugging-and-error-recovery/SKILL.md`.
Use `.claude/skills/test-driven-development-dotnet/SKILL.md` for regression coverage when behavior changed.

Minimum verification:

- `dotnet build`
- relevant tests for the changed area

If behavior changed, add or update tests.

## Scope Guard

Stop and escalate if any of these become true:

- a 4th file is required
- a new handler/entity/slice is needed
- the fix requires architectural re-planning

## Final Report

Report briefly:

- files changed
- root cause
- tests added or updated
- build result
- relevant test result

## Critical Rules

1. Read before editing.
2. Match the local codebase pattern.
3. Do not gold-plate unrelated improvements.
4. Escalate instead of letting a quick fix become a hidden feature project.
