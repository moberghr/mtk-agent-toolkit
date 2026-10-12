---
name: incremental-implementation
description: Use when executing an approved multi-file implementation to ensure each batch compiles, tests, and stays within the approved manifest.
type: skill
license: MIT
compatibility:
  - claude-code
  - codex
trigger: approved-multi-file-implementation|batched-execution
skip_when: single-file-change|minimal-fix
user-invocable: false
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
6.5. **Capture analyzer output.** After the build command completes, pipe its output
   through the build diagnostics parser if available:
   ```bash
   # Example for .NET (adapt command from tech stack skill's Build & Test Commands):
   dotnet build 2>&1 | tee /dev/tty | hooks/parse-build-diagnostics.sh > .mtk/analyzer-output.json
   ```
   Surface any critical analyzer findings immediately — they block the batch just like
   build failures. Warning-level findings carry forward to the pre-commit review.
   If `hooks/parse-build-diagnostics.sh` does not exist in the installed toolkit, skip this step.
7. Read `.claude/references/pre-commit-review-list.md` if present and fix any violations immediately.
8. Mark the batch complete in `tasks/todo.md`. Record the per-batch gate decision and progress on the workflow artifact **in the same shell call as the checkpoint test run** — `<test cmd> && "$WFA" batch "$MTK_WF_UUID" gate phase_exit_gate pass --reason "batch <id> green" -- set results.batches_completed=<n>` (on red: `|| "$WFA" gate … fail …` to trigger remediation). A standalone bookkeeping turn is a wasted turn. See `.claude/references/orchestration-gates.md`.
9. **Churn check:** After completing each batch, run `git diff --stat` and count net lines changed **since the last review** (intermediate or Phase 4), **excluding generated and mechanical files** — lockfiles, `*.Designer.cs`, `*.g.cs`, `*.generated.*`, EF migration snapshots, `*.min.js`/`*.min.css`, built bundle output (e.g. `wwwroot/dist/**`). Generated churn is not review load. Thresholds are `MTK_CHURN_REVIEW_LINES` (default **300**) and `MTK_CHURN_HALT_LINES` (default **500**); at rigor HIGH/MAX — the subagent path or the inline-MAX profile — the defaults **double** to 600/1000, because every batch there is already isolated and drift-checked and a full two-stage review is guaranteed at Phase 4, so the mid-run review is a safety net, not the primary review. If the count exceeds the review threshold, pause and trigger an early review checkpoint:
   - Run the pre-commit review list if present
   - Assess whether the scope is still within the approved manifest
   - If the count exceeds the halt threshold without a review, stop and run `compliance-reviewer` before continuing; the count resets after that review
   - This catches large unplanned changes mid-implementation rather than at the end
10. After all batches, run the full test command from the tech stack and write an explicit behavioral diff.
11. **Append the `implement` section to the JSON handoff artifact** at
    `docs/specs/<date>-<slug>.json`. Schema:
    `.claude/schemas/handoff.schema.json`. Required keys:
    ```json
    "implement": {
      "actual_files": ["..."],         // git diff --name-only <base>...HEAD
      "completed_batches": ["B1","B2"],
      "deviations": [
        { "kind": "extra-file", "detail": "src/Helper.cs",
          "justification": "needed to unblock B2; spec did not anticipate" }
      ],
      "behavioral_diff": "..."
    }
    ```
    Be honest about deviations — `spec-drift-detection` will diff
    `change_manifest` against `actual_files` regardless. Run
    `bash scripts/validate-handoff.sh docs/specs/<date>-<slug>.json` to
    surface drift before handing off to review.

## Rules

- Never touch a file outside the manifest without re-planning.
- Never defer all tests to the end.
- Never continue across batches on a failing build.
- New public behavior must be test-covered.
- Keep changes rollback-friendly and dependency-focused.
- Do not mix unrelated cleanup into implementation batches.

## Common Rationalizations

See `.claude/references/workflow-rationalizations.md` for the shared table. Incremental-implementation-specific traps: "since I'm in the file already, I'll clean this up too" (that is how slices become unreadable and impossible to review — stay scoped per batch), and "this abstraction will help future work" (future work is hypothetical, current complexity is real — earn abstractions from duplication, don't pre-build them).

## Red Flags

- Skipped checkpoint
- Batch grows beyond planned size
- Behavioral diff no longer matches the original intent
- Repeated build failures that suggest the design is wrong
- New abstractions appearing before the third real use case
- Cumulative non-generated churn exceeding the halt threshold (`MTK_CHURN_HALT_LINES`, default 500; 1000 at HIGH/MAX) without an intermediate review

## Verification

- [ ] Each batch compiles and tests cleanly before the next begins
- [ ] Full solution tests pass at the end
- [ ] Behavioral diff is explicit and matches the request
- [ ] No files outside the approved manifest were touched without re-planning
