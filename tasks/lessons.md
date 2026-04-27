# Lessons Learned

> This file captures patterns and mistakes discovered during AI-assisted development.
> It is read at the start of every `/moberg:implement` session.
> Commit this file — it is institutional memory for the team.

## 2026-04-23 — marketplace.json is a third version file the validator checks

**What happened:** After bumping `manifest.json` and `plugin.json` to 7.1.0, `validate-toolkit.sh` still failed with "Version mismatch: manifest=7.1.0 marketplace=7.0.0". The `.claude-plugin/marketplace.json` is a third file that must stay in sync.

**Rule:** When bumping version, update all three: `manifest.json`, `plugin.json`, AND `marketplace.json`. The spec change manifest must list all three.

**Why:** The validator checks all three version fields. Omitting one from the spec/plan means the bump is incomplete.

**Applies to:** Any version bump task — add `marketplace.json` to the change manifest alongside manifest.json and plugin.json.

---

## 2026-04-23 — Hook test assertions inside subshells lose their counters

**What happened:** The first version of `test-context-estimator.sh` used `(...)` subshells to isolate `source "$HOOK_IO"`. Assertions inside those subshells incremented local `pass`/`fail` counters that were never seen by the parent, producing "4/4 passed" despite 7 assertions running.

**Rule:** Hook benchmark tests must use exit-1-on-failure patterns (like existing tests), not accumulating counters. Any counter-based approach requires writing counts to a temp file and reading them back in the parent.

**Why:** Bash subshells don't propagate variable changes to the parent. Sourcing hook-io inside a subshell correctly isolates namespace but silently loses counters.

**Applies to:** Any new test in `tests/hooks/` that needs to source `hook-io.sh` and assert results.

---

## 2026-04-11 — TaskCompleted hook blocks task completion

**What happened:** The `TaskCompleted` prompt hook in `settings.json` prevents tasks from being marked `completed`. The hook fires on the event and its evaluation interferes with the state transition. Tasks stayed stuck at `in_progress` despite repeated `TaskUpdate(completed)` calls. `deleted` worked because no hook fires on deletion.

**Rule:** Do not use prompt hooks on `TaskCompleted` events — they block completion state transitions. Use the `Stop` hook for verification reminders instead, which fires on agent response completion without interfering with task state.

**Why:** Prompt hooks on state-change events can interfere with the state change itself. The `TaskCompleted` hook was designed to be informational but it silently prevents tasks from reaching `completed` status.

**Applies to:** Any settings.json configuration that uses hooks on TaskCompleted events.
