---
description: Five named fail-closed gates the implement workflow must record on the workflow artifact before advancing
globs: ["**/*"]
alwaysApply: false
---

# Orchestration Gates

These five named gates are the only legitimate places where `/mtk implement` is allowed to advance, retry, or stop. Every gate decision is persisted on the workflow artifact (`.mtk/workflows/{uuid}.json` plus an event in `{uuid}.events.jsonl`) via `scripts/workflow-artifact.sh gate`. Gates are **fail-closed** — `pending` means "have not evaluated yet", and only `pass` permits the next phase.

The gate name is the contract. When skills, agents, and hooks reference a gate they MUST use one of the five names below.

## 1. `plan_trust_gate`

**When evaluated:** Phase 2.5, after `AskUserQuestion` returns the engineer's approval choice.

**Pass:** The engineer chose `Approve & run until done` or `Approve (interactive)`. Spec + plan + todo are all on disk. No open decisions remain unresolved.

**Fail:** Engineer chose `Revise` (record `fail`, return to Phase 1) or the spec/plan/todo trio is incomplete.

**Pending:** Engineer chose `Edit first` or `Show plan in terminal` — wait, do not advance.

**Skill responsible:** `implement` (calls `spec-driven-development`, `planning-and-task-breakdown`, then evaluates the gate).

## 2. `phase_exit_gate`

**When evaluated:** End of every phase from Phase 3 onward.

**Pass:** All phase exit criteria from `.claude/skills/implement/SKILL.md` are met for the phase. For Phase 3: every batch buildable, every behavior-changing batch has tests, change manifest not exceeded, behavioral diff written. For Phase 4: review verdict captured, all Critical issues resolved.

**Fail:** Any exit criterion is missing OR a downstream verifier (integration verifier, drift detector, reviewer) returned a Critical/Block finding. Triggers remediation loop, not workflow abort.

**Pending:** Phase still in progress.

**Skill responsible:** `incremental-implementation`, `subagent-implementation`, `code-review-and-quality`, `spec-drift-detection` — each owns the gate at its own phase boundary.

## 3. `failure_stop_gate`

**When evaluated:** Whenever an unrecoverable failure occurs — three or more remediation iterations on the same finding, scope expansion beyond the change manifest that the engineer has not approved, missing harness tooling, irreproducible test failures, or any safety violation (secret about to be committed, deletion of an unrelated file).

**Pass:** Not used — this gate is never `pass`. It is recorded only when it `fail`s.

**Fail:** Workflow terminates immediately. Set `status=failed`, emit `workflow_failed` with a reason, do not emit further events. The engineer must take over.

**Pending:** Default state when no failure has been detected.

**Skill responsible:** Any phase. The gate must be tripped by whichever skill detected the unrecoverable condition.

## 4. `memory_sync_gate`

**When evaluated:** End of Phase 7, after lessons capture and CLAUDE.md drift check.

**Pass:** Lessons captured to `tasks/lessons.md` (or none were learned and that is honestly reflected). If the workflow modified `tasks/lessons.md`, `CLAUDE.md`, or `.claude/references/architecture-principles.md`, those changes were proposed to the engineer and either accepted or explicitly skipped — not silently merged.

**Fail:** Lessons that should have been captured were dropped, or stable patterns were silently merged into protected files without engineer awareness.

**Pending:** Phase 7 not yet reached.

**Skill responsible:** `implement` (Phase 7), with input from `correction-capture` and `promote-lesson`.

## 5. `skill_precedence_gate`

**When evaluated:** Phase 0, before any other phase logic runs, and re-evaluated whenever the orchestrator considers loading additional skills.

**Pass:** The active skill set is the minimum required for the current phase, the active tech stack skill is loaded, and no skill outside MTK has hijacked routing for a workflow MTK owns (e.g., a third-party "plan" skill must not pre-empt `spec-driven-development`).

**Fail:** A non-MTK skill or a deferred MTK skill is masking workflow orchestration. Stop, surface the conflict to the engineer, and either disable the conflicting skill for the session or hand the workflow to it explicitly.

**Pending:** Default until Phase 0 completes.

**Skill responsible:** `context-engineering` (loads context and detects conflicts) plus `implement` (records the gate).

## How to record a gate

```bash
scripts/workflow-artifact.sh gate "$MTK_WF_UUID" plan_trust_gate pass --reason "approve & run until done"
scripts/workflow-artifact.sh gate "$MTK_WF_UUID" phase_exit_gate fail --reason "build red on batch 2"
scripts/workflow-artifact.sh gate "$MTK_WF_UUID" failure_stop_gate fail --reason "3rd remediation iteration on same flake"
```

The helper writes the new value to `gates.{name}` in `{uuid}.json` AND appends a `gate_decided` event to the log. Reading either surface alone is incomplete — auditors should reconcile both.

## Skipping is a hard rule violation

Advancing a phase without recording the corresponding gate is treated the same as advancing on `fail`. The validator and reviewers may treat a missing gate event as drift. If you genuinely have no information to evaluate, leave the gate `pending` and stop — do not invent `pass`.

## Interaction with `MTK_AUTO_PROCEED`

When `MTK_AUTO_PROCEED=1` is set in `.claude/settings.local.json` `env`, the orchestrator MAY default the recommended option on `plan_trust_gate` only when ALL of:

- The spec has zero open decisions
- No `plan-gap-reviewer` `BLOCKING` findings are unresolved
- `skill_precedence_gate` is `pass`
- Scope is not classified as breaking change or high `security_impact`

Auto-proceed never overrides explicit user standards, open plan decisions, or `failure_stop_gate`. When applied, the orchestrator records the bypass via a `gate_decided` event with `reason: "AUTO_PROCEED — all preconditions met"` so audit can replay the decision.

## Cross-references

- Schema: `.claude/references/workflow-artifact-schema.md`
- Helper: `scripts/workflow-artifact.sh`
- Skill: `.claude/skills/workflow-artifacts/SKILL.md`
- Phase definitions: `.claude/skills/implement/SKILL.md`
