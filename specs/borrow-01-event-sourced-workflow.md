# Spec 01 — Event-Sourced Workflow State (borrowed from weft)

> Status: Draft 2026-04-29
> Source of inspiration: https://github.com/dioptx/weft
> Target version: MTK v7.3.0

## Problem

MTK's current cross-session continuity relies on:
- A static PreCompact git snapshot (commit 3094, hooks/pre-compact-snapshot.sh) — captures repo state once, doesn't track *what the agent was doing*.
- `handoff` skill — produces a typed artifact, but written manually at end-of-session.
- Implicit transcript memory — lost on auto-compaction or `/clear`.

Result: when the agent resumes after compaction, it knows the file state but not which spec/batch/skill phase it was in. `incremental-implementation` can drift past its approved manifest because the manifest itself is stored only in conversation context. `spec-drift-detection` can only compare git diff vs spec — it can't tell whether the spec was *followed in the order claimed*.

weft solves this with an append-only `events.jsonl` plus a derived `state.json` projection. The event log is the source of truth; the projection is rebuildable. Every workflow transition (skill invoked, batch started, batch verified, agent reviewed, drift checked) is an event.

## Goal

Give MTK a durable, replayable record of *workflow* state — orthogonal to git's record of *file* state — so that:

1. After compaction, the agent can reconstruct "I was on spec X, batch 2 of 4, last verified step Y" without re-reading the whole transcript.
2. `spec-drift-detection` can verify the *sequence* of skills used, not just the diff.
3. Compliance reviewers (finance domain) get a tamper-evident timeline of what the agent did and when — fits MTK's regulated-software positioning.
4. Tier-2 hooks can emit events without owning state — single writer, multiple readers.

Non-goal: replacing git, replacing the transcript, replacing claude-mem observations. This is *workflow-state*, not knowledge or code.

## Design

### Storage layout

```
.claude/mtk/
  events.jsonl        # append-only, one JSON event per line, gitignored
  state.json          # projected state, regenerated from events.jsonl
  events.lock         # advisory file lock for the writer
```

`events.jsonl` is gitignored (per-machine workflow state is not a team artifact). `state.json` is also gitignored. A cleartext export is committed as part of `handoff` artifacts when the user wants to share state.

### Event schema

```jsonc
{
  "ts": "2026-04-29T10:47:24.873Z",   // RFC3339 UTC
  "seq": 1234,                         // monotonically increasing per repo
  "session_id": "<claude-session-id>", // from $CLAUDE_SESSION_ID env if available
  "type": "skill.invoked",             // see event types below
  "actor": "agent" | "hook" | "user",
  "payload": { ... },                  // type-specific
  "prev_hash": "sha256:...",           // hash of previous event (chain integrity)
  "hash": "sha256:..."                 // sha256(canonical_json(this event minus hash))
}
```

Hash chain is the compliance lever: any tampering with a past event invalidates every event after it. Verification is `mtk events verify`.

### Event types (v1)

| Type | Emitted by | Payload |
|---|---|---|
| `session.started` | session-start hook | `{tech_stack, mtk_version, git_head}` |
| `session.compacted` | PreCompact hook | `{git_head_at_compaction}` |
| `skill.invoked` | tier-2 skill-invoke hook | `{skill, args, trigger}` |
| `spec.approved` | spec-driven-development | `{spec_id, files_planned, contracts_added}` |
| `batch.started` | incremental-implementation | `{spec_id, batch_index, batch_total, manifest}` |
| `batch.verified` | verification-before-completion | `{spec_id, batch_index, evidence_paths}` |
| `agent.reviewed` | review-agent runner | `{agent, verdict, blocking_issues}` |
| `drift.checked` | spec-drift-detection | `{spec_id, drift_items}` |
| `correction.captured` | correction-capture | `{lesson_id, scope}` |

### Writer contract

- Single writer at a time, enforced by `flock` on `events.lock`.
- Hooks that need to emit call `hooks/lib/events.sh emit <type> <json_payload>`.
- The library appends one line, computes hash chain, fsyncs.
- Failure to acquire lock within 2s → log a warning, do not block the hook (workflow state is best-effort, never blocking).

### Projector

`scripts/project-state.sh` reads `events.jsonl` from sequence 0 and produces `state.json`:

```jsonc
{
  "current_session_id": "...",
  "active_spec": {"id": "...", "approved_at": "...", "manifest": [...]},
  "active_batch": {"index": 2, "total": 4, "started_at": "..."},
  "last_verified_batch": 1,
  "skills_used_this_session": ["spec-driven-development", "planning-and-task-breakdown", "incremental-implementation"],
  "open_corrections": [...],
  "last_drift_check": {"ts": "...", "verdict": "clean"}
}
```

`state.json` is regenerated on:
- Every event append (cheap incremental update if last hash matches).
- `mtk events rebuild` (full replay).
- Session-start hook (full replay, in case prior writes were lost).

### MCP tool surface

Add to `mtk-context` MCP server:
- `mtk_workflow_state` → returns `state.json`.
- `mtk_workflow_timeline(since: ISO8601, limit: int)` → returns recent events.
- `mtk_workflow_verify` → returns `{ok: bool, broken_at_seq: int | null}`.

These slot next to existing read-only state tools (manifest/audit/analytics).

### Hook integration

Tier-2 skill-invoking hooks already fire on PreToolUse for skill triggers. Add an `events.sh emit skill.invoked` call at the head of each tier-2 hook. Cost: ~5ms per fire. `MTK_HOOKS_TIER2=0` already disables the whole tier — no separate flag needed.

PreCompact hook (existing `hooks/pre-compact-snapshot.sh`) gets one extra line: emit `session.compacted` event before the git snapshot.

### Skill changes

- `incremental-implementation` writes `batch.started` / `batch.verified` events at batch boundaries (already has the boundaries; only adds the emit).
- `spec-drift-detection` reads `events.jsonl` and adds a "sequence" check: were the expected skills invoked in the expected order between `spec.approved` and the diff under review?
- `handoff` reads `state.json` and includes the active spec/batch in the handoff artifact (currently it has to reconstruct this from the transcript).
- `verification-before-completion` reads `state.json` to confirm `batch.verified` events exist for every claimed batch.

### Failure modes

| Mode | Behavior |
|---|---|
| `events.jsonl` corrupt mid-line | Projector skips invalid line, logs warning, continues. `mtk events repair` truncates to last valid line. |
| Lock contention | Hook logs warning, drops the event. Workflow state is best-effort. |
| Hash chain broken | `mtk_workflow_verify` returns `broken_at_seq`. Compliance reviewers can quote this. Doesn't block work. |
| Orphan `state.json` (events deleted) | Session-start hook detects mismatch and rebuilds. |

## Out of scope (v1)

- Cross-machine sync — events.jsonl is local. A later v2 could mirror to a team store.
- UI / TUI for browsing the timeline — start with `jq events.jsonl` and the MCP timeline tool.
- Replacing claude-mem — claude-mem is observation-grained, this is workflow-grained.

## Files added

```
hooks/lib/events.sh                            # emit, lock, hash chain
scripts/project-state.sh                       # full replay projector
scripts/verify-events.sh                       # hash chain verifier
.claude/skills/mtk-events/SKILL.md             # ops skill: rebuild, verify, repair, dump
.claude/mcp/mtk-context/tools/workflow-*.ts    # 3 MCP tools
.gitignore                                     # add .claude/mtk/events.jsonl, state.json, events.lock
```

## Files modified

- `hooks/pre-compact-snapshot.sh` — emit `session.compacted`.
- `hooks/session-start.sh` — emit `session.started`, run projector.
- All tier-2 skill-invoke hooks — emit `skill.invoked`.
- `.claude/skills/incremental-implementation/SKILL.md` — emit batch events.
- `.claude/skills/spec-drift-detection/SKILL.md` — read sequence, flag missing skills.
- `.claude/skills/verification-before-completion/SKILL.md` — read state.json.
- `.claude/skills/handoff/SKILL.md` — include active state in artifact.
- `.claude/manifest.json` — register new files, bump version.
- `.claude-plugin/plugin.json` — bump version.

## Acceptance

1. After running `/mtk implement <feature>` end-to-end, `events.jsonl` contains at minimum: session.started, spec.approved, ≥1 batch.started, ≥1 batch.verified, ≥1 agent.reviewed, drift.checked.
2. `mtk events verify` returns `{ok: true}` and a non-zero seq count.
3. Triggering a `/clear` mid-batch and resuming: session-start projector rebuilds `state.json` and `mtk_workflow_state` MCP tool returns `active_batch` correctly.
4. Tampering with one event line in `events.jsonl` and running `mtk events verify` returns `broken_at_seq` pointing to the tampered event.
5. New pressure test: `tests/pressure-tests/event-sourced-workflow.md` covers compaction-mid-batch, lock-contention, and hash-chain-tamper.
6. `bash scripts/validate-toolkit.sh` passes.

## Open questions

- Should `correction.captured` events sync into `claude-mem` observations, or stay local? (Lean: stay local for now; team-wide promotion already happens via `promote-lesson`.)
- Hash algorithm: sha256 (chosen) vs blake3 (faster, fewer .NET defaults). Sticking with sha256 for ubiquity.
- Should the projector run on every event append or batch every N? Start with every-append; revisit if profiling shows >50ms overhead.
