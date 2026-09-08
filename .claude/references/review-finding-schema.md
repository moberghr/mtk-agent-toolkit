---
description: Schema for review findings emitted by code-review-and-quality
globs: ["**/*"]
alwaysApply: false
---
# Review Finding Schema

Canonical output for every review source (skills, reviewer agents, linters, drift): a markdown
table **plus** a trailing fenced JSON block; the JSON is the source of truth. Hooks may emit
findings-only fragments merged into this envelope. Worked examples and long-form rationale live in
`.claude/references/review-finding-examples.md` — read when authoring a reviewer, not running one.

## JSON Schema

```json
{
  "verdict": "PASS | NEEDS_CHANGES | ABSTAINED",
  "abstention": { "reason": "required when ABSTAINED", "stage": "load-standards | get-diff | review | score | emit", "checked": [] },
  "threshold": 80,
  "summary": { "critical": 0, "warning": 0, "suggestion": 0, "filtered_below_threshold": 0 },
  "findings": [{
    "id": "F001", "severity": "critical | warning | suggestion", "confidence": 95,
    "rule": "§1.1 / Coding Guidelines — LINQ / SECRET-HARDCODED",
    "rule_ref": "optional, e.g. OWASP A03:2021", "category": "optional", "gate": "optional, e.g. mandatory",
    "source": "ai | linter | drift | analyzer | context",
    "file": "relative/path.ext", "line": 42,
    "rationale": "one line: why this is a problem",
    "suggested_fix": "one line: the remediation",
    "decision_origin": "user-directed | claude-recommended-approved | claude-recommended-modified | claude-recommended-rejected | system-inferred",
    "failure_mode": "optional F1..F14 from ai-failure-modes.md"
  }],
  "scores": { "<dim>": { "value": 8, "evidence": "file:line", "rationale": "one line" } },
  "internet_facing": false,
  "needs_human_review": [{ "area": "optional axis", "why": "..." }],
  "below_threshold_rationale": "required when findings[] has < 2 entries"
}
```

## Field rules

- `source`: `linter`/`analyzer` always carry `confidence: 100`; `ai` is reasoned; `drift` is spec-drift; `context` is mined history.
- `rule` is the canonical citation; `rule_ref`, `category`, `gate`, `failure_mode`, `internet_facing`, `needs_human_review` are optional.
- `decision_origin` is **required** on every finding (validated by `validate-toolkit.sh --strict-decision-origin`).
- `scores` has exactly five dimensions: `correctness`, `security`, `test_coverage`, `architecture_fit`, `simplicity`. `value` is 1–10; `evidence` is a `file:line`; a score without evidence counts as 0.

## Markdown table

```
| ID   | Sev      | Conf | Src | File:Line   | Rule | Issue |
|------|----------|------|-----|-------------|------|-------|
| F001 | critical |   95 | ai  | src/X.cs:42 | §1.1 | Hardcoded connection string |
```

## Confidence and threshold

Confidence = certainty the finding is real, not its severity. Bands: 95–100 deterministic ·
85–94 clear violation · 80–84 one inference · 70–79 judgment call · 50–69 speculative ·
<50 do not report. Default threshold `80` (`.claude/review-config.json` → `thresholds.default`,
per-engineer override in `review-config.local.json`). Only `confidence >= threshold` enters
`findings[]`; the rest are counted in `summary.filtered_below_threshold`.

Never inflate confidence to reach the ≥2-findings bar. Drop, and do **not** count, false-positive
categories: pre-existing issues outside the diff, compiler/linter-catchable issues from `source: "ai"`,
style nits not in a loaded guideline, justified silences, plausibly intentional changes, generic
concerns with no concrete vector, guesses needing unloaded context.

## Verdict mapping (in order)

1. Review could not be completed → `ABSTAINED` (`abstention.reason` required; `scores` may be omitted; real findings found before stopping are kept but never convert to `PASS`).
2. Any `critical` at/above threshold, or any `gate: "mandatory"` → `NEEDS_CHANGES`.
3. Any `scores.<dim>.value < 7`, or all five values equal (`non-discriminating`) → `NEEDS_CHANGES`.
4. Otherwise → `PASS`. `findings[]` with < 2 entries **requires** `below_threshold_rationale`.

Warnings and suggestions never force `NEEDS_CHANGES`. Remediation on one blocking dimension is
capped at 2 iterations; a third escalates to a human.

## Lane accounting (orchestrator)

Each dispatched lane records one of `PASS` · `NEEDS_CHANGES` · `ABSTAINED` · `NO_RESPONSE`.
`NO_RESPONSE` = `ABSTAINED`; the aggregate cannot be `PASS` while any lane abstained (it is
`NEEDS_HUMAN_REVIEW`). Report the roster, dedupe by `(file, line, rule)`, never hide an abstention
behind a retry. With `MTK_WF_UUID` set, emit `results.review_scores.<dim>` + `results.review_iteration`.
