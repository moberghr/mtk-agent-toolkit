---
name: handoff
description: Use when context is approaching limits, before ending a long session with in-progress work, or when handing off to a teammate — capture session state into a recovery artifact so a new session can resume cleanly.
license: MIT
compatibility:
  - claude-code
  - cursor
  - codex
trigger: context-limit-approaching|long-session-ending|teammate-handoff|pre-compaction|branch-switch-mid-feature
skip_when: short-session|no-in-progress-work|nothing-meaningful-to-resume
---

# Handoff

## Overview

A handoff captures the current session state — branch, in-progress work, decisions, blockers, and key files — into a small markdown artifact so the next session (yours after compaction, a new conversation tomorrow, or a teammate) can resume without re-discovering the context. The artifact is a pointer, not a transcript: it tells the next reader where to look, not what every step was.

## When To Use

- Context is approaching its limit and compaction is imminent
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
   - Active spec or plan: check `docs/specs/` and `docs/plans/` for recent files
   - Lessons captured this session: check `tasks/lessons.md` for today's entries

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
   ```

4. **Ensure gitignored.** Add `docs/handoffs/` to `.gitignore` if not already there. Handoffs are working artifacts, not committed deliverables.

5. **Report.** Tell the engineer:
   - Where the handoff was saved
   - How to resume: "Start a new session, read `docs/handoffs/[file]`, then continue"

## Rules

- Handoffs must be factual — describe what IS, not what should be
- Include file paths so the next session can load context efficiently
- Keep under 100 lines. This is a pointer, not a transcript
- Do not include full code or diffs — reference the files instead
- Use today's actual date (resolve via `date +%Y-%m-%d`), not placeholder text

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "The git log is enough — the next session can read it" | Git log shows what was committed. It does not show in-progress work, blockers, or the *why* behind decisions. |
| "I'll just paste the whole conversation" | A 100-line pointer beats a 5,000-token transcript. The next session has tools — give it the file paths, not the contents. |
| "I'll write what should happen next" | Handoffs describe state, not plans. If the next steps are real, they belong in `tasks/todo.md` or a spec, not the handoff. |
| "It's a short session, no need" | If you're invoking this skill, it's not a short session. Capture it. |

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
