---
name: verification-before-completion
description: Use before reporting any task, batch, or fix as complete — requires fresh execution evidence for every completion claim.
type: skill
license: MIT
compatibility:
  - claude-code
  - cursor
  - codex
trigger: reporting-done|closing-task|handing-off|claiming-success
skip_when: mid-exploration|research-phase
effort: high
user-invocable: false
---

# Verification Before Completion

## Active Stack

```!
echo "--- Tech Stack ---"
cat .claude/tech-stack 2>/dev/null || echo "(not set)"
```

## Overview

No completion claim is valid without fresh evidence from an actual command execution. "Should work," "probably fixed," and "looks correct" are not verification. Run the command, read the output, check the exit code, then state the result with evidence.

## When To Use

- Before reporting a batch as complete
- Before reporting a fix as verified
- Before handing off to review
- Before claiming tests pass
- Before claiming a build succeeds
- Any time you are about to say "done"

### When NOT To Use

- Mid-exploration, where the goal is understanding rather than completion

## Workflow

1. Identify the verification command for the current claim — read the active tech stack skill (`.claude/skills/tech-stack-{stack}/SKILL.md`, where `{stack}` comes from `.claude/tech-stack`) and pick from its `## Build & Test Commands` section:
   - Build claim -> the stack's compile/type-check command (dotnet: `dotnet build`, python: `mypy .`, typescript: `<pm> run build` or `tsc --noEmit`)
   - Test claim -> the stack's test command (dotnet: `dotnet test`, python: `pytest`, typescript: `<pm> test`)
   - Fix claim -> the specific test or reproduction step
   - Deployment claim -> the relevant smoke test
2. Execute the command to completion. Do not stop at partial output.
3. Read the full output, including:
   - exit code
   - error messages
   - warning count
   - test pass/fail counts
4. Confirm the output supports the specific claim being made.
5. Only then state the result, citing the evidence.
6. Re-check freshness against the latest edit. MTK's hook state tracks the most
   recent file edit and the latest verification command in the session; a
   completion claim is stale when the verification event happened before the
   latest code-change event, even if both landed in the same wall-clock second.
7. **Wiring check.** For every skill, hook, agent, or reference touched in
   this task, run:
   ```bash
   bash scripts/validate-toolkit.sh --task-scoped <comma-separated paths>
   ```
   The check verifies that each file is fully registered — skill `name:`
   matches its directory and appears in `manifest.json`, hooks are
   executable and referenced from `settings.json` / `hooks/hooks.json`,
   agents appear in `plugin.json`, references appear in
   `.claude/references.index`. Authoring without wiring is a hard fail:
   the toolkit ships features by registration, not by file existence, so
   an unwired file is dead code that produces nothing at runtime. The
   touched-files list comes from `git diff --name-only HEAD` (or the
   spec's `change_manifest` when running inside a workflow). If the file
   list is empty (no toolkit artifacts touched), this step is a no-op.

## Claim Extraction (When Verifying Upstream Agent Work)

When the work being verified came from a prior agent — a builder subagent, a reviewer, an integration verifier — do NOT trust their summary. Extract their factual claims and reconcile each one independently before stating completion.

**Procedure:**

1. **List every factual claim** from the upstream agent's output. A claim is any sentence asserting a fact the verifier can re-check: "tests pass", "no SQL injection found", "the migration is reversible", "all error paths log", "Batch 2 is complete". Quote each one verbatim with its source.
2. **Mark each claim `UNVERIFIED`** in your working notes.
3. **Reconcile each claim** to one of:
   - `VERIFIED` — you ran a command or read a file and the evidence supports the claim. Cite the evidence.
   - `CONTRADICTED` — evidence shows the claim is false. The work is not complete; do not advance the gate. Block.
   - `UNVERIFIABLE` — the claim cannot be checked from current state (no test exists, the codepath is not exercised, the assertion is opinion). Treat as a finding: ask the upstream agent for evidence or downgrade the verdict.
4. **A claim that affects your verdict and remains `UNVERIFIED` is a stop condition.** State explicitly that you cannot complete verification, list the unverified claims, and return control without claiming pass.

**Why:** Upstream agents have an incentive to declare success. A neutral readback that re-asserts their summary is not verification — it is laundering. The reconciliation step forces you to see the difference between "they said it" and "I checked it".

**Example:**

> Builder claim: "All Batch 2 tests pass."
> → Run the same test command. Exit 0 with N/N → `VERIFIED: dotnet test --filter Batch2 → 14/14 pass`.
> → Exit 0 with 0/0 (no tests collected) → `CONTRADICTED: 0 tests in Batch2 — claim is false`.
> → Cannot run the test command in this environment → `UNVERIFIABLE: no test runner available; downgrade verdict and surface to engineer`.

## Rules

- Every completion claim must cite a specific command and its output.
- Partial verification is not verification. Run the full command.
- Cached results from earlier in the session do not count as fresh evidence.
- Evidence is stale if the latest verification event in session state predates
  the most recent file-write event to any file in the change set. MTK records
  both timestamps and event order in the hook session file; completion claims
  must use verification that happened after the last edit.
- If the verification fails, the task is not complete. Do not report it as complete with caveats.
- Re-verify after any fix-up, even a trivial one.

## Common Rationalizations

See `.claude/skills/context-engineering/SKILL.md` — the shared MTK rationalization table covers the universal shortcuts. Skill-specific traps to watch for here: running tests a few minutes ago (stale once you touched code), treating build success as test success (different claims, different evidence), and assuming compilation proves behavior (it proves syntax only).

## Red Flags

- "Should work" or "probably fixed" in a completion report
- Completion reported without any command output cited
- Partial test run used to claim full verification
- Stale evidence from before the latest edit
- Success claimed despite warnings or skipped tests in the output
- New skill / hook / agent / reference authored but not wired (no manifest entry, hook not chmod +x or not referenced from settings, agent missing from plugin.json) — files exist on disk but nothing dispatches them

## Signal-Based Enforcement

This skill is enforced via hooks in `settings.json`:

- **Stop hook:** When the agent finishes responding, a prompt hook checks whether completion claims cite specific command output. If not, the agent is reminded to run verification and cite evidence.
- **Freshness check:** `hooks/context-budget.sh` records the latest edit time and
  the latest verification command run in the session. `hooks/verify-completion`
  compares those timestamps and warns with `VERIFICATION GAP:` when the evidence
  is stale or missing.

The Stop hook is the enforcement mechanism. The skill documentation above is the contract; the hook is the guardrail.

### Stuck Signal

If you are stuck — repeated failures, unclear root cause, or blocked by missing context — do not force a completion. Instead:

1. State clearly: "I am stuck."
2. Describe what you've tried and what is blocking progress.
3. Ask for help or escalate to the engineer.

Forcing past a stuck state produces garbage output. Admitting difficulty is always the right move.

## Verification

- [ ] A specific command was executed for the claim
- [ ] The full output was read (not just the exit code)
- [ ] The output directly supports the claim
- [ ] The evidence is from after the most recent code change
- [ ] No warnings or failures were silently ignored
- [ ] If verifying upstream agent work, every factual claim was extracted and reconciled (`VERIFIED`, `CONTRADICTED`, or `UNVERIFIABLE`) — none left `UNVERIFIED`
