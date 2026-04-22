# Hooks-as-Skill-Invocation — Phase 1

- **Date:** 2026-04-20
- **Slug:** hooks-as-skill-invocation
- **Scope:** new-feature
- **Status:** approved
- **Implementation date:** 2026-04-22 (v6.4.0)
- **Implementation notes:** Three pre-build concerns addressed before coding:
  (1) `UserPromptSubmit` contract resolved — hooks emit
  `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"..."}}`;
  (2) correction detection demoted to a tier-1 nudge (no queue) to avoid
  paying queue infrastructure cost for a use case the agent can handle from
  the prompt it already sees; (3) correction-trigger and queue-drain merged
  into a single `userprompt-dispatch.sh` so ordering is explicit in shell,
  not implicit in settings.json array position. An agreement filter (e.g.
  "No, I think the original is correct") suppresses the most common
  false-positive class before the correction regex runs.

## Summary

Add a **tier-2 skill-invoking hook layer** to MTK on top of today's tier-1 text-nudging hooks. Phase 1 introduces a filesystem **queue primitive** and a **`UserPromptSubmit` drain** as the default invocation mechanism, plus two concrete triggers that exercise the pattern end-to-end: **correction-capture** on correction keywords in user prompts, and **planning-and-task-breakdown** on a spec transitioning to `status: approved`.

Tier 2 **proposes, never acts**: hooks write queue entries that the next `UserPromptSubmit` surfaces to the agent via `additionalContext`. No source files are modified by hooks. A global kill-switch (`MTK_HOOKS_TIER2`) disables the whole layer.

## Success Criteria

| ID  | Description | Verification |
|-----|---|---|
| SC1 | With `MTK_HOOKS_TIER2=1`, a user prompt matching a correction keyword causes the next turn to receive `additionalContext` listing a queued `correction-capture` invocation. | Shell integration test `tests/hooks/test-correction-trigger.sh` |
| SC2 | With `MTK_HOOKS_TIER2=1`, writing a spec markdown containing `status: approved` causes the next turn to receive `additionalContext` listing a queued `planning-and-task-breakdown` invocation with the spec path. | Shell integration test `tests/hooks/test-spec-approval-trigger.sh` |
| SC3 | With `MTK_HOOKS_TIER2=0`, neither trigger writes to the queue and the drain emits nothing. | Shell integration test `tests/hooks/test-killswitch.sh` |
| SC4 | Queue entries older than 24 hours are skipped by the drain and marked expired in analytics. | Shell integration test `tests/hooks/test-queue-expiry.sh` |
| SC5 | `.claude/analytics.json` gains `queue_writes` and `queue_drains` counters that increment after each hook run. | Read analytics before and after; diff counters. |
| SC6 | Pressure test scenarios in `hooks-skill-invocation-pressure.md` pass when run manually against a live session. | Manual adversarial run per `## How To Use These Tests`. |
| SC7 | `bash scripts/validate-toolkit.sh` passes after all batches — manifest entries exist, frontmatter valid, versions synced. | Toolkit validation green. |

## Architecture and Design

### Two-tier hook model

| Tier | Emits | When | Example (existing) | Example (new in Phase 1) |
|---|---|---|---|---|
| 1. Text-nudging | Advisory text, `{"context": "..."}`, block (exit 2) | Main thread has context; action obvious | `security-gate.sh`, `scope-guard.sh`, `verify-completion`, `post-compact.sh` | — |
| 2. Skill-invoking | Queue entry on disk; drained into next `additionalContext` | Needs isolated reasoning, deferred action, or user-approved follow-up | — | `correction-trigger`, `spec-approval-trigger` |

Tier-2 hooks never modify source code. They write a single queue entry under `.claude/queue/` and exit. The drain turns queue entries into a list of suggested skill invocations for the agent to pick up — the agent decides whether to invoke; the user sees what was queued.

### Queue protocol

**Location:** `.claude/queue/<timestamp>-<skill>-<hash>.json` (gitignored).

**Entry schema:**
```json
{
  "queued_at": "2026-04-20T11:03:14Z",
  "skill": "correction-capture",
  "reason": "matched correction keyword 'not like that' in user prompt",
  "context": { "prompt_excerpt": "no, not like that — don't modify the auth layer" },
  "ttl_hours": 24,
  "source_hook": "correction-trigger"
}
```

**Atomic write:** trigger hooks write to `<name>.tmp` then `mv` into place. Prevents partial reads during concurrent hook firing.

**Drain behavior (`hooks/userprompt-drain.sh`, runs on `UserPromptSubmit`):**
1. If `MTK_HOOKS_TIER2=0`, exit silently.
2. Glob `.claude/queue/*.json`. Cap at 3 entries per drain (most recent first). Collapse duplicates by `skill + source_hook` key.
3. Filter out entries older than `ttl_hours`; log expired count to analytics; delete expired files.
4. Emit a concise `{"additionalContext": "..."}` JSON listing pending skill invocations with their reason and context excerpt.
5. Delete drained entries after emission.

**Hook invocation mechanism:**
```json
{
  "additionalContext": "MTK-QUEUED (2 pending):\n- correction-capture — matched 'not like that' in user prompt. Consider: invoke the correction-capture skill now.\n- planning-and-task-breakdown — spec docs/specs/2026-04-20-hooks-as-skill-invocation.md transitioned to status: approved. Consider: invoke planning-and-task-breakdown now."
}
```

### Trigger 1 — correction-trigger (`UserPromptSubmit` pre-drain)

Detects correction keywords addressed at the agent. **Tight regex** to avoid false positives on casual "no".

**Match heuristic (bash regex, case-insensitive):**
- Explicit redirections: `^(no|stop|don't|don.?t|undo|revert)\b[,\. -]`
- Corrective phrases anywhere: `\bnot like (that|this)\b`, `\bthat.?s wrong\b`, `\bthat.?s not (what|right)\b`, `\byou (got|have) it wrong\b`, `\bwrong approach\b`
- Scope redirections: `\bthat.?s out of scope\b`, `\btoo much\b(?!\s+(to|fun))`

**Runs before drain** (order in `settings.json` matters — `correction-trigger` first, `userprompt-drain` second) so a correction queued this turn shows up in the same turn's `additionalContext`.

### Trigger 2 — spec-approval-trigger (`PostToolUse: Edit|Write` matching `docs/specs/*.md`)

Detects a spec transitioning to approved state. **Convention:** spec markdown contains a line matching `^\s*-\s*\*\*Status:\*\*\s*approved\s*$` **or** YAML frontmatter with `status: approved`. The transition is detected by comparing the previous file state (git HEAD version) to the new content — only fires when approved is newly added, not on every edit of an already-approved spec.

**Additional guard:** only queues once per spec. Queue key is `spec-approval-<spec-slug>`. Repeat writes to the same approved spec are deduplicated by the drain's collapse step.

### Kill-switch

`MTK_HOOKS_TIER2` env var, default `1` (enabled). Set to `0` to disable all tier-2 hooks globally. Read from `.claude/settings.json` env section or shell. Documented in `CLAUDE.md` routing table.

### Analytics

`session-analytics.sh` gains three integer counters:
- `queue_writes` — total queue entries written across sessions
- `queue_drains` — total entries surfaced via drain
- `queue_expired` — total entries expired without being drained

Used by `toolkit-health` skill to surface "tier-2 is firing but never drained" anomaly (expired ≫ drained means the agent ignores reminders or the user closes sessions too fast).

## Security and Compliance Impact

**Classification:** `none`.

**Rationale:** Hooks write gitignored local files. No network, no secrets, no auth paths, no audit trail, no IAM, no PII new surface beyond what the engineer already types into a prompt (which is already in Claude's transcript). Queue content is capped and escaped.

**Mitigations (hygiene, not security gates):**
- Prompt excerpts in queue entries are capped at **500 chars** and have newlines escaped.
- Shell-escape all queue content via the same JSON escaper used by `post-compact.sh`.
- `.claude/queue/` added to `.gitignore` so queue entries never commit.
- Drain emission is capped at 3 entries to bound context injection cost per turn.

## Change Manifest

**New files (create):**

| Path | Purpose |
|---|---|
| `hooks/lib/skill-queue.sh` | Shared helper: `queue_skill <skill> <reason> <context-json>`, atomic write, dedup key |
| `hooks/userprompt-drain.sh` | `UserPromptSubmit` hook: drain queue → `additionalContext`, handle TTL expiry |
| `hooks/correction-trigger.sh` | `UserPromptSubmit` pre-drain: match correction regex, call `queue_skill correction-capture` |
| `hooks/spec-approval-trigger.sh` | `PostToolUse: Edit\|Write` (path filter `docs/specs/*.md`): detect approval transition, call `queue_skill planning-and-task-breakdown` |
| `tests/pressure-tests/hooks-skill-invocation-pressure.md` | Two adversarial scenarios plus three additional scenarios (killswitch, TTL, dedupe) |
| `tests/hooks/test-correction-trigger.sh` | SC1 integration test |
| `tests/hooks/test-spec-approval-trigger.sh` | SC2 integration test |
| `tests/hooks/test-killswitch.sh` | SC3 integration test |
| `tests/hooks/test-queue-expiry.sh` | SC4 integration test |

**Modified files:**

| Path | Change |
|---|---|
| `.claude/settings.json` | Add `UserPromptSubmit` hook entries (correction-trigger, userprompt-drain in that order); extend `PostToolUse: Edit\|Write` to include `spec-approval-trigger.sh`; add `MTK_HOOKS_TIER2=1` to `env` section |
| `.claude/rules/hooks-and-scripts.md` | Add S3.13 (tier classification), S3.14 (queue protocol), S3.15 (kill-switch requirement) |
| `hooks/session-analytics.sh` | Read and persist `queue_writes`, `queue_drains`, `queue_expired` counters |
| `.claude/manifest.json` | Register all new files; bump version to `6.4.0`; update `updated` date |
| `.claude-plugin/plugin.json` | Bump version to `6.4.0` (sync with manifest per C0.1) |
| `.gitignore` | Add `.claude/queue/` |
| `CLAUDE.md` | Add one-line row to Skill Routing table: `Tier-2 hook kill-switch \| env MTK_HOOKS_TIER2=0 \| Disable skill-invoking hooks` |
| `scripts/validate-toolkit.sh` | Validate new manifest entries exist, new rule IDs present, `hooks/lib/skill-queue.sh` is executable |

## Test Manifest

| Path | Covers |
|---|---|
| `tests/hooks/test-correction-trigger.sh` | SC1 |
| `tests/hooks/test-spec-approval-trigger.sh` | SC2 |
| `tests/hooks/test-killswitch.sh` | SC3 |
| `tests/hooks/test-queue-expiry.sh` | SC4 |
| `tests/pressure-tests/hooks-skill-invocation-pressure.md` | SC6 (manual adversarial) |

**Pressure test scenarios (in `hooks-skill-invocation-pressure.md`):**
1. **Casual "no" in a long sentence** — "No, I think the original approach is correct, so let's keep going." Must NOT fire correction-trigger.
2. **Long session with 3 drained entries** — 50 turns, 6 queued/drained entries total. Queue is always clean at end. Drain never emits more than 3 per turn.
3. **Repeat save of already-approved spec** — `spec-approval-trigger` fires once per spec slug, not on every edit.
4. **Kill-switch respected** — `MTK_HOOKS_TIER2=0` fully silences both triggers and the drain.
5. **TTL expiry** — queue entry older than 24h is skipped and the expiry counter increments.

## Implementation Batches

| Batch | Files | Verification |
|---|---|---|
| 1. Queue primitive | `hooks/lib/skill-queue.sh`, `hooks/userprompt-drain.sh`, `.gitignore`, `.claude/settings.json` (UserPromptSubmit wiring for drain only) | Manual shell test: call `queue_skill` from CLI, invoke drain, confirm `additionalContext` JSON on stdout |
| 2. Correction trigger | `hooks/correction-trigger.sh`, `.claude/settings.json` (add trigger ahead of drain), `tests/hooks/test-correction-trigger.sh`, `tests/hooks/test-killswitch.sh` | SC1 + SC3 green; pressure scenario 1 passes |
| 3. Spec-approval trigger | `hooks/spec-approval-trigger.sh`, `.claude/settings.json` (PostToolUse matcher extension), `tests/hooks/test-spec-approval-trigger.sh`, `tests/hooks/test-queue-expiry.sh` | SC2 + SC4 green; pressure scenario 3 + 5 pass |
| 4. Analytics + rules + manifest | `hooks/session-analytics.sh` (counter updates), `.claude/rules/hooks-and-scripts.md` (S3.13–15), `.claude/manifest.json`, `.claude-plugin/plugin.json`, `CLAUDE.md`, `scripts/validate-toolkit.sh` | SC5 green; `bash scripts/validate-toolkit.sh` passes (SC7) |
| 5. Pressure tests + finalization | `tests/pressure-tests/hooks-skill-invocation-pressure.md` | SC6 manual run; full-test re-run of SC1–SC5 |

## Risks and Assumptions

**Assumptions:**
- A1. Claude Code supports `UserPromptSubmit` hooks producing `{"additionalContext": "..."}` JSON on stdout. If the contract differs (e.g. the event uses `{"context": "..."}` like SessionStart), Batch 1 confirms and adjusts shape. Fallback: `SessionStart` drain (less responsive but same architecture).
- A2. `PostToolUse: Edit|Write` receives stdin JSON containing `tool_input.file_path` (already used by `scope-guard.sh`). Confirmed by existing hook.
- A3. `${CLAUDE_PLUGIN_ROOT}` and relative `hooks/` paths both work in settings.json hook commands (existing pattern).
- A4. The engineer consents to a small prompt-excerpt appearing in a gitignored local queue file for <24h. Aligns with existing `scope-guard.sh` cache under `/tmp`.

**Risks:**
- R1. **False-positive corrections.** Casual "no" in longer sentences triggers correction-capture and pollutes context. Mitigated by tight regex + pressure scenario 1; budget = zero false positives in the 10 non-correction prompts in the pressure test.
- R2. **Context pollution.** Unbounded drain emission eats tokens. Mitigated by 3-entry cap, duplicate collapse, 24h TTL.
- R3. **Race on concurrent hook fires.** Two triggers in one turn could collide. Mitigated by atomic temp-file-then-rename writes with hash-suffixed filenames.
- R4. **Agent ignores reminder.** Drain emits but agent skips invocation. Accepted — tier-2 is "propose, never act". `toolkit-health` surfaces the drain-but-not-invoked ratio for later tuning.
- R5. **Spec approval detection is convention-based.** `status: approved` marker may be missed if the engineer uses different phrasing. Mitigated by documenting the convention in `spec-driven-development` skill output (separate follow-up, noted in Phase 2 scope).
- R6. **Version drift.** `.claude/manifest.json` currently says `6.3.2`, `plugin.json` says `6.3.1` — pre-existing C0.1 violation. This spec bumps both to `6.4.0` in Batch 4, resolving incidentally.

## Open Questions

- Q1. **`UserPromptSubmit` JSON shape** — confirm in Batch 1 whether the correct key is `additionalContext` (per Claude Code docs) or `context` (per MTK's PostCompact pattern). Adjust `userprompt-drain.sh` accordingly; no spec change needed.
- Q2. **Per-engineer opt-out** — should `MTK_HOOKS_TIER2` live in `.claude/settings.local.json` (per-engineer) or `.claude/settings.json` (shared)? Default: shared (settings.json) at `1`; engineers override locally. Consistent with existing hook env patterns.
- Q3. **Should drain mark entries "seen" before deletion, to survive a crash between emit and delete?** Probably not for Phase 1 — the user sees the list, a crash just means they see it twice next turn (mild annoyance, not data loss). Revisit if the drain becomes a persistence layer in Phase 2.

## Out of Scope (Phase 2 and Phase 3)

- **Phase 2 — Hook registry + generator.** A `hooks/hook-registry.json` declaring `{event, matcher, invoke, rate_limit, env_gate}` plus `scripts/generate-hooks.sh` that emits `hooks.json` + settings-hook stanzas. Makes future triggers config, not code.
- **Phase 2 — Additional triggers.** `SessionEnd` → `handoff` (unfinished spec detection); `PostToolUse: Bash(dotnet test|pytest|vitest)` exit≠0 → tier-1 nudge toward `debugging-and-error-recovery`; `PostToolUse: Bash(git commit)` → queue `spec-drift-detection`.
- **Phase 3 — Headless sub-agent fanout.** `PostToolUse: Bash(gh pr create)` → parallel `claude -p --agent {compliance,architecture,test}-reviewer` runs, findings in `.claude/reviews/<sha>/`. Requires `MTK_HOOK_AGENT_FANOUT` gate and cost telemetry.
- **Cross-repo aggregation of analytics** — out of scope for all three phases; probably a nightly GitHub Action separate from the plugin.
- **Team-shared queue** — queue stays strictly per-workspace. No cross-machine replication.
