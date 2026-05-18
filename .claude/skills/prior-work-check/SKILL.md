---
name: prior-work-check
description: Use before approving a spec or starting a multi-file implementation to confirm no existing skill, helper, handler, or lesson already covers the proposed work.
type: skill
license: MIT
compatibility:
  - claude-code
  - codex
trigger: pre-spec-approval|pre-implementation|duplication-risk|new-capability
skip_when: typo-fix|config-update|trivial-change
user-invocable: false
effort: high
required-toolsets: [read-only]
---

# Prior Work Check

## Overview

Before writing new code, confirm the codebase doesn't already do this. The
single most common cause of waste in mature codebases is re-implementing a
capability that already exists under a different name. Three deterministic
pre-task queries run against MTK's file-based artifacts (lessons, specs,
code index) before a spec is approved or a planner opens a batch.

Three deterministic queries run against the repo. Each must complete before
the spec is handed to the approval gate or the planner begins task breakdown.

## When To Use

- Before `spec-driven-development` Phase 1.5 approval check
- Before `planning-and-task-breakdown` opens a batch
- When the engineer says "let's add an X" and X sounds generic (cache, retry,
  validator, formatter, normalizer)
- When the change manifest names files in an area you haven't touched recently

### When NOT To Use

- Typo fixes, single-line config tweaks
- Bug fixes where the file in scope is already named
- Changes inside a clearly-isolated feature module with no shared surface

## Workflow

### Query 1 — `search_prior_work`

Look for an existing implementation of the capability under any name.

1. Extract 2-4 capability keywords from the spec `summary` and
   `success_criteria`. Verbs + nouns ("issue token", "retry policy",
   "currency formatter").
2. Run, in parallel:
   - `grep -rn -i "<keyword>" --include="*.{cs,py,ts,tsx,js}" src/` (or the
     active stack's source roots — read `.claude/tech-stack`).
   - If `CODE_INDEX.md` exists at the repo root, `grep -i "<keyword>" CODE_INDEX.md`.
   - If an MCP code-index tool is available (e.g. `mcp__gitnexus__query`,
     `mcp__ast-index__*`), prefer it over raw grep.
3. For each hit, report:
   - file:line
   - one-line summary of what it does
   - whether it can be reused, extended, or is genuinely different

### Query 2 — `get_constraints`

Surface the rules and lessons that govern this area.

1. Read `tasks/lessons.md` and `.claude/lessons/personal.md` (if present).
   Grep for the capability keywords and the touched module names.
2. Read `.claude/references/architecture-principles.md` and grep for tags
   matching the touched slice. Note any `[EXTRACTED]` principles that
   constrain the design — these block contradicting changes.
3. Read CLAUDE.md and any `.claude/rules/*.md` file whose name matches the
   slice (e.g. `git-workflow.md` for git-touching work).
4. Report every constraint discovered, with severity:
   - `block` — EXTRACTED principle or explicit lesson "never do X"
   - `flag` — INFERRED ≥0.7 principle or "prefer X"
   - `note` — soft preference or general guidance

### Query 3 — `get_risk_profile`

Identify the risk surface this change crosses.

1. Map the `change_manifest[].path` entries to risk categories:
   - **regulated** — auth, payments, audit, PII, financial-state
   - **boundary** — public API, exported contracts, migrations, message bus
   - **shared** — utilities used by 3+ slices
   - **isolated** — single-slice internal change
2. For each non-isolated category, list the reviewers/agents that must run
   in Phase 4 (compliance-reviewer always for regulated; architecture-reviewer
   for boundary; etc.).
3. Confirm `security_impact` in the spec matches the highest risk category.
   If `security_impact: none` but a regulated path is touched, **emit a
   BLOCKING finding** — the spec is mis-classified.

## Output

Emit one fenced block summarizing all three queries:

```markdown
### Prior Work Check

**Query 1 — search_prior_work**
- match: src/Auth/TokenService.cs:42 — already issues JWTs. **Reuse, do not
  reimplement.** Spec should be revised to extend, not create.
- (no other matches)

**Query 2 — get_constraints**
- block: tasks/lessons.md L88 — "never store raw tokens; always Argon2id hash"
- flag: architecture-principles.md [INFERRED:0.85] — "auth changes go via
  AuthSlice/Handlers"

**Query 3 — get_risk_profile**
- regulated: src/Auth/*.cs — compliance-reviewer required in Phase 4
- spec declares `security_impact: low` → **mis-classified, should be `high`**
```

## Verdict

- Any **BLOCK** finding (existing implementation, EXTRACTED contradiction,
  mis-classified security impact) → `BLOCKED`. Spec must be revised before
  the approval gate runs.
- Any **FLAG** → `PROCEED_WITH_CHANGES` — surface to the engineer; they
  decide whether to amend the spec or justify the deviation in writing.
- Only **NOTE** findings (or none) → `PASS`.

## Integration

- `spec-driven-development` runs this skill at Phase 1.5 before the approval
  prompt. A BLOCKED verdict means the spec is not eligible for approval.
- `planning-and-task-breakdown` runs this skill again if the spec was
  approved more than a session ago — risk profile and prior work may have
  shifted.
- `code-simplification --audit-duplicates` uses Query 1's grep recipe to
  find duplicate capabilities across the codebase.

## Rules

- Three queries always run — no skipping "because the area is obvious".
- A grep miss is not the same as a confirmed absence. If grep finds nothing
  but the capability is generic ("validator", "formatter"), widen the
  search with synonyms before declaring `PASS`.
- This skill does not edit files. It only reports.
- Findings are deterministic where possible. Don't downgrade severity based
  on convenience.

## Common Rationalizations

See `.claude/skills/context-engineering/SKILL.md` for the shared table.
Prior-work-specific traps: "I already grepped during planning" (you grepped
for the spec's chosen name — re-grep for the capability under other names),
"there's nothing in lessons.md about this" (re-read with synonyms — lessons
are written in human prose, not your chosen keywords), and "security_impact
is conservative enough" (regulated paths drive the floor; never the
engineer's gut feel).

## Red Flags

- Skipped Query 1 because "I already know there's no implementation"
- Query 2 read lessons.md but didn't grep architecture-principles.md
- Query 3 produced `regulated` matches but the spec's `security_impact`
  wasn't reclassified
- Verdict `PASS` with one or more BLOCK findings hidden in the body

## Verification

- [ ] All three queries ran with output captured
- [ ] At least one synonym/alternate keyword was tried in Query 1
- [ ] Lessons AND architecture principles AND CLAUDE.md were consulted in Query 2
- [ ] Every path in `change_manifest` was classified in Query 3
- [ ] `security_impact` was compared against Query 3's highest category
- [ ] Verdict matches the highest-severity finding
