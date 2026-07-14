---
name: audit-merge-mode
description: The entire setup-audit MERGE MODE (--merge) branch — STEP 0-3 flow, Confidence Tag Merge Rules, the unified-document template, and the merge-mode read-only invariants — read only when setup-audit is invoked with --merge.
globs: [".claude/skills/setup-audit/**"]
alwaysApply: false
---

# Setup Audit — MERGE MODE (--merge)

Read this companion when `setup-audit` is invoked with `--merge`. It carries the full multi-repo unification flow that the `# MERGE MODE (--merge)` section of the skill defers to.

You have audited multiple repositories and now want a single, unified architecture principles document. This mode reads audit files from `.claude/references/audits/` and produces a unified doc.

## STEP 0: Locate Inputs

```bash
ls -la .claude/references/audits/
```

Each file is an architecture audit from a different project (e.g., `payfac.md`, `collection-system.md`, `bnpl.md`).

If the directory is empty or doesn't exist, tell the engineer:
> "No audit files found. To use --merge:
> 1. Run `/mtk-setup --audit` (without --merge) in each repo (payfac, collection-system, etc.)
> 2. Copy each generated `.claude/references/architecture-principles.md` into THIS repo at:
>    `.claude/references/audits/payfac.md`
>    `.claude/references/audits/collection-system.md`
>    etc.
> 3. Run `/mtk-setup --merge` again."

## STEP 1: Analyze Across Audits

For each section of the architecture doc, compare across all audits:

### What's Consistent (standardize on this)
- Patterns used the same way across all projects → these are your team's actual standards
- Same tools and frameworks → these are your tech stack

### What's Different (team needs to decide)
- Different patterns for the same concern → flag as "needs alignment"
- Different conventions → flag with a recommendation

### What's Unique (project-specific)
- Patterns that only appear in one project → document as project-specific, not team-wide

### Confidence Tag Merge Rules (S1.15)

Per-repo audits already carry `[EXTRACTED] / [INFERRED:N] / [AMBIGUOUS]` tags (see STEP 3 of single-repo audit). When merging:

- All sources tag the principle `[EXTRACTED]` and agree → keep `[EXTRACTED]`.
- Mixed tags or one source `[INFERRED]` → output `[INFERRED:min(confidences)]`. Cite both source repos.
- Sources contradict the principle itself → output `[AMBIGUOUS]` with both source pointers.
- A principle appears in only one repo → keep its original tag, mark as project-specific.

## STEP 2: Generate Unified Document

Generate `.claude/references/architecture-principles.md` (overwriting if it already exists — ask via AskUserQuestion first):

```markdown
# Moberg Architecture Principles

> Unified from audits of: [list repos]
> Generated: [date]
>
> This document defines team-wide architectural standards.
> Project-specific patterns are noted where they differ.

---

## Team-Wide Standards
[Patterns consistent across ALL scanned projects]

## Recommended Alignments
⚠️ [Patterns that differ between projects — with recommendation on which to standardize]

## Project-Specific Patterns
### PayFac
[Unique patterns]
### Collection System
[Unique patterns]
[etc.]
```

## STEP 3: Present Results

Present the unified doc and highlight the key decisions the team needs to make. Do not make standardization decisions for the team — flag them clearly so engineers can debate and decide.

## MERGE MODE — IMPORTANT
- This mode is READ-ONLY except for writing the unified output document
- If `.claude/references/architecture-principles.md` already exists, use AskUserQuestion before overwriting
- Do not modify the input audit files in `.claude/references/audits/`
