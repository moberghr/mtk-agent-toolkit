---
name: audit-merge-mode
description: The entire setup-audit MERGE MODE (--merge) branch — STEP 0-3 flow, Confidence Tag Merge Rules, the unified-document template, and the merge-mode read-only invariants — read only when setup-audit is invoked with --merge.
globs: [".claude/skills/setup-audit/**"]
alwaysApply: false
---

# Setup Audit — MERGE MODE (--merge)

Unify the per-repo audits in `.claude/references/audits/` into one team-wide `.claude/references/architecture-principles.md`. The only file written is that output. The input audits are never modified.

## STEP 0: Locate Inputs

`ls -la .claude/references/audits/`. If it is empty or missing, tell the engineer: run `/mtk-setup --audit` in each repo, copy each `architecture-principles.md` here as `audits/<repo>.md`, then re-run `/mtk-setup --merge`.

## STEP 1: Analyze Across Audits

Per section, sort each principle into **consistent** (same everywhere: a team standard), **different** (same concern, different patterns: needs alignment, with a recommendation), or **unique** (one repo: project-specific).

**Confidence Tag Merge Rules (S1.15):**
- All sources `[EXTRACTED]` and agreeing → `[EXTRACTED]`.
- Mixed tags, or any source `[INFERRED]` → `[INFERRED:min(confidences)]`, citing each source repo.
- Sources contradict → `[AMBIGUOUS]` with both source pointers.
- Only one repo → keep its tag; mark it project-specific.

Every merged line keeps its evidence anchors, prefixed with the source repo.

## STEP 2: Generate Unified Document

If the output already exists, ask via `AskUserQuestion` before overwriting, and write through `mtk_guarded_write` (`hooks/lib/shrink-guard.sh`, S3.16).

```markdown
# Architecture Principles

> Unified from audits of: [repos] · Generated: [date]

## Team-Wide Standards
## Recommended Alignments
⚠️ [differing patterns, with a recommendation]
## Project-Specific Patterns
### <repo>
```

## STEP 3: Present Results

Present the doc and list the alignment decisions. The team makes them: flag each one, never decide it.
