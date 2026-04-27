# Official Claude Plugins — Borrowed Improvements

- **Date:** 2026-04-25
- **Slug:** official-plugin-borrow-improvements
- **Scope:** new-feature + enhancement
- **Status:** draft (Batch 1 shipped 2026-04-27)

> **Batch 1 correction (post-implementation, 2026-04-27):** On inspection,
> MTK already shipped the full confidence rubric, threshold, anti-inflation,
> and anti-sandbagging machinery on 2026-04-13. The actual Feature 1 gap was
> the named **False-Positive Exclusion List** alone. Batch 1 delivered just
> that addition (~50 lines in `review-finding-schema.md` + reference wiring
> in the skill and agent). SCs 1, 2, 3, 5 were satisfied before this work;
> only SC4 required new content. The spec's "Architecture and Design"
> section for Feature 1 is **descriptive of the existing system, not a
> change set**.

## Summary

Four improvements drawn from a comparative analysis of Anthropic's official Claude Code plugins (`code-review`, `pr-review-toolkit`, `skill-creator`, `claude-md-management`) against MTK. Each addresses a measured gap without compromising MTK's enforcement-first philosophy.

| # | Feature | Source plugin | What changes | Why |
|---|---------|---------------|-------------|-----|
| 1 | **Confidence-scored review with FP exclusion list** | `code-review` | `code-review-and-quality` skill emits findings with 0–100 confidence scores; filters <80; embeds explicit false-positive categories | Cuts reviewer noise; matches the "adversarial but not hysterical" target |
| 2 | **`silent-failure-hunter` reviewer agent** | `pr-review-toolkit` | New `.claude/agents/silent-failure-hunter.md` specialist; dispatched from `code-review-and-quality` when catch blocks / fallbacks change | Adds a focused lens for a recurring serious-software bug class that MTK currently treats as a sub-bullet |
| 3 | **Skill eval harness** | `skill-creator` | New `scripts/skill-eval/` runner that fires test prompts at a skill, grades responses with a sub-agent, reports pass/fail + variance | Turns pressure tests from documentation into runnable evidence; powers the v7.x reproducibility narrative |
| 4 | **CLAUDE.md audit skill** | `claude-md-management` | New `claude-md-audit` skill that grades existing CLAUDE.md against rubric and proposes minimal diffs; complements (does not replace) `setup-bootstrap` | CLAUDE.md is protected (S1.5) and rots silently after bootstrap — needs a re-grade loop |

> **What MTK already has and is NOT changing:** spec/plan versioning, manifest integrity validation, content-addressed pinned coding guidelines, tier-2 deferred skill queue, three-way merge for re-runs. These remain MTK's differentiators.

---

## Success Criteria

| ID | Description | Verification |
|----|-------------|-------------|
| **Feature 1 — Confidence Scoring** | | |
| SC1 | `code-review-and-quality` skill includes a confidence rubric (0/25/50/75/100 scale with definitions) | Manual: read skill body; rubric matches spec |
| SC2 | Skill emits each finding as `{description, severity, confidence, evidence, claude_md_rule?}` | Manual: run review on a sample diff; inspect output structure |
| SC3 | Findings with confidence <80 are filtered before final report | Manual: seed a known FP scenario; verify it's dropped |
| SC4 | Skill includes the FP exclusion list (pre-existing issues, lines outside diff, linter-catchable, intentional silences) | Manual: read skill body |
| SC5 | `compliance-reviewer` agent inherits the same confidence schema | Manual: read agent body |
| **Feature 2 — silent-failure-hunter** | | |
| SC6 | `.claude/agents/silent-failure-hunter.md` exists with adversarial frontmatter (read-only toolset, fork context) | `bash scripts/validate-toolkit.sh` passes |
| SC7 | Agent flags: empty catch blocks, catch-then-default-return, fallback values that mask errors, swallowed promise rejections, silenced linters/TODOs without justification | Pressure test in `tests/pressure-tests/silent-failure-hunter.md` |
| SC8 | `code-review-and-quality` dispatches to it conditionally when diff touches error-handling code (catch / try / except / fallback / default / null-coalesce) | Manual: review skill body; trace the dispatch logic |
| SC9 | Manifest entry exists; new agent listed in AGENTS.md | `bash scripts/validate-toolkit.sh` passes |
| **Feature 3 — Skill Eval Harness** | | |
| SC10 | `scripts/skill-eval/run-eval.sh` accepts `--skill <name> --prompts <file.jsonl>` and writes results to `evals/results/<skill>/<timestamp>.json` | Manual: run on `code-review-and-quality` with seeded prompts |
| SC11 | Each result entry contains `prompt`, `response_summary`, `grade` (pass/fail/partial), `grader_rationale`, `tokens`, `latency_ms` | Manual: inspect output JSON |
| SC12 | A "grader" sub-agent (Haiku) evaluates each response against per-prompt assertions in the JSONL | Manual: trace one run end-to-end |
| SC13 | `scripts/skill-eval/aggregate.sh` runs N iterations and reports pass-rate + variance (std dev) | Manual: run with `--iterations 5`; verify variance reported |
| SC14 | At least one skill (`code-review-and-quality`) ships with a starter `evals/<skill>/prompts.jsonl` of 5+ prompts | File exists; manifest entry present |
| SC15 | `scripts/validate-toolkit.sh` learns to skip `evals/results/` (gitignored) but require `evals/<skill>/prompts.jsonl` for every skill that declares `eval: true` in frontmatter | Validator passes |
| **Feature 4 — CLAUDE.md Audit Skill** | | |
| SC16 | `.claude/skills/claude-md-audit/SKILL.md` exists with full anatomy (S2.2 compliant) | Validator passes |
| SC17 | Skill scans for all CLAUDE.md files (root + nested + `~/.claude/CLAUDE.md`) and grades each on 6 weighted criteria (commands, architecture, non-obvious patterns, conciseness, currency, actionability) → A–F grade | Manual: run on this repo; grade emitted |
| SC18 | Skill outputs the rubric report **before** any edits and waits for user approval | Manual: trigger skill; verify no edit attempts before approval prompt |
| SC19 | Edits are presented as diffs; rule S1.5 (CLAUDE.md protected) is honored — append-only or replace-section edits, never full rewrites | Manual: trigger an edit; inspect mode |
| SC20 | Skill is routed by `/mtk` natural-language router (e.g., "audit CLAUDE.md", "is CLAUDE.md still good?") | Manual: invoke `/mtk` with these phrases |
| **Cross-cutting** | | |
| SC21 | `bash scripts/validate-toolkit.sh` passes on the final commit | Validator output |
| SC22 | `.claude/manifest.json` and `.claude-plugin/plugin.json` versions bumped together (minor — additive features) | Manual: diff the two files |
| SC23 | CHANGELOG.md entry documents all four features under a single version section | Manual: read CHANGELOG |

---

## Architecture and Design

### Feature 1 — Confidence-Scored Review with FP Exclusion List

**Mechanism:** Two changes to `.claude/skills/code-review-and-quality/SKILL.md`:

1. Insert a **Confidence Rubric** section the reviewer applies to each finding:

   ```
   0   — Not confident. False positive on light scrutiny, or pre-existing issue.
   25  — Somewhat confident. Might be real; couldn't verify. Stylistic, not in CLAUDE.md.
   50  — Moderately confident. Verified real but minor / nitpick relative to PR scope.
   75  — Highly confident. Verified real, will hit in practice, OR called out in CLAUDE.md.
   100 — Certain. Direct evidence of the bug; happens frequently.
   ```

2. Insert a **False-Positive Exclusion List** (verbatim from `code-review` plugin, adapted):

   - Pre-existing issues on lines the diff did not touch
   - Linter / typechecker / compiler-catchable issues (CI handles these)
   - Pedantic style nits not enumerated in CLAUDE.md
   - Issues silenced explicitly in code (lint-ignore comments with reason)
   - Plausibly intentional functional changes related to the broader change
   - Generic "lacks tests" / "could be more secure" without a concrete vector

3. Filter step: drop findings with confidence < 80 before composing the final report. Emit dropped findings in a collapsed `<details>` block for transparency (so reviewers can audit the filter).

**Output schema** (each finding):

```json
{
  "rule": "S2.4 | security-checklist:input-validation | bug | ...",
  "severity": "blocker | major | minor",
  "confidence": 85,
  "file": "src/foo.ts",
  "lines": "42-47",
  "description": "...",
  "evidence": "quoted code or CLAUDE.md excerpt"
}
```

`compliance-reviewer.md` agent gets the same schema in its system prompt so output is consistent whether the skill runs inline or dispatches to the agent.

**Why filter at 80, not lower:** The official `code-review` plugin uses 80 as the floor for posting on a real PR. MTK's audience is internal serious-software teams where false-positive fatigue kills adoption faster than missed bugs. Start at 80; tune via Feature 3 (eval harness) if data justifies moving it.

---

### Feature 2 — `silent-failure-hunter` Reviewer Agent

**File:** `.claude/agents/silent-failure-hunter.md`

**Frontmatter:**

```yaml
---
name: silent-failure-hunter
description: Adversarial reviewer that hunts silent failures — empty catches, fallbacks that mask errors, swallowed rejections, silenced linters. Read-only.
type: agent
required-toolsets: [read-only]
context: fork
effort: high
---
```

**Body covers:**

- The bug pattern catalogue (with examples per language: try/except `pass`, `catch (e) { return null }`, `?.` chains that hide nulls in audited paths, `// eslint-disable-next-line` without reason, `.catch(() => {})`, default values that diverge from "absent" semantically)
- Decision rule: **if removing the silent handler would surface a real bug at runtime, flag it.** Otherwise skip.
- Loads `.claude/references/security-checklist.md` for the audited-state subset (failures in money/permissions paths get severity bumps)
- Output uses the same Feature 1 confidence schema

**Dispatch from `code-review-and-quality`:**

```
If `git diff` matches \b(catch|except|finally|fallback|default|\?\?|\.catch\()\b
  → dispatch silent-failure-hunter in parallel with compliance-reviewer
  → merge findings, dedupe by (file, lines, rule)
```

**Pressure test** (`tests/pressure-tests/silent-failure-hunter.md`):

- Scenario A: PR adds `catch (e) {}` in a payment confirmation handler — must flag with confidence ≥ 80
- Scenario B: PR adds `try { ... } catch { logger.warn(e) }` in a non-critical telemetry path — must NOT flag (logging is not silencing)
- Scenario C: PR adds `// eslint-disable-next-line no-explicit-any` with a one-line why — must NOT flag (explicit silence with reason is fine)
- Scenario D: PR adds `result?.user?.id ?? 'anonymous'` in an authorization check — must flag (auth path, fallback masks "no user")

---

### Feature 3 — Skill Eval Harness

**Directory layout:**

```
scripts/skill-eval/
├── run-eval.sh           # entry point; one prompt → one result
├── aggregate.sh          # N iterations → pass-rate + variance
├── grader-prompt.md      # sub-agent system prompt for grading
└── lib/
    ├── render-prompt.sh  # interpolate {{vars}} into prompt template
    └── score.sh          # parse grader output → pass/fail/partial

evals/
├── code-review-and-quality/
│   └── prompts.jsonl     # 5+ test cases (input + assertions)
└── results/              # gitignored; per-skill, per-run JSON
```

**Prompt JSONL schema** (one per line):

```json
{
  "id": "cr-fp-pre-existing",
  "prompt": "Review this diff: <diff snippet that contains a known pre-existing issue>",
  "must_contain": [],
  "must_not_contain": ["pre-existing", "false positive flag"],
  "assertion": "Reviewer must NOT flag the pre-existing issue (it's outside the diff lines).",
  "expected_grade": "pass"
}
```

**Runner flow:**

1. `run-eval.sh --skill <name> --prompts <file>` reads JSONL line by line
2. For each prompt: spawn an isolated Claude subprocess with the skill loaded, feed the prompt, capture the response
3. Spawn a Haiku grader sub-agent with `grader-prompt.md` + the original assertion + the response → returns `{grade: pass|fail|partial, rationale: "..."}`
4. Append result row to `evals/results/<skill>/<ISO-timestamp>.json`

**Aggregate:** `aggregate.sh --skill <name> --iterations 5` runs the eval 5 times, computes pass-rate per prompt, reports variance. Outputs:

```
Skill: code-review-and-quality
Iterations: 5
Prompts: 7
Overall pass-rate: 86% (σ = 4.2%)
Per-prompt variance:
  cr-fp-pre-existing: 100% (σ=0%)  ← stable
  cr-confidence-threshold: 60% (σ=20%)  ← unstable, investigate
```

**Validator integration (S3.10 compliant):** `validate-toolkit.sh` adds:
- For every skill with `eval: true` in frontmatter, assert `evals/<skill>/prompts.jsonl` exists and has ≥ 5 lines
- `evals/results/` is gitignored
- `scripts/skill-eval/*.sh` follow S3.1 (set -euo pipefail, etc.)

**Why this is the right shape, not the official plugin's Python:** MTK's S3.3 forbids non-coreutils dependencies. The Python `run_eval.py` model is the right *idea* (test prompts → grader sub-agent → variance), but it must be reimplemented in bash + Claude Code subprocess invocation to honor the toolkit's portability constraint. Grader sub-agent and JSON output are the load-bearing pieces; Python is not.

**Scope boundary:** Phase 1 ships the harness + eval set for `code-review-and-quality` only. Other skills add eval sets opt-in via the `eval: true` frontmatter flag; not a forced migration.

---

### Feature 4 — `claude-md-audit` Skill

**File:** `.claude/skills/claude-md-audit/SKILL.md`

**Positioning:** Distinct from `setup-bootstrap` (one-time CLAUDE.md generation) and `setup-audit` (refreshes `architecture-principles.md`). This skill **re-grades the existing CLAUDE.md** against a rubric and proposes minimal patches. Honors S1.5 — never overwrites, only appends sections or replaces a single section after diff approval.

**Frontmatter:**

```yaml
---
name: claude-md-audit
description: Audit existing CLAUDE.md against quality rubric (commands, architecture, gotchas, conciseness, currency, actionability) and propose minimal diffs. Use periodically or when CLAUDE.md feels stale.
type: skill
trigger: claude-md-audit|memory-rot|stale-claude-md
user-invocable: true
allowed-tools: Read, Glob, Grep, Bash, Edit
argument-hint: "[--all] | [path/to/CLAUDE.md]"
required-toolsets: [read-only, edit-claude-md]
effort: high
---
```

**Workflow:**

1. **Discovery** — `find . -name CLAUDE.md -o -name .claude.local.md` + `~/.claude/CLAUDE.md`. List all matches with size + last-modified.
2. **Rubric grading** — for each file, score against 6 weighted criteria (commands /20, architecture /20, non-obvious patterns /15, conciseness /15, currency /15, actionability /15). "Currency" check: cross-reference commands in CLAUDE.md against `package.json`, `Makefile`, scripts that actually exist; flag dead commands.
3. **Report** — emit the table; STOP and wait for user approval before any edits.
4. **Targeted patches** — for each accepted recommendation, show a diff of the smallest change that fixes the gap. Bias toward append (new section) over rewrite (existing section).
5. **Apply** — `Edit` with explicit `old_string`/`new_string`. Never `Write` over CLAUDE.md.

**Pressure test** (`tests/pressure-tests/claude-md-audit.md`):

- Scenario A: CLAUDE.md has `npm run dev` but `package.json` has no `dev` script → must flag stale command, suggest correct command
- Scenario B: CLAUDE.md is 800 lines of generic best practices → must flag conciseness, suggest cutting (but require user approval — never auto-delete)
- Scenario C: CLAUDE.md is fine → must say so plainly and not invent improvements (rationalization trap: "I should find at least one issue")

**Routing:** Add to `/mtk` router:
- "audit CLAUDE.md" → claude-md-audit
- "is CLAUDE.md still good" → claude-md-audit
- "memory rot" → claude-md-audit

**Why a separate skill, not a phase of `setup-audit`:** `setup-audit` writes `architecture-principles.md` from a fresh codebase scan. CLAUDE.md audit is a **diff against existing intent** — different inputs, different output, different cadence. Folding them muddles both. They share a verb ("audit"); they don't share a workflow.

---

## Manifest Changes

```json
{
  ".claude/skills/claude-md-audit/SKILL.md": {
    "source": ".claude/skills/claude-md-audit/SKILL.md",
    "target": ".claude/skills/claude-md-audit/SKILL.md",
    "action": "sync",
    "description": "Audits existing CLAUDE.md files against a quality rubric and proposes minimal diffs"
  },
  ".claude/agents/silent-failure-hunter.md": {
    "source": ".claude/agents/silent-failure-hunter.md",
    "target": ".claude/agents/silent-failure-hunter.md",
    "action": "sync",
    "description": "Adversarial reviewer that hunts silent failures and fallbacks that mask errors"
  },
  "scripts/skill-eval/run-eval.sh": {
    "source": "scripts/skill-eval/run-eval.sh",
    "target": "scripts/skill-eval/run-eval.sh",
    "action": "sync",
    "description": "Runs a single skill eval prompt and writes a graded result"
  },
  "scripts/skill-eval/aggregate.sh": {
    "source": "scripts/skill-eval/aggregate.sh",
    "target": "scripts/skill-eval/aggregate.sh",
    "action": "sync",
    "description": "Runs N eval iterations and reports pass-rate plus variance"
  },
  "scripts/skill-eval/grader-prompt.md": {
    "source": "scripts/skill-eval/grader-prompt.md",
    "target": "scripts/skill-eval/grader-prompt.md",
    "action": "sync",
    "description": "Sub-agent system prompt used by the eval grader"
  },
  "evals/code-review-and-quality/prompts.jsonl": {
    "source": "evals/code-review-and-quality/prompts.jsonl",
    "target": "evals/code-review-and-quality/prompts.jsonl",
    "action": "sync",
    "description": "Starter eval prompt set for code-review-and-quality skill"
  },
  "tests/pressure-tests/silent-failure-hunter.md": {
    "source": "tests/pressure-tests/silent-failure-hunter.md",
    "target": "tests/pressure-tests/silent-failure-hunter.md",
    "action": "sync",
    "description": "Adversarial pressure test for silent-failure-hunter agent"
  },
  "tests/pressure-tests/claude-md-audit.md": {
    "source": "tests/pressure-tests/claude-md-audit.md",
    "target": "tests/pressure-tests/claude-md-audit.md",
    "action": "sync",
    "description": "Adversarial pressure test for claude-md-audit skill"
  }
}
```

Plus an entry in `.gitignore` for `evals/results/`.

---

## Implementation Plan

Suggested batching for `planning-and-task-breakdown`:

| Batch | Scope | Files | Verification |
|-------|-------|-------|-------------|
| 1 | Feature 1 — confidence schema + FP list | `code-review-and-quality/SKILL.md`, `compliance-reviewer.md` | Re-run review on a known-noisy diff; compare finding count before/after |
| 2 | Feature 2 — silent-failure-hunter agent + dispatch + pressure test | `silent-failure-hunter.md`, `code-review-and-quality/SKILL.md` (dispatch), `tests/pressure-tests/silent-failure-hunter.md`, AGENTS.md, manifest | Pressure-test scenarios A–D produce expected flag/no-flag |
| 3 | Feature 4 — claude-md-audit skill + pressure test + `/mtk` routing | `claude-md-audit/SKILL.md`, `mtk/SKILL.md` (routes), `tests/pressure-tests/claude-md-audit.md`, manifest | Run skill on this repo's CLAUDE.md; grade emitted; no edits without approval |
| 4 | Feature 3 — eval harness + starter eval set + validator hook | `scripts/skill-eval/*`, `evals/code-review-and-quality/prompts.jsonl`, `validate-toolkit.sh` (skip results dir, require prompts.jsonl when `eval: true`), `.gitignore`, manifest | `bash scripts/skill-eval/aggregate.sh --skill code-review-and-quality --iterations 3` produces a pass-rate report |
| 5 | Wrap — version bump, CHANGELOG, validator pass | `manifest.json`, `plugin.json`, `CHANGELOG.md` | `bash scripts/validate-toolkit.sh` passes |

Batches 1–4 are independent and can ship as separate PRs if needed. Recommend Batch 1 first (lowest risk, immediate visible improvement to review noise), Batch 3 next (CLAUDE.md audit is a clean addition), then Batch 2, finally Batch 4 (touches validator).

---

## Risks and Trade-offs

| Risk | Mitigation |
|------|-----------|
| Confidence threshold of 80 silently hides real bugs | Emit filtered findings in a collapsed `<details>` block so reviewers can audit. Tune threshold via Feature 3 evals once data accumulates. |
| `silent-failure-hunter` becomes pedantic about defensive `?.` chains | Pressure test scenarios B and C are explicitly designed against this. Decision rule: "would removing the silent handler surface a real bug?" — answers no for telemetry/logging paths. |
| Eval harness creates a maintenance treadmill (every skill change breaks eval) | Eval is opt-in (`eval: true` frontmatter flag). Phase 1 covers one skill only. Variance reporting reveals brittle prompts so they can be removed, not patched. |
| `claude-md-audit` rationalizes inventing issues to look useful | Pressure test scenario C asserts the "no issues found" path. Skill body must include the rationalization trap explicitly. |
| Bash reimplementation of skill-creator's Python is less capable | Accepted trade-off for S3.3 compliance. The load-bearing piece (grader sub-agent) is platform-agnostic; only orchestration is bash. |

---

## Out of Scope (Explicitly Deferred)

- Porting `comment-analyzer` and `type-design-analyzer` from `pr-review-toolkit` — useful but lower ROI than silent-failure-hunter; revisit after Feature 2 ships
- Multi-architecture pitch from `feature-dev` (parallel architects offering trade-off variants in `implement` skill) — non-trivial UX change to the implement workflow; spec separately if desired
- Description auto-tuning from `skill-creator`'s `improve_description.py` — depends on Feature 3 being in place first; revisit once eval data exists for ≥3 skills
- Per-pattern security reminders (the `security-guidance` plugin's deduped per-session warnings) — overlaps with existing `security-gate.sh`; would be a refactor, not an addition
