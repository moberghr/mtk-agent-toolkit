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
    "memory_sync_gate":     "pending|pass|fail"
  },
  "results": {
    "spec_path": "docs/specs/2026-05-07-foo.md",
    "plan_path": "docs/plans/2026-05-07-foo.md",
    "todo_path": "tasks/todo.md",
    "handoff_path": "docs/handoffs/2026-05-07-foo.md",
    "health_report_path": ".claude/repo-health-latest.md",
    "artifact_url": "https://claude.ai/code/artifact/<id>",
    "batches_total": 4,
    "batches_completed": 2,
    "remediation": {
      "build_failure": { "iterations": 2, "scores": [5, 7], "plateau": false },
      "review": {
        "iterations": 2, "scores": [], "plateau": false,
        "opens": [3, 2], "stalled": false,
        "findings": {
          "open": ["F-1a2b3c4d5e", "F-0f9e8d7c6b"],
          "last": { "FIXED": ["F-5a6b7c8d9e"], "STILL_OPEN": ["F-1a2b3c4d5e"], "NEW": ["F-0f9e8d7c6b"] }
        }
      }
    },
    "review": {
      "input_fingerprint": "<base commit sha> <tree hash>",
      "recorded_at": "2026-05-07T14:30:00Z"
    },
    "usage": { "tokens_total": 0, "error_codes": [] },
    "dispatch_incidents": [
      { "batch_id": "B1", "kind": "killed", "reason": "org spend limit",
        "from_model": "opus", "to_model": "sonnet", "partial_compiled": true,
        "ts_killed": "2026-05-07T14:20:00Z", "ts_respawned": "2026-05-07T14:44:00Z" }
    ]
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

`results.usage` is an optional roll-up of the per-subagent usage envelopes returned by `subagent-implementation` (`tokens_total` summed across batches, `error_codes` collecting any non-null batch `error_code`). It is a cost / loop-safety signal for post-run review — never a gate input.

`results.dispatch_incidents[]` is an append-only list of per-batch dispatch failures that were **not** a returned result — a killed or aborted implementer (`kind: killed`), plus the tier fallback it forced (`from_model` → `to_model`, both absent when the tier did not change). `partial_compiled` records what the orchestrator found on disk before respawning. The pair `ts_killed` / `ts_respawned` is the only record of what the incident cost; the run receipt sums those gaps into its *time lost to dispatch incidents* figure and writes `not recorded` when either stamp is missing. Written by `subagent-implementation` **before** the replacement is dispatched, so a second kill cannot erase the first.

`results.context_pack` is the path of the per-run context pack written by `scripts/build-context-pack.sh` after Phase 2 (normally `.mtk/workflows/{uuid}/context-pack.md`): the build/test/format commands, CLAUDE.md critical rules, manifest-selected coding-guideline sections, `[EXTRACTED]` principles, and matching lessons that every implementer and reviewer subagent reads **instead of** the files it was built from. Rebuilt when the manifest is amended; passed by path in every subagent prompt.

`results.artifact_url` is the URL of the workflow's published Claude Artifact (the single browsable rollup of spec/plan/handoff/health, updated in place across phases). It is set only when artifact publishing is enabled and available — see `.claude/references/artifact-publishing.md`. The `*_path` fields (`spec_path`, `plan_path`, `todo_path`, `handoff_path`, `health_report_path`) are the on-disk source docs the assembler (`scripts/workflow-artifact-md.sh`) concatenates into `.mtk/workflows/{uuid}.artifact.md`. Disk remains the source of truth; the artifact is an additive rendered mirror.

## Review input and remediation tracking

`results.review.input_fingerprint` binds a review to the tree its lanes read. `review-input <uuid> --record` (at lane dispatch) stores the output of `mtk_tree_fingerprint` from `hooks/lib/hook-io.sh` — the same fingerprint the Stop hook binds evidence with, format `<base commit> <hash>` — plus `recorded_at`. `review-input <uuid> --check` (before aggregating the lanes) recomputes it against the **recorded** base commit and exits:

| Exit | Meaning |
|---|---|
| `0` | Unchanged. A write under `.mtk/` and a commit of exactly the reviewed tree both stay `0`. |
| `1` | Changed: a tracked file was edited or deleted, or an untracked, non-ignored file appeared. Prints `recorded=` and `current=`. Re-dispatch the lanes whose files changed. |
| `2` | Uncheckable: nothing recorded, not a git work tree, an unreadable file, or `hook-io.sh` absent (it is looked up beside the script, then under `CLAUDE_PLUGIN_ROOT`). |

`results.remediation.<trigger>` is the circuit-breaker state written by `remediation <uuid> <trigger>`. It keeps two independent series:

- `scores` (`--score N`, higher is better). `plateau` is true when the last two did not increase.
- `opens` (`--open N`, the open-finding count, lower is better). `stalled` is true when the last two did not decrease (`opens[-1] >= opens[-2]`). `stalled` is written only for a trigger that has reported an open count.

Either flag, or `iterations >= MTK_MAX_REMEDIATION_ITERS` (default 3), prints `ESCALATE`, else `CONTINUE`. The verdict is always line 1 of the output. A stall adds a `reason: stalled` line after it.

`--findings <file.json>` takes a JSON array of findings, or a lane result object with `findings[]` (`review-finding-schema.md`). It cannot be combined with `--open`, because it supplies N itself as the number of distinct open findings. Each finding gets a UID `F-` + the first 10 hex of `sha1(file|rule|snippet)`:

- `snippet` is the first non-empty field of `snippet`, `evidence` or `code`, which linter and analyzer findings may carry.
- `review-finding-schema.md` defines no snippet field, so an AI finding falls back to `rationale`, then `description`, `title` or `message`.
- Whitespace in the snippet is collapsed and stripped.
- The line number is never part of the UID, so a finding keeps its UID when edits move it.
- A reworded `rationale` reads as a new finding: one `FIXED` plus one `NEW`.

The UIDs are reconciled against the previous `--findings` call for the same trigger. The result is stored as `findings.open` (current UIDs) and `findings.last`, and printed after the verdict as three lines, `FIXED <n> <uid>…`, `STILL_OPEN <n> <uid>…` and `NEW <n> <uid>…`:

- `FIXED` — was open, now absent.
- `STILL_OPEN` — open in both calls.
- `NEW` — first seen now.

A findings file that is unreadable or has the wrong shape exits `2` and records nothing.

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
| `agent_dispatched` | A subagent is spawned | `agent`, `prompt_excerpt`, optional `source: workflow-replay` when the `ts` was captured by the dynamic-workflow runtime and replayed via `event --ts` |
| `agent_returned` | A subagent finishes — or is killed (`verdict: killed`, `findings_count: 0`) | `agent`, `verdict`, `findings_count`, optional `source: workflow-replay` |
| `remediation_started` | Loop entered to fix issues | `trigger` |
| `remediation_resolved` | Loop exits successfully | `trigger`, `iterations` |
| `remediation_escalated` | Circuit-breaker tripped (cap, plateau or stall) | `trigger`, `iterations`, `plateau`, `stalled` (bool), `reason` (`stalled` \| `plateau` \| `cap`, first that holds) |
| `review_input_recorded` | `review-input --record` stored the reviewed tree's fingerprint | `input_fingerprint` |
| `workflow_completed` | Final phase done | `summary` |
| `workflow_failed` | Failure-stop gate trips | `reason` |

Every event line carries: `ts` (ISO-8601 UTC), `workflow_uuid`, `event`, `data`.

The `ts` stamps are the run's only timing record. `phase_started` → `phase_completed` bounds each phase's active time; `agent_dispatched` → `agent_returned` bounds each implementer or reviewer; the gap between a `phase_completed` and the next `phase_started`, or between a gate's prompt and its `gate_decided`, is time spent waiting on the engineer. The run receipt derives its timing section from these pairs and never estimates a duration the log does not bound.

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

# Bind a review to its input tree; reconcile a review iteration's findings (line 1 = verdict)
scripts/workflow-artifact.sh review-input "$UUID" --record      # later: --check → 0/1/2
scripts/workflow-artifact.sh remediation "$UUID" review --findings lane-result.json

# Expire workflows (any status) not updated within N days; N >= 1 unless --force; prints pruned uuids
scripts/workflow-artifact.sh prune --older-than 30 [--dry-run]
```

The approval seal (`seal` / `verify-seal`, recorded under `results.approval_seal`) also carries `criteria`: `{path, sha256, count}` over the spec sidecar's frozen `success_criteria` fields (`id`, `observable`, `evidence_channel`). Spec sidecars are gitignored working artifacts, so this hash, not a `git diff`, is what proves the goalposts did not move.

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
