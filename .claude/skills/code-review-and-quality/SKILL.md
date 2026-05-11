---
name: code-review-and-quality
description: Use after implementation is verified and before merge, or when reviewing a PR, to check correctness, security, architecture, and test quality against project standards.
type: skill
license: MIT
compatibility:
  - claude-code
  - codex
trigger: post-implementation|pr-review|merge-safety-check|quality-audit
skip_when: no-behavioral-diff|pre-implementation-phase
effort: max
context: fork
user-invocable: false
---

# Code Review And Quality

## Current Diff Context

```!
echo "--- Branch ---"
git branch --show-current 2>/dev/null || echo "(detached)"
echo "--- Tech Stack ---"
cat .claude/tech-stack 2>/dev/null || echo "(not set)"
echo "--- Diff stat ---"
git diff --stat HEAD 2>/dev/null || git diff --stat --cached 2>/dev/null || echo "(no diff)"
```

## Overview

Review changed code as an adversary, not a collaborator. The review must prioritize real risks over style and decide whether the change improves overall code health.

## When To Use

- After implementation and verification
- For PR review or merge-safety checks
- When a change touches audited state, auth, data integrity, or infra
- After bug fixes, including review of the regression test

### When NOT To Use

- Before the implementation has a coherent behavioral diff or verification story

## Workflow

1. Load standards:
   - `CLAUDE.md`
   - `.claude/tech-stack` to identify the active stack, then `.claude/skills/tech-stack-{stack}/SKILL.md` for stack-specific reference paths
   - The coding guidelines and other reference files listed in the tech stack's `## Reference Files` section
   - `.claude/references/security-checklist.md`
   - `.claude/references/testing-patterns.md`
   - `.claude/references/performance-checklist.md`
   - If a domain supplement exists (e.g. `.claude/references/domain-finance.md`), load it for domain-specific rationalizations
2. Read the behavioral diff if provided.

### CI Context (if available)

If reviewing a PR or branch with CI runs, check CI status:
1. Run `bash hooks/ci-status.sh` to get check run results
2. If CI failed, note which checks failed — the review should focus on those areas
3. If CI passed, note any warnings from the build output (`.mtk/analyzer-output.json`)
4. If `hooks/ci-status.sh` is not available or `gh` is not installed, proceed without CI context

3. Review across these axes:
   - correctness — including **stub detection** per `.claude/references/stub-detection.md` (empty bodies, `NotImplementedException`, suspect `return null`/`[]`/`{}`, mock data in production paths, unwired handlers)
   - readability and simplicity
   - architectural fit
   - security and compliance
   - performance and scaling risk
   - test quality and verification strength
4. Route specialized review when needed:
   - `compliance-reviewer` for security/compliance-sensitive work
   - `test-reviewer` for coverage and verification quality
   - `architecture-reviewer` for boundary and slice integrity concerns
   - `silent-failure-hunter` when the diff touches error handling — dispatch
     when `git diff` matches any of `\b(catch|except|finally)\b`,
     `\.catch\(`, `\?\?`, `\|\|`, or adds `// eslint-disable`, `# noqa`,
     `@ts-ignore`, `@ts-expect-error`, `Skip =`, `it\.skip`, `xit\(`.
     Run in parallel with `compliance-reviewer`; merge findings, dedupe by
     `(file, line, rule)`. The hunter emits `category: "error-handling"`
     so dedupe is straightforward.
5. Categorize findings per the schema in `.claude/references/review-finding-schema.md`:
    - Apply the **False-Positive Exclusion List** in that schema before
      scoring confidence — drop candidates that match an FP category rather
      than scoring them low
    - `critical`, `warning`, `suggestion` severities
    - `confidence` score 0–100 per the rubric
    - Optional top-level fields only when they add real signal: `internet_facing`
      for boundary exposure and `needs_human_review` for axes the AI cannot
      honestly clear from the diff alone
6. **Score the five dimensions (1–10).** Borrowed from sanmak/specops (`core/evaluation.md`).
   Assign one score per dimension and cite at least one **file:line evidence quote** per score (high or low):
   - `correctness` — does the code do what the spec said? Edge cases? Invariants?
   - `security` — auth, secrets, input validation, audit, supply chain
   - `test_coverage` — public behaviors tested? error paths exercised? assertions meaningful?
   - `architecture_fit` — slices, boundaries, patterns honored?
   - `simplicity` — fewer files / abstractions / moving parts feasible?

   **Score rubric:** 9–10 exemplary · 7–8 acceptable · 4–6 blocks merge · 1–3 severe.

   **Auto-fail rules:**
   - Any dimension < 7 → verdict `NEEDS_CHANGES` regardless of finding count.
   - Uniform scores across all five dimensions → review rejected as **non-discriminating**. Vary the scores or revisit; at least one must differ.
   - A score without a `file:line` evidence quote → treated as 0 (auto-fail).

   **Iteration cap.** If a dimension has scored < 7 in two prior iterations and a third iteration would also score it < 7, **stop and escalate to a human**. Automated remediation has stopped converging. Report the dimension, iteration count, and remaining findings.

7. Emit output in the canonical format:
    - Markdown table of surfaced findings (confidence >= threshold from `.claude/review-config.json`, default 80)
    - **Scores table** — 5 dimensions × {score, evidence file:line, one-line rationale}
    - Fenced JSON block with the full structured result (verdict, summary, findings, **scores object**, below_threshold_rationale)
8. If `findings[]` has fewer than 2 entries, populate `below_threshold_rationale` explicitly stating what axes were checked and why the code is genuinely clean. Silent empty reviews are invalid.
9. If a workflow artifact is active (`MTK_WF_UUID` set), record scores:
    `scripts/workflow-artifact.sh set "$MTK_WF_UUID" results.review_scores.<dimension>=<n>` for each of the five dimensions, and `results.review_iteration=<n>` for the current cycle.

## Rules

- Real risks first, style second.
- Missing tests on mutation paths are substantive findings.
- Mismatch between behavioral diff and actual code is a critical finding.
- Security-sensitive changes need explicit scrutiny, not a passing glance.
- Approve changes that improve overall code health even if they are not perfect.

## Common Rationalizations

See `.claude/skills/context-engineering/SKILL.md` for the shared MTK rationalization table. Review-specific traps: authors are blind to their own assumptions (self-review isn't review), "mostly style" is a dodge (real review starts with correctness and risk), and soft-pedaling a real production risk to avoid blocking progress is a review failure.

## Red Flags

- Review with no severity ordering
- Security-sensitive diff with no security-focused findings or explicit clear statement
- No verification story for the implementation
- Large unreviewable change accepted as-is instead of flagged

## Verification

- [ ] Findings are actionable and severity-ordered
- [ ] Review references governing rules or checklists
- [ ] Testing gaps are explicitly called out or explicitly cleared
- [ ] Review verdict matches the actual risk level of the change
- [ ] Output follows `.claude/references/review-finding-schema.md` (markdown table + fenced JSON)
- [ ] Confidence scores follow the rubric; no inflation to hit finding-count bars
- [ ] False-Positive Exclusion List was applied before scoring (no pre-existing-issue, linter-catchable, or unjustified-stylistic items in `findings[]`)
- [ ] `below_threshold_rationale` is populated when fewer than 2 findings surface
- [ ] All five dimensions are scored 1–10 with a file:line evidence quote each
- [ ] No uniform-score review; verdict is `NEEDS_CHANGES` when any dimension < 7
- [ ] Iteration cap respected — third < 7 on the same dimension escalates to human
