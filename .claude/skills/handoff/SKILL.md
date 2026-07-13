---
name: handoff
description: Use when context nears limits, before ending a long session with in-progress work, or handing off to a teammate — captures session state into a recovery artifact so a new session resumes cleanly.
type: skill
license: MIT
compatibility:
  - claude-code
  - cursor
  - codex
trigger: context-limit-approaching|long-session-ending|teammate-handoff|pre-compaction|branch-switch-mid-feature
skip_when: short-session|no-in-progress-work|nothing-meaningful-to-resume
user-invocable: false
---

# Handoff

## Current Session State

```!
echo "--- Branch ---"
git branch --show-current 2>/dev/null || echo "(detached)"
echo "--- Uncommitted changes ---"
git status --short 2>/dev/null | head -20 || echo "(not a git repo)"
echo "--- Recent commits (this branch) ---"
git log --oneline -5 2>/dev/null || echo "(no commits)"
```

## Overview

A handoff captures the current session state — branch, in-progress work, decisions, blockers, and key files — into a small markdown artifact so the next session (yours after compaction, a new conversation tomorrow, or a teammate) can resume without re-discovering the context. The artifact is a pointer, not a transcript: it tells the next reader where to look, not what every step was.

## When To Use

- Context is approaching its limit and compaction is imminent — including when the `context-budget` hook nudges that the session is past `MTK_CONTEXT_BUDGET_PCT`% (default 60) of the window: reset deliberately *before* quality degrades rather than riding it to compaction
- Ending a long session that has unfinished, non-trivial work
- Handing off to a teammate who will continue the work
- Switching branches or features mid-stream and the current state needs to survive
- The user explicitly asks to "save state", "snapshot", or "hand off"

### When NOT To Use

- Short sessions where the next session can re-derive everything from `git status` + the last commit
- Work that is fully committed with a clear commit message — the commit IS the handoff
- Trivial or exploratory work where there is nothing meaningful to resume
- Already produced a handoff in this session and nothing material has changed since

## Workflow

1. **Gather state.** Collect the facts that the next reader will need:
   - Current branch: `git branch --show-current`
   - Recent commits on this branch: `git log --oneline -10`
   - Uncommitted changes: `git status --short`
   - Open tasks: read `tasks/todo.md` if it exists
   - Active spec or plan: check `docs/specs/` and `docs/plans/` for recent files. Record the **full path** of the active spec including any version suffix (e.g., `docs/specs/2026-04-23-foo-v2.md`) — this becomes `spec_path` in the artifact.
   - Lessons captured this session: check `tasks/lessons.md` for today's entries

1a. **Read fatigue signals.** Use the four-signal heuristic from
    `context-engineering` (token util / scope scatter / re-read ratio /
    error density) to decide whether this handoff is "clean snapshot" or
    "salvage". When 2+ signals are elevated, lead the handoff with the
    elevated signals so the next session knows what to mistrust about the
    half-done state (e.g., "scope scattered across 4 unrelated modules —
    revisit the goal before continuing batch 3").

2. **Summarize decisions.** Without restating the conversation:
   - What was the goal of this session?
   - What decisions were made and why?
   - What was completed?
   - What is still in progress (and where is it half-done)?
   - What is blocked or needs human input?
   - Any corrections received from the engineer that future-you should respect

3. **Write the artifact.** Save to `docs/handoffs/YYYY-MM-DD-<slug>.md`. Use today's actual date, not a placeholder:

   ```markdown
   # Session Handoff — [date] — [brief topic]

   ## Branch
   [current branch name]

   ## Active Spec
   spec_path: [full path to active spec including version suffix, e.g. docs/specs/2026-04-23-foo-v2.md — or "(none)" if no active spec]

   ## Goal
   [what this session set out to accomplish]

   ## Completed
   - [list of completed items]

   ## In Progress
   - [list of items started but not finished, with current state and file paths]

   ## Decisions Made
   - [key decisions with brief rationale]

   ## Blocked / Needs Attention
   - [anything that requires input or is stuck]

   ## Key Files
   - [list of files most relevant to resuming work — paths only, not contents]

   ## Resume Instructions
   [specific steps to pick up where this left off]

   ## Fatigue Signals (if elevated)
   [name the elevated signals — token util / scope scatter / re-read ratio /
   error density — and what the next session should mistrust because of them.
   Omit this section entirely if no signals are elevated.]
   ```

4. **Ensure gitignored.** Add `docs/handoffs/` to `.gitignore` if not already there. Handoffs are working artifacts, not committed deliverables.

4.5. **Publish/update the workflow artifact (additive, capability-gated).** If a workflow uuid resolves, record the handoff path (`scripts/workflow-artifact.sh set "$MTK_WF_UUID" results.handoff_path=docs/handoffs/<file>.md`) and follow `.claude/references/artifact-publishing.md` to add the Handoff section to the workflow's Claude Artifact — updating the existing URL in place so a teammate opening the link sees current state. If no workflow is active (a bare handoff), publishing standalone is fine; report the URL. Silent no-op when the tool is unavailable or `MTK_ARTIFACT_PUBLISH=0`. Disk is written first regardless.

5. **Report.** Tell the engineer:
   - Where the handoff was saved
   - The artifact URL, if one was published (and that it reflects the latest state)
   - How to resume: "Start a new session, read `docs/handoffs/[file]`, then continue"

## Rules

- Handoffs must be factual — describe what IS, not what should be
- Include file paths so the next session can load context efficiently
- Keep under 100 lines. This is a pointer, not a transcript
- Do not include full code or diffs — reference the files instead
- Use today's actual date (resolve via `date +%Y-%m-%d`), not placeholder text

## Common Rationalizations

See `.claude/skills/context-engineering/SKILL.md` for the shared table. Handoff-specific traps: "the git log is enough" (git log shows what was committed, not in-progress work or the why behind decisions), "I'll just paste the whole conversation" (a 100-line pointer beats a 5,000-token transcript — the next session has tools), and "I'll write what should happen next" (handoffs describe state, not plans — next steps belong in `tasks/todo.md` or a spec).

## Red Flags

- Handoff over 100 lines — you're writing a transcript, trim it
- Handoff includes code blocks longer than 5 lines — reference the file instead
- Handoff written but `docs/handoffs/` not in `.gitignore`
- Date in the handoff is wrong or a placeholder

## Verification

- [ ] Artifact saved to `docs/handoffs/YYYY-MM-DD-<slug>.md` with today's actual date
- [ ] Artifact is under 100 lines
- [ ] Branch, in-progress work, decisions, and key files are all listed
- [ ] `docs/handoffs/` is in `.gitignore`
- [ ] Engineer was told the path and how to resume
- [ ] Handoff published/updated to the workflow artifact (or gate correctly closed) per `.claude/references/artifact-publishing.md`; disk written first (step 4.5)
