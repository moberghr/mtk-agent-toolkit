---
name: correction-capture
description: Use when the engineer corrects your approach, says "no", "not like that", "stop", or redirects your work — capture the correction as a reusable lesson.
type: skill
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

3. **Decide where it belongs — personal or team.** Two destinations:
   - `.claude/lessons/personal.md` (gitignored) — default. Personal preferences, individual workflow tweaks, "I prefer X here".
   - `tasks/lessons.md` (committed) — team-wide rules. Architectural patterns, repeated team-wide mistakes, conventions every contributor should follow.

   **Heuristic:**
   - First-person language ("I", "my", "for me") → personal.
   - References to team/architecture/codebase patterns ("the team's...", "we always...", "this codebase uses...") → ask before writing to team file.
   - When in doubt → personal. Promotion to team is explicit via `/promote-lesson`.

4. **Check for prior lessons.** Before capturing, grep both files for keywords related to this correction. If a similar lesson already exists, update it instead of duplicating.
   ```bash
   grep -i "<keyword>" .claude/lessons/personal.md tasks/lessons.md 2>/dev/null
   ```
   When *replacing* an existing lesson (vs. appending), write to a temp file and promote via `mtk_guarded_write` so a partial regenerate cannot truncate the file. Pure appends are safe — append never shrinks.

5. **Capture the lesson.** Append to the chosen file (create `.claude/lessons/` if missing). Resolve path to main worktree if in a worktree.
   ```markdown
   ## [Date] — [Short title]

   **Correction:** [What the engineer said]
   **Rule:** [The reusable rule extracted from the correction]
   **Why:** [Why this matters — the underlying principle]
   **Applies to:** [When this rule should activate in future work]
   ```

6. **Check for pattern.** If this is the second or third time a similar correction has been captured:
   - For personal lessons: still personal — repetition just means a stable preference.
   - For team lessons: escalate — suggest adding the rule to `CLAUDE.md` as a permanent standard. Reference the prior lessons as evidence of a pattern.
   - Cross-file: if a personal lesson keeps recurring AND clearly applies to others, suggest promotion via `/promote-lesson`.

7. **Apply immediately.** Adjust your current work to follow the correction. Do not wait for the next task.

## Rules

- Capture every correction, even if it seems minor. Minor corrections compound.
- Extract the general rule, not just the specific instance.
- Include the "why" — without it, the rule becomes a cargo-cult practice.
- Never argue with a correction in the moment. Apply it, then discuss if you genuinely think it's wrong.
- Repeated corrections (3+) should be proposed as CLAUDE.md rules.

## Common Rationalizations

See `.claude/skills/context-engineering/SKILL.md` for the shared table. Correction-specific traps: "this correction is too specific to save" (extract the general principle — the specific instance becomes a reusable rule), "the engineer is being nitpicky" (if they took the time to correct you, it matters — capture it), and "this is already in the coding guidelines" (then you missed it — note which guideline and why, that's the real lesson).

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
