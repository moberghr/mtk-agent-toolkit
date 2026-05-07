# Spec 02 — Cognitive Guards (borrowed from episteme)

> Status: Draft 2026-04-29
> Source of inspiration: https://github.com/junjslee/episteme
> Target version: MTK v7.4.0 (depends on Spec 01 events.jsonl)

## Problem

MTK already has *post-hoc* guards: `spec-drift-detection` runs after implementation, `pre-commit-review` runs before commit, review agents run before merge. But there is no guard *at the moment of high-impact action*. Today an agent can:

- Modify files outside the approved spec manifest during `incremental-implementation` and only get caught at `spec-drift-detection`.
- Run `git push --force` or delete a hook with no friction.
- Skip writing a failing test in TDD and proceed straight to implementation; `verification-before-completion` only checks evidence after the fact.
- Commit without surfacing assumptions — the agent's reasoning is implicit, not auditable.

In regulated software (MTK's positioning), "we caught it later" is not the same as "it never happened". Compliance evidence requires the agent to *declare what it knows, what it assumes, and what could disconfirm it* before acting on a high-impact path.

episteme implements this with PreToolUse blockers gated on a "Reasoning Surface" JSON file. If the file isn't present and fresh, the action is blocked. The Reasoning Surface contains Knowns/Unknowns/Assumptions/Disconfirmation entries, plus a calibration field (predicted-vs-observed for prior decisions).

## Goal

Add a thin pre-action layer that:

1. Blocks designated high-impact tool calls until the agent has produced a fresh Reasoning Surface.
2. Records the Reasoning Surface as a workflow event (Spec 01 dependency) so reviewers can replay the agent's stated reasoning at decision time.
3. Tracks calibration: did the agent's predicted outcome match what happened? Surface drift in `toolkit-health` analytics.
4. Stays *off* by default in non-regulated repos; *on* by default when the finance domain supplement is loaded.

Non-goal: thinking-style chain-of-thought capture. The Reasoning Surface is a structured artifact, not a transcript dump.

## Design

### Trigger surface

Configurable list of "guarded actions". Defaults:

| Action | Match | Why |
|---|---|---|
| `git push` (any) | Bash command regex | Outbound side effect to shared state |
| `git push --force*` | Bash command regex | Irreversible |
| Edit/Write to files outside `state.json.active_spec.manifest` | PreToolUse on Edit/Write | Drift at the moment of drift, not after |
| Edit/Write to `hooks/`, `.claude/agents/`, `scripts/validate-toolkit.sh` | PreToolUse | Toolkit self-modification |
| `dotnet ef database update` / `alembic upgrade` | Bash command regex | Schema migration |
| `npm publish`, `dotnet nuget push` | Bash command regex | Package release |

User overrides via `.claude/cognitive-guards.json`:

```jsonc
{
  "enabled": true,
  "actions": [
    {"id": "git-push", "match": {"tool": "Bash", "regex": "^git\\s+push"}, "level": "block"},
    {"id": "manifest-drift", "match": {"tool": "Edit|Write", "outside_manifest": true}, "level": "block"},
    {"id": "schema-migration", "match": {"tool": "Bash", "regex": "ef database update|alembic upgrade"}, "level": "block"}
  ],
  "freshness_seconds": 600
}
```

`level: "warn"` logs but doesn't block. `level: "block"` returns a PreToolUse deny verdict with a human-readable reason.

### Reasoning Surface artifact

Path: `.claude/mtk/reasoning/<action_id>.json`. Schema:

```jsonc
{
  "action_id": "git-push",
  "ts": "2026-04-29T10:47:24.873Z",
  "session_id": "...",
  "knowns": [
    "All tests pass locally (verification-before-completion seq=1234 emitted batch.verified)",
    "Spec 01 was approved at seq=1100"
  ],
  "unknowns": [
    "CI hasn't run yet — local pass != CI pass",
    "No reviewer has signed off the architecture-reviewer agent"
  ],
  "assumptions": [
    "main branch is not frozen (no project memory entry indicates a freeze)"
  ],
  "disconfirmation": [
    "If CI fails, this push will create a red main and require a revert"
  ],
  "predicted_outcome": "PR merges within 24h after CI green",
  "expires_at": "2026-04-29T10:57:24.873Z"
}
```

The artifact is created by the agent (not by a skill that auto-fills it) — the act of writing is the discipline. `expires_at = ts + freshness_seconds` from config; stale surfaces don't unlock the action.

### PreToolUse hook

`hooks/cognitive-guard.sh`:

1. Read the tool call from PreToolUse JSON input.
2. Match against `cognitive-guards.json` actions.
3. For each match, look for `.claude/mtk/reasoning/<action_id>.json`. If absent or stale, return `{"decision": "block", "reason": "Cognitive guard <id>: produce .claude/mtk/reasoning/<id>.json (Knowns/Unknowns/Assumptions/Disconfirmation/predicted_outcome) within <freshness_seconds>s before this action."}`.
4. If present and fresh, emit `cognitive.surface.consumed` event (Spec 01) and allow.
5. After the action completes (PostToolUse), emit `cognitive.surface.outcome` event with the actual exit code / observed effect.

### Manifest-drift guard (special case)

For Edit/Write checks, the hook reads `state.json.active_batch.manifest` (Spec 01 projection). If the target path is not in the manifest:
- If no active batch (no `incremental-implementation` running), allow without guard.
- If active batch and path outside manifest, require Reasoning Surface for `action_id: "manifest-drift"` *and* an explicit "manifest-extension" entry in the surface.

This catches drift at write-time rather than at `spec-drift-detection` time.

### Calibration

After `cognitive.surface.outcome` events accumulate, a new analytic in `analytics.json`:

```jsonc
"calibration": {
  "git-push": {"predicted_success_rate": 0.95, "observed_success_rate": 0.78, "n": 23},
  "manifest-drift": {"predicted_success_rate": 0.90, "observed_success_rate": 0.62, "n": 8}
}
```

`toolkit-health` skill surfaces calibration drift (>15pp gap) as a soft warning: "manifest-drift surfaces are over-confident — consider stricter spec breakdown."

### Skill changes

- `spec-driven-development` — pre-fills a starter Reasoning Surface for the spec itself (knowns: spec content; unknowns: untested integrations; etc.).
- `verification-before-completion` — refuses to mark a batch verified unless its preceding manifest-drift surfaces, if any, were consumed.
- `pre-commit-review` — adds a check: any `block`-level guard triggered without a consumed surface in this session is a hard fail.
- `toolkit-health` — surfaces calibration analytics.

### MCP tool surface

Add to `mtk-context`:
- `mtk_cognitive_active(session_id)` → list of unconsumed surfaces.
- `mtk_cognitive_calibration` → calibration table.

### Failure modes

| Mode | Behavior |
|---|---|
| Surface file unparseable | Treat as missing; block. |
| Hook itself fails | Fail-open with a logged warning (don't brick the agent). Compliance reviewers see the gap in events.jsonl. |
| Agent in a hurry writes a junk surface to bypass | Calibration metric will diverge; `toolkit-health` flags. Not a security control, a discipline tool. |

## Files added

```
hooks/cognitive-guard.sh
.claude/cognitive-guards.json                    # default config (committed)
.claude/skills/mtk-cognitive/SKILL.md            # ops skill: list, refresh, audit
.claude/mcp/mtk-context/tools/cognitive-*.ts
tests/pressure-tests/cognitive-guards.md
```

## Files modified

- `.claude/settings.json` — register PreToolUse + PostToolUse hooks.
- `.claude/skills/spec-driven-development/SKILL.md` — pre-fill starter surface.
- `.claude/skills/verification-before-completion/SKILL.md` — check consumed surfaces.
- `.claude/skills/pre-commit-review/SKILL.md` — block-level audit.
- `.claude/skills/toolkit-health/SKILL.md` — calibration.
- `.claude/references/domain-finance.md` — recommend `enabled: true` and stricter freshness.
- `.gitignore` — add `.claude/mtk/reasoning/` (per-session artifacts).
- `.claude/manifest.json`, `.claude-plugin/plugin.json` — register & bump.

## Acceptance

1. With `enabled: true`, attempting `git push` without a fresh `.claude/mtk/reasoning/git-push.json` returns a PreToolUse block with the prescribed reason text.
2. Writing a valid surface and pushing within `freshness_seconds` succeeds; `cognitive.surface.consumed` and `cognitive.surface.outcome` events appear in `events.jsonl`.
3. Editing a file outside the active batch manifest is blocked and unblocked only after a `manifest-drift` surface with a `manifest-extension` field.
4. After 10 surface/outcome pairs, `analytics.json` contains a calibration entry per action_id.
5. `toolkit-health` flags any calibration gap >15pp.
6. With `enabled: false` (default in non-finance repos), zero behavioral change vs current MTK.
7. Pressure test `tests/pressure-tests/cognitive-guards.md` covers: missing surface, stale surface, junk surface, manifest-drift block, fail-open on hook crash.
8. `bash scripts/validate-toolkit.sh` passes.

## Dependencies

- Spec 01 (events.jsonl) — surfaces are recorded as events; calibration depends on event log.
- Tier-2 hooks layer (already shipped v6.4.0) — registration pattern.

## Open questions

- Should `manifest-drift` block apply during `fix` skill (1-3 file scope) or only `implement`? Lean: only `implement`, since `fix` has no formal manifest. Make it config-driven.
- Should freshness expire on git HEAD change as well as time? Probably yes — a surface written before a rebase is stale by definition. Add `git_head_at_creation` field; mismatch = stale.
- Calibration scope: per-repo vs per-team. Start per-repo; later v2 could roll up across the team via the multi-repo audit merge mechanism.
