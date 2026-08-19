---
name: lesson-refresh
description: Audit the lessons stores for staleness — verify cited paths/symbols, triage each lesson Keep/Update/Consolidate/Retire — suggest-only, retirement is always a human decision.
type: skill
license: MIT
compatibility:
  - claude-code
trigger: refresh-lessons|audit-lessons|stale-lessons|prune-lessons|lessons-cleanup
skip_when: mid-task|no-lessons-file|single-lesson-edit
user-invocable: false
---

# Lesson Refresh

## Overview

Capture is solved (`correction-capture`, `golden-path-capture`, `lesson-mining`,
`promote-lesson`) — but `tasks/lessons.md` and `.claude/lessons/personal.md` are
append-only and grow forever. Nothing checks whether a lesson still matches the
code, consolidates overlapping lessons, or retires superseded ones. A store that
only grows stops being read, and a lesson citing a file that no longer exists
reads as authority while pointing at nothing.

Lesson-refresh is the periodic audit that closes the lifecycle: a deterministic
stale-anchor pre-pass (`scripts/lesson-anchors.sh`), then per-lesson triage into
**Keep / Update / Consolidate / Retire**. It is **suggest-only**: it proposes a
verdict per lesson with evidence; the engineer rules on each. It never deletes —
retirement means marking the entry `> STALE (<date>): <reason>` so the history
stays auditable, and even that marking happens only after explicit approval.

**Prune never decides alone.** The strongest field evidence for this posture: a
comparable tool's first automated prune run scored 56 lessons as dead — and
every single verdict was wrong. Staleness signals locate candidates; they do
not decide.

## When To Use

- The engineer says "refresh lessons", "audit lessons", "are the lessons stale",
  "clean up lessons.md"
- Periodically (once a release cycle) — pairs naturally with `lesson-mining`:
  mining adds, refresh retires
- After a large refactor or file reorganization that likely moved cited paths
- When `mtk-doctor` reports stale lesson anchors

### When NOT To Use

- Mid-task — refresh is a reflective sweep, not an interruption
- To edit one known lesson — just edit it
- To capture new lessons — that is `correction-capture` / `lesson-mining`

## Workflow

1. **Deterministic pre-pass.** Run `bash scripts/lesson-anchors.sh` and collect
   the STALE-PATH / STALE-SYMBOL findings with their rename suggestions. These
   are *location signals*, not verdicts — a stale anchor often means "update the
   citation", not "retire the lesson".
2. **Read the stores.** `tasks/lessons.md` and (if present)
   `.claude/lessons/personal.md`. For each lesson, check its claims against the
   current repo: does the failure mode still exist? Is it now caught by tooling
   (a validator check, a hook, a rule) that postdates the lesson? Does another
   lesson or an S-rule cover the same ground? Prioritize by due-ness: lessons
   whose dated heading is oldest and which no later entry re-confirms get the
   deepest checks — refresh is "check what is due", not "re-litigate everything
   equally". Consult the economics when available: `bash scripts/mtk-savings.sh`
   prints each lesson's context rent and `.mtk/recall-log.jsonl` shows which
   entries actually surface in queries — a lesson with high rent and zero
   recalls is a prime Consolidate/Retire candidate. Data informs the triage;
   it never decides it.
3. **Triage each lesson** into exactly one verdict, with cited evidence:
   - **Keep** — still true, still non-obvious, anchors live. The default; when
     unsure, Keep. Match docs to reality, not the reverse.
   - **Update** — core claim holds but a citation moved or a detail drifted;
     propose the corrected text. Re-anchoring follows unique-match-or-
     unresolvable: a citation is repointed only when exactly one candidate
     matches (the pre-pass rename suggestion); zero or several candidates →
     mark the citation unresolvable in the proposal, never guess.
   - **Consolidate** — materially overlaps another lesson or an existing rule
     (cite the rule id); propose the merged entry, superseding not appending.
   - **Retire** — the failure mode is now mechanically prevented (name the
     guard/check) or the cited subsystem no longer exists. Propose the
     `> STALE (<date>): <reason>` marking, never deletion.
4. **Present the triage table** — one row per lesson: verdict, one-line reason,
   evidence. Lessons verdicted Keep may be listed in a single collapsed line.
   The engineer rules per lesson (accept / reject / edit); batch-accept is the
   engineer's call to make, never the default framing.
5. **Apply only approved rulings.** Updates and consolidations edit in place;
   retirements add the STALE marking above the entry. Mirror accepted changes
   to `.mtk/learnings.jsonl` via `scripts/learnings.sh` where entries exist.
   Appends aside, in-place rewrites of `tasks/lessons.md` go through
   `mtk_guarded_write` (S3.16), and the proposed rewrite must pass
   `bash scripts/growth-gate.sh tasks/lessons.md <proposed>` — a refresh that
   grows the store defeats its purpose; supersede content, don't append to it.

## Verification

- Re-run `bash scripts/lesson-anchors.sh --strict` — accepted updates must
  leave zero stale anchors in lessons the triage touched.
- Every non-Keep verdict in the applied result carries its evidence line.
- No lesson was deleted: retired entries still exist with a STALE marking.
- `bash scripts/validate-toolkit.sh` still passes (the stores are prose, but
  the run guards against accidental structural damage).
