---
name: verification-before-completion
description: Require fresh execution evidence before claiming any task is complete. Use before reporting success, closing a task, or handing off to review.
license: MIT
compatibility:
  - claude-code
  - cursor
  - codex
trigger: reporting-done|closing-task|handing-off|claiming-success
skip_when: mid-exploration|research-phase
effort: high
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

## Rules

- Every completion claim must cite a specific command and its output.
- Partial verification is not verification. Run the full command.
- Cached results from earlier in the session do not count as fresh evidence.
- If the verification fails, the task is not complete. Do not report it as complete with caveats.
- Re-verify after any fix-up, even a trivial one.

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "The change is trivial, it obviously works" | Trivial changes cause production incidents. Verify anyway. |
| "I just ran the tests a few minutes ago" | You changed code since then. The prior result is stale. |
| "The build passed, so the tests probably pass too" | Build success and test success are different claims requiring different evidence. |
| "I'll verify after the review" | Review assumes verification already happened. Unverified code wastes reviewer time. |
| "It compiled without errors, that's good enough" | Compilation proves syntax. It does not prove behavior, correctness, or safety. |

## Red Flags

- "Should work" or "probably fixed" in a completion report
- Completion reported without any command output cited
- Partial test run used to claim full verification
- Stale evidence from before the latest edit
- Success claimed despite warnings or skipped tests in the output

## Signal-Based Enforcement

This skill is enforced via hooks in `settings.json`:

- **Stop hook:** When the agent finishes responding, a prompt hook checks whether completion claims cite specific command output. If not, the agent is reminded to run verification and cite evidence.
- **TaskCompleted hook:** When a task is marked done, a prompt hook reminds the agent to verify build and test results are fresh.

These hooks are the enforcement mechanism. The skill documentation above is the contract; the hooks are the guardrails.

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
