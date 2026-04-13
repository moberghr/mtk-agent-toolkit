---
name: incremental-implementation
description: Use when executing an approved multi-file implementation to ensure each batch compiles, tests, and stays within the approved manifest.
license: MIT
compatibility:
  - claude-code
  - codex
trigger: approved-multi-file-implementation|batched-execution
skip_when: single-file-change|minimal-fix
---

# Incremental Implementation

## Overview

Implement in thin slices. Each slice must compile, test, and remain explainable before moving on. Use `test-driven-development` for the test strategy inside each slice and `source-driven-development` when framework behavior is uncertain.

## When To Use

- Any approved multi-file implementation
- Refactors that still require verification
- Any task where the cost of late failure is high

### When NOT To Use

- Single-file, single-function changes already minimal enough for the fix workflow

## Workflow

1. Before each batch, re-read the relevant rules from `CLAUDE.md` and the shared references.
2. Ask the simplicity question: what is the smallest correct implementation that could work?
3. Implement only the files listed for the batch.
4. Follow `test-driven-development` for tests in the same batch.
5. Use `source-driven-development` when any framework, library, or SDK behavior is uncertain.
6. Run the batch checkpoint using the build and test commands from the active tech stack skill's `## Build & Test Commands`.
7. Read `.claude/references/quick-check-list.md` if present and fix any violations immediately.
8. Mark the batch complete in `tasks/todo.md`.
9. **Churn check:** After completing each batch, run `git diff --stat` and count net lines changed. If cumulative changes across batches exceed 300 lines, pause and trigger an early review checkpoint:
   - Run quick-check list if present
   - Assess whether the scope is still within the approved manifest
   - If changes exceed 500 lines without a review, stop and run `compliance-reviewer` before continuing
   - This catches large unplanned changes mid-implementation rather than at the end
10. After all batches, run the full test command from the tech stack and write an explicit behavioral diff.

## Rules

- Never touch a file outside the manifest without re-planning.
- Never defer all tests to the end.
- Never continue across batches on a failing build.
- New public behavior must be test-covered.
- Keep changes rollback-friendly and dependency-focused.
- Do not mix unrelated cleanup into implementation batches.

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "I'll finish the feature and test later" | Late testing turns a small bug into a multi-batch excavation. |
| "This abstraction will help future work" | Future work is hypothetical. Current complexity is real. Earn abstractions. |
| "Since I'm in the file already, I'll clean this up too" | That is how slices become unreadable and impossible to review. |
| "The docs probably say this API works like the last one I used" | Probably is not good enough. Verify unfamiliar APIs from the source. |

## Red Flags

- Skipped checkpoint
- Batch grows beyond planned size
- Behavioral diff no longer matches the original intent
- Repeated build failures that suggest the design is wrong
- New abstractions appearing before the third real use case
- Cumulative churn exceeding 500 lines without an intermediate review

## Verification

- [ ] Each batch compiles and tests cleanly before the next begins
- [ ] Full solution tests pass at the end
- [ ] Behavioral diff is explicit and matches the request
- [ ] No files outside the approved manifest were touched without re-planning
