---
name: golden-path-capture
description: Use when you struggle with the same sub-problem 2+ times in the current session and then find a working approach — capture the failed attempts and the fix as a reusable lesson, no engineer correction required.
type: skill
license: MIT
compatibility:
  - claude-code
  - cursor
  - codex
trigger: self-struggle-then-success|repeated-failure-same-signature|trial-and-error-resolved|found-working-approach
skip_when: first-attempt-succeeded|engineer-correction|one-off-flake|already-documented
user-invocable: false
---

# Golden Path Capture

## Overview

The moment of highest lesson-density is when *you* — not the engineer — get stuck. You try the same sub-problem, hit the same failure signature 2+ times, then switch to a materially different approach that works. That struggle-then-success arc contains exactly the knowledge a future session needs: the dead ends to avoid and the golden path that resolved them. Left uncaptured, it is lost until a later mining sweep happens to notice it — if it ever does. Capture it immediately, in-session.

This skill sits between two siblings; keep the three distinct:

- **`correction-capture`** — engineer-driven. Fires when the *human* says "no", "stop", "not like that", or redirects your approach. The knowledge originates from a person.
- **`golden-path-capture`** (this skill) — self-driven. Fires when *you* resolve your own repeated failure through trial and error, with **no** engineer correction involved. The knowledge originates from your own struggle.
- **`lesson-mining`** — after-the-fact. A periodic sweep of past session *transcripts*, reject-by-default, suggest-only. It is the safety net that catches what live capture missed; this skill is the live capture that means the sweep rarely has to.

The capture reuses `correction-capture`'s destinations and the same `scripts/learnings.sh add` structured path — do not invent a new storage format. Frame the lesson around `wrong_turns` (the failed attempts) and `time_cost` (minutes the loop cost), because those are precisely what this trigger produces.

## When To Use

- The same file, error message, or failure signature has failed 2+ times this session, then a **materially different** approach succeeded
- You looped on a build/test/config error, changed strategy, and it finally passed
- You discovered a non-obvious constraint the hard way (an API shape, an ordering requirement, a hidden dependency) after repeated attempts
- The resolution is durable — a future session hitting the same signature would benefit from knowing the golden path up front

### When NOT To Use

- The first attempt succeeded — there is no struggle arc to capture
- The engineer corrected or redirected you — that is `correction-capture`, not this skill
- A one-off flake (a transient network error, a machine hiccup) that resolved itself with no new insight
- The new approach is not materially different — you just retried the same thing and it happened to work
- The lesson is already documented in CLAUDE.md, references, or an existing lesson

## Workflow

1. **Recognize the struggle-then-success arc.** Confirm all three, honestly:
   - **Repetition:** the same file / error / failure signature failed **2+ times** this session (not two different problems that each failed once).
   - **No engineer correction:** the human did not say "no"/"stop"/redirect. This is your own trial-and-error. If they did correct you, stop and use `correction-capture` instead.
   - **Material change:** the approach that worked is genuinely different from the ones that failed — not a retry of the same thing.

2. **Name the failure signature and the golden path.** State plainly:
   - What kept failing and why (the shared root cause of the failed attempts).
   - What the working approach was, and *why* it works where the others did not.
   - Do not narrate performatively ("finally got it!") — just record the signature and the fix.

3. **Decide where it belongs — personal or team.** Same two destinations as `correction-capture`:
   - `.claude/lessons/personal.md` (gitignored) — default. Individual workflow discoveries, "when I hit X here, do Y".
   - `tasks/lessons.md` (committed) — team-wide. A codebase-level constraint or pattern every contributor would hit the same way.

   **Heuristic:** first-person / individual-workflow → personal. Codebase/architecture/team-wide constraint → ask before writing to the team file. When in doubt → personal; promotion is explicit via `/promote-lesson`.

4. **Check for prior lessons.** Grep both files for keywords from the failure signature before capturing. If a similar lesson exists, update it (bump recurrence) instead of duplicating.
   ```bash
   grep -i "<keyword>" .claude/lessons/personal.md tasks/lessons.md 2>/dev/null
   ```
   When *replacing* an existing lesson (vs. appending), write to a temp file and promote via `mtk_guarded_write` so a partial regenerate cannot truncate the file. Pure appends are safe.

5. **Capture the lesson — structured + markdown.**

   **a. Structured (preferred when `scripts/learnings.sh` is present).** The distinctive fields for this skill are `--wrong-turns` (the failed attempts) and `--time-cost` (minutes the loop cost) — populate them; they are what the trigger produces. Use `--source golden-path`. Since this is self-driven trial-and-error with no human or model *recommendation*, the decision origin is `system-inferred`.
   ```bash
   bash scripts/learnings.sh add \
     --workflow "${MTK_WF_UUID:-manual}" \
     --scope "personal|team" \
     --source golden-path \
     --decision-origin system-inferred \
     --severity "info|warn|block" \
     --phase "spec|plan|implement|review|any" \
     --files "comma,separated,paths" \
     --title "Short title — the golden path, not the struggle" \
     --body  "What kept failing (the signature) and what finally worked" \
     --rule  "The reusable rule: when you hit <signature>, do <golden path>" \
     --applies-when "When this rule should activate (file/error signature)" \
     --wrong-turns "failed attempt A — why it failed,failed attempt B — why it failed" \
     --time-cost 15 \
     --evolution-actions "routing|claude_md|reference|hook|none"
   bash scripts/learnings.sh regen-markdown   # rebuilds tasks/lessons.md
   ```
   - `--wrong-turns` — the dead ends you tried, each with a one-line why, so the next session doesn't repeat them. This is the core of a golden-path lesson.
   - `--time-cost` — rough minutes lost to the loop. Makes the value of the golden path concrete.
   - `--evolution-actions` — a FORCED decision: if you repeatedly hit this signature, the fix may belong in CLAUDE.md, a reference, or a hook, not just a lesson. `none` is allowed but state why in the body.
   - `--source golden-path` is a new but consistent free-text source value (`learnings.sh add` accepts `--source` as pass-through; only `--decision-origin` is enum-validated). It lets retrieval and metrics distinguish self-driven captures from engineer corrections.

   Schema: `.claude/references/learnings-schema.md`.

   **b. Markdown fallback (older repos without `learnings.sh`).** Append to the chosen file (create `.claude/lessons/` if missing). Resolve path to main worktree if in a worktree.
   ```markdown
   ## [Date] — [Short title — the golden path]

   **Failure signature:** [What kept failing, 2+ times, and the shared root cause]
   **Golden path:** [The materially different approach that worked, and why]
   **Rule:** [When you hit <signature>, do <golden path>]
   **Applies to:** [When this rule should activate in future work]
   **Wrong turns:** [Each failed attempt + why it failed — so they aren't repeated]
   **Time cost:** [Rough minutes lost to the loop]
   **Evolution:** [Which toolkit asset you changed because of this: routing / CLAUDE.md / a reference / a hook / none-and-why]
   ```

   The structured form enables 5-layer retrieval (proximity / recurrence / severity / validity / phase) at the start of the next spec or fix. The markdown form remains the team-canonical, committed view.

6. **Check for pattern.** If the same failure signature has been captured before:
   - Personal: bump recurrence — a stable self-struggle is a strong signal.
   - Team: if it recurs (3+), escalate — propose a CLAUDE.md rule or a reference note so the golden path is loaded up front and the loop never happens again. A recurring self-struggle that changed nothing will recur.

7. **Capture now — do not defer.** Write the lesson in-session, at the moment of resolution. Do **not** wait for Phase 7 (compound), the post-ship retro, or a later `lesson-mining` sweep — that is exactly the loss this skill exists to prevent.

## Rules

- Require the full arc before capturing: 2+ failures on the same signature, no engineer correction, and a materially different fix. Two unrelated one-off failures are not a golden path.
- The `wrong_turns` are not filler — they are the payload. A golden-path lesson without its dead ends teaches only half the lesson.
- Record `time_cost` whenever it is measurable; it is the evidence that this loop was expensive enough to be worth preventing.
- Extract the general rule (the signature → golden path mapping), not just this one instance.
- Never confuse this with `correction-capture`. If a human redirected you, it is a correction, full stop.
- Capture in-session. A golden path deferred to a later sweep is a golden path usually lost.

## Common Rationalizations

See `.claude/skills/context-engineering/SKILL.md` for the shared table. Golden-path-specific traps: "I figured it out myself, so there's nothing to record" (self-figured-out is the *whole point* — the struggle you resolved is the highest-density lesson there is), "I'll let the lesson-mining sweep catch this later" (the sweep is the safety net for what live capture missed; do not offload live capture onto it), "it only failed a couple of times, not a real pattern" (2+ on the same signature is the bar — it already cleared it), and "the wrong turns are embarrassing, I'll just record the fix" (the wrong turns are what stop the next session repeating them — record them).

## Red Flags

- A struggle-then-success arc resolved but no lesson captured before moving on
- Lesson captured with an empty or omitted `wrong_turns` — the failed attempts were dropped
- Capturing something the engineer actually corrected (belongs in `correction-capture`)
- Deferring capture to Phase 7 or a future `lesson-mining` sweep instead of writing it now
- A recurring self-struggle (3+) captured as a lesson but never proposed for CLAUDE.md / reference promotion
- Recording a single-attempt success or a transient flake as a golden path

## Verification

- [ ] The full arc was confirmed: same signature failed 2+ times, no engineer correction, materially different fix
- [ ] A lesson entry was added to the chosen destination (`.claude/lessons/personal.md` or `tasks/lessons.md`)
- [ ] The lesson includes the failure signature, the golden path, the rule, and applies-to
- [ ] `wrong_turns` were recorded (the failed attempts), and `time_cost` when measurable
- [ ] The lesson was captured in-session, not deferred to a retro or mining sweep
- [ ] When `scripts/learnings.sh` is present: added via `--source golden-path` with `--decision-origin system-inferred`, and `tasks/lessons.md` regenerated
- [ ] Recurring signatures (3+) were flagged for CLAUDE.md / reference promotion
