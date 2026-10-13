---
description: Schema for review findings emitted by code-review-and-quality
globs: ["**/*"]
alwaysApply: false
---
# Review Finding Schema

Canonical output for every review source (skills, reviewer agents, linters, drift): a markdown
table **plus** a trailing fenced JSON block; the JSON is the source of truth. Hooks may emit
findings-only fragments merged into this envelope. Worked examples and long-form rationale live in
`docs/review-finding-examples.md` — read when authoring a reviewer, not running one.

## JSON Schema

```json
{
  "verdict": "PASS | NEEDS_CHANGES | ABSTAINED",
  "abstention": { "reason": "required when ABSTAINED", "stage": "load-standards | get-diff | review | emit", "checked": [] },
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
    "decision_origin": "optional: user-directed | claude-recommended-approved | claude-recommended-modified | claude-recommended-rejected | system-inferred",
    "failure_mode": "optional F1..F16 from ai-failure-modes.md"
  }],
  "internet_facing": false,
  "needs_human_review": [{ "area": "optional axis", "why": "..." }],
  "below_threshold_rationale": "required when findings[] is empty"
}
```

## Field rules

- `source`: `linter`/`analyzer` always carry `confidence: 100`; `ai` is reasoned; `drift` is spec-drift; `context` is mined history.
- `rule` is the canonical citation; `rule_ref`, `category`, `gate`, `failure_mode`, `decision_origin`, `internet_facing`, `needs_human_review` are optional.
- `decision_origin`, when present, must be one of the five values above (meanings: `docs/review-finding-examples.md`). Emit it when the reviewer knows who made the decision under review; omit it rather than guess.
- There is no score block. Findings and the evidence behind them decide the verdict.

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

There is no findings quota: a clean diff with zero findings is a valid result, explained by `below_threshold_rationale`. Never inflate confidence or pad `findings[]` to avoid an empty list. Drop, and do **not** count, false-positive
categories: pre-existing issues outside the diff, compiler/linter-catchable issues from `source: "ai"`,
style nits not in a loaded guideline, justified silences, plausibly intentional changes, generic
concerns with no concrete vector, guesses needing unloaded context.

## Verdict mapping (in order)

1. Review could not be completed → `ABSTAINED` (`abstention.reason` required; real findings found before stopping are kept but never convert to `PASS`).
2. Any `critical` at/above threshold, or any `gate: "mandatory"` → `NEEDS_CHANGES`.
3. Otherwise → `PASS`, which needs evidence: an empty `findings[]` **requires** `below_threshold_rationale` naming what was checked (`file:line` or the files and axes covered) and why nothing reached the threshold. A PASS without that evidence is not a PASS — the orchestrator records the lane as `ABSTAINED`.

Warnings and suggestions never force `NEEDS_CHANGES`. Remediation on the same blocking finding is
capped at 2 iterations; a third escalates to a human.

## Reviewer contract

Every agent in `.claude/agents/` follows this section; the agent file adds only its own lane.

- **Inputs.** Read the context pack at the path the orchestrator passes (`results.context_pack`)
  instead of the constitution, the tech-stack skill and the guideline files. Standalone (no
  pack): the constitution (`AGENTS.md`, or `CLAUDE.md` in legacy repos — skip it if it is
  already in your context), `.claude/tech-stack` → `.claude/skills/tech-stack-{stack}/SKILL.md`,
  its `## ORM & Data Layer Guidance` and `## Framework Patterns` sections, and from its
  `## Reference Files` only the files your lane names. Read the spec and its JSON
  sidecar when passed. Diff: `git diff --cached`, else `git diff HEAD`.
- **Rules.** Read only the rule files that apply (procedure below), never every file in
  `.claude/rules/`.
- **Threshold.** `.claude/review-config.json` → `thresholds.default`, overridden by
  `review-config.local.json`. Emit the markdown table, then the fenced JSON (source of truth).
  Apply *Confidence and threshold* above; an empty `findings[]` carries a
  `below_threshold_rationale` naming what was checked.
- **Anti-anchoring.** Judge from evidence: the diff, the code, the spec/sidecar and the pack.
  Do not read other lanes' output, earlier review iterations, or planner rationale; if the
  orchestrator passes any, treat it as a pointer to verify, never as a conclusion.
- **ABSTAINED.** If you cannot finish (empty diff, unreadable input, a needed file missing, too
  little context to judge), set `"verdict": "ABSTAINED"` in the JSON with `abstention.reason`
  naming the blocker and what you would need, `abstention.stage`, and `abstention.checked`
  listing what you did complete. Never return a PASS-shaped empty `findings[]` instead: a
  reviewer that did not run must never read as a clean one.

**Rule selection.** (1) If the pack has `## Applicable rules`, read exactly the files it lists,
plus any unmatched file whose globs match a diff path outside the manifest. (2) Otherwise:
`Grep` `^paths:` with `-A 8` over `.claude/rules/` (`glob: "**/*.md"`); a file with no `paths:`
frontmatter is global and applies; a path-scoped file applies when one of its globs (`**` any
depth, `*` one segment) matches a path in `git diff --name-only HEAD`. Read only those. A rule
whose globs miss but whose topic the change plainly needs (a security pass, a release) may be
read too; say why in the rationale.

## Lane accounting (orchestrator)

Each dispatched lane records one of `PASS` · `NEEDS_CHANGES` · `ABSTAINED` · `NO_RESPONSE`.
`NO_RESPONSE` = `ABSTAINED`; the aggregate cannot be `PASS` while any lane abstained (it is
`NEEDS_HUMAN_REVIEW`). Report the roster, dedupe by `(file, line, rule)`, never hide an abstention
behind a retry. With `MTK_WF_UUID` set, count review iterations with `workflow-artifact.sh remediation <uuid> review`.
