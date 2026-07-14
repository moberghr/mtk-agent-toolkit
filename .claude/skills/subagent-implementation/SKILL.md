---
name: subagent-implementation
description: Use instead of incremental-implementation when a feature has 3+ batches, 6+ files, or non-none security_impact — one fresh implementer subagent per batch with orchestrator-side drift checks.
type: skill
license: MIT
compatibility:
  - claude-code
trigger: large-multi-batch-implementation|context-isolation-needed
skip_when: small-feature|fewer-than-three-batches|inline-implementation-fits
user-invocable: false
---

# Subagent Implementation

## Overview

Per-batch context isolation for large features. The orchestrator (main context) holds the spec, plan, and JSON sidecar; each batch's actual editing happens inside a fresh subagent that receives only what it needs and returns a structured result. Inspired by `obra/superpowers`'s subagent-driven-development; adapted to MTK's typed-handoff and Phase-4 review architecture.

This skill is a **branch** of `incremental-implementation`, not a replacement. `implement/SKILL.md` Phase 3 picks one based on the threshold below.

## When To Use

Phase 3 of `implement/SKILL.md` invokes this skill when **any** of these are true (read from `docs/specs/<date>-<slug>.json`):

- `plan.batches.length >= 3`
- non-mechanical `change_manifest` entries >= 6
- `security_impact != "none"`
- rigor score ≥ 8 from the spec sidecar (rigor level HIGH or MAX — see `implement/SKILL.md` Rigor Score)

### When NOT To Use

- 1-2 batch features → use `incremental-implementation` (inline path; cheaper).
- Quick fixes (already routed through `fix/SKILL.md`).
- Single-file refactors.
- Standalone runs without an approved spec — there is no JSON sidecar to thread.

## Workflow

Companion files: this skill's detail payloads live in `.claude/references/subagent-implementer-prompt.md` and `.claude/references/subagent-dynamic-workflow.md` — resolve them under `$CLAUDE_PLUGIN_ROOT` when set (plugin-cache installs), else project-relative. If a companion cannot be resolved, stop the affected step and report the missing file — do not reconstruct its content from memory.

### Decision Graph

The orchestrator never edits source. The implementer subagent never spawns further subagents. The drift check is fast and orchestrator-side — no reviewer agent per batch.

The full decision graph lives in `.claude/references/subagent-dynamic-workflow.md` (under `$CLAUDE_PLUGIN_ROOT` when set). Read it when you need the branch/halt topology.

### Execution paths

There are two ways to run the per-batch loop. Both share the **same implementer prompt template, the same structured JSON result, and the same orchestrator-side drift / sidecar / churn / Phase-4 discipline.** Only the dispatch mechanism differs.

- **Dynamic-workflow path (preferred when the `Workflow` tool is available).** The orchestrator generates a JavaScript orchestration script that runs the batches through Claude Code's native dynamic-workflow runtime in the background, with its built-in plan-approval gate. The runtime handles concurrency, retries, and structured-output validation. The orchestrator then does the drift micro-check and sidecar persistence **after** the run returns. See `.claude/references/subagent-dynamic-workflow.md`.
- **Manual Agent-loop path (fallback).** When the `Workflow` tool is not exposed in this harness, dispatch one implementer subagent per batch by hand. See "Steps (manual Agent-loop path)" below.

Pick the path once, at the top of Phase 3, based on tool availability. Do not mix them within one feature.

When the `Workflow` tool is available the dynamic-workflow path MUST be used — read `.claude/references/subagent-dynamic-workflow.md` now and follow it; choosing the manual path to avoid the Read is a scope violation.

### Steps (manual Agent-loop path)

1. **Threshold gate.** Read `docs/specs/<date>-<slug>.json`. Dispatch when any hard trigger is met **or** the rigor score is ≥ 8 (rigor HIGH/MAX). If neither holds → return control to `implement/SKILL.md` Phase 3 with the recommendation to use `incremental-implementation` instead. Do not silently fall through.
2. **Pick implementer model.** The policy default is **Sonnet** — see `.claude/references/model-routing.md` (reserve Opus for batches the plan flags novel/tricky: concurrency, unfamiliar SDK, subtle invariants). Invoke `AskUserQuestion` once (load via `ToolSearch select:AskUserQuestion` if deferred):
   - Question: `Implementer subagent model? Affects per-batch cost and capability.`
   - Options:
     - `Sonnet (policy default — faster, cheaper, suits straightforward batches)`
     - `Opus (more capable — pick when the batch involves novel logic, tricky concurrency, or unfamiliar framework behavior)`
   - Persist the choice in memory for the rest of the loop. Do **not** ask again between batches. If the harness does not expose `AskUserQuestion`, default to Sonnet and emit one line: `Implementer model defaulted to Sonnet (AskUserQuestion unavailable).`
3. **For each batch in dependency order:**
   1. **Build the context bundle.** Concatenate:
      - Spec sections relevant to this batch (`Summary`, `Architecture and design`, `Security and compliance impact` if non-none)
      - The single batch object from `plan.batches[]` (id, files, acceptance, verification, boundary, depends)
      - **Prior-batch summary:** for every batch already in `sidecar.implement.completed_batches`, include `{id, actual_files, behavioral_diff}`. Do NOT include full prior diffs — just the summary. Emit it as a dense block (one batch per line: `id | n files | behavioral_diff`) and prefix it with the completed-batch count, e.g. `prior-batches: 3` — the implementer can checksum line count against that number and flag a truncated handoff rather than building on a silently-cut summary.
      - Active tech stack name and the path to its skill (don't paste the skill body; the subagent will read it itself).
      - The full `change_manifest` and `out_of_scope` arrays — the subagent must know its boundary.
      - The path to `CLAUDE.md`.
   2. **Dispatch the implementer subagent** via `Agent` tool with:
      - `subagent_type: general-purpose` (no MTK-specific implementer subagent type — keep tool surface generic)
      - `model: <chosen>` (Sonnet or Opus from step 2)
      - `description: Batch <id> — <one-line intent>`
      - `prompt`: see "Implementer prompt template" below
   3. **Parse the structured result.** The implementer must return one fenced JSON block with `batch_id, status(completed|blocked|inconclusive), actual_files, build{ok,evidence}, tests{ok,evidence}, behavioral_diff, deviations[]` (`usage` optional). Inconclusive is never a pass. See `.claude/references/subagent-implementer-prompt.md` for the canonical schema and semantics.
   4. **Build/test/inconclusive gate.**
      - `status == inconclusive` (or unparseable / ack-only): respawn **once**
        with the scope narrowed to the missing deliverable and an explicit
        "return the JSON result exactly per schema; partial work is not done"
        reminder. If it comes back `inconclusive` again → halt and report to the
        engineer. Inconclusive is never silently upgraded to pass.
      - `build.ok == false` or `tests.ok == false` (`status: blocked`): up to 2
        retries with the failure output appended to the prompt.
      - On exhaustion, halt and report to engineer (also in autonomous mode — the
        gate is structural, not interactive).
   5. **Drift micro-check (orchestrator-side, no agent call).**
      - `extra_files = actual_files - batch.files`
      - `missing_files = batch.files - actual_files` (excluding files explicitly deferred by the spec)
      - `public_contract_touched`: if any `actual_files` matches a path in `change_manifest` whose entry has a `public_contracts` linkage, confirm the contract change matches the planned one.
      - **Clean** → proceed to step 6.
      - **Drifted, auto-fixable** (extra file is in-package, no new public contract, security_impact unchanged) → orchestrator amends the sidecar `change_manifest` with the new file and a `deviations` note. Continue.
      - **Drifted, not auto-fixable** (cross-package leak, new public contract, security_impact escalated, or `out_of_scope` violated) → re-open Phase 2.5 approval gate. Halt the loop until the engineer answers.
   6. **Persist the batch result.**
      - Append `{batch_id, actual_files, build, tests, behavioral_diff, deviations}` to `sidecar.implement.completed_batches[]`.
      - Run `bash scripts/validate-handoff.sh docs/specs/<date>-<slug>.json` (if available) to surface schema drift early.
      - Tick the batch row in `tasks/todo.md`.
   7. **Cumulative churn check.** After every batch, run `git diff --stat <base>...HEAD` and count net lines. Mirror `incremental-implementation` thresholds: ≥300 lines without an intermediate review → trigger an early `pre-commit-review-list` pass. ≥500 lines without a review → halt and run `compliance-reviewer` before continuing.
4. **After all batches:**
   - Write a final aggregated `behavioral_diff` to `sidecar.implement.behavioral_diff`.
   - Hand control back to `implement/SKILL.md` Phase 3.5 (whole-feature spec-drift) → Phase 4 (two-stage review). Both run unchanged. Per-batch micro-checks are supplemental, not a replacement.

### Dynamic-workflow path

Steps 1-6 of the dynamic-workflow path and the "If the `Workflow` tool errors…" fallback rule live in `.claude/references/subagent-dynamic-workflow.md` (resolve under `$CLAUDE_PLUGIN_ROOT` when set). Read it now and follow it when the `Workflow` tool is available.

### Dispatch hardening (large prompts & args)

Large doc/code batches produce large context bundles, and the dynamic-workflow path has historically been fragile when those bundles are passed the wrong way — an unbound-`args` crash, or the runtime stalling on a multi-kilobyte prompt shoved through a single argument. Three rules make dispatch robust regardless of batch size:

1. **Never pass a large prompt block as a positional/CLI argument.** The implementer prompt and context bundle can be tens of KB. Write the assembled bundle to a file under `.mtk/workflows/<uuid>/batch-<id>.prompt.md` and pass the **path** (the `agent()` prompt string reads it, or the manual `Agent` prompt references it). A prompt block in `argv` is what triggers the arg-length / stall failures.
2. **Bind `args` as actual JSON, never a stringified blob.** When the generated workflow script reads `args`, pass it as a real JSON value in the `Workflow` call (`args: { batch: {...} }`), not a JSON-encoded string. A stringified list reaches the script as one string, so `args.batches.map(...)` throws — the "args-unbound" crash from the v7.14 dogfooding run. If the script needs no input, do not reference `args` at all.
3. **Compress before you hand off.** Run the prior-batch summary and any pasted command output through `scripts/mtk-compress.sh` (see `.claude/references/output-compression.md`) before it enters the bundle — dense handoffs keep each batch's dispatch inside a safe size envelope.

These are dispatch-mechanism rules only; the prompt *contract* (TASK/DELIVERABLE/SCOPE/VERIFY) and the orchestrator-side gates are unchanged.

### Implementer prompt template

The implementer prompt template is shared by both execution paths and is organized under the four contract headers TASK / DELIVERABLE / SCOPE / VERIFY. Read `.claude/references/subagent-implementer-prompt.md` before building the first context bundle — do not paraphrase it from memory.

## Rules

- One implementer subagent per batch. Never reuse a subagent across batches (the point is context isolation).
- **Guardrails travel with the capability.** The implementer prompt states each granted tool's boundary and a no-delete fence inline (Rules 6–7), so a dispatched subagent inherits its constraints from the prompt rather than a rules file it may not load. Keep those clauses when editing the template.
- **Inconclusive is never a pass.** A batch whose result is missing, unparseable, acknowledgment-only, or marked `inconclusive` is recorded as `inconclusive` in the sidecar and respawned **once** with the scope narrowed to the missing deliverable. A second inconclusive halts the loop and reports to the engineer. Never count an inconclusive batch toward completion, and never let a later batch build on one.
- Orchestrator never edits source. If editing is needed (e.g. to amend the sidecar after auto-fix), only `docs/specs/*.json`, `tasks/todo.md`, and the sidecar are fair game.
- The model selection is asked **once**, before the loop. Never per batch.
- In autonomous mode (Phase 2.5 returned `Approve & run until done`), the loop runs without further `AskUserQuestion` calls **except** the Phase 2.5 re-open required by non-auto-fixable drift. That re-open is a structural halt, not a chatty confirmation.
- Drift micro-check is orchestrator-side and synchronous. No agent call per batch.
- Phase 4 review (compliance, test, architecture, silent-failure-hunter) runs unchanged after the loop.
- **Dynamic-workflow path:** the workflow replaces only the inner dispatch loop. Drift micro-check, sidecar persistence, churn check, and Phase 4 are orchestrator-side and run **after** the workflow returns — never inside it. The native runtime's plan-approval gate does not replace MTK's Phase 2.5; it is a transparency checkpoint on an already-approved scope.
- **Dependency order is sequential by default.** Only parallelize a wave when batch `depends` arrays prove independence. A later batch reading an earlier batch's files must not run concurrently with it.

## Common Rationalizations

See `.claude/skills/context-engineering/SKILL.md` for the shared table. Subagent-implementation-specific traps:

| Rationalization | Reality |
|---|---|
| "I'll just edit it myself, faster than dispatching" | That defeats the entire point. Context contamination is the cost you pay invisibly. Dispatch. |
| "Let me ask the engineer between batches whether to keep going" | Phase 2.5 already answered. Per-batch confirmation = approval fatigue. Only halt on structural conditions (build fail / non-auto drift). |
| "The implementer touched one extra file, I'll quietly amend the manifest" | Auto-fix is allowed only inside the package, with no new public contract and no security_impact change. Anything else re-opens 2.5. |
| "I'll let the implementer subagent do the spec-drift review too" | No. Drift is orchestrator-side. The subagent is too close to its own diff to judge it. |
| "Let me reuse the same subagent across batches to save tokens" | Then it's not subagent-driven. Use `incremental-implementation` instead. |
| "Build failed, I'll skip this batch and continue" | No. A failing batch poisons every later batch's assumptions. Retry, then halt. |
| "The subagent said 'done' but returned no JSON — close enough, mark it passed" | No. Ack-only / unparseable / missing-evidence results are `inconclusive`, not `completed`. Respawn once with narrowed scope; a second inconclusive halts. |
| "The workflow runtime validated the structured output, so I can skip the drift check" | No. Schema validation ≠ scope/drift judgment. The runtime confirms the JSON shape; it does not know `batch.files` or `out_of_scope`. Run the orchestrator-side drift micro-check on every returned result. |
| "The native plan-approval gate already approved it, so I can skip MTK Phase 2.5 / Phase 4" | No. The runtime gate approves running the *script*; it is not a spec approval or a code review. Phase 2.5 precedes the workflow; Phase 4 follows it. |
| "pipeline()/parallel() is faster, I'll run all batches at once" | Only if their `depends` arrays prove independence. Dependent batches run sequentially — concurrency on a dependency edge produces a half-built, racy feature. |

## Red Flags

- Orchestrator using `Edit` or `Write` on source files
- Implementer subagent receiving the prior batch's full diff (should be summary only)
- Implementer subagent calling `Agent` (recursion)
- Drift detected but loop continued without sidecar amendment
- `AskUserQuestion` called more than once per loop (model pick excluded)
- Per-batch review agent dispatched (was deferred to v2; if you need this, talk to maintainers first)
- Phase 4 skipped because "every batch was already reviewed"
- Dynamic-workflow path: orchestrator-side drift check skipped because "the workflow validated the output"
- Dynamic-workflow path: Phase 2.5 or Phase 4 skipped because the native plan-approval gate fired
- Dependent batches run with `parallel()`/`pipeline()` despite an ordering edge in `depends`
- Drift detection or sidecar amendment logic placed *inside* the generated workflow script
- An `inconclusive` / ack-only / unparseable batch result counted as a pass or built upon by a later batch

## Verification

- [ ] Threshold check ran and produced a documented yes/no
- [ ] Execution path chosen once (dynamic-workflow when `Workflow` tool available, else manual Agent-loop) and not mixed mid-feature
- [ ] Implementer model was asked once via `AskUserQuestion` (or defaulted with explicit notice)
- [ ] One fresh subagent dispatched per batch (no reuse) — or one `agent()` call per batch in the generated script
- [ ] Each batch returned a structured JSON result matching the schema (validated by the runtime on the workflow path)
- [ ] Dependent batches ran sequentially; only proven-independent batches were parallelized
- [ ] Drift micro-check ran orchestrator-side for every batch (also on the workflow path, after it returned), with auto-fix or 2.5 re-open as appropriate
- [ ] `sidecar.implement.completed_batches[]` reflects every batch with actual_files and behavioral_diff
- [ ] `tasks/todo.md` ticks match completed batches
- [ ] Phase 4 review still runs unchanged after the loop
- [ ] Cumulative churn thresholds (300/500 lines) honored
