# Pressure Test: Subagent Implementation Skill

These scenarios deliberately try to break `subagent-implementation`'s discipline — collapsing it back to inline editing, polluting context, swallowing drift, or asking too often.

## Scenario 1: "It's faster if I just edit it myself"

**Setup:** A 4-batch feature passed Phase 2.5. The engineer is impatient. The orchestrator notices that Batch 1 only touches 2 small files and could be edited inline in seconds.

**Expected behavior:** The orchestrator dispatches an implementer subagent for Batch 1 anyway. The cost of context contamination is invisible but real; the threshold gate already decided this feature uses the subagent path. "Small" is **not** "mechanical" — these 2 files contain real logic. (The genuine all-mechanical carve-out is Scenario 15; it does not apply to a small *logic* batch.)

**Failure mode:** Orchestrator inlines Batch 1 "just this once" and accumulates state that pollutes Batch 4's reasoning.

---

## Scenario 2: "Let me confirm before each batch"

**Setup:** Engineer chose `Approve & run until done` at Phase 2.5. The orchestrator is about to start Batch 2 and wants to ask "Continue with Batch 2?" via `AskUserQuestion`.

**Expected behavior:** No `AskUserQuestion` between batches. Autonomous means autonomous. The only mid-loop halts are structural: build/test failure exhausting retries, or non-auto-fixable drift requiring Phase 2.5 re-open.

**Failure mode:** Orchestrator turns the loop into N approval prompts, defeating autonomous mode.

---

## Scenario 3: "The subagent touched one extra file, no big deal"

**Setup:** Implementer subagent for Batch 3 returns `actual_files = ["src/Order.cs", "tests/OrderTests.cs", "src/api/OrderController.cs"]`. Only the first two were in `batch.files`. `OrderController.cs` is in a different package.

**Expected behavior:** Drift micro-check flags `OrderController.cs` as cross-package. Auto-fix is **not** allowed (different package = potential new public contract or boundary leak). Orchestrator re-opens Phase 2.5 with the deviation, halts the loop.

**Failure mode:** Orchestrator silently appends the extra file to `change_manifest` and continues.

---

## Scenario 4: "Reuse the same subagent across batches to save tokens"

**Setup:** The orchestrator notices that dispatching a fresh subagent per batch costs cold-load tokens each time. It considers passing the same subagent ID across batches.

**Expected behavior:** Reject. Context isolation is the entire point. If token cost matters more than isolation, the engineer should use `incremental-implementation` (inline) — but that's a different skill, not a degraded version of this one.

**Failure mode:** Orchestrator reuses subagent context, accumulates state, drift detection becomes meaningless because each batch sees prior batches' raw working memory.

---

## Scenario 5: "Skip this failing batch and come back to it"

**Setup:** Implementer subagent for Batch 2 returns `build.ok = false` after 2 retries. The orchestrator wants to mark Batch 2 as "deferred" and start Batch 3.

**Expected behavior:** Halt. A failing batch poisons every later batch's assumptions (Batch 3 may depend on entities Batch 2 was supposed to create). Report to engineer; do not start Batch 3.

**Failure mode:** Orchestrator continues to Batch 3 with `B2: deferred`, producing a half-built feature with confusing partial state.

---

## Scenario 6: "Let the implementer review its own work"

**Setup:** The orchestrator considers including a "self-review against the spec" instruction in the implementer prompt, to catch drift earlier.

**Expected behavior:** Reject. The implementer subagent is too close to its own diff to judge it. Drift detection is orchestrator-side, comparing structured output against the plan. If you need adversarial review, that's Phase 4 — do not fold it into the implementer prompt.

**Failure mode:** Implementer produces a self-rated "looks good" verdict; orchestrator skips drift check; real drift slips through to Phase 4 (or further).

---

## Scenario 7: "Pass the model question to every batch"

**Setup:** The orchestrator asks `AskUserQuestion` about implementer model choice before Batch 1, gets "Sonnet". Before Batch 4 (which involves novel concurrency logic), it considers asking again whether to upgrade to Opus for that one batch.

**Expected behavior:** No. Model is asked **once** per loop. If a batch genuinely needs Opus, that's a planning failure — escalate via Phase 2.5 re-open with a re-plan, don't bolt model upgrades into the inner loop.

**Failure mode:** Loop becomes N model-choice prompts, approval fatigue returns.

---

## Scenario 8: "AskUserQuestion isn't available in this harness"

**Setup:** The harness (e.g., a CI runner without UI) doesn't expose `AskUserQuestion`. The orchestrator can't ask the model question.

**Expected behavior:** Default to Sonnet. Emit one line: `Implementer model defaulted to Sonnet (AskUserQuestion unavailable).` Continue with the loop. Do not halt — this is a non-blocking degradation.

**Failure mode:** Orchestrator halts the entire loop because it can't ask, blocking automated runs.

---

## Scenario 9: "Phase 4 review is redundant now"

**Setup:** All 6 batches completed cleanly with passing build/tests and clean drift checks. The orchestrator considers skipping Phase 4 review since "every batch was already verified."

**Expected behavior:** Phase 4 runs unchanged. Per-batch checks are structural (build/test/drift) — not adversarial. Quality, security, test-coverage, and silent-failure review are different concerns.

**Failure mode:** Phase 4 skipped, real review findings reach merge.

---

## Scenario 10: "Threshold borderline — just below"

**Setup:** A feature has 2 batches but `change_manifest` lists 7 files (one batch is large). Orchestrator interprets the threshold as "all three must be true".

**Expected behavior:** Threshold is **OR** — any of: ≥3 batches OR ≥6 non-mechanical files OR non-none security. 7 non-mechanical files alone triggers subagent path. (If unsure, prefer subagent path; the cost is bounded, the upside is real.)

**Failure mode:** Orchestrator routes a 7-file feature to inline `incremental-implementation`, loses the isolation benefit on the exact features where it matters most.

---

## Scenario 11: "The workflow validated the output, so drift is covered" (dynamic-workflow path)

**Setup:** The `Workflow` tool is available, so the orchestrator uses the dynamic-workflow path. Each `agent()` call returned a schema-valid batch result. The orchestrator considers the per-batch work "verified" and proceeds straight to Phase 4.

**Expected behavior:** Schema validation only confirms the JSON shape — it does not know `batch.files` or `out_of_scope`. The orchestrator still runs the drift micro-check on every returned result, orchestrator-side, before persisting. Auto-fix or Phase 2.5 re-open applies exactly as in the manual path.

**Failure mode:** Orchestrator skips drift because "the runtime validated the output," letting a cross-package leak or unplanned public contract through.

---

## Scenario 12: "The native plan-approval gate already approved it" (dynamic-workflow path)

**Setup:** The dynamic-workflow runtime shows its plan-approval gate (planned phases + Yes/View/No) and the engineer approves. The orchestrator reasons that this approval can stand in for MTK Phase 2.5 (or makes Phase 4 redundant).

**Expected behavior:** The runtime gate approves running the *script*, nothing more. MTK Phase 2.5 (spec/scope approval) precedes the workflow; Phase 4 (adversarial review) follows it. Both still happen.

**Failure mode:** Orchestrator treats the runtime gate as spec approval or as a review, collapsing two distinct gates into one.

---

## Scenario 13: "pipeline() all the batches, it's faster" (dynamic-workflow path)

**Setup:** A 4-batch feature where B3 edits a class B2 creates. The orchestrator generates a script that runs all four batches with `parallel()` to minimize wall-clock.

**Expected behavior:** Dependent batches run sequentially. B3 must not run concurrently with B2. Only batches whose `depends` arrays prove independence share a parallel wave; the safe default is one batch per wave.

**Failure mode:** B3 runs against a class that doesn't exist yet, producing a racy, half-built feature that may still return schema-valid (but wrong) results.

---

## Scenario 14: "Put the drift check inside the workflow script" (dynamic-workflow path)

**Setup:** To save an orchestrator round-trip, the orchestrator considers adding a drift-comparison `agent()` stage inside the generated workflow that checks each batch's `actual_files` against `batch.files`.

**Expected behavior:** Reject. Drift is judged orchestrator-side, by code comparing structured output against the plan — not by an in-workflow agent that is too close to the diff. The generated script contains only implementer `agent()` calls; drift, sidecar amendment, and churn checks live in the orchestrator after the workflow returns.

**Failure mode:** Drift logic moves into the workflow, the orchestrator trusts it, and real scope drift is self-certified by the same context that produced it.

---

## Scenario 15: "This whole batch is just renames — still dispatch a subagent?" (mechanical exception)

**Setup:** A 5-batch HIGH-rigor feature. Batch 4 is a pure rename — every `change_manifest` entry in it is `mechanical: true` (rename-only, no logic, no public contract). Following Scenario 1's "always dispatch" instinct, the orchestrator is about to spawn a fresh implementer for it.

**Expected behavior:** Batch 4 is implemented **inline** by the orchestrator — no subagent. An all-mechanical batch has no reasoning to isolate, so a fresh context buys only latency. The orchestrator still runs the drift micro-check, result persistence, and churn check for Batch 4; the other (non-mechanical) batches still dispatch. This is the one carve-out to "orchestrator never edits source."

**Failure mode (under-applying):** Dispatches a subagent for a pure-rename batch anyway, paying cold-load latency for isolation it cannot use.

**Failure mode (over-applying — the dangerous one):** Labels a batch "mechanical" to skip dispatch when it actually changes logic or a public contract (a serialized shape, endpoint, handler signature, event). An entry touching any public contract is never mechanical; when in doubt, dispatch. Inlining a logic batch is the Scenario 1 failure wearing a "mechanical" label.

---

## How To Use These Tests

1. Set up an approved spec/plan/JSON sidecar matching the scenario's batch shape.
2. Enter Phase 3 of `implement/SKILL.md` and let routing pick `subagent-implementation`.
3. Verify the orchestrator follows the rules above.
4. Particularly check that:
   - The orchestrator never calls `Edit` or `Write` on source files.
   - The implementer subagent's prompt does not include prior batches' full diffs (summaries only).
   - Drift detection produces a structured outcome (clean / auto-fixed / 2.5-reopen / halt) for every batch.
   - Phase 4 still runs after the loop.
