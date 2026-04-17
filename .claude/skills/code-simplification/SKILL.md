---
name: code-simplification
description: Use after a feature or fix is verified and passing to reduce complexity, remove dead code, and improve clarity without changing behavior.
type: skill
license: MIT
compatibility:
  - claude-code
  - cursor
  - codex
trigger: post-verification|cleanup-pass|heavy-abstractions
skip_when: pre-correctness|unrelated-refactor
user-invocable: false
---

# Code Simplification

## Overview

Simplify only after behavior is proven. The goal is to reduce complexity, remove dead weight, and improve clarity without broadening scope or changing behavior.

## When To Use

- After a feature or fix is working
- During a cleanup pass
- When abstractions are heavier than the current use case needs

### When NOT To Use

- Before correctness is established
- As cover for a broad refactor unrelated to the task

## Workflow

1. Start from verified working code.
2. Identify the smallest simplifications that improve readability or reduce dead code.
3. Remove debug artifacts, dead code, and redundant indirection where safe.
4. Collapse premature abstractions that are not earning their cost.
5. If dead code is ambiguous or ownership is unclear, ask before deleting.
6. Re-run build and tests after the cleanup pass.

## Rules

- Preserve behavior.
- Keep cleanup scoped to the task area.
- Prefer deleting complexity over moving it around.
- Ask before removing uncertain dead code.

## Common Rationalizations

See `.claude/skills/context-engineering/SKILL.md` for the shared table. Simplification-specific traps: "now that I'm here, I should refactor the whole module" (cleanup is not permission for a hidden rewrite — stay scoped), and "the dead code is probably still needed somewhere" (probably is a reason to verify or ask, not to leave clutter in place).

## Red Flags

- Cleanup that changes behavior
- Broad refactor hidden inside feature work
- Dead code left in place because nobody verified ownership

## Verification

- [ ] Behavior is unchanged
- [ ] Build and tests still pass
- [ ] Cleanup stayed within scope
- [ ] Any uncertain deletion was explicitly surfaced
