---
description: Phase 4 review detail for implement — two-stage procedure, reviewer lane selection, and lane accounting when subagents are unavailable
globs: []
alwaysApply: false
---
# Phase 4 Review — two stages, reviewer lanes, lane accounting

> Extracted from `.claude/skills/implement/SKILL.md` (S2.26: a SKILL.md is a
> navigation layer, not a payload). The skill keeps the decision — when this
> fires, what it outputs, and what stops the run. This file holds the detail,
> and is read **only** when that phase is actually reached.

---

## Phase 4: Review (Two-Stage)

Follow `.claude/skills/code-review-and-quality/SKILL.md`.
Follow `.claude/skills/verification-before-completion/SKILL.md` before starting review.

Stage 1 runs first (spec compliance) because if the implementation doesn't match the spec, code quality review is wasted effort. Within Stage 2, reviewers run in parallel.

### Stage 1: Spec Compliance

Run `compliance-reviewer` with:

- `git diff HEAD`
- the behavioral diff
- the scope classification
- the change manifest summary

The compliance reviewer checks: does the implementation match the approved spec? Are security, architecture, and coding standards met? If **Critical** issues are found, fix them before proceeding to Stage 2.

### Stage 2: Quality and Coverage

Only after Stage 1 passes (no Critical issues). When both reviewers apply, run them **in parallel** — dispatch in a single message with multiple `Agent` tool calls so reviews run concurrently. See `docs/parallelism-patterns.md` for the canonical spawn pattern.

- `test-reviewer` — when the change introduces or changes public behavior
- `architecture-reviewer` — when the change introduces new slices, boundaries, handlers, or cross-project interactions

Size this from the **current** rigor level — the level recomputed in Phase 3.5 if scope was reduced, not the original Phase 2 level. At rigor MAX, run **both** reviewers regardless of the conditions above, plus `silent-failure-hunter` (empty catches, swallowed errors, masking fallbacks). At rigor HIGH, always run `test-reviewer`, but run `architecture-reviewer` only when the boundary/slice condition above holds — a change that adds or moves no modules and crosses no boundary (e.g. a pure rename or frontmatter-only batch) skips it. At LIGHT/STANDARD, the conditions above decide.

Provide all reviewers with the same diff and behavioral diff.

### Lane accounting (both stages)

Every reviewer dispatched in Stage 1 or Stage 2 must be accounted for before Phase 5.
Record one outcome per lane — `PASS`, `NEEDS_CHANGES`, `ABSTAINED`, or `NO_RESPONSE` — per
**Lane Accounting** in `.claude/references/review-finding-schema.md`.

- A subagent that returns null, errors out, times out, or emits unparseable output is
  `NO_RESPONSE`, which counts as `ABSTAINED`. **Silence is not assent** — the `Agent` tool
  returns null on terminal errors, and an unfiltered null must never be read as a clean pass.
- **Phase 4 cannot be reported as passing while any lane is `ABSTAINED` or `NO_RESPONSE`.**
  Either re-dispatch that lane (recording both attempts) or escalate to a human. A review
  the toolkit could not complete is an open question, not an approval.
- State the roster in the final report: reviewers dispatched, outcome of each, and the
  reason for any abstention. A finding count alone hides a lane that never ran.
- If ceremony was reduced for this run — reviewers skipped, or run inline instead of as
  forked agents — that is itself an abstention-shaped event. Record the skipped lanes as
  `ABSTAINED` with the reason, rather than reporting a clean two-stage review that did not
  happen.
- **`ABSTAINED(by-policy)` — the one abstention that does not block Phase 4.** When the
  Phase 2.9 probe recorded `dispatch_capability=forbidden|unavailable`, a lane that could not
  be forked is not an open question about the code; it is a known property of the session. Such
  a lane records `ABSTAINED (by-policy: <reason>; compensations C1-C3)` and Phase 4 may pass —
  **but only if** the inline-MAX compensations were actually applied and named, and the final
  report states which lanes ran inline. Without the compensations recorded, it is an ordinary
  `ABSTAINED` and still blocks. This is the difference between a substitute and an excuse: a
  lane whose isolation was replaced is accounted for, a lane that simply did not run is not.
