---
name: subagent-dynamic-workflow
description: Opt-in dynamic-workflow dispatch for subagent-implementation — runs the per-batch loop through the Workflow tool; read only when the engineer explicitly opts in.
globs: [".claude/skills/subagent-implementation/**"]
alwaysApply: false
---

# Dynamic-Workflow Dispatch (opt-in)

Only when the engineer explicitly opted in this session **and** the `Workflow` tool is exposed;
the manual Agent-loop in `subagent-implementation` is the default (field runs of this path
failed 5 of 5). The workflow replaces only the dispatch of sub-steps 3.1–3.4. Drift micro-check,
sidecar amendment, churn check and Phase 4 stay orchestrator-side.

1. **Model pick** as in the manual path (no `AskUserQuestion` in autonomous mode); pass it as
   `model` on every `agent()` call.
2. **Waves from `depends`.** Each batch's wave is its topological level; a wave wider than
   `MTK_BATCH_WAVE_MAX` (default 3, `args.waveMax`) is chunked. If an edge looks missing (two
   batches share a file, or one reads a type another creates), fix the plan, not the script.
3. **Script.** Adapt `templates/workflows/subagent-implementation.workflow.js`: one `agent()`
   per batch with the same implementer prompt as the manual path, the batch-result schema as
   `schema`, `label: "batch:<id>"`; waves run in order, a wave's batches via `parallel()`.
4. **Run it with `Workflow`.** Its plan-approval screen is a transparency checkpoint — Phase 2.5
   already approved the scope. In autonomous mode, do not re-prompt.
5. **On return, per batch in order:**
   - Replay `ts_dispatched` / `ts_returned` onto the workflow artifact in one `"$WFA" batch`
     call (`event agent_dispatched|agent_returned --ts … --data '{"agent":"batch:B1","source":"workflow-replay"}'`), before any gate can halt.
   - `inconclusive` or schema-invalid → respawn once with narrowed scope, then halt; build or
     tests red → halt and report. Never count either as pass.
   - `partial` → not a pass: respawn via `RESUME:` + `resume_note`, max 2 per batch, then halt.
   - A killed `agent()` (spend/rate limit, model unavailable) is not `inconclusive`: run the
     manual path's killed-mid-batch recovery, record `results.dispatch_incidents[]` first, and
     re-run only unstarted later waves on the fallback tier.
   - Drift micro-check once per wave (union of `actual_files` ⊆ union of `batch.files`, contracts
     ⊆ planned); attribute any extra file to its batch before deciding amend vs re-open Phase 2.5.
   - Persist to `sidecar.implement.completed_batches[]`, tick `tasks/todo.md`, record progress on
     the same call; run the churn check (600/1000 at HIGH/MAX).
6. Aggregate the `behavioral_diff`, emit `phase_exit_gate`, hand back to Phase 3.5 → 4.

If `Workflow` errors, is denied, or disappears mid-run, finish the remaining batches on the
manual Agent-loop path.
