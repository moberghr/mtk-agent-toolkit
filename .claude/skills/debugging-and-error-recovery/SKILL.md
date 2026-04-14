---
name: debugging-and-error-recovery
description: Use when a test fails, a runtime error occurs, or a behavioral regression is reported — reproduce first, then fix the root cause within scope.
license: MIT
compatibility:
  - claude-code
  - cursor
  - codex
trigger: test-failure|runtime-error|behavioral-regression|bug-report
skip_when: new-feature-design|large-scope-planning
---

# Debugging And Error Recovery

## Current State

```!
echo "--- Branch ---"
git branch --show-current 2>/dev/null || echo "(detached)"
echo "--- Working tree ---"
git status --short 2>/dev/null | head -15 || echo "(not a git repo)"
```

## Overview

Start from the failure, confirm the cause, make the smallest correct fix, and verify it with build and test evidence. Guesswork is not debugging.

## When To Use

- Bug fixes
- Failing tests
- Runtime errors
- Small behavioral regressions

### When NOT To Use

- New feature design
- Large scope changes requiring formal planning first

## Workflow

1. Reproduce: capture the failing test, error output, or behavioral evidence before editing.
2. Localize: read the failing file, its neighbors, and the most relevant standard sections.
3. Reduce: narrow the likely root cause to the smallest responsible area.
4. Hypothesize: state what you think is wrong before editing.
5. Fix: apply the smallest correction that matches the local codebase pattern.
6. Guard: add or update a regression test if behavior changed or failure could recur.
7. Verify: run the active tech stack's build/test commands (from `.claude/skills/tech-stack-{stack}/SKILL.md` `## Build & Test Commands`).
8. Escalate to the full implementation workflow if the task grows past 3 files or needs new architecture.

## Rules

- Read before editing.
- Match existing patterns.
- Do not gold-plate unrelated improvements.
- Stop after repeated failed attempts and explain what is blocking forward progress.
- Fix the root cause, not just the visible symptom.

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "I know where the bug is without reproducing it" | You have a hunch, not evidence. Preserve the failure first. |
| "This quick change should fix it" | Maybe. State the hypothesis so the fix can be judged against it. |
| "The test already fails, I don't need a regression test" | If the failure can recur, guard it explicitly. |
| "It's only one more file" | Hidden scope creep is how quick fixes become unplanned feature work. |

## Red Flags

- Editing based on guesswork without reproduction
- Touching a 4th file without escalation
- Fixing symptoms while leaving the root cause intact
- Multiple failed attempts with no updated hypothesis

## Verification

- [ ] Root cause is stated clearly
- [ ] Build passes
- [ ] Relevant tests pass
- [ ] Regression coverage exists when behavior changed
- [ ] Scope remained within quick-fix boundaries or was escalated
