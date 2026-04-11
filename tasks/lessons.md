# Lessons Learned

> This file captures patterns and mistakes discovered during AI-assisted development.
> It is read at the start of every `/moberg:implement` session.
> Commit this file — it is institutional memory for the team.

## 2026-04-11 — TaskCompleted hook blocks task completion

**What happened:** The `TaskCompleted` prompt hook in `settings.json` prevents tasks from being marked `completed`. The hook fires on the event and its evaluation interferes with the state transition. Tasks stayed stuck at `in_progress` despite repeated `TaskUpdate(completed)` calls. `deleted` worked because no hook fires on deletion.

**Rule:** Do not use prompt hooks on `TaskCompleted` events — they block completion state transitions. Use the `Stop` hook for verification reminders instead, which fires on agent response completion without interfering with task state.

**Why:** Prompt hooks on state-change events can interfere with the state change itself. The `TaskCompleted` hook was designed to be informational but it silently prevents tasks from reaching `completed` status.

**Applies to:** Any settings.json configuration that uses hooks on TaskCompleted events.
