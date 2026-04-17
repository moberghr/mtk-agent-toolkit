# Plan — Opus 4.7 Toolkit Modernization (v6.3.0)

Spec: `docs/specs/2026-04-17-opus-47-toolkit-updates.md`
Todo: `tasks/todo.md`

## Execution order

Batches are independent *in content* but sequenced *in execution* so each batch leaves the toolkit in a valid-validating state.

### Batch A — Parallelism patterns

1. Create `docs/parallelism-patterns.md` — short reference (≤80 lines) covering:
   - When parallelism helps (reads that don't depend on each other, reviewer agents on orthogonal axes, ToolSearch for unrelated deferred tools).
   - When it hurts (dependent reads, same-file writes, interactive prompts).
   - Canonical patterns: "load refs in parallel", "spawn reviewer agents in one message", "ToolSearch multiple deferred tools with `select:…,…`".
2. Edit `.claude/skills/context-engineering/SKILL.md`:
   - Add a `## Parallel Loading` subsection after `## Workflow` (refs to the new doc).
   - Trim the stale "~150 instructions" absolute-cap language to a softer budget note.
3. Edit `.claude/skills/implement/SKILL.md`:
   - Phase 0, step 4: append one sentence and example — "Load these references in parallel (single message, multiple Read calls)".
   - Phase 4 Stage 2: change "run `test-reviewer`" + "run `architecture-reviewer`" into a single parallel `Agent`-call block with both.
4. Edit `.claude/skills/fix/SKILL.md`:
   - Load Context step 4: append parallel-read note (same pattern).

### Batch B — Route & description sharpening + fix→implement self-escalation

1. Edit `.claude/skills/fix/SKILL.md` Scope Guard:
   - Change "stop and escalate" language to "invoke `/mtk implement` with the same description via `Skill(skill: \"mtk\", args: …)` — do not silently expand scope in place".
2. Edit `.claude/skills/mtk/SKILL.md`:
   - Tighten route-table "Ambiguous → ask" rule so unambiguous inputs bypass the disambiguation prompt.
   - Move the `fix` row above the `add|create|build` row in the table (fix has narrower scope triggers that should match first).
3. Sharpen `description:` frontmatter — condition-triggering, non-overlapping:
   - `fix/SKILL.md`: already good, leave as reference.
   - `debugging-and-error-recovery/SKILL.md`: differentiate from `fix` — emphasize "reproduce the failure before touching code".
   - `planning-and-task-breakdown/SKILL.md`: emphasize "after spec approval, for batched multi-file work".
   - `spec-driven-development/SKILL.md`: emphasize "before planning, when a change needs a written and approved contract".
   - `incremental-implementation/SKILL.md`: emphasize "during implementation, to enforce one-batch-at-a-time discipline".

### Batch C — Cache-stable prefix convention

1. Edit `.claude/skills/writing-skills/SKILL.md`:
   - Add `## Cache-Stable Prefixes` section (≤25 lines) with: what prompt caching is, why skill authors should put invariants first, the rule (invariants → dynamic state via `!`-blocks).
2. Edit `.claude/skills/setup-bootstrap/SKILL.md`:
   - Add a one-line note in the root CLAUDE.md template rules section reminding the engineer that invariants go on top, per-repo variables below.
3. Edit three reviewer agents — prepend an invariant stability line right after frontmatter:
   - `compliance-reviewer.md` — after "# Compliance-Aware Code Review Agent" add a short stable preface that describes the persona (the cache-friendliest lead-in — prompt stays identical across sessions).
   - Same for `test-reviewer.md` and `architecture-reviewer.md`.
   - Add `context: fork` to their frontmatter if not present — makes behavior consistent whether invoked from a skill with or without `context: fork`.

### Batch D — Toolkit-health skill

1. Create `.claude/skills/toolkit-health/SKILL.md` with workflow-skill anatomy (Overview / When To Use / Workflow / Verification). ≤200 lines. Reads:
   - `.claude/analytics.json` (session counts, ops, mods, specs, lessons, scope-guard warnings, benchmarks).
   - `tasks/lessons.md` (total lesson entries).
   - `docs/specs/` and `docs/plans/` counts.
   - `git log --since="30 days ago" --oneline` for MTK-related commits.
2. Output:
   - Health table: sessions, avg ops/session, specs:sessions ratio, lessons:specs ratio, scope warnings delta.
   - Anomaly flags with suggested actions (e.g. "specs_created is 0 over 20 sessions — team may not be running `/mtk` for features").
   - Graceful degradation if analytics missing (< 3 sessions = "insufficient data").
3. Create `tests/pressure-tests/toolkit-health-pressure.md` with three adversarial scenarios:
   - Corrupted `.claude/analytics.json` (invalid JSON).
   - Stale analytics with dates predating the current CHANGELOG.
   - Empty/first-session (counts all zero).
4. No new agent; no manifest changes to agents. Register both new files in manifest.

### Batch E — Release bump

1. Edit `.claude/manifest.json`:
   - `"version": "6.2.0"` → `"6.3.0"`.
   - `"updated"` → `"2026-04-17"`.
   - Add entries for new paths (`docs/parallelism-patterns.md`, `.claude/skills/toolkit-health/SKILL.md`, `tests/pressure-tests/toolkit-health-pressure.md`).
2. Edit `CHANGELOG.md`:
   - Under `## [6.3.0] - 2026-04-17`, add a new subsection: `### Added (Opus 4.7 modernization)` listing the five wins.
3. `README.md`: only touch if skill count table or command list is now stale.

### Verification (after each batch)

- `bash scripts/validate-toolkit.sh` — must print "Toolkit validation passed." Run after A, C, D, E (B does not touch manifest-tracked structure).
- After E, verify versions match in all three JSON files.

## File budget estimate

| Batch | Files | New lines | Edited lines |
|---|---|---|---|
| A | 4 | ~80 (new doc) | ~20 |
| B | 6 | 0 | ~25 |
| C | 5 | ~35 | ~15 |
| D | 2 | ~220 | 0 |
| E | 2-3 | ~10 | ~20 |

Total: ~5 new files, 16 edited, <500 lines of change.

## Behavioral diff (pre-implementation prediction)

For the engineer using the toolkit AFTER v6.3.0:

- `/mtk` routes faster on unambiguous inputs (no spurious disambiguation question).
- `/mtk fix` that grows beyond 3 files auto-promotes to `/mtk implement` instead of stopping.
- `implement` Stage 2 review completes ~50% faster wall-clock (test + architecture in parallel).
- New `/mtk` diagnostic surface: health report after substantial use.
- Reviewer agents spawn into isolated contexts whether called from a skill or directly.
- Manifest and plugin versions match — no validate-toolkit.sh version drift error.

No user-visible file changes in consumer repos. Updating via plugin marketplace is the only action.
