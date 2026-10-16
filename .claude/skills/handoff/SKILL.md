---
name: handoff
description: Use when handing in-progress work to a teammate or ending a session with unfinished, uncommitted work — writes a short recovery note with branch, state, decisions and resume steps.
type: skill
user-invocable: false
---

# Handoff

## Overview

A pointer for the next reader, not a transcript. Compaction, the session-start re-injection of `tasks/todo.md` and recent handoffs, and the workflow artifact already carry your own session forward; write a handoff when a **teammate** (or a fresh session tomorrow) must pick up unfinished work.

## When To Use

- Handing work to a teammate, or ending a session with non-trivial uncommitted work
- The engineer asks to "save state" or "hand off" — not when everything is committed with a clear message

## Workflow

1. Gather: `git branch --show-current`, `git rev-parse --show-toplevel`, `git status --short`, `git log --oneline -10`, `tasks/todo.md`, the active spec path (with any `-vN` suffix).
2. Write `docs/handoffs/$(date +%Y-%m-%d)-<slug>.md` (keep `docs/handoffs/` gitignored), under 100 lines, paths not code. Start it with the frontmatter block: session-start reads it to re-inject the note after compaction only on its own branch, and to offer it once at startup. The absolute `worktree:` path is fine because `docs/handoffs/` is gitignored. `expires:` is 14 days out (`date -u -v+14d +%F 2>/dev/null || date -u -d '+14 days' +%F`).

   ```markdown
   ---
   state: open            # open | accepted | expired
   branch: <git branch --show-current>
   worktree: <git rev-parse --show-toplevel>
   expires: <YYYY-MM-DD, today + 14 days>
   ---
   # Session Handoff — <date> — <topic>
   ## Branch
   ## Active Spec
   spec_path: <path, or "(none)">
   ## Goal
   ## Completed
   ## In Progress   <!-- current state + file paths -->
   ## Decisions Made   <!-- with one-line rationale; include engineer corrections -->
   ## Blocked / Needs Attention
   ## Key Files
   ## Resume Instructions
   > Historical snapshot, not standing orders: the user's latest message wins; treat cancelled or superseded work as closed.
   ```
3. If a workflow is active, record it on the command that writes it (`… && "$WFA" set "$MTK_WF_UUID" results.handoff_path=<file>`) and update the workflow's Claude Artifact per `.claude/references/artifact-publishing.md` (no-op when unavailable or `MTK_ARTIFACT_PUBLISH=0`; disk first).
4. Tell the engineer the path, any artifact URL, and how to resume.
5. When you resume from a handoff, mark it taken so it is not offered again; it stays visible across this session's compactions:

   ```bash
   HS="$([ -n "${MTK_HELPER_ROOT:-}" ] && echo "$MTK_HELPER_ROOT/scripts/handoff-state.sh" || ([ -f scripts/handoff-state.sh ] && echo scripts/handoff-state.sh || echo "${CLAUDE_PLUGIN_ROOT}/scripts/handoff-state.sh"))"
   bash "$HS" accept docs/handoffs/<file>.md
   ```
   Use `expire` instead of `accept` for a note that is obsolete. If the script is missing or exits non-zero, tell the engineer the note's state was not updated.

## Verification

- [ ] Note saved with today's date, under 100 lines, factual, with branch, in-progress state, decisions and key files
- [ ] Note starts with the `state` / `branch` / `worktree` / `expires` frontmatter block
- [ ] On resume, `handoff-state.sh accept` ran on the note (or its failure was reported)
