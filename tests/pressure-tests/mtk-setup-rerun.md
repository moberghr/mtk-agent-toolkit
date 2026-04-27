# Pressure Test — `/mtk-setup --audit` re-run semantics

> Adversarial scenarios that target the versioned 3-way merge introduced in v7.0.0 (B3 of the mtk-setup hardening spec). The goal: prove the re-run never silently clobbers engineer edits and never leaves the repo in a half-merged state.

## Scenario 1 — Clean re-run, no edits

**Setup:**
- Repo bootstrapped at v7.0.0. `.claude/.mtk-cache/v7.0.0/` matches every generated file on disk byte-for-byte.
- Engineer runs `/mtk-setup --audit` with no intervening edits.

**Expected behavior:**
- STEP -1 classifies every file as `stock` (cmp matches previous template).
- Re-run summary shows every file as `OVERWRITE`.
- `.mtk-cache/v7.0.0/` is updated with the new template outputs.
- No conflict markers anywhere.

**Failure signal:** If the skill produces a conflict marker or asks the engineer to classify files, that's a false positive — the cache should have answered the question.

## Scenario 2 — Engineer added sections, no template change to same sections

**Setup:**
- Engineer added a `## Custom: Deployment Notes` section to `CLAUDE.md`.
- The new template changes an unrelated section (`## Skill Routing`).

**Expected behavior:**
- 3-way merge succeeds cleanly.
- On-disk CLAUDE.md retains the `## Custom: Deployment Notes` section AND picks up the new `## Skill Routing` table.
- `.mtk-cache/` updated.
- No conflict markers.

**Failure signal:** The custom section disappears (skill overwrote), or the template change is silently skipped (skill treated hand-edited as `hand-edited` blanket-skip instead of merging).

## Scenario 3 — Engineer edited the same section the template changed

**Setup:**
- Engineer rewrote the `## Project Profile` table in CLAUDE.md.
- New template rewrites the same table differently.

**Expected behavior:**
- 3-way merge fails. The on-disk file contains `<<<<<<< / ======= / >>>>>>>` conflict markers around the `## Project Profile` block.
- Skill prints `CONFLICT: CLAUDE.md — resolve markers manually before next run`.
- `.mtk-cache/` is **not** updated for CLAUDE.md (but may be updated for other non-conflicted files).
- Exit status is non-zero or the skill explicitly flags the run as partial.

**Failure signal:** The skill silently picks one side ("latest wins"), or the cache is updated despite the unresolved conflict (next re-run would then treat resolved state as baseline — data loss).

## Scenario 4 — Protected file edited

**Setup:**
- `manifest.protected` lists `tasks/lessons.md`.
- Engineer has heavily edited `tasks/lessons.md`.
- Audit would regenerate files; lessons.md is in the generation path.

**Expected behavior:**
- Re-run summary shows `tasks/lessons.md` as `SKIP (protected)`.
- File on disk is byte-identical before and after the audit.
- `.mtk-cache/` for this file is **not** touched.

**Failure signal:** Protected file gets merged (even cleanly) — the `manifest.protected` list must short-circuit before any merge logic.

## Scenario 5 — Cache version skew (pre-v7 migration)

**Setup:**
- Repo was bootstrapped on v6.5.0. CLAUDE.md has no footer; `.claude/.mtk-cache/` does not exist.
- Engineer installs v7.0.0 and runs `/mtk-setup --audit`.

**Expected behavior:**
- STEP -1 detects missing footer and missing cache.
- Skill prompts via `AskUserQuestion` with three options: hand-edited / stock / cancel.
- Choosing `hand-edited` runs merge with current on-disk files as both ancestor and current → no conflicts, no change.
- Choosing `stock` seeds pseudo-previous from current files and then cleanly overwrites.
- Choosing `cancel` exits with zero modifications.

**Failure signal:** The skill proceeds without prompting, OR proceeds with empty `PREV_CACHE` and produces conflicts on every file.

## Scenario 6 — Partial cache (one file missing)

**Setup:**
- `.claude/.mtk-cache/v7.0.0/CLAUDE.md` exists but `.claude/.mtk-cache/v7.0.0/rules/security.md` is missing (disk-corruption-style).
- Engineer runs `--audit`.

**Expected behavior:**
- For CLAUDE.md: normal 3-way merge proceeds.
- For `rules/security.md`: missing previous template triggers migration-path prompt for that file specifically, OR the skill treats the file as `hand-edited` conservatively. Either is acceptable; silently overwriting is not.

**Failure signal:** The skill silently overwrites `rules/security.md` because "previous template wasn't there so anything goes."

## Scenario 7 — Conflict resolved mid-session, re-run immediately

**Setup:**
- Previous run left CLAUDE.md with conflict markers (from Scenario 3).
- Engineer resolved the markers by hand, saved the file.
- Engineer immediately runs `/mtk-setup --audit` again.

**Expected behavior:**
- STEP -1 sees CLAUDE.md has no conflict markers (grep for `<<<<<<<` is clean).
- Because `.mtk-cache/` was NOT updated during the previous run (by Scenario 3's invariant), the ancestor is still the pre-conflict template.
- Engineer's resolution is now the "current" content — merge either produces a clean result (matches new template on other sections) or surfaces new conflicts if the template changed again.

**Failure signal:** Skill refuses to run because the previous session "didn't complete cleanly," or cache is mid-updated and ancestor is now post-conflict — losing the engineer's resolution track.

## Scenario 8 — Cache retention

**Setup:**
- Repo has `.claude/.mtk-cache/v6.5.0/`, `v7.0.0/`, and `v7.0.0-migration/`.
- Engineer runs bootstrap at v7.1.0.

**Expected behavior:**
- After generation, `.mtk-cache/v7.1.0/` exists.
- At most 2 version dirs remain (spec: "keep only last 2"). Oldest (`v6.5.0`) is pruned.
- `v7.0.0-migration/` handling is explicit — either always-retained or always-pruned, not left ambiguous.

**Failure signal:** Cache grows unbounded across 10+ versions, or arbitrary dirs get pruned and a valid re-run loses its ancestor.

## Verification Checklist

Run each scenario against a fresh clone of a test repo. Record:
- [ ] Exit code matches expectation
- [ ] Files touched match expectation (diff against pre-run snapshot)
- [ ] `.claude/.mtk-cache/` state matches expectation
- [ ] No conflict markers in files marked `OVERWRITE` or `SKIP`
- [ ] Engineer-facing output is accurate (no false success)

A scenario passes only when all five check boxes match. Partial passes are regressions.
