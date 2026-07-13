---
name: subagent-dynamic-workflow
description: Dynamic-workflow dispatch — decision graph plus the step-by-step runtime path; read by subagent-implementation when the Workflow tool is available.
globs: [".claude/skills/subagent-implementation/**"]
alwaysApply: false
---

# Dynamic-Workflow Dispatch — Decision Graph & Runtime Path

## Decision Graph

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

## Dynamic-workflow path

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
   - **Build/test/inconclusive gate.** Inspect each result's `status` and `build.ok` / `tests.ok`. `status: inconclusive` (or a result the runtime could not validate against the schema) → respawn once with narrowed scope; a second inconclusive halts and reports. Any `build.ok`/`tests.ok == false` (`status: blocked`, after the runtime's own retries) → halt and report, exactly as the manual path. An inconclusive or failing batch poisons later ones — never count it as pass.
   - **Drift micro-check.** `actual_files ⊆ batch.files`? public contracts touched ⊆ planned? Clean → persist. Auto-fixable (in-package, no new contract, security unchanged) → amend sidecar. Otherwise → re-open Phase 2.5. The subagent is too close to its own diff; drift is judged here, never inside the workflow.
   - **Persist.** Append `{batch_id, actual_files, build, tests, behavioral_diff, deviations}` to `sidecar.implement.completed_batches[]`; tick `tasks/todo.md`; record progress on the workflow artifact (`scripts/workflow-artifact.sh set "$MTK_WF_UUID" results.batches_completed=<n>`).
   - **Cumulative churn check.** Same 300/500-line thresholds as the manual path.
6. **After all batches:** write the aggregated `behavioral_diff`, emit `phase_exit_gate pass` (or `fail` and stop), and hand back to `implement/SKILL.md` Phase 3.5 → Phase 4. **Unchanged.**

If the `Workflow` tool errors, is denied, or is unavailable mid-run, fall back to the manual Agent-loop path for the remaining batches — do not abandon the per-batch discipline.
