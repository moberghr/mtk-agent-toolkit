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

## Verdict Mapping

- Any `critical` finding at or above threshold → `NEEDS_CHANGES`
- Any finding with `gate: "mandatory"` → `NEEDS_CHANGES`
- Otherwise → `PASS`

Warnings and suggestions do not force `NEEDS_CHANGES` but should be addressed.
