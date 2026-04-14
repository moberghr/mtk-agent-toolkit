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
   - correctness
   - readability and simplicity
   - architectural fit
   - security and compliance
   - performance and scaling risk
   - test quality and verification strength
4. Route specialized review when needed:
   - `compliance-reviewer` for security/compliance-sensitive work
   - `test-reviewer` for coverage and verification quality
   - `architecture-reviewer` for boundary and slice integrity concerns
5. Categorize findings per the schema in `.claude/references/review-finding-schema.md`:
   - `critical`, `warning`, `suggestion` severities
   - `confidence` score 0–100 per the rubric
6. Emit output in the canonical format:
   - Markdown table of surfaced findings (confidence >= threshold from `.claude/review-config.json`, default 80)
   - Fenced JSON block with the full structured result (verdict, summary, findings, below_threshold_rationale)
7. If `findings[]` has fewer than 2 entries, populate `below_threshold_rationale` explicitly stating what axes were checked and why the code is genuinely clean. Silent empty reviews are invalid.

## Rules

- Real risks first, style second.
- Missing tests on mutation paths are substantive findings.
- Mismatch between behavioral diff and actual code is a critical finding.
- Security-sensitive changes need explicit scrutiny, not a passing glance.
- Approve changes that improve overall code health even if they are not perfect.

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "The tests pass, so this is fine" | Passing tests do not clear architecture, security, or performance risks. |
| "I wrote it, so I already reviewed it" | Authors are blind to their own assumptions. Review is a separate activity. |
| "This is mostly style" | Real review starts with correctness and risk, not formatting. |
| "I'll mention the issue softly so I don't block progress" | Soft-pedaling a real production risk is a review failure. |

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
- [ ] `below_threshold_rationale` is populated when fewer than 2 findings surface
