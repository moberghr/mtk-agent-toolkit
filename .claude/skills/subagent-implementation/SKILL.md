---
name: subagent-implementation
description: Use instead of incremental-implementation when a feature has 3+ batches, 6+ files, or non-none security_impact — dispatches one fresh implementer subagent per batch with orchestrator-side drift checks.
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
- `change_manifest.length >= 6`
- `security_impact != "none"`

### When NOT To Use

- 1-2 batch features → use `incremental-implementation` (inline path; cheaper).
- Quick fixes (already routed through `fix/SKILL.md`).
- Single-file refactors.
- Standalone runs without an approved spec — there is no JSON sidecar to thread.

## Workflow

### Decision Graph

The orchestrator never edits source. The implementer subagent never spawns further subagents. The drift check is fast and orchestrator-side — no reviewer agent per batch.

```dot
digraph subagent_impl {
  rankdir=TB;
  node [shape=box, style=rounded, fontname="Helvetica"];
  edge [fontname="Helvetica", fontsize=10];

  start    [label="Phase 3 entered\n(spec + sidecar approved)"];
  thr      [label="threshold met?\n(≥3 batches OR ≥6 files OR\nsecurity_impact != none)", shape=diamond];
  inline   [label="dispatch to\nincremental-implementation\n(inline path)", style="rounded,filled", fillcolor="#e0f0e0"];
  ask      [label="ASK ONCE: implementer model\n(Sonnet faster/cheaper |\nOpus more capable)\nvia AskUserQuestion",
            style="rounded,filled", fillcolor="#fff8d0"];

  next     [label="next batch\n(dependency order)", shape=diamond];
  bundle   [label="build context bundle:\nspec excerpt · batch.files ·\nbatch.acceptance · prior batches'\nactual_files · diff summary"];
  spawn    [label="Agent(subagent_type=general-purpose,\nmodel=<chosen>, tools=read+edit+bash)\n→ implementer prompt"];
  parse    [label="parse structured result:\nactual_files · build · tests ·\nbehavioral_diff · deviations"];
  buildok  [label="build + batch tests\ngreen?", shape=diamond];
  retry    [label="retry budget left?", shape=diamond];
  halt     [label="HALT — report to engineer\n(autonomous mode also halts here)",
            style="rounded,filled", fillcolor="#ff9090"];

  drift    [label="drift micro-check\n(orchestrator-side):\nactual_files ⊆ batch.files?\npublic_contracts touched ⊆ planned?", shape=diamond];
  fixable  [label="auto-fixable?\n(extra file is helper /\nin-package only)", shape=diamond];
  reapprove[label="re-open Phase 2.5\nfor scope amendment",
            style="rounded,filled", fillcolor="#fff8d0"];
  amend    [label="orchestrator amends\nchange_manifest + sidecar"];

  persist  [label="append batch result to\nsidecar.implement.completed_batches\n+ tick tasks/todo.md"];
  more     [label="more batches?", shape=diamond];
  done     [label="hand back to\nPhase 3.5 (drift) → Phase 4 (review)",
            style="rounded,filled", fillcolor="#e0f0e0"];

  start -> thr;
  thr -> inline [label="no"];
  thr -> ask    [label="yes"];
  ask -> next;
  next -> bundle -> spawn -> parse -> buildok;
  buildok -> retry [label="no"];
  retry -> spawn  [label="yes (≤2 retries)"];
  retry -> halt   [label="no"];
  buildok -> drift [label="yes"];
  drift -> persist [label="clean"];
  drift -> fixable [label="drifted"];
  fixable -> amend [label="yes"];
  fixable -> reapprove [label="no"];
  amend -> persist;
  reapprove -> halt;
  persist -> more;
  more -> next [label="yes"];
  more -> done [label="no"];
}
```

### Execution paths

There are two ways to run the per-batch loop. Both share the **same implementer prompt template, the same structured JSON result, and the same orchestrator-side drift / sidecar / churn / Phase-4 discipline.** Only the dispatch mechanism differs.

- **Dynamic-workflow path (preferred when the `Workflow` tool is available).** The orchestrator generates a JavaScript orchestration script that runs the batches through Claude Code's native dynamic-workflow runtime in the background, with its built-in plan-approval gate. The runtime handles concurrency, retries, and structured-output validation. The orchestrator then does the drift micro-check and sidecar persistence **after** the run returns. See "Dynamic-workflow path" below.
- **Manual Agent-loop path (fallback).** When the `Workflow` tool is not exposed in this harness, dispatch one implementer subagent per batch by hand. See "Steps (manual Agent-loop path)" below.

Pick the path once, at the top of Phase 3, based on tool availability. Do not mix them within one feature.

### Steps (manual Agent-loop path)

1. **Threshold gate.** Read `docs/specs/<date>-<slug>.json`. If thresholds not met → return control to `implement/SKILL.md` Phase 3 with the recommendation to use `incremental-implementation` instead. Do not silently fall through.
2. **Pick implementer model.** Invoke `AskUserQuestion` once (load via `ToolSearch select:AskUserQuestion` if deferred):
   - Question: `Implementer subagent model? Affects per-batch cost and capability.`
   - Options:
     - `Sonnet (default — faster, cheaper, suits straightforward batches)`
     - `Opus (more capable — pick when the batch involves novel logic, tricky concurrency, or unfamiliar framework behavior)`
   - Persist the choice in memory for the rest of the loop. Do **not** ask again between batches. If the harness does not expose `AskUserQuestion`, default to Sonnet and emit one line: `Implementer model defaulted to Sonnet (AskUserQuestion unavailable).`
3. **For each batch in dependency order:**
   1. **Build the context bundle.** Concatenate:
      - Spec sections relevant to this batch (`Summary`, `Architecture and design`, `Security and compliance impact` if non-none)
      - The single batch object from `plan.batches[]` (id, files, acceptance, verification, boundary, depends)
      - **Prior-batch summary:** for every batch already in `sidecar.implement.completed_batches`, include `{id, actual_files, behavioral_diff}`. Do NOT include full prior diffs — just the summary.
      - Active tech stack name and the path to its skill (don't paste the skill body; the subagent will read it itself).
      - The full `change_manifest` and `out_of_scope` arrays — the subagent must know its boundary.
      - The path to `CLAUDE.md`.
   2. **Dispatch the implementer subagent** via `Agent` tool with:
      - `subagent_type: general-purpose` (no MTK-specific implementer subagent type — keep tool surface generic)
      - `model: <chosen>` (Sonnet or Opus from step 2)
      - `description: Batch <id> — <one-line intent>`
      - `prompt`: see "Implementer prompt template" below
   3. **Parse the structured result.** The implementer must return a fenced JSON block matching:
      ```json
      {
        "batch_id": "B2",
        "actual_files": ["src/Foo.cs", "tests/FooTests.cs"],
        "build": { "ok": true, "evidence": "command + tail" },
        "tests": { "ok": true, "evidence": "test summary" },
        "behavioral_diff": "what an external caller now observes that they didn't before",
        "deviations": [
          { "kind": "extra-file|skipped-file|extra-contract|other",
            "detail": "...", "justification": "..." }
        ]
      }
      ```
      If JSON parse fails → treat as build/test failure (retry once with explicit "return JSON exactly per schema" reminder; then halt).
   4. **Build/test gate.** If `build.ok == false` or `tests.ok == false`:
      - Up to 2 retries with the failure output appended to the prompt.
      - On exhaustion, halt and report to engineer (also in autonomous mode — the gate is structural, not interactive).
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

Use this when the `Workflow` tool is available. It moves the per-batch dispatch loop into a generated JS script that the native runtime executes in the background, so the orchestrator's main context stays light. **What does NOT move into the workflow:** the drift micro-check, sidecar amendment, cumulative churn check, and Phase 4 review. Those stay orchestrator-side, exactly as in the manual path. The workflow is a faster, runtime-managed replacement for steps 3.1–3.4 only.

1. **Threshold gate + model pick.** Identical to manual steps 1–2. The model chosen (Sonnet/Opus) is passed as the `model` option on each `agent()` call in the script.
2. **Build the batch schedule (dependency order).** Compute a serial order from each batch's `depends` array. **Default to sequential execution** — a later batch may rely on files an earlier batch created, and `pipeline()`/`parallel()` run items concurrently. Only group batches into a parallel wave when their `depends` arrays prove they are mutually independent (no shared files, no ordering edge). When unsure, keep them sequential; correctness beats wall-clock here.
3. **Generate the workflow script.** Adapt `templates/workflows/subagent-implementation.workflow.js`. Each batch becomes one `agent()` call that:
   - receives the **same self-sufficient prompt** as the manual path (see "Implementer prompt template" — repo root, CLAUDE.md, tech stack skill path, the single batch object, spec excerpt, full `change_manifest`, `out_of_scope`, and prior-batch summaries),
   - passes the batch-result JSON schema as the `schema` option so the runtime validates structured output and retries on mismatch (this replaces the manual JSON-parse-failure retry),
   - sets `model` to the chosen tier and a `label` of `batch:<id>`.
   Dependent batches run in a sequential `for…await` loop; independent waves may use `parallel()`. The script returns the array of structured batch results, in batch order.
4. **Run it via the `Workflow` tool.** The native runtime shows its own plan-approval gate (the planned phases + Yes / View raw script / No). Because MTK Phase 2.5 has **already** approved the spec and scope, this gate is a transparency checkpoint, not a re-litigation: in interactive mode let the engineer see/approve the script; in autonomous mode (Phase 2.5 returned `Approve & run until done`) proceed without re-prompting, governed by the session permission mode. Do not author a second scope question here.
5. **On return, run the orchestrator-side gates per batch, in order** — these did NOT run inside the workflow:
   - **Build/test gate.** Inspect each result's `build.ok` / `tests.ok`. Any `false` (after the runtime's own retries) → halt and report, exactly as the manual path. A failing batch poisons later ones.
   - **Drift micro-check.** `actual_files ⊆ batch.files`? public contracts touched ⊆ planned? Clean → persist. Auto-fixable (in-package, no new contract, security unchanged) → amend sidecar. Otherwise → re-open Phase 2.5. The subagent is too close to its own diff; drift is judged here, never inside the workflow.
   - **Persist.** Append `{batch_id, actual_files, build, tests, behavioral_diff, deviations}` to `sidecar.implement.completed_batches[]`; tick `tasks/todo.md`; record progress on the workflow artifact (`scripts/workflow-artifact.sh set "$MTK_WF_UUID" results.batches_completed=<n>`).
   - **Cumulative churn check.** Same 300/500-line thresholds as the manual path.
6. **After all batches:** write the aggregated `behavioral_diff`, emit `phase_exit_gate pass` (or `fail` and stop), and hand back to `implement/SKILL.md` Phase 3.5 → Phase 4. **Unchanged.**

If the `Workflow` tool errors, is denied, or is unavailable mid-run, fall back to the manual Agent-loop path for the remaining batches — do not abandon the per-batch discipline.

### Implementer prompt template

The implementer subagent has no MTK context other than what you give it. The prompt must be self-sufficient. **This template is shared by both execution paths** — in the manual path you pass it as the `Agent` prompt; in the dynamic-workflow path it is the `agent()` prompt string in the generated script.

```
You are implementing one batch of a planned feature.

Repo root: <absolute path>
Read first (in this order):
  - CLAUDE.md
  - .claude/skills/tech-stack-<stack>/SKILL.md (build/test commands, ORM/framework patterns, reference files)
  - The coding guidelines listed in that tech stack's "## Reference Files" section

This batch:
<paste batch object: id, files, acceptance, verification, boundary, depends>

Spec context for this batch:
<paste relevant spec sections>

Whole-feature change_manifest (your hard boundary — do NOT touch files outside this list without
returning a "deviation" entry; do NOT add new public contracts not listed):
<paste change_manifest>

Out of scope (must not be touched):
<paste out_of_scope>

Prior batches already completed (you can rely on these existing; do NOT re-edit them):
<paste prior actual_files + behavioral_diff summaries>

Rules:
1. Read before editing. Match local patterns.
2. Stay within batch.files. If you discover an unavoidable extra file, edit it but record it
   as a `deviation` in your final JSON.
3. Add or update tests in this same batch — never defer to a later batch.
4. Run the build command and the relevant test command from the tech stack skill before returning.
5. If build or tests fail, return the error in `build.evidence` / `tests.evidence` with `ok: false`
   and a one-line analysis. Do not loop endlessly.
6. Do NOT spawn further subagents.
7. Do NOT ask the engineer questions — you are an inner subagent, not the orchestrator.

Return EXACTLY one fenced JSON block matching this schema, then stop:

```json
{
  "batch_id": "<id>",
  "actual_files": ["..."],
  "build":  { "ok": true|false, "evidence": "..." },
  "tests":  { "ok": true|false, "evidence": "..." },
  "behavioral_diff": "...",
  "deviations": [ { "kind": "...", "detail": "...", "justification": "..." } ]
}
```
```

## Rules

- One implementer subagent per batch. Never reuse a subagent across batches (the point is context isolation).
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
