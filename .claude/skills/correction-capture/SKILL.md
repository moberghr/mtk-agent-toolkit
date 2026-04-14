---
name: correction-capture
description: Use when the engineer corrects your approach, says "no", "not like that", "stop", or redirects your work — capture the correction as a reusable lesson.
license: MIT
compatibility:
  - claude-code
  - cursor
  - codex
trigger: engineer-correction|no|stop|not-like-that|redirect
skip_when: one-off-feedback|style-preference|already-documented
user-invocable: false
---

# Correction Capture

## Overview

When an engineer corrects your approach, that correction contains knowledge that should compound across sessions. Capture it immediately, process it into a reusable lesson, and ensure it loads in future sessions. The goal: the engineer should never need to give the same correction twice.

## When To Use

- The engineer says "no", "not like that", "stop doing X", "I told you before"
- The engineer redirects your approach mid-task
- The engineer overrides a decision you made
- A review finding reveals a repeated mistake
- A pattern that worked elsewhere fails in this codebase

### When NOT To Use

- One-off task-specific feedback that wouldn't apply to future work
- Feedback about conversation style rather than technical approach
- Corrections that are already documented in CLAUDE.md or references

## Workflow

1. **Recognize the correction.** Look for:
   - Direct negation: "no", "don't", "stop", "wrong"
   - Redirection: "instead do X", "use Y not Z", "the pattern here is..."
   - Frustration signal: "I already said", "again", "like I mentioned"

2. **Acknowledge without performing.** State what you understand changed:
   - "Understood — I'll use X instead of Y because [reason]."
   - Do not say "You're absolutely right!" or "Great point!" — just state the correction and act on it.

3. **Check for prior lessons.** Before capturing, grep `tasks/lessons.md` for keywords related to this correction. If a similar lesson already exists, update it instead of duplicating. This prevents lessons.md from growing unbounded and strengthens recurring patterns.
   ```bash
   grep -i "<keyword>" tasks/lessons.md
   ```

4. **Capture the lesson.** Append to `tasks/lessons.md` (resolve path to main worktree if in a worktree):
   ```markdown
   ## [Date] — [Short title]
   
   **Correction:** [What the engineer said]
   **Rule:** [The reusable rule extracted from the correction]
   **Why:** [Why this matters — the underlying principle]
   **Applies to:** [When this rule should activate in future work]
   ```

5. **Check for pattern.** If this is the second or third time a similar correction has been captured:
   - Escalate: suggest adding the rule to `CLAUDE.md` as a permanent standard
   - Reference the prior lessons as evidence of a pattern

6. **Apply immediately.** Adjust your current work to follow the correction. Do not wait for the next task.

## Rules

- Capture every correction, even if it seems minor. Minor corrections compound.
- Extract the general rule, not just the specific instance.
- Include the "why" — without it, the rule becomes a cargo-cult practice.
- Never argue with a correction in the moment. Apply it, then discuss if you genuinely think it's wrong.
- Repeated corrections (3+) should be proposed as CLAUDE.md rules.

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "This correction is too specific to save" | Extract the general principle. "Don't use InMemory for this test" becomes "Use the project's standard test provider for relational behavior." |
| "I'll remember this for next time" | You won't. You have no persistent memory without explicit capture. |
| "The engineer is being nitpicky" | If they took the time to correct you, it matters to them. Capture it. |
| "This is already in the coding guidelines" | Then you missed it. Note which guideline and why it was missed — that's the real lesson. |

## Red Flags

- Correction received but not captured in lessons.md
- Lesson captured without the "why" or "applies to" fields
- Same correction given more than twice without proposing a CLAUDE.md rule
- Correction acknowledged performatively but not applied to current work

## Verification

- [ ] The correction was acknowledged without performative agreement
- [ ] A lesson entry was added to tasks/lessons.md
- [ ] The lesson includes: correction, rule, why, and applies-to
- [ ] Current work was adjusted to follow the correction
- [ ] Repeated patterns were flagged for CLAUDE.md promotion
