---
description: Lightweight fix/task using the MTK debugging workflow. Use for 1-3 file changes that do not require feature planning.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
argument-hint: [--terse|--verbose] <description of fix or small task>
---

# MTK Fix — Lightweight Task Loop

Use this for small, well-bounded work. The source of truth for the fix workflow is:

- `.claude/skills/context-engineering/SKILL.md`
- `.claude/skills/debugging-and-error-recovery/SKILL.md`
- `.claude/skills/test-driven-development/SKILL.md` when behavior changes
- `.claude/skills/source-driven-development/SKILL.md` when framework behavior is uncertain
- `.claude/skills/security-and-hardening/SKILL.md` when the fix touches auth, audited state, secrets, or infra
- `.claude/skills/tech-stack-{stack}/SKILL.md` — loaded based on `.claude/tech-stack`

## When To Use

- Bug fixes
- Validation tweaks
- Query fixes
- Small config changes
- Renames or narrow refactors that stay within 1-3 files

If the work grows beyond 3 files, introduces new architecture, or needs a formal change manifest, stop and switch to `/mtk:implement`.

## Load Context (Progressive Disclosure)

1. Follow `.claude/skills/context-engineering/SKILL.md`.
2. Read `CLAUDE.md`. If missing, stop and tell the engineer to run `/mtk:setup-bootstrap`.
3. Load the active tech stack: read `.claude/tech-stack` and `.claude/skills/tech-stack-{stack}/SKILL.md`. This provides build/test commands and stack-specific reference paths.
4. Read only what the fix needs:
   - **Always:** the coding guidelines from the tech stack's `## Reference Files`
   - **If fix touches data layer/ORM:** the ORM checklist from the tech stack's `## Reference Files`
   - **If fix touches auth/secrets/financial:** `.claude/references/security-checklist.md`
   - **If adding tests:** `.claude/references/testing-patterns.md` plus the testing supplement from the tech stack
   - **Before commit:** `.claude/references/pre-commit-review-list.md` if present
5. Resolve and scan relevant lessons from `tasks/lessons.md`.
6. Read the target file and its closest neighbors before editing.

**Progressive disclosure principle:** Small fixes do not need all references loaded. Load what's relevant to the specific fix, then load additional references if the scope shifts.

## Execute The Fix Workflow

Follow `.claude/skills/debugging-and-error-recovery/SKILL.md`.
Use `.claude/skills/test-driven-development/SKILL.md` for regression coverage when behavior changed.

Minimum verification (using build/test commands from the active tech stack skill):

- run the build command
- run the relevant tests for the changed area

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
