---
description: Capture session state into a recovery artifact for context continuity across sessions or after context compaction.
allowed-tools: Read, Write, Bash, Glob, Grep
---

# Session Handoff

Create a recovery artifact that captures the current session state so a new session
(or post-compaction context) can resume where this one left off.

## When To Use

- Before ending a long session with in-progress work
- When context is approaching limits and compaction is imminent
- When handing off to a teammate who will continue the work
- When switching between branches or features mid-stream

## Workflow

1. **Gather state.** Collect:
   - Current branch: `git branch --show-current`
   - Recent commits on this branch: `git log --oneline -10`
   - Uncommitted changes: `git status --short`
   - Open tasks: read `tasks/todo.md` if it exists
   - Active spec: check `docs/specs/` for recent files
   - Lessons captured this session: check `tasks/lessons.md` for today's entries

2. **Summarize decisions.** Write a brief section covering:
   - What was the goal of this session?
   - What decisions were made and why?
   - What was completed?
   - What is still in progress?
   - What is blocked or needs attention?
   - Any corrections received from the engineer

3. **Write the artifact.** Save to `docs/handoffs/YYYY-MM-DD-<slug>.md`:
   ```markdown
   # Session Handoff — [date] — [brief topic]

   ## Branch
   [current branch name]

   ## Goal
   [what this session set out to accomplish]

   ## Completed
   - [list of completed items]

   ## In Progress
   - [list of items started but not finished, with current state]

   ## Decisions Made
   - [key decisions with brief rationale]

   ## Blocked / Needs Attention
   - [anything that requires input or is stuck]

   ## Key Files
   - [list of files most relevant to resuming work]

   ## Resume Instructions
   [specific steps to pick up where this left off]
   ```

4. **Ensure gitignored.** Add `docs/handoffs/` to `.gitignore` if not already there.
   Handoffs are working artifacts, not committed deliverables.

5. **Report.** Tell the engineer:
   - Where the handoff was saved
   - How to resume: "Start a new session, read `docs/handoffs/[file]`, then continue"

## Rules

- Handoffs must be factual — describe what IS, not what should be.
- Include file paths so the next session can load context efficiently.
- Keep under 100 lines. This is a pointer, not a transcript.
- Do not include full code or diffs — reference the files instead.
