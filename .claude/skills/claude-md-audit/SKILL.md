---
name: claude-md-audit
description: Use periodically or when CLAUDE.md feels stale, drifts from the codebase, or commands break — audits CLAUDE.md against a quality rubric and proposes minimal append-only diffs.
type: skill
license: MIT
compatibility:
  - claude-code
  - cursor
  - codex
trigger: claude-md-audit|memory-rot|stale-claude-md|claude-md-quality
skip_when: bootstrap|first-time-setup|no-existing-claude-md
user-invocable: false
---

# CLAUDE.md Audit

## Current Audit Targets

```!
echo "--- Existing CLAUDE.md files ---"
{ find . -maxdepth 6 -name CLAUDE.md -not -path "./.git/*" -not -path "*/node_modules/*" 2>/dev/null; \
  find . -maxdepth 4 -name ".claude.local.md" 2>/dev/null; } | sort -u
echo "--- ~/.claude/CLAUDE.md ---"
test -f "$HOME/.claude/CLAUDE.md" && echo "$HOME/.claude/CLAUDE.md ($(wc -l < "$HOME/.claude/CLAUDE.md") lines)" || echo "(absent)"
echo "--- Tech stack ---"
cat .claude/tech-stack 2>/dev/null || echo "(not set)"
```

## Overview

Audit existing CLAUDE.md files against a quality rubric, then propose minimal
append-only diffs. This is a **re-grade loop**, not a regeneration. The skill
honors rule S1.5 (CLAUDE.md is protected) — it never overwrites and never
rewrites whole sections without explicit user approval.

This skill is distinct from `setup-bootstrap` (one-time creation of CLAUDE.md
from a fresh codebase scan) and `setup-audit` (refreshes
`architecture-principles.md`, not CLAUDE.md). Audit grades intent against
reality; bootstrap creates intent from scratch.

## When To Use

- Periodic CLAUDE.md health check (recommended every 4-8 weeks)
- After significant codebase changes that may have invalidated documented commands
- When AI sessions start hitting friction that suggests stale context (broken
  build commands, references to deleted files, missing recent conventions)
- When the engineer says "CLAUDE.md feels off" or "is the AI seeing the right things?"

### When NOT To Use

- First-time setup of a repo — use `/mtk-setup` (which runs `setup-bootstrap`)
- Refreshing architecture principles — use `/mtk-setup --audit` (which runs
  `setup-audit`)
- Repos with no CLAUDE.md yet — bootstrap first; audit only re-grades existing
  intent
- After a single session of edits — the rot worth detecting takes weeks to
  accumulate; auditing too often manufactures churn

## Workflow

### Phase 1 — Discovery

The dynamic-context block at the top of this skill already lists target files.
Confirm the inventory before proceeding. If the project root has no CLAUDE.md,
**stop and tell the user to run `/mtk-setup` first** — there is no intent to
audit.

For each file found, record: absolute path, line count, last-modified date.

### Phase 2 — Currency Cross-Checks

Currency is the most common rot. For the project-root CLAUDE.md, run these
checks before scoring:

1. **Commands referenced exist.** Extract any `bash`, `dotnet`, `npm`, `pnpm`,
   `python`, `make`, `pytest`, or `cargo` lines from CLAUDE.md. For each:
   - If it references a script (`scripts/foo.sh`), confirm the file exists.
   - If it references a package script (`npm run X`), confirm `X` is in
     `package.json` `scripts`.
   - If it references a Makefile target, confirm the target exists.
   - If it references a `dotnet` solution / project, confirm the file exists.
2. **Files and paths referenced exist.** Extract any path-like strings
   (`src/...`, `tests/...`, `app/...`). Confirm each path resolves. Stale
   paths from old layouts are common rot.
3. **Tech stack matches.** Read `.claude/tech-stack`. If CLAUDE.md describes a
   different stack, that is a Critical currency issue.

Record each broken reference. These are evidence for the Currency criterion.

### Phase 3 — Rubric Scoring

For each CLAUDE.md, score against six weighted criteria:

| Criterion             | Weight | Definition |
|-----------------------|--------|------------|
| Commands & workflows  | 20     | Are build / test / dev / lint commands documented and current? |
| Architecture clarity  | 20     | Can a new agent understand the codebase shape in one read? |
| Non-obvious patterns  | 15     | Are gotchas, conventions, and project-specific quirks captured? |
| Conciseness           | 15     | Is the file dense — no verbose preamble, no restating the obvious? |
| Currency              | 15     | Do all referenced commands and paths still resolve? (Phase 2 evidence) |
| Actionability         | 15     | Are rules concrete enough to act on, vs. vague platitudes? |

Map total to grade: **A** 90-100, **B** 70-89, **C** 50-69, **D** 30-49,
**F** 0-29.

### Phase 4 — Quality Report (No Edits Yet)

**Stop before any edit.** Emit the report and wait for user approval.

```
## CLAUDE.md Quality Report

### Files audited
- ./CLAUDE.md — 142 lines, last modified 2026-03-12

### Project root: ./CLAUDE.md
**Score: 78/100 — Grade B**

| Criterion             | Score | Notes |
|-----------------------|-------|-------|
| Commands & workflows  | 14/20 | `npm run dev` no longer in package.json (now `pnpm dev`) |
| Architecture clarity  | 18/20 | Clear, but does not mention the recent /workers split |
| Non-obvious patterns  | 12/15 | Captures EF Core gotchas; missing the new auth middleware quirk |
| Conciseness           | 14/15 | Tight; no obvious bloat |
| Currency              |  9/15 | 1 broken script ref, 1 deleted file path |
| Actionability         | 11/15 | Some rules are aspirational ("write good tests") |

**Broken references found:**
- Line 24: `npm run dev` — script no longer exists
- Line 91: `src/legacy/auth.ts` — file deleted in #1207

**Recommended additions (will show as diffs after approval):**
- Update line 24 build command to current pnpm script
- Add gotcha section for the new auth middleware
- Remove or rewrite line 91 path reference

**Recommended removals:**
- (none — biased against deletion without approval)
```

Then ask: **"Approve these changes? (yes / partial / no)"**

### Phase 5 — Targeted Diffs

After explicit approval, emit one diff per accepted change. Bias toward append
or replace-single-line over rewrite. **Never `Write` over CLAUDE.md.** Always
use `Edit` with explicit `old_string` / `new_string`.

For each change, the diff block follows this shape:

```
### Change 1: ./CLAUDE.md line 24

**Why:** `npm run dev` no longer exists; `pnpm dev` is the current command.

**Before:**
\`\`\`
- Run dev server: `npm run dev`
\`\`\`

**After:**
\`\`\`
- Run dev server: `pnpm dev`
\`\`\`
```

If the user approved "partial", apply only the explicitly named subset.

### Phase 6 — Verification

After applying edits:

1. Re-run the Phase 2 currency checks on the modified file.
2. Confirm line count is within 10% of original (no accidental rewrite).
3. Report the new grade.

## Rules

- **Never auto-delete content.** The user owns CLAUDE.md. Removals require
  explicit per-line approval; "approve all" does not authorize deletions.
- **Never invent issues to look useful.** If the file is genuinely clean, say
  so. The anti-sandbagging rule from
  `.claude/references/review-finding-schema.md` applies.
- **Append over rewrite.** New gotchas and commands go at the end of the
  relevant section, not into a restructured replacement.
- **Use `Edit`, never `Write`.** The protected-file rule (S1.5) means Write
  on CLAUDE.md is a bug, even if the engineer asks for it.
- **Honor the active CLAUDE.md style.** If the file uses tables, additions
  should use tables. If it uses bullet lists, match that. Do not impose a
  template.

## Common Rationalizations

See `.claude/skills/context-engineering/SKILL.md` for the shared MTK
rationalization table. Audit-specific traps:

- **"I should find at least one issue per criterion."** No. Empty findings
  with rationale beats manufactured ones.
- **"This whole section is stale; I should rewrite it."** No. Propose a diff
  of the smallest change that fixes the gap, then ask. Wholesale rewrites are
  the engineer's call, not the skill's.
- **"The codebase has so many new conventions; I should add them all."**
  Captures should be specific to *this* CLAUDE.md, not a generic best-practices
  dump. If a convention is not yet enforced, it doesn't belong here.

## Red Flags

- Audit report with no rubric scores (just prose impressions)
- Edits applied before user approval
- A "rewrite the whole file" proposal in Phase 4
- Currency cross-checks skipped — broken-command rot is the highest-value
  finding and must not be missed

## Verification

- [ ] Phase 2 currency checks ran and broken references are listed (or "none
      found" stated explicitly)
- [ ] Each CLAUDE.md got a six-criterion rubric score and grade
- [ ] No edits applied before user approval
- [ ] Edits used `Edit` tool with explicit old/new strings (never `Write`)
- [ ] Post-edit line count is within 10% of original
- [ ] Report names specific lines and reasons; no vague "could be improved"
