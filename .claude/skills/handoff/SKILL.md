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

1. Gather: `git branch --show-current`, `git status --short`, `git log --oneline -10`, `tasks/todo.md`, the active spec path (with any `-vN` suffix).
2. Write `docs/handoffs/$(date +%Y-%m-%d)-<slug>.md` (keep `docs/handoffs/` gitignored), under 100 lines, paths not code:

   ```markdown
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

## Verification

- [ ] Note saved with today's date, under 100 lines, factual, with branch, in-progress state, decisions and key files
