---
description: Schema for review findings emitted by code-review-and-quality
globs: ["**/*"]
alwaysApply: false
---
# Review Finding Schema

Canonical output format for reviews across the toolkit: `pre-commit-review`,
`code-review-and-quality`, `compliance-reviewer`, and future linter
or drift-detection sources. Every review produces a human-readable markdown
table **plus** a trailing fenced JSON block. The JSON is the source of truth;
the table is rendered from it for scanning.

Producer note: some deterministic hooks emit **findings-only fragments** that are
later merged into the canonical review object. The schema below defines the
full review envelope expected from review skills and reviewer agents.

## JSON Schema

```json
{
  "verdict": "PASS | NEEDS_CHANGES | ABSTAINED",
  "abstention": {
    "reason": "Required when verdict is ABSTAINED. One line: what stopped the review.",
    "stage": "load-standards | get-diff | review | score | emit",
    "checked": ["axes that WERE completed before the reviewer gave up"]
  },
  "threshold": 80,
  "summary": {
    "critical": 0,
    "warning": 0,
    "suggestion": 0,
    "filtered_below_threshold": 0
  },
  "findings": [
    {
      "id": "F001",
      "severity": "critical",
      "confidence": 95,
      "rule": "<e.g., §1.1 / Coding Guidelines — LINQ / SECRET-HARDCODED>",
      "rule_ref": "<optional external rule ref such as OWASP A03:2021>",
      "category": "<optional category such as security | architecture | tests>",
      "gate": "<optional gate flag such as mandatory>",
      "source": "ai | linter | drift | analyzer | context",
      "file": "relative/path/to/file.ext",
      "line": 42,
      "rationale": "One-line statement of why this is a problem.",
      "suggested_fix": "One-line description of the remediation.",
      "decision_origin": "user-directed | claude-recommended-approved | claude-recommended-modified | claude-recommended-rejected | system-inferred",
      "failure_mode": "F1 | F2 | F3 | ... | F14 (optional — cite an F-code from ai-failure-modes.md when the finding matches a catalogued mode)"
    }
  ],
  "scores": {
    "correctness": { "value": 8, "evidence": "src/Order.cs:142", "rationale": "Edge cases for partial fills handled" },
    "security": { "value": 9, "evidence": "src/AuthMiddleware.cs:30", "rationale": "RBAC at service layer; no PII in logs" },
    "test_coverage": { "value": 6, "evidence": "tests/OrderTests.cs:1", "rationale": "Happy path only; cancellation path untested" },
    "architecture_fit": { "value": 8, "evidence": "src/Orders/", "rationale": "Stays within slice; no cross-project access" },
    "simplicity": { "value": 7, "evidence": "src/Orders/Handlers.cs:55", "rationale": "Could collapse two helpers but acceptable" }
  },
  "internet_facing": false,
  "needs_human_review": [
    {
      "area": "<optional review axis such as business-logic>",
      "why": "<why the AI cannot fully validate this axis from the diff alone>"
    }
  ],
  "below_threshold_rationale": "Required when findings[] has < 2 entries."
}
```

The `source` field distinguishes deterministic linter findings from AI
reasoning and spec-drift checks. Static linters emit `source: "linter"`
with confidence always `100`. AI findings emit `source: "ai"`.
Analyzer findings (from Roslyn, ruff, tsc, biome) emit `source: "analyzer"` with confidence always `100`.
Context-miner findings (from `git log`/`git blame` history, PR/issue threads, learnings query) emit `source: "context"`.

`failure_mode` is optional. When a finding matches one of the catalogued AI failure modes in `.claude/references/ai-failure-modes.md`, cite its F-code (e.g., `"failure_mode": "F1"`). This enables aggregation by failure mode across reviews and surfaces patterns in AI-generated code. Omit the field when no F-code matches.

- `rule` remains the canonical citation field used across all findings.
- `rule_ref` is optional and reserved for external standards naming, such as
  OWASP categories or analyzer rule IDs that should surface separately from the
  human-readable `rule` citation.
- `gate` is optional and only used when a finding forces verdict semantics beyond
  the normal confidence threshold mapping.
- `internet_facing` and `needs_human_review` are optional top-level fields used
  by review flows that need to declare boundary exposure or explicitly hand an
  axis back to a human reviewer.

## Markdown Table Template

```
| ID   | Sev      | Conf | Src   | File:Line    | Rule | Issue                          |
|------|----------|------|-------|--------------|------|--------------------------------|
| F001 | critical |   95 | ai    | src/X.cs:42  | §1.1 | Hardcoded connection string    |
```

## Confidence Rubric

Confidence reflects how certain the reviewer is that the finding is a real
problem — **not** how severe the problem is.

| Band              | Range   | Meaning |
|-------------------|---------|---------|
| Deterministic     | 95–100  | Exact pattern match. Regex-detected secret, visible SQL concatenation, missing `[Authorize]` on an `[ApiController]`. Linter-grade certainty. |
| High              | 85–94   | Clear rule violation with unambiguous evidence in the diff. N+1 query, missing audit log on financial mutation. |
| Solid             | 80–84   | Rule violation requiring one reasonable inference ("this looks like PII going to logs"). |
| Moderate          | 70–79   | Judgment call. Alternative readings exist. |
| Speculative       | 50–69   | Might be wrong given context we don't have. |
| Below report floor| < 50    | Do not report. |

## Threshold

Default: `80`. Configured in `.claude/review-config.json` under
`thresholds.default`. Per-engineer overrides live in
`.claude/review-config.local.json`. Commands may accept a per-invocation
override where documented.

Only findings with `confidence >= threshold` appear in `findings[]`.
Below-threshold findings are counted in `summary.filtered_below_threshold`.

## Empty-Findings Rule (Anti-Sandbagging)

If `findings[]` has fewer than 2 entries, `below_threshold_rationale` is
**required**. State:

1. Number of below-threshold findings suppressed (if any).
2. Classes of issues actively checked (security, architecture, data layer,
   tests, performance).
3. Why the reviewer concludes the code is genuinely clean, vs. "I didn't
   look hard enough."

An empty review without rationale is not a valid review.

## Anti-Inflation Rule

Confidence is bounded by evidence, not by the reviewer's desire to hit the
≥2-findings bar. If the honest confidence is 65, report it as 65 (and it
will be filtered). Do **not** promote it to 80 to force a surface. Inflating
confidence to manufacture findings is a review failure.

## False-Positive Exclusion List

Before assigning confidence, drop the candidate entirely if it falls into any
of these categories. These are not "low-confidence findings to suppress" —
they are not findings at all and must not enter the schema.

1. **Pre-existing issues outside the diff.** A bug exists, but the lines that
   produce it were not touched in this change. Out of scope for this review.
2. **Linter / typechecker / compiler-catchable issues.** Missing imports, type
   errors, formatting, broken builds. CI handles these. Do not surface them
   from `source: "ai"`. Deterministic sources (`linter` / `analyzer`) emit
   them with `confidence: 100` — that is the correct path.
3. **Pedantic style nits not enumerated in the loaded coding guidelines.** If
   the rule is not in the active tech stack's coding guidelines, in
   `.claude/rules/*.md`, or in a loaded reference, the reviewer's personal
   preference is not a finding.
4. **Issues silenced explicitly in code with a stated reason.** A
   `// eslint-disable — <why>`, `# noqa: E501  # <why>`, or inline comment
   justifying the deviation is an accepted trade-off. Flag only when the
   silence carries no justification.
5. **Plausibly intentional functional changes related to the stated purpose.**
   If the diff's stated purpose plausibly explains the behavior shift, do not
   flag it as a regression. Behavioral-diff mismatches still count — they are
   the explicit signal that actual code diverges from declared intent.
6. **Generic concerns without a concrete vector.** "Could be more secure",
   "lacks tests" without naming the missing path, "might not scale". Either
   produce a specific finding (file, line, named risk) or drop it.
7. **Issues that depend on context the reviewer did not load.** If three more
   files would be needed to confirm, either read them or escalate to
   `NEEDS_CONTEXT`. Do not emit a guess as a finding.

When a candidate matches one of these categories, **do not** count it in
`summary.filtered_below_threshold`. That counter tracks honest findings that
fell below the confidence floor, not non-findings excluded by category.

If a candidate is borderline between "real but low-confidence" and "FP
category", prefer the FP category and drop it. The cost of a noisy review is
higher than the cost of a missed minor issue — major issues survive any
honest filter.

## Verdict Mapping

- **Review could not be completed → `ABSTAINED`** (evaluated first; see below)
- Any `critical` finding at or above threshold → `NEEDS_CHANGES`
- Any finding with `gate: "mandatory"` → `NEEDS_CHANGES`
- **Any `scores.<dim>.value < 7` → `NEEDS_CHANGES`** (per the scored-evaluator contract)
- **Uniform `scores` (all five values equal) → `NEEDS_CHANGES` with reason `non-discriminating`**
- Otherwise → `PASS`

Warnings and suggestions do not force `NEEDS_CHANGES` but should be addressed.

## ABSTAINED — a lane that did not run is not a clean lane

`PASS` and `NEEDS_CHANGES` both assert that a review *happened*. A reviewer that errored,
timed out, could not read the diff, ran out of context, or produced unparseable output has
asserted nothing — and the single most dangerous thing it can do is emit an empty
`findings[]`, because downstream that is indistinguishable from "I looked and it is clean."

**A missing reviewer must never read as a clean one.**

Emit `ABSTAINED` when any of these hold:

- Required standards, the diff, or the files under review could not be loaded.
- The change is too large or too unfamiliar to review honestly within budget.
- The reviewer would otherwise emit an empty `findings[]` **without** being able to write an
  honest `below_threshold_rationale` naming what it checked.
- Any error, timeout, or truncation prevented completing the axes the reviewer owns.

Rules for an abstaining reviewer:

- `abstention.reason` is **required** and must name the concrete blocker — not "unable to
  complete". `"git diff returned empty and no files were supplied"` is a reason.
- `abstention.checked` lists axes genuinely completed before stopping. Partial work is still
  useful; claiming coverage that did not happen is not.
- `findings[]` may contain real findings discovered before abstaining. They are reported,
  but they do **not** convert the verdict to `PASS`.
- `scores` may be omitted entirely. A dimension that was not evaluated must **not** be
  scored — inventing a 7 to fill the schema is the exact failure this verdict exists to stop.
- Never choose `ABSTAINED` to dodge work. Abstention is for genuine inability, not
  reluctance. A reviewer that can review and does not is failing, not abstaining.

## Lane Accounting (orchestrator contract)

An orchestrator that dispatches N reviewer lanes must account for all N. For each lane
record exactly one outcome:

| Outcome | Meaning |
|---|---|
| `PASS` | Reviewer ran and found nothing blocking |
| `NEEDS_CHANGES` | Reviewer ran and found blocking issues |
| `ABSTAINED` | Reviewer ran and reported it could not complete |
| `NO_RESPONSE` | Lane was dispatched and never returned (crash, null, timeout) |

Binding rules:

1. **A dispatched lane that returns nothing is `NO_RESPONSE`, and `NO_RESPONSE` is treated
   exactly as `ABSTAINED`.** Silence is not assent.
2. **The overall verdict cannot be `PASS` while any lane is `ABSTAINED` or `NO_RESPONSE`.**
   The aggregate is `NEEDS_HUMAN_REVIEW`: the change may be fine, but the toolkit did not
   establish that.
3. **Report the roster, not just the findings.** State which lanes ran, which abstained, and
   why. "3 reviewers, 0 findings" is not a reportable result when one of the three abstained.
4. **Corroboration outranks volume.** When lanes overlap, a finding raised independently by
   two lanes ranks above one raised loudly by a single lane. Dedupe by `(file, line, rule)`.
5. **Never silently re-dispatch to turn an abstention into a pass.** A retry is allowed; the
   abstention still appears in the roster with both attempts recorded.

## Scores Block (Scored Adversarial Evaluator)

Every review (compliance and code-review-and-quality) MUST emit a `scores` object with five dimensions: `correctness`, `security`, `test_coverage`, `architecture_fit`, `simplicity`.

**Per-dimension contract:**
- `value` — integer 1–10 (9–10 exemplary · 7–8 acceptable · 4–6 blocks · 1–3 severe).
- `evidence` — file:line citation. A score without evidence is treated as 0 (auto-fail).
- `rationale` — one-line explanation tying the score to the evidence.

**Auto-fail rules** (enforced by reviewers, not the schema):
1. Any `value < 7` → block.
2. All five `value`s equal → reject as `non-discriminating`.
3. Missing `evidence` → score becomes 0 → block.

**Iteration cap.** Orchestrators cap remediation at 2 iterations on the same blocking dimension. A third iteration that would still score < 7 on the same dimension escalates to a human reviewer.

**Workflow artifact integration.** When `MTK_WF_UUID` is set, the orchestrator emits per-dimension scores into `results.review_scores.<dim>` plus `results.review_iteration` for cycle tracking.

## Decision-Origin Tagging

Every finding carries a `decision_origin` field that records who or what produced the underlying decision. The five values map to authorship in the conversation:

| Value | Meaning |
|---|---|
| `user-directed` | The decision under review was explicitly directed by the engineer (e.g. "use repository pattern", "no cache layer"). The reviewer is checking conformance to a stated requirement. |
| `claude-recommended-approved` | The model proposed an approach, the engineer accepted it without modification. The reviewer is checking a model-proposed design that wasn't pushed back on. |
| `claude-recommended-modified` | The model proposed an approach, the engineer modified it before accepting. The final shape reflects engineer judgement applied to a model proposal. |
| `claude-recommended-rejected` | The model proposed an approach, the engineer rejected it; the implementation went a different way. The reviewer is checking the engineer-chosen alternative. |
| `system-inferred` | Neither user-directed nor model-proposed — emerged from a deterministic gate, lint rule, or schema constraint. |

**Required at emit time.** Reviewer agents and skills emit `decision_origin` for every finding. Findings with a missing or invalid value are rejected by the review-output validator (run by `validate-toolkit.sh --strict-decision-origin`).

**Why it matters.** The distribution of `decision_origin` values across a workstream reveals provenance: a stream dominated by `claude-recommended-approved` signals that the engineer is accepting model recommendations without pushback (sycophancy risk). The metric is operationalised as the **sycophancy index (π)**:

```
π = approved / (approved + modified + rejected)
```

Computed over the last 30 days of learnings and reviews by `bash scripts/learnings.sh metrics`. The default warn threshold is `0.70` and is tunable via `.claude/review-config.json` (`sycophancy_index.warn_threshold`). Crossing the threshold is a process signal, not an error — it surfaces in `toolkit-health` and prompts a deliberate re-read of the last few recommendations.
