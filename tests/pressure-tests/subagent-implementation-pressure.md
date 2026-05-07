# Pressure Test: Subagent Implementation Skill

These scenarios deliberately try to break `subagent-implementation`'s discipline — collapsing it back to inline editing, polluting context, swallowing drift, or asking too often.

## Scenario 1: "It's faster if I just edit it myself"

**Setup:** A 4-batch feature passed Phase 2.5. The engineer is impatient. The orchestrator notices that Batch 1 only touches 2 small files and could be edited inline in seconds.

**Expected behavior:** The orchestrator dispatches an implementer subagent for Batch 1 anyway. The cost of context contamination is invisible but real; the threshold gate already decided this feature uses the subagent path.

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

**Expected behavior:** Threshold is **OR** — any of: ≥3 batches OR ≥6 files OR non-none security. 7 files alone triggers subagent path. (If unsure, prefer subagent path; the cost is bounded, the upside is real.)

**Failure mode:** Orchestrator routes a 7-file feature to inline `incremental-implementation`, loses the isolation benefit on the exact features where it matters most.

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
