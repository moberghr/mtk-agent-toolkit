# Spec — Continuity quick wins (PR-1 of auto-continuation) — 2026-10-20

Source: `docs/plans/2026-10-20-auto-continuation.md` §3 R0 and §4 PR-1 (approved 2026-10-20).
Sidecar: `docs/specs/2026-10-20-continuity-quick-wins.json`. Release: **9.3.0**. Scope: new-feature.
Security impact: none (no auth, secrets or IAM surface). The compaction archive holds conversation text and is guarded (see Risks).

## Goal

Stop sessions running to the 1M wall, and make a fresh session after `/clear` find the previous one's state without the engineer pasting a path. This PR is the groundwork that PR-2 (checkpoint and context guard) and PR-3 (dashboard) build on.

## Requirements

**R0.1 Compaction window in the settings baseline.**
- `.claude/references/settings-baseline.md` gains a `### settings` section of top-level scalar keys. Its first entry is `autoCompactWindow: 300000`.
- `scripts/settings-baseline.sh`:
  - `--json` emits those keys at the top level beside `permissions`.
  - `--missing` prints `settings<TAB>autoCompactWindow: 300000` when the key is **absent**. A key present with any value counts as present: the engineer's value is respected.
  - `--merge` adds the key only when absent. `merge-settings.sh` already lets the target win on scalar conflicts.
- `mtk-doctor` names a missing baseline setting in its existing baseline WARN, with wording that covers rules **and** settings, and `--fix` merges it.
- `setup-bootstrap` merges it as part of the baseline. `setup-refresh` proposes it as its own hunk.

**R0.2 PostCompact archive.**
- New `hooks/compact-archive.sh`, registered on `PostCompact` in `hooks/hooks.json` with `async: true` and a timeout. It reads `session_id`, `trigger` and `compact_summary` from stdin.
- It writes `<project root>/.mtk/sessions/<session_id>/compact-<UTC yyyymmddTHHMMSSZ>.md`, mode 0600, with frontmatter:
  - `session`
  - `branch` (current branch, or `-`)
  - `trigger`
  - `created` (ISO UTC)
  - `workflow` (uuid of the active workflow from `hooks/lib/active_workflow.py`, or `-`)

  The summary text follows as the body.
- **It writes nothing** when:
  - `MTK_COMPACT_ARCHIVE=0` is set;
  - the summary is empty or missing;
  - the project is a git repo where `.mtk/` is **not** git-ignored, so conversation text is never committable.
- It prunes `.mtk/sessions/*` directories older than 14 days.
- It always exits 0, prints nothing on stdout, and stamps liveness (`mtk_hook_seen compact-archive.sh`).
- `hooks/lib/hook_registry.py` classifies `PostCompact` handlers as `rare`, like SubagentStart, so `mtk-doctor` liveness does not WARN "never fired" in repos that never compacted. The doctor text naming the rare events is updated to match.

**R0.3 Session-start offers.**
- The branch-scoped `HANDOFF OFFER` line, today emitted only for `source=startup`, is also emitted for `source=clear`.
- When no handoff offer line is emitted for `startup` or `clear`, one `COMPACTION OFFER` line names the newest `.mtk/sessions/*/compact-*.md`. It must have `branch` equal to the current branch and an mtime within 24h, and it is presented as a historical snapshot to read only if picking the work up.
- The `compact` source behaviour is unchanged.

**R0.4 Bounded implementers.**
- `.claude/references/subagent-implementer-prompt.md` adds a budget rule. Past `MTK_IMPLEMENTER_MAX_CALLS` tool calls (default 120, substituted by the orchestrator), or after two verify runs fail on the same error with no new approach, the implementer stops and returns `status: "partial"` with `resume_note`: done, left, next step, files touched.
- It adds a result-size rule: the JSON block stays at or under about 60 lines, and longer detail goes to `.mtk/workflows/<uuid>/batches/<batch_id>/report.md`, cited by path.
- The schema adds `partial` and an optional `resume_note`.
- `subagent-implementation` and `subagent-dynamic-workflow.md` treat `partial` as resumable, not failed. They respawn a fresh implementer with the existing `RESUME:` preamble plus the `resume_note`, at most twice per batch, then halt and report. `partial` is never a pass.
- `env-knobs.md` documents the knob.

**R0.5 Typable workflow skills.**
- `implement`, `fix` and `batch-fix` get `user-invocable: true` plus `allowed-tools` and `argument-hint` (S2.4).
- AGENTS.md ("Five skills are user-invocable") and `docs/agent-routing-guide.md` list them as direct shortcuts. `/mtk <description>` stays the natural-language router.
- Rationale: this reverses the 6.3.0 consolidation (454a52c, "consolidate to two entry points", done for menu simplicity) for the three work skills only. In a 45-day session sample, engineers typed `/mtk:implement` and got "can only be invoked by Claude" (3 sessions). The router stays the natural-language entry, and escalation (fix to batch-fix to implement) still routes through it.

**Release.**
- 9.3.0 in all three manifests (C0.1).
- CHANGELOG entry with the hook-process table.
- Manifest entries for new files (C0.2).
- `checksums.sha256` regenerated last (S4.11).

## Out of scope

- R1 checkpoint, R2 context guard and telemetry, R3 relay, R4 PROGRAM workflows, R5 dashboard (PR-2+).
- Doctor resolution of the *effective* window across env vars and user settings.
- Any edit to the engineer's personal `~/.claude` files.

## Assumptions

- `PostCompact` input carries `trigger` and `compact_summary`, and SessionStart delivers `source=clear` (Claude Code hooks docs, checked 2026-10-20).
- `autoCompactWindow` takes an integer token count from 100k to 1M, capped at the model window (model-config docs).
- **Not proved:** that the `autoCompactWindow` settings key also bounds subagents (the env var does, per the docs); and the PostCompact payload as seen live on the installed CLI. Both are recorded in the receipt.

## Risks

- Archived summaries contain conversation text. Mitigations: written only when `.mtk/` is git-ignored, mode 0600, 14-day prune, kill switch.
- Adding a baseline setting makes doctor WARN in every existing repo until refresh. This is intended; the WARN names the fix.
- A 300k window compacts more often. Mitigation: the engineer's value wins, and the offers make the summaries findable.
- Parallel implementers share one working tree. Batches are file-disjoint or carry `depends` edges.
