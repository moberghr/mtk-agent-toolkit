---
name: bootstrap-report
description: The STEP 5 verbatim verification-and-report template for setup-bootstrap — the final MTK INIT COMPLETE block that ~15 earlier steps route their report lines into and verify-claims.sh consumes. Read on-demand by setup-bootstrap STEP 5.
globs: [".claude/skills/setup-bootstrap/**"]
alwaysApply: false
---

# Setup Bootstrap — Verify & Report Template (STEP 5)

Read this companion from `setup-bootstrap` STEP 5 ("Verify & Report"). Emit this report verbatim, filling the [bracketed] placeholders — do not paraphrase it from memory. Roughly 15 earlier steps route their report lines into this template and `scripts/verify-claims.sh` consumes the output.

```
✅ MTK INIT COMPLETE

Project: [name]
Tech stack: [stack name from .claude/tech-stack]
Secondary stacks: [comma-separated list, or "none"] — workflow skills (implement/fix) operate on the primary stack only.
Ingested AI configs: [list of source paths, or "none found"]

Standards sources:
  ✓ Tech stack skill: .claude/skills/tech-stack-{stack}/SKILL.md
  ✓ Coding guidelines: .claude/references/{stack}/coding-guidelines.md
  ✓ Architecture principles: .claude/references/architecture-principles.md [or ⚠️ not found]
  ✓ Codebase scan: [N] files across [N] projects/modules

Generated/Updated:
  ✓ .claude/tech-stack: [stack]
  ✓ CLAUDE.md ([N] lines — under 120 ✓)
  ✓ .claude/rules/ — [N] rule files generated
  ✓ .claude/references/pre-commit-review-list.md — [generated with N items | already exists, skipped]
  ✓ .claude/references/product.md — [generated | preserved (existing)]
  ✓ .claude/references/decisions.md — [seeded | preserved (existing)]
  ✓ .claude/settings.json — merged [N] stack-specific entries
  ✓ Git pre-commit hook: [installed | ⚠️ existing hook found, skipped]
  ✓ Tool prerequisites: [all found | ⚠️ N missing — see details above]
  ✓ Command verification: [N verified, N unverified, N skipped | skipped via --no-verify-commands]
  [if any unverified:]
      ⚠️ [name]: [first line of detail from verify-commands.sh]
  [if monorepo:]
  ✓ Monorepo detected — [N] packages found
      ✓ Generated per-package CLAUDE.md for: [list of packages]
      [⚠️ Skipped (already exists): list of packages]

Preserved hand-authored files (untouched):
  [list any pre-existing nested CLAUDE.md, custom commands/rules, or other non-MTK files left in place — or "none found"]
Retired prior MTK files (explicitly removed this run):
  [list any MTK-owned files this re-run superseded — or "none". If this section is non-empty, each entry must be an MTK-owned file, never hand-authored content.]

Updated: [N] | Created: [N] | Preserved (untouched): [N] | Needs review: [N]
[if Needs review > 0:]
Needs review:
  [one line per item — file path + the conflicting hunk/region that could not be auto-applied, per .claude/references/regen-diff-contract.md]

Codebase findings:
  [stack-specific summary based on scan]

Skills available:
  /mtk <feature>         — Full feature loop
  /mtk fix <description> — Quick fix (1-3 files)
  /mtk review before commit — Fast security-focused review of staged changes
  /mtk-setup --audit     — Re-run architecture audit
Keep CLAUDE.md fresh: press # mid-session to append a learning instantly; run claude-md-capture at session end to propose session learnings as diffs (personal notes → .claude.local.md).
Next: Try it with:
  /mtk Add [your feature description here]
```
