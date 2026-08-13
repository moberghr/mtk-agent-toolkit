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

This skill is specifically for **engineer-driven** corrections. When *you* resolve your own repeated failure through trial and error — same signature failing 2+ times, then a materially different fix, with no human redirect — that is self-driven, not a correction: use `golden-path-capture` instead. (And `lesson-mining` is the after-the-fact transcript sweep for what neither live skill captured.)

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

   **If the grep finds a lesson that *contradicts* the new one** (not a duplicate — an actual reversal of prior guidance), do not silently append a second, conflicting rule. Capture the new lesson with `--supersedes <old-id>`: the old entry stays for the audit trail but `learnings.sh query` stops surfacing it, so retrieval never returns two rules that disagree. A duplicate of the *same* rule is different — that just increments `recurrence.count`.

5. **Capture the lesson — structured + markdown.**

   **a. Structured (preferred when `scripts/learnings.sh` is present).** Append a JSONL entry to `.mtk/learnings.jsonl` (gitignored, machine-readable). Then regenerate the markdown view:
   ```bash
   # Resolve the script: project copy first, else the plugin's copy (plugin
   # installs never receive scripts/ into the target repo).
   LS="$([ -n "${MTK_HELPER_ROOT:-}" ] && echo "$MTK_HELPER_ROOT/scripts/learnings.sh" || ([ -f scripts/learnings.sh ] && echo scripts/learnings.sh || echo "${CLAUDE_PLUGIN_ROOT:-.}/scripts/learnings.sh"))"
   bash "$LS" add \
     --workflow "${MTK_WF_UUID:-manual}" \
     --scope "personal|team" \
     --source correction \
     --decision-origin "claude-recommended-rejected|claude-recommended-modified|user-directed" \
     --severity "info|warn|block" \
     --phase "spec|plan|implement|review|any" \
     --files "comma,separated,paths" \
     --title "Short title" \
     --body  "What the engineer said" \
     --rule  "The reusable rule extracted" \
     --applies-when "When this rule should activate" \
     --wrong-turns "dead end A,dead end B" \
     --time-cost 12 \
     --evolution-actions "routing|claude_md|reference|hook|none" \
     --memory-type "episodic|semantic|procedural" \
     --supersedes "L-old-id"   # only when this lesson reverses an existing one
   bash "$LS" regen-markdown   # rebuilds tasks/lessons.md

   # v7.14 enrichment (all optional — omit when not applicable):
   #   --wrong-turns      comma-separated dead ends tried, so the next session
   #                      doesn't repeat them (back-compat: absent on old entries)
   #   --time-cost        rough minutes lost to the absence of this rule
   #   --evolution-actions which toolkit asset you changed because of this lesson.
   #                      This is a FORCED decision: pick one. `none` is allowed
   #                      but state why in the body (e.g. "none — one-off, not a pattern").
   #                      A lesson that changed nothing is a lesson that will recur.

   # decision-origin guidance:
   #   claude-recommended-rejected — engineer stopped the approach the model proposed
   #   claude-recommended-modified — engineer accepted the proposal with edits, captured the edit as the rule
   #   user-directed — correction is enforcing a pre-stated engineer constraint the model missed
   ```
   Schema: `.claude/references/learnings-schema.md`.

   **b. Markdown fallback (older repos without `learnings.sh`).** Append to the chosen file (create `.claude/lessons/` if missing). Resolve path to main worktree if in a worktree.
   ```markdown
   ## [Date] — [Short title]

   **Correction:** [What the engineer said]
   **Rule:** [The reusable rule extracted from the correction]
   **Why:** [Why this matters — the underlying principle]
   **Applies to:** [When this rule should activate in future work]
   **Wrong turns:** [Dead ends tried this session, so they aren't repeated — omit if none]
   **Time cost:** [Rough minutes lost — omit if not measurable]
   **Evolution:** [Which toolkit asset you changed because of this: routing / CLAUDE.md / a reference / a hook / none-and-why]
   ```

   The structured form enables 5-layer retrieval (proximity / recurrence / severity / validity / phase) at the start of the next spec or fix. The markdown form remains the team-canonical, committed view.

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

- Correction received but not captured in the chosen destination (`.claude/lessons/personal.md` or `tasks/lessons.md`)
- Lesson captured without the "why" or "applies to" fields
- Same correction given more than twice without proposing a CLAUDE.md rule
- Correction acknowledged performatively but not applied to current work

## Verification

- [ ] The correction was acknowledged without performative agreement
- [ ] A lesson entry was added to the chosen destination (`.claude/lessons/personal.md` or `tasks/lessons.md`)
- [ ] The lesson includes: correction, rule, why, and applies-to
- [ ] Current work was adjusted to follow the correction
- [ ] Repeated patterns were flagged for CLAUDE.md promotion
- [ ] When `scripts/learnings.sh` is present, the lesson was added to `.mtk/learnings.jsonl` and `tasks/lessons.md` regenerated (single source flows through the JSON store)
