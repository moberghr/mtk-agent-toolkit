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

**Verification contract.** Every success criterion carries an `evidence_channel` (the surface where the observable result is captured) and an `observable` (a binary pass/fail statement declared before execution). Verification must go criterion-by-criterion — trust the list over memory. For behavior-shaped changes, tests alone never prove done: the `evidence_channel` must be a real execution surface (`smoke-boot`, `http-probe`, `db-state-diff`, `cli-stdout`, or `browser`), not a build artifact.

**Re-arm rule.** Any edit that lands after the most recent verification resets every criterion's status to `re-armed`. A completion claim is rejected while any criterion is `re-armed`. Re-verification must run after the edit, cite the observable result per criterion, and set each criterion to `verified` before the claim is accepted.

## Frozen Criteria & Tamper Check

The `success_criteria[]` definitions (`id`, `observable`, `evidence_channel`) are **frozen at Phase 2.5 approval**. They are the goalposts; the run is not allowed to move them. The criteria are read-only ground truth during implementation — the same invariant F15 (Frozen-Replay / Non-Varying Evidence) names: *editing what measures you to move the number defeats the gate.*

Before accepting any completion claim, run the **tamper check**: confirm the frozen criteria block has not changed since approval. The spec sidecar is committed at Phase 2.5, so the cheapest check is a diff of the criteria block against the approved version:

```bash
# Tamper check: did success_criteria change since the spec was approved?
git diff --no-color <approval-ref>..HEAD -- docs/specs/<date>-<slug>.json \
  | grep -E '"(id|observable|evidence_channel)"' || echo "criteria intact"
```

- **Intact** → proceed with verification.
- **Changed** → a goalpost moved. This is **fail-closed**: do NOT verify against the new definition. Re-open Phase 2.5 for explicit re-approval of the amended criteria (an unapproved criteria change is unapproved scope — `failure_stop_gate` territory if it slipped in to force a pass). Record the tamper finding; never silently accept the edited criterion.

A criterion the implementer rewrote to match what the code happens to do is not a verified criterion — it is a laundered one.

### Approval-seal check (authoritative when a seal is recorded)

When the workflow artifact carries an `approval_seal` (recorded by the implement Phase 2.5 gate over the approved spec/plan bodies — the todo is progress state and is not sealed), run it **before** the criteria diff — it is a stronger, whole-artifact check the criteria-block diff cannot game:

```bash
scripts/workflow-artifact.sh verify-seal "$MTK_WF_UUID"
```

- **exit 0** → the approved bytes are intact; proceed.
- **exit 1 (STALE)** → a sealed artifact (spec or plan) changed after approval. **Fail-closed:** do NOT accept the completion claim. The edit re-opens Phase 2.5 — the engineer re-approves and the gate re-seals (`workflow-artifact.sh seal`). Record the printed `sealed=`/`current=` hashes and the named changed file in the block finding.
- **exit 3 (no seal)** → older workflow with no seal recorded; fall back to the criteria-block tamper check above.

The seal supersedes the git-diff tamper check because it binds the exact approved bytes of both scope artifacts (spec + plan), not just the criteria block — a laundered criterion or a quietly-edited plan breaks the hash. The todo is progress state and is intentionally *not* sealed, so ticking a completed batch off never trips it; a moved success-criterion goalpost is caught by the criteria diff below regardless.

## When To Use

- Before reporting a batch as complete
- Before reporting a fix as verified
- Before handing off to review
- Before claiming tests pass
- Before claiming a build succeeds
- Any time you are about to say "done"

### When NOT To Use

- Mid-exploration, where the goal is understanding rather than completion

## Evidence Channel Taxonomy

The `evidence_channel` field on each success criterion names the surface where the observable result is captured. Use the channel that corresponds to what the change actually does:

| Channel | When to use |
|---|---|
| `test-run` | Automated test suite (unit, integration, end-to-end) |
| `build-output` | Compiler, type-checker, or linter output |
| `http-probe` | HTTP request/response against a running service |
| `cli-stdout` | Command-line tool output inspected manually |
| `db-state-diff` | Before/after query of a database or file store |
| `browser` | Visual or functional check in a browser — capture an artifact; see below |
| `smoke-boot` | The built artifact/service boots and responds to a live request — the strongest real execution surface |
| `log-capture` | Structured log entry captured at runtime |
| `script-output` | Shell script execution result |

**Rule:** For behavior-shaped changes (new endpoint, changed handler, migration, state transition), `test-run` and `build-output` are insufficient on their own — the channel must include at least one real execution surface (`smoke-boot`, `http-probe`, `db-state-diff`, `cli-stdout`, or `browser`). Tests alone never prove behavior done. `smoke-boot` is the strongest: the thing actually starts and answers.

**`browser` capture.** The `browser` channel must persist what was seen, not just assert it. When Playwright MCP is available, capture `browser_take_screenshot` / `browser_console_messages` / `browser_network_requests` around the observable behavior and save them under `docs/specs/<slug>.evidence/<criterion-id>/`; when MCP is unavailable, fall back to an explicit textual description and say so in the completion table — never silently claim `browser` evidence with no artifact. Procedure: `Read .claude/references/evidence-capture.md`.

## Workflow

1. **Load the active success criteria.** Read the spec JSON sidecar at `docs/specs/<date>-<slug>.json` (or use the sidecar named in the workflow artifact). Extract `success_criteria[]` — each entry has `id`, `description`, `evidence_channel`, and `observable`. These are the items you verify one by one. Trust the list over memory.
2. Identify the verification command for the current claim — read the active tech stack skill (`.claude/skills/tech-stack-{stack}/SKILL.md`, where `{stack}` comes from `bash scripts/resolve-tech-stack.sh "<a changed file path>"`, not a bare root read; in a polyglot repo the root pin would hand you a build command that does not compile the subtree you changed) and pick from its `## Build & Test Commands` section:
   - Build claim -> the stack's compile/type-check command (dotnet: `dotnet build`, python: `mypy .`, typescript: `<pm> run build` or `tsc --noEmit`)
   - Test claim -> the stack's test command (dotnet: `dotnet test`, python: `pytest`, typescript: `<pm> test`)
   - Fix claim -> the specific test or reproduction step
   - Deployment claim -> the relevant smoke test
3. Execute the command to completion. Do not stop at partial output.
4. Read the full output, including:
   - exit code
   - error messages
   - warning count
   - test pass/fail counts

   **Evidence economy.** When the output will exceed a bounded tail (~30 lines), run the command through `bash scripts/mtk-verify-run.sh -- <cmd>` instead of bare: the full output persists to a citable `.mtk/evidence/` log, context carries `exit=N` plus the tail (runner summaries print last, so the tail keeps them), and the log path goes in the evidence cell. Contract: `Read .claude/references/verification-evidence-contract.md`.
5. **Criterion-by-criterion check.** For each success criterion in the list:
   a. Run (or re-run) the verification step appropriate to its `evidence_channel`.
   b. Confirm the result matches the criterion's `observable` (the binary pass/fail statement declared before execution).
   c. Record the criterion status: `verified` if the observable is met, `re-armed` if any edit landed after this check, `pending` if not yet checked.
   d. Do not advance past a criterion that remains `re-armed` or `pending`.
6. Confirm the output supports the specific claim being made.
7. Only then state the result as a **completion evidence table** — one row per criterion, three columns, no prose substitute:

   | criterion | verdict | evidence |
   |---|---|---|
   | SC1 | verified | `dotnet test --filter Batch2 → 14/14 pass` |
   | SC2 | verified | `curl :5080/health → 200, body {"status":"ok"}` |

   `verdict` is binary (`verified` / `not-verified`) — there is no "mostly". A table with any `not-verified` row is not a completion. The table is less gameable than a prose summary: every claim is pinned to a re-runnable command and its observed output.

   **First-verified-output baseline.** When a criterion has no automated regression test (e.g. a `cli-stdout` or `db-state-diff` observable checked by hand), persist the first verified output as a golden baseline under `docs/specs/<slug>.baselines/<SCn>.txt` and cite it in the evidence cell. Later runs diff against the baseline instead of re-judging from scratch — a cheap durable regression artifact for criteria the test suite does not cover.
8. Re-check freshness against the latest edit. MTK's hook state tracks the most
   recent file edit and the latest verification command in the session; a
   completion claim is stale when the verification event happened before the
   latest code-change event, even if both landed in the same wall-clock second.
9. **Re-arm check.** If any edit landed after the most recent verification, all
   criteria revert to `re-armed`. The `hooks/verify-completion` hook compares
   `last_edit_seq` vs `last_verification_seq` and emits a re-arm notice when
   stale. Do not claim completion while any criterion is `re-armed` — re-run
   verification from step 1 after the edit.
10. **Wiring check.** For every skill, hook, agent, or reference touched in
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
- Verify criterion-by-criterion. Passing SC1 does not imply SC2–SCN. Each
  criterion's `evidence_channel` and `observable` are the contract; confirm both.
- Any edit after the last verification re-arms all criteria. While any criterion
  is `re-armed`, the completion claim is rejected. Re-verification must cite
  the observable result per criterion before the claim is accepted.
- For behavior-shaped changes, tests alone never prove done. The evidence
  channel must include at least one real execution surface.
- Success criteria are frozen at approval. Run the tamper check before any
  completion claim; a changed `observable`/`evidence_channel`/`id` is fail-closed
  and re-opens Phase 2.5. Never verify against a goalpost the run moved.
- When the workflow carries an `approval_seal`, `verify-seal` is the authoritative
  pre-completion check. A STALE seal (exit 1) is fail-closed — the approved
  spec/plan bytes changed after approval (the todo is progress state and is not
  sealed); re-open Phase 2.5 and re-seal before any completion claim. Never
  complete against a stale seal.
- State completion as the `criterion | verdict | evidence` table. A prose
  "all good" without the table is not a completion claim.
- When re-verification keeps failing the same criterion, do not loop forever:
  drive it through the remediation circuit-breaker
  (`scripts/workflow-artifact.sh remediation`) and escalate to a human on
  `ESCALATE` — iteration cap or plateau (see `.claude/references/orchestration-gates.md`).

## Common Rationalizations

See `.claude/skills/context-engineering/SKILL.md` — the shared MTK rationalization table covers the universal shortcuts. Skill-specific traps to watch for here: running tests a few minutes ago (stale once you touched code), treating build success as test success (different claims, different evidence), and assuming compilation proves behavior (it proves syntax only).

## Red Flags

- "Should work" or "probably fixed" in a completion report
- Completion reported without any command output cited
- Partial test run used to claim full verification
- Stale evidence from before the latest edit
- Success claimed despite warnings or skipped tests in the output
- New skill / hook / agent / reference authored but not wired (no manifest entry, hook not chmod +x or not referenced from settings, agent missing from plugin.json) — files exist on disk but nothing dispatches them
- Claiming done while any criterion is `re-armed` (edit landed after verification)
- Verifying at the batch level instead of criterion-by-criterion
- Using `test-run` or `build-output` alone for a behavior-shaped change (missing real execution surface)
- A `success_criteria` `observable` was edited mid-run to match the code (goalpost moved — tamper check skipped)
- Completion claimed while the workflow's `approval_seal` is STALE (approved spec/plan edited after approval, gate not re-opened)
- Completion stated as prose instead of the `criterion | verdict | evidence` table

## Signal-Based Enforcement

This skill is enforced via hooks in `settings.json`:

- **Stop hook:** When the agent finishes responding, a prompt hook checks whether completion claims cite specific command output. If not, the agent is reminded to run verification and cite evidence.
- **Freshness check:** `hooks/context-budget.sh` records the latest edit time and
  the latest verification command run in the session. `hooks/verify-completion`
  compares those timestamps and warns with `VERIFICATION GAP:` when the evidence
  is stale or missing.
- **Re-arm notice:** When `last_edit_seq > last_verification_seq`, `hooks/verify-completion`
  emits `VERIFICATION GAP: criteria re-armed` — all success criteria are reset to
  `re-armed` and a completion claim is rejected until re-verification runs after
  the edit.

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
- [ ] Every success criterion was verified individually (criterion-by-criterion, citing the `observable` per criterion)
- [ ] No criterion remains `re-armed` (no edit landed after the last verification)
- [ ] Behavior-shaped changes cite a real execution surface (`smoke-boot`, `http-probe`, `db-state-diff`, `cli-stdout`, or `browser`), not only `test-run` / `build-output`
- [ ] For a `browser` criterion, the `docs/specs/<slug>.evidence/<criterion-id>/` evidence directory path is cited alongside the criterion in the completion table (or an explicit no-MCP fallback note; see `.claude/references/evidence-capture.md`)
- [ ] If verifying upstream agent work, every factual claim was extracted and reconciled (`VERIFIED`, `CONTRADICTED`, or `UNVERIFIABLE`) — none left `UNVERIFIED`
- [ ] Frozen-criteria tamper check ran (no `success_criteria` `id`/`observable`/`evidence_channel` changed since Phase 2.5 approval)
- [ ] When an `approval_seal` exists, `verify-seal` returned exit 0 (not STALE) before the completion claim
- [ ] Completion stated as the `criterion | verdict | evidence` table, every verdict binary
