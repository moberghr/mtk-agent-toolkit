---
name: subagent-implementation
description: Use instead of incremental-implementation for 3+ batches, 6+ non-mechanical files, or non-none security_impact — one fresh implementer subagent per batch with orchestrator drift checks.
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

- **Inline-MAX path (when dispatch is forbidden or unavailable).** Neither of the two paths above can run if the harness exposes no subagent tools, or if a standing instruction forbids subagents the engineer did not ask for. That is a property of the session, and `implement`'s Phase 2.9 probe records it as `dispatch_capability=forbidden|unavailable` **before** Phase 3 promises a path. In that case run the batches inline under the **inline-MAX profile** (`implement/SKILL.md` Phase 2.9): the same per-batch order, the same sealed manifest, the same drift micro-check and churn check — with C1-C3 replacing what dispatch would have bought. Two rules make it a substitute rather than an excuse:
  - **Say it before the first batch, not in the report afterwards.** Record `results.phase3_path="inline-MAX (<reason>; C1-C3 applied)"`.
  - **Do not lower the rigor level to fit the path.** The level reflects the change's blast radius; the path reflects the session's tooling. Recomputing MAX down to STANDARD because dispatch is unavailable is a scope reduction that never happened.

  If this is the *second* run in the same repo to take this path for the same reason, Phase 7's repeat-reduction rule applies: propose `MTK_SUBAGENT_DISPATCH=0` (or a lesson naming the constraint) instead of recording the same reduction again.

Pick the path once, at the top of Phase 3, based on tool availability **and** the Phase 2.9 dispatch probe. Do not mix them within one feature.

When the `Workflow` tool is available, take the dynamic-workflow path: read `.claude/references/subagent-dynamic-workflow.md` now and follow it. The manual Agent-loop path below is for sessions where `Workflow` is not exposed.

### Steps (manual Agent-loop path)

1. **Threshold gate.** Read `docs/specs/<date>-<slug>.json`. Dispatch when any hard trigger is met **or** the rigor score is ≥ 8 (rigor HIGH/MAX). If neither holds → return control to `implement/SKILL.md` Phase 3 with the recommendation to use `incremental-implementation` instead. Do not silently fall through.
2. **Pick implementer model.** The policy default is **Sonnet** — see `.claude/references/model-routing.md` (reserve Opus for batches the plan flags novel/tricky: concurrency, unfamiliar SDK, subtle invariants). Whether to *ask* depends on the Phase 2.5 mode:
   - **Autonomous mode (Phase 2.5 returned `Approve & run until done`): do NOT ask.** An `AskUserQuestion` here would violate the autonomous "never call `AskUserQuestion` in Phases 3-7" rule (`implement/SKILL.md`) — the two rules only appear to conflict; the model ask is an interactive affordance, and autonomous mode resolves it by *not asking*. Default to the policy tier (Sonnet), escalate to Opus only for batches the plan flags novel/tricky, and emit one line: `Implementer model: Sonnet (autonomous default; Opus for plan-flagged novel/tricky batches).`
   - **Interactive mode: invoke `AskUserQuestion` once** (load via `ToolSearch select:AskUserQuestion` if deferred):
     - Question: `Implementer subagent model? Affects per-batch cost and capability.`
     - Options:
       - `Sonnet (policy default — faster, cheaper, suits straightforward batches)`
       - `Opus (more capable — pick when the batch involves novel logic, tricky concurrency, or unfamiliar framework behavior)`
     - Persist the choice in memory for the rest of the loop. Do **not** ask again between batches. If the harness does not expose `AskUserQuestion`, default to Sonnet and emit one line: `Implementer model defaulted to Sonnet (AskUserQuestion unavailable).`
3. **For each batch in dependency order:**

   **Mechanical batch → inline (skip dispatch).** Before building a bundle, check the batch: if *every* entry in it is mechanical (rename-only, formatting-only, generated, no-behavioral-change — the `implement/SKILL.md` Rigor Score definition; an entry touching any public contract is never mechanical), do **not** dispatch a fresh implementer. Implement it inline in the orchestrator context — with no logic or contract to isolate, a fresh subagent buys nothing but latency. Still apply the drift micro-check (sub-step 5), result persistence (6), and churn check (7) for that batch; skip only the dispatch (sub-steps 1–4). Non-mechanical batches take the full dispatch path below. This keeps a stray config/rename batch inside an otherwise-HIGH run from paying subagent ceremony it cannot use.

   1. **Build the context bundle.** Concatenate:
      - Spec sections relevant to this batch (`Summary`, `Architecture and design`, `Security and compliance impact` if non-none)
      - The single batch object from `plan.batches[]` (id, files, acceptance, verification, boundary, depends)
      - **Prior-batch summary:** for every batch already in `sidecar.implement.completed_batches`, include `{id, actual_files, behavioral_diff}`. Do NOT include full prior diffs — just the summary. Emit it as a dense block (one batch per line: `id | n files | behavioral_diff`) and prefix it with the completed-batch count, e.g. `prior-batches: 3` — the implementer can checksum line count against that number and flag a truncated handoff rather than building on a silently-cut summary.
      - The path of the run's **context pack** (`results.context_pack`, built in `implement` Phase 2 by `scripts/build-context-pack.sh`). It carries the build/test/format commands, CLAUDE.md critical rules, the manifest-selected coding-guideline sections, `[EXTRACTED]` principles, and matching lessons — the subagent reads it **instead of** CLAUDE.md, the tech-stack skill, and the guideline files. Do not paste the pack body; pass the path. If the manifest was amended since the pack was built, rebuild it first.
      - The full `change_manifest` and `out_of_scope` arrays — the subagent must know its boundary.
   2. **Dispatch the implementer subagent** via `Agent` tool with:
      - `subagent_type: general-purpose` (no MTK-specific implementer subagent type — keep tool surface generic)
      - `model: <chosen>` (Sonnet or Opus from step 2)
      - `description: Batch <id> — <one-line intent>`
      - `prompt`: see "Implementer prompt template" below
      Emit `agent_dispatched` on the workflow artifact in the same shell call as any pre-dispatch command, and `agent_returned` in the same call as the post-return build check (`<build cmd> && "$WFA" batch "$MTK_WF_UUID" event agent_returned --data '{"agent":"batch:<id>"}' -- set results.batches_completed=<n>`) — these two timestamps are the only record of per-batch active time and of what a kill cost; the receipt derives its timing section from them and writes `not recorded` wherever they are missing. Bookkeeping never gets its own turn.
      **Waves.** Batches whose `depends` arrays put them at the same topological level are dispatched together — one message, one `Agent` call per batch, at most `MTK_BATCH_WAVE_MAX` (default 3) at a time — and the next wave starts only after every result in the current one has passed the gate below. The plan guarantees that same-wave batches share no file.
   3. **Parse the structured result.** The implementer must return one fenced JSON block with `batch_id, status(completed|blocked|inconclusive), actual_files, build{ok,evidence}, tests{ok,evidence}, behavioral_diff, deviations[]` (`usage` optional). Inconclusive is never a pass. See `.claude/references/subagent-implementer-prompt.md` for the canonical schema and semantics.
   4. **Build/test/inconclusive gate.**
      - `status == inconclusive` (or unparseable / ack-only): respawn **once**
        with the scope narrowed to the missing deliverable and an explicit
        "return the JSON result exactly per schema; partial work is not done"
        reminder. If it comes back `inconclusive` again → halt and report to the
        engineer. Inconclusive is never silently upgraded to pass.
      - `build.ok == false` or `tests.ok == false` (`status: blocked`): up to 2
        retries with the failure output appended to the prompt.
      - **Killed mid-batch** (the dispatch was terminated from outside — org
        spend or rate limit, model unavailable, harness kill, timeout — so there
        is *no result at all*, not a malformed one): this is **not**
        `inconclusive`, because the implementer's partial work is already on
        disk and the narrowed-scope respawn would either redo it or build a
        second copy beside it. Follow the **killed-mid-batch recovery** below.
      - On exhaustion, halt and report to engineer (also in autonomous mode — the
        gate is structural, not interactive).

      **Killed-mid-batch recovery** (one attempt, then halt):
      1. **Inventory the partial state.** `git status --porcelain` and
         `git diff --stat` — list the files the dead implementer touched. Any
         touched file outside `batch.files` is drift and goes through sub-step 5
         like any other extra file; do not delete it.
      2. **Build the partial state** with the tech stack's build command.
         - **Compiles** → respawn one implementer whose bundle adds the partial
           diff summary (files + one line each, not the diff) and an explicit
           `RESUME: the files listed are your own earlier partial work; finish
           the batch from that state, do not re-implement or duplicate it`.
         - **Does not compile** → revert only the batch's own files
           (`git checkout -- <batch.files that changed>`; never anything
           outside `batch.files`, never an untracked file — leave those for the
           drift check) and respawn from clean, with the original bundle.
      3. **Tier fallback.** If the kill was the tier being unavailable (spend
         limit, rate limit, model error) rather than a generic crash, respawn on
         the `default` slot (Sonnet) and **keep that tier for every remaining
         batch** — this is not a second model ask, it is the policy's fallback
         rule (`.claude/references/model-routing.md` → *Tier fallback*). Do not
         retry the unavailable tier hoping the limit lifted. If `default` is also
         unavailable, halt: implementer code never drops to `fast`.
      4. **Record the incident before dispatching the replacement**, so a
         second kill cannot erase the first: append
         `{batch_id, kind:"killed", reason, from_model, to_model,
         partial_compiled, ts_killed, ts_respawned}` to
         `results.dispatch_incidents[]` on the workflow artifact
         (`"$WFA" set … ` — schema in
         `.claude/references/workflow-artifact-schema.md`) and emit
         `agent_returned` with `verdict: killed`. The receipt's *time lost*
         figure is computed from these two timestamps; an unrecorded kill is
         time the run can never account for.
      5. A **second kill on the same batch** halts the loop and reports —
         two external kills mean the environment, not the batch, is the problem.
   5. **Drift micro-check (orchestrator-side, no agent call).**
      - `extra_files = actual_files - batch.files`
      - `missing_files = batch.files - actual_files` (excluding files explicitly deferred by the spec)
      - `public_contract_touched`: if any `actual_files` matches a path in `change_manifest` whose entry has a `public_contracts` linkage, confirm the contract change matches the planned one.
      - **Clean** → proceed to step 6.
      - **Drifted, auto-fixable** (extra file is in-package, no new public contract, security_impact unchanged) → orchestrator amends the sidecar `change_manifest` with the new file and a `deviations` note. Continue.
      - **Drifted, not auto-fixable** (cross-package leak, new public contract, security_impact escalated, or `out_of_scope` violated) → re-open Phase 2.5 approval gate. Halt the loop until the engineer answers.
   6. **Persist the batch result.**
      - Append `{batch_id, actual_files, build, tests, behavioral_diff, deviations, implementer_model}` to `sidecar.implement.completed_batches[]` — `implementer_model` is the tier that produced the *accepted* result (after any fallback), so a later reader can see which batches ran on which tier without replaying the event log.
      - Run `bash scripts/validate-handoff.sh docs/specs/<date>-<slug>.json` (if available) to surface schema drift early.
      - Tick the batch row in `tasks/todo.md`.
   7. **Cumulative churn check.** After every batch, run `git diff --stat <base>...HEAD` and count net **non-generated** lines since the last review (same exclusion list as `incremental-implementation` step 9). This path always runs at rigor HIGH/MAX, so the thresholds are the doubled defaults: ≥ `MTK_CHURN_REVIEW_LINES` (**600** here) without an intermediate review → trigger an early `pre-commit-review-list` pass; ≥ `MTK_CHURN_HALT_LINES` (**1000** here) without a review → halt and run `compliance-reviewer` before continuing, then reset the count. A field run with the flat 500-line rule ran four mid-loop compliance reviews before the two-stage review — each found real items, but review time roughly doubled for a run whose batches were already isolated and drift-checked.
4. **After all batches:**
   - Write a final aggregated `behavioral_diff` to `sidecar.implement.behavioral_diff`.
   - Hand control back to `implement/SKILL.md` Phase 3.5 (whole-feature spec-drift) → Phase 4 (two-stage review). Both run unchanged. Per-batch micro-checks are supplemental, not a replacement.

### Dynamic-workflow path

Steps 1-6 of the dynamic-workflow path and the "If the `Workflow` tool errors…" fallback rule live in `.claude/references/subagent-dynamic-workflow.md` (resolve under `$CLAUDE_PLUGIN_ROOT` when set). Read it now and follow it when the `Workflow` tool is available.

The **mechanical exception** applies here too: the orchestrator implements all-mechanical batches inline *before* generating the workflow, and the generated script covers only the non-mechanical batches (one `agent()` call each). Do not spawn an `agent()` for a batch that changes no logic and no contract.

### Dispatch hardening (large prompts & args)

Large doc/code batches produce large context bundles, and the dynamic-workflow path has historically been fragile when those bundles are passed the wrong way — an unbound-`args` crash, or the runtime stalling on a multi-kilobyte prompt shoved through a single argument. Three rules make dispatch robust regardless of batch size:

1. **Never pass a large prompt block as a positional/CLI argument.** The implementer prompt and context bundle can be tens of KB. Write the assembled bundle to a file under `.mtk/workflows/<uuid>/batch-<id>.prompt.md` and pass the **path** (the `agent()` prompt string reads it, or the manual `Agent` prompt references it). A prompt block in `argv` is what triggers the arg-length / stall failures.
2. **Bind `args` as actual JSON, never a stringified blob.** When the generated workflow script reads `args`, pass it as a real JSON value in the `Workflow` call (`args: { batch: {...} }`), not a JSON-encoded string. A stringified list reaches the script as one string, so `args.batches.map(...)` throws — the "args-unbound" crash from the v7.14 dogfooding run. If the script needs no input, do not reference `args` at all.
3. **Compress before you hand off.** Run the prior-batch summary and any pasted command output through `scripts/mtk-compress.sh` (see `.claude/references/output-compression.md`) before it enters the bundle — dense handoffs keep each batch's dispatch inside a safe size envelope.

These are dispatch-mechanism rules only; the prompt *contract* (TASK/DELIVERABLE/SCOPE/VERIFY) and the orchestrator-side gates are unchanged.

### Implementer prompt template

The implementer prompt template is shared by both execution paths and is organized under the four contract headers TASK / DELIVERABLE / SCOPE / VERIFY. Read `.claude/references/subagent-implementer-prompt.md` before building the first context bundle — do not paraphrase it from memory.

## Rules

- One implementer subagent per batch. Never reuse a subagent across batches (the point is context isolation). **Exception: an all-mechanical batch is implemented inline with no subagent** — see the per-batch loop; there is no reasoning to isolate.
- **Guardrails travel with the capability.** The implementer prompt states each granted tool's boundary and a no-delete fence inline (Rules 6–7), so a dispatched subagent inherits its constraints from the prompt rather than a rules file it may not load. Keep those clauses when editing the template.
- **Inconclusive is never a pass.** A batch whose result is missing, unparseable, acknowledgment-only, or marked `inconclusive` is recorded as `inconclusive` in the sidecar and respawned **once** with the scope narrowed to the missing deliverable. A second inconclusive halts the loop and reports to the engineer. Never count an inconclusive batch toward completion, and never let a later batch build on one.
- **Killed is not inconclusive.** `inconclusive` means the implementer *returned* without evidence; *killed* means it never returned because the dispatch was terminated from outside (spend/rate limit, model unavailable, harness kill). The two recover differently: inconclusive narrows scope and respawns from the current state; killed inventories the partial work on disk, builds it, and respawns to **finish** (or reverts the batch's own files and restarts) — with the tier dropped to `default` if the kill was tier unavailability. One recovery attempt per batch; a second kill halts. Every kill is recorded in `results.dispatch_incidents[]` **before** the replacement is dispatched.
- **Tier fallback is not a model re-ask.** When the chosen tier becomes unavailable mid-loop, drop to `default` for the rest of the loop without an `AskUserQuestion`, record the switch on the artifact, and name it in the final report. Implementer code never falls back to `fast`.
- Orchestrator never edits source **for a dispatched (non-mechanical) batch** — those edits happen inside the batch's subagent. The one carve-out is an **all-mechanical batch, which the orchestrator implements inline** (renames/formatting/generated edits carry no reasoning to contaminate later batches). Otherwise, if editing is needed (e.g. to amend the sidecar after auto-fix), only `docs/specs/*.json`, `tasks/todo.md`, and the sidecar are fair game.
- The model selection is asked **once**, before the loop, and never per batch — **in interactive mode only.** In autonomous mode it is not asked at all; the Sonnet policy default applies (Opus for plan-flagged novel/tricky batches). See step 2.
- In autonomous mode (Phase 2.5 returned `Approve & run until done`), the loop runs without further `AskUserQuestion` calls **except** the Phase 2.5 re-open required by non-auto-fixable drift. That re-open is a structural halt, not a chatty confirmation.
- Drift micro-check is orchestrator-side and synchronous. No agent call per batch.
- Phase 4 review (compliance, test, architecture, silent-failure-hunter) runs unchanged after the loop — sized from the **current** rigor level, which may have been recomputed lower if scope was reduced mid-loop (see next rule).
- **Mid-loop scope reduction re-scores rigor.** If the approved batch set shrinks during the loop (a batch is deferred, dropped, or split to a follow-up), recompute the rigor level from the remaining batches (see `implement/SKILL.md` Rigor Score → *Recompute on scope reduction*) and record the transition on the workflow artifact. Batches already dispatched are unaffected; if the recomputed level drops below HIGH, remaining not-yet-started batches return to `implement` Phase 3 for the inline path.
- **Dynamic-workflow path:** the workflow replaces only the inner dispatch loop. Drift micro-check, sidecar persistence, churn check, and Phase 4 are orchestrator-side and run **after** the workflow returns — never inside it. The native runtime's plan-approval gate does not replace MTK's Phase 2.5; it is a transparency checkpoint on an already-approved scope.
- **Waves come from `depends`, and only from `depends`.** Batches at the same topological level run concurrently (width ≤ `MTK_BATCH_WAVE_MAX`, default 3); different levels run strictly in order. A later batch reading an earlier batch's files must carry an edge — if it does not, the plan is wrong: fix the edge, do not hand-serialize.

## Common Rationalizations

See `.claude/references/workflow-rationalizations.md` for the shared table. Subagent-implementation-specific traps:

| Rationalization | Reality |
|---|---|
| "I'll just edit it myself, faster than dispatching" | That defeats the entire point. Context contamination is the cost you pay invisibly. Dispatch. |
| "The implementer got killed by the rate limit — treat it as inconclusive and respawn with narrowed scope" | No. Its partial work is on disk; a narrowed respawn either redoes it or builds a second copy beside it. Inventory, build, and respawn to *finish* from the partial state (or revert the batch's own files and restart) on the fallback tier. Record the kill first. |
| "These two batches touch the same file but the edits don't overlap, they can share a wave" | No. Two implementers writing one file race on the Edit tool's read-before-write check; one of them stalls or clobbers. Same file ⇒ edge, always. |

Full table: `.claude/references/workflow-rationalizations.md` → subagent-implementation.

## Red Flags

- Orchestrator using `Edit` or `Write` on source files
- Two batches in one wave whose `files` overlap (the plan is missing an edge)
- A killed implementer handled as `inconclusive` (narrowed-scope respawn over partial work already on disk), or respawned on the same unavailable tier

Full table: `.claude/references/workflow-rationalizations.md` → subagent-implementation.

## Verification

- [ ] Threshold check ran and produced a documented yes/no
- [ ] Execution path chosen once (dynamic-workflow when `Workflow` tool available, else manual Agent-loop) and not mixed mid-feature
- [ ] Implementer model was asked once via `AskUserQuestion` (or defaulted with explicit notice)
- [ ] One fresh subagent dispatched per batch (no reuse) — or one `agent()` call per batch in the generated script
- [ ] Each batch returned a structured JSON result matching the schema (validated by the runtime on the workflow path)
- [ ] Waves were derived from `depends`; no same-wave batches shared a file; wave width never exceeded `MTK_BATCH_WAVE_MAX`
- [ ] Drift micro-check ran orchestrator-side for every batch (also on the workflow path, after it returned), with auto-fix or 2.5 re-open as appropriate
- [ ] `sidecar.implement.completed_batches[]` reflects every batch with actual_files, behavioral_diff, and `implementer_model`
- [ ] Every killed dispatch is in `results.dispatch_incidents[]` with both timestamps, and any tier fallback was applied to all remaining batches
- [ ] `tasks/todo.md` ticks match completed batches
- [ ] Phase 4 review still runs unchanged after the loop
- [ ] Cumulative churn thresholds (600/1000 non-generated lines at HIGH/MAX, or `MTK_CHURN_*` overrides) honored
