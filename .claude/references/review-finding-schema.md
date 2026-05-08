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
  "verdict": "PASS | NEEDS_CHANGES",
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
      "source": "ai | linter | drift | analyzer",
      "file": "relative/path/to/file.ext",
      "line": 42,
      "rationale": "One-line statement of why this is a problem.",
      "suggested_fix": "One-line description of the remediation."
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

- Any `critical` finding at or above threshold → `NEEDS_CHANGES`
- Any finding with `gate: "mandatory"` → `NEEDS_CHANGES`
- **Any `scores.<dim>.value < 7` → `NEEDS_CHANGES`** (per the scored-evaluator contract)
- **Uniform `scores` (all five values equal) → `NEEDS_CHANGES` with reason `non-discriminating`**
- Otherwise → `PASS`

Warnings and suggestions do not force `NEEDS_CHANGES` but should be addressed.

## Scores Block (Scored Adversarial Evaluator)

Borrowed from sanmak/specops (`core/evaluation.md`). Every review (compliance and code-review-and-quality) MUST emit a `scores` object with five dimensions: `correctness`, `security`, `test_coverage`, `architecture_fit`, `simplicity`.

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
