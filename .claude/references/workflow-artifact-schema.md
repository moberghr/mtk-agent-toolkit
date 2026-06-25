---
description: Schema and lifecycle for durable workflow artifacts under .mtk/workflows/
globs: ["**/*"]
alwaysApply: false
---

# Workflow Artifact Schema

Durable orchestration state lives under `.mtk/workflows/`, outside `.claude/` so Claude Code's sensitive-file gate does not fire on every write. Each workflow has two files:

- `.mtk/workflows/{uuid}.json` — current state (overwritten in place by helpers)
- `.mtk/workflows/{uuid}.events.jsonl` — append-only event log (one JSON object per line)

`.mtk/` is added to `.gitignore` by `setup-bootstrap`. Artifacts are local-only by default; promote to commit only when teams agree on shared workflow audit.

## Why durable artifacts

- Survive auto-compaction — orchestration state is not chat-resident.
- Allow `/mtk implement` to resume after crash, restart, or session handoff.
- Give review and post-mortem an objective trace independent of the transcript.
- Make orchestrator behavior testable via JSON fixtures (`tests/fixtures/`).

## Identity

`workflow_uuid` format: `wf-YYYYMMDDTHHMMSSZ-{6 hex}`. Stable across the workflow's lifetime, prefix-sortable by start time, no PII.

## Top-level shape

```json
{
  "workflow_uuid": "wf-20260507T140000Z-a1b2c3",
  "workflow_type": "BUILD|DEBUG|REVIEW|PLAN|FIX",
  "schema_version": 1,
  "created_at": "2026-05-07T14:00:00Z",
  "updated_at": "2026-05-07T14:12:33Z",
  "status": "active|completed|failed|abandoned",
  "phase_cursor": "phase-0|phase-1|...|phase-7",
  "intent": { "goal": "<one-line user goal>" },
  "gates": {
    "plan_trust_gate":      "pending|pass|fail",
    "phase_exit_gate":      "pending|pass|fail",
    "failure_stop_gate":    "pending|pass|fail",
    "memory_sync_gate":     "pending|pass|fail",
    "skill_precedence_gate":"pending|pass|fail"
  },
  "results": {
    "spec_path": "docs/specs/2026-05-07-foo.md",
    "plan_path": "docs/plans/2026-05-07-foo.md",
    "todo_path": "tasks/todo.md",
    "batches_total": 4,
    "batches_completed": 2,
    "remediation": {
      "build_failure": { "iterations": 2, "scores": [5, 7], "plateau": false }
    }
  },
  "criteria_status": {
    "SC1": "pending",
    "SC2": "verified",
    "SC3": "re-armed"
  },
  "remediation_history": [
    { "ts": "...", "phase": "phase-3", "trigger": "build_failure", "outcome": "fixed" }
  ]
}
```

Implementations may add fields under `results` and `intent` without breaking schema_version 1. Removing or changing an existing field requires a schema bump.

## criteria_status

`criteria_status` is a top-level map from criterion id (`SC1`, `SC2`, …) to its current verification state:

| Value | Meaning |
|---|---|
| `pending` | Not yet verified in this workflow run. |
| `verified` | Verified through its declared `evidence_channel`; observable observed. |
| `re-armed` | Was verified, but a subsequent Edit or Write landed — must be re-verified before a completion claim is accepted. |

**Re-arm rule.** When any Edit or Write tool completes after the most recent verification, the orchestrator must set every `verified` criterion to `re-armed`. A workflow with any criterion in `re-armed` state rejects completion claims.

**Completion gate.** Before accepting a completion claim, `verification-before-completion` checks each criterion in `criteria_status`. All must be `verified`; none may be `pending` or `re-armed`.

Helper commands:

```bash
# Mark a criterion verified (after observing its evidence_channel)
scripts/workflow-artifact.sh criteria "$UUID" SC1=verified

# Re-arm all verified criteria (called by verify-completion hook on edit-after-verify)
scripts/workflow-artifact.sh criteria "$UUID" --rearm-all

# Abandon an active workflow (for the workflow-continuation nudge "abandon" option)
scripts/workflow-artifact.sh abandon "$UUID" [--reason "<text>"]
```

## Event types

Events are append-only. One line per event in `{uuid}.events.jsonl`.

| Event | When | Required `data` keys |
|---|---|---|
| `workflow_started` | At init | `workflow_type` |
| `phase_started` | Entering a phase | `phase` |
| `phase_completed` | Phase exits cleanly | `phase` |
| `gate_decided` | A named gate is evaluated | `gate`, `result` (`pass` or `fail`), `reason` |
| `field_updated` | `set` subcommand updates state | `keys` (array of dotted paths) |
| `agent_dispatched` | A subagent is spawned | `agent`, `prompt_excerpt` |
| `agent_returned` | A subagent finishes | `agent`, `verdict`, `findings_count` |
| `remediation_started` | Loop entered to fix issues | `trigger` |
| `remediation_resolved` | Loop exits successfully | `trigger`, `iterations` |
| `remediation_escalated` | Circuit-breaker tripped (cap or plateau) | `trigger`, `iterations`, `plateau` |
| `workflow_completed` | Final phase done | `summary` |
| `workflow_failed` | Failure-stop gate trips | `reason` |

Every event line carries: `ts` (ISO-8601 UTC), `workflow_uuid`, `event`, `data`.

## Gate semantics

See `.claude/references/orchestration-gates.md` for full definitions. The artifact stores only the latest decision per gate; the event log carries the history.

## Helper script

All reads/writes go through `scripts/workflow-artifact.sh`:

```bash
# Start a workflow
UUID=$(scripts/workflow-artifact.sh init BUILD --goal "Add user-profile page")

# Append an event
scripts/workflow-artifact.sh event "$UUID" phase_started --data '{"phase":"phase-1"}'

# Update a field (dotted paths supported)
scripts/workflow-artifact.sh set "$UUID" phase_cursor=phase-2 results.batches_completed=1

# Record a gate decision
scripts/workflow-artifact.sh gate "$UUID" plan_trust_gate pass --reason "engineer approved"

# Read state / list active workflows
scripts/workflow-artifact.sh read "$UUID"
scripts/workflow-artifact.sh list
```

Skills and agents must not write the JSON directly. Always go through the helper so the event log stays in sync.

## Resume rule

On entering `/mtk implement` with no explicit workflow uuid:

1. Run `scripts/workflow-artifact.sh list`.
2. If exactly one `active` workflow exists for the same `workflow_type`, offer resume.
3. If multiple, ask the engineer which uuid (`AskUserQuestion`).
4. If none, init a new one.

## Lifecycle invariants

- A workflow at `status: active` always has a `phase_cursor` matching one of the implement-skill phases.
- `gates.failure_stop_gate: fail` MUST be followed by `status: failed` and a `workflow_failed` event. No further events after failure.
- `phase_exit_gate: pass` is required before `phase_cursor` advances. Skipping is a hard rule violation; use the gate.
- `memory_sync_gate: pass` is required before `workflow_completed` for any workflow that mutated `tasks/lessons.md`, `CLAUDE.md`, or `.claude/references/architecture-principles.md`.
