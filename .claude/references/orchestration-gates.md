---
description: Four named fail-closed gates the implement workflow must record on the workflow artifact before advancing
globs: ["**/*"]
alwaysApply: false
---

# Orchestration Gates

These four named gates are the only legitimate places where `/mtk implement` is allowed to advance, retry, or stop. Every gate decision is persisted on the workflow artifact (`.mtk/workflows/{uuid}.json` plus an event in `{uuid}.events.jsonl`) via `scripts/workflow-artifact.sh gate`. Gates are **fail-closed** — `pending` means "have not evaluated yet", and only `pass` permits the next phase.

The gate name is the contract. When skills, agents, and hooks reference a gate they MUST use one of the four names below. (A fifth, `skill_precedence_gate`, was dropped: no skill ever recorded it. Old artifacts that still carry the key load fine; the helper no longer creates or accepts it.)

## 1. `plan_trust_gate`

**When evaluated:** Phase 2.5, after `AskUserQuestion` returns the engineer's approval choice.

**Pass:** The engineer chose `Approve & run until done` or `Approve (interactive)`. Spec + plan + todo are all on disk. No open decisions remain unresolved.

**Fail:** Engineer chose `Revise` (record `fail`, return to Phase 1) or the spec/plan/todo trio is incomplete.

**Pending:** Engineer chose `Edit first` or `Show full plan & spec in terminal` — wait, do not advance.

**Skill responsible:** `implement` (calls `spec-driven-development`, `planning-and-task-breakdown`, then evaluates the gate).

## 2. `phase_exit_gate`

**When evaluated:** End of every phase from Phase 3 onward.

**Pass:** All phase exit criteria from `.claude/skills/implement/SKILL.md` are met for the phase. For Phase 3: every batch buildable, every behavior-changing batch has tests, change manifest not exceeded, behavioral diff written. For Phase 4: review verdict captured, all Critical issues resolved.

**Fail:** Any exit criterion is missing OR a downstream verifier (integration verifier, drift detector, reviewer) returned a Critical/Block finding. Triggers remediation loop, not workflow abort.

**Frozen-criteria tamper check.** Before `verification-before-completion` marks a criterion `verified`, it confirms the frozen `success_criteria[]` definitions (`id`, `observable`, `evidence_channel`) have not changed since Phase 2.5 approval. A criteria edit made to force a pass is an unapproved goalpost move — re-open Phase 2.5, and if it slipped in to manufacture a pass, trip `failure_stop_gate`.

**Pending:** Phase still in progress.

**Skill responsible:** `incremental-implementation`, `subagent-implementation`, `implement-review-lanes.md` (review), `spec-drift-detection` — each owns the gate at its own phase boundary.

## 3. `failure_stop_gate`

**When evaluated:** Whenever an unrecoverable failure occurs — the remediation circuit-breaker trips (see below), scope expansion beyond the change manifest that the engineer has not approved, missing harness tooling, irreproducible test failures, or any safety violation (secret about to be committed, deletion of an unrelated file).

**Remediation circuit-breaker.** Track each fix loop with `scripts/workflow-artifact.sh remediation <uuid> <trigger> [--score N]`. It increments `results.remediation.<trigger>.iterations` and prints `ESCALATE` when either condition holds, else `CONTINUE`:
- **Iteration cap:** iterations reach `MTK_MAX_REMEDIATION_ITERS` (default 3) on the same trigger.
- **Plateau:** the latest `--score` did not improve on the previous one (`score[-1] <= score[-2]`) — automated remediation has stopped converging, even before the cap.

On `ESCALATE`, stop the loop, record `failure_stop_gate fail`, and hand the trigger + iteration count + remaining findings to a human. The subcommand emits a `remediation_escalated` event for the audit trail.

**Pass:** Not used — this gate is never `pass`. It is recorded only when it `fail`s.

**Fail:** Workflow terminates immediately. Set `status=failed`, emit `workflow_failed` with a reason, do not emit further events. The engineer must take over.

**Pending:** Default state when no failure has been detected.

**Skill responsible:** Any phase. The gate must be tripped by whichever skill detected the unrecoverable condition.

## 4. `memory_sync_gate`

**When evaluated:** End of Phase 7, after lessons capture and CLAUDE.md drift check.

**Pass:** Lessons captured to `tasks/lessons.md` (or none were learned and that is honestly reflected). If the workflow modified `tasks/lessons.md`, `CLAUDE.md`, or `.claude/references/architecture-principles.md`, those changes were proposed to the engineer and either accepted or explicitly skipped — not silently merged.

**Fail:** Lessons that should have been captured were dropped, or stable patterns were silently merged into protected files without engineer awareness.

**Pending:** Phase 7 not yet reached.

**Skill responsible:** `implement` (Phase 7), with input from the `lessons` skill (`capture` and `promote` modes).

## How to record a gate

```bash
# A gate decision rides in the same shell call as the command that decided it:
dotnet test --nologo -v q && "$WFA" gate "$MTK_WF_UUID" phase_exit_gate pass --reason "batch 2 green"
dotnet test --nologo -v q || "$WFA" gate "$MTK_WF_UUID" phase_exit_gate fail --reason "build red on batch 2"
# Several writes at once — one invocation, ops separated by a bare `--`:
"$WFA" batch "$MTK_WF_UUID" gate plan_trust_gate pass --reason "approve & run until done" -- seal
"$WFA" gate "$MTK_WF_UUID" failure_stop_gate fail --reason "3rd remediation iteration on same flake"
```

The helper writes the new value to `gates.{name}` in `{uuid}.json` AND appends a `gate_decided` event to the log. Reading either surface alone is incomplete — auditors should reconcile both. A gate write never gets its own model turn: append it to the deciding command or group it with `batch` (see `workflow-artifacts/SKILL.md` step 2).

## Skipping is a hard rule violation

Advancing a phase without recording the corresponding gate is treated the same as advancing on `fail`. The validator and reviewers may treat a missing gate event as drift. If you genuinely have no information to evaluate, leave the gate `pending` and stop — do not invent `pass`.

## Interaction with `MTK_AUTO_PROCEED`

When `MTK_AUTO_PROCEED=1` is set in `.claude/settings.local.json` `env`, the orchestrator MAY default the recommended option on `plan_trust_gate` only when every precondition in the canonical list holds: `.claude/references/implement-approval-gate.md` → `MTK_AUTO_PROCEED` opt-in. That list is the single source; `scripts/run-fixtures.sh` evaluates it against the `auto-proceed-*` fixtures and fails if the list and its evaluator drift apart.

Auto-proceed never overrides explicit user standards, open plan decisions, or `failure_stop_gate`. When applied, the orchestrator records the bypass via a `gate_decided` event with `reason: "AUTO_PROCEED — all preconditions met"` so audit can replay the decision.

## Cross-references

- Schema: `.claude/references/workflow-artifact-schema.md`
- Helper: `scripts/workflow-artifact.sh`
- Skill: `.claude/skills/workflow-artifacts/SKILL.md`
- Phase definitions: `.claude/skills/implement/SKILL.md`
