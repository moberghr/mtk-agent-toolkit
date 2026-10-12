---
name: audit-rerun-migration
description: Migration Path (pre-v7 to v7+), Re-Run Merge Logic with the re-run summary table, and the generated-doc stamp-block format including the re-run-only delta fields — read by setup-audit at STEP -1 (migration/re-run branch) and STEP 3.7 (stamp).
globs: [".claude/skills/setup-audit/**"]
alwaysApply: false
---

# Setup Audit — Re-Run, Migration & Stamp Detail

Read this companion from `setup-audit` when STEP -1 classifies the run as a migration or a clean re-run (the Migration Path and Re-Run Merge Logic sections below), and from STEP 3.7 for the stamp-block format.

## Migration Path (pre-v7 → v7+)

The engineer is running `--audit` on a repo that was bootstrapped before the versioned cache existed. Prompt via `AskUserQuestion`:

```
question: "No previous template cache found. How should I treat the current generated files?"
header: "v7.0.0 migration"
options:
  - label: "hand-edited"
    description: "Current files contain engineer edits. I'll diff the new template against them and surface conflicts — won't clobber your edits."
  - label: "stock"
    description: "Current files are unmodified from the last bootstrap. Safe to overwrite with the new template."
  - label: "cancel"
    description: "Stop — I'll investigate first."
```

On `hand-edited`: follow the **no-ancestor** procedure in `.claude/references/regen-diff-contract.md` §3a — propose **only additive hunks** from the fresh template; never derive removal proposals by diffing the fresh template against the engineer's on-disk content. Sections the fresh template no longer emits are listed informationally under Needs review, not proposed as deletions.

On `stock`: copy existing files into `.claude/.mtk-cache/v${CURRENT_VERSION}-migration/` as pseudo-previous-template, then proceed to Re-Run Merge Logic. New template will cleanly overwrite.

On `cancel`: exit without modifying anything.

## Re-Run Merge Logic

For each file the audit would regenerate (`.claude/references/architecture-principles.md` is the primary target — other files only if bootstrap-mode and this section is reused from there), classify against the cached ancestor before touching anything:

```bash
PREV="${PREV_CACHE}/<file>"    # ancestor: previous stock template
CURRENT="<file>"                # what's on disk now
```

Classify and resolve every file per `.claude/references/regen-diff-contract.md` — read it now and follow §2 (classification), §3/§3a (proposals), §4 (cache rule), and §6 (invariants: the AskUserQuestion gate is not skippable, non-interactive runs defer engineer-edited files to NEEDS REVIEW, deletion is never an outcome). Do not restate or improvise the contract's rules here; report using its RESULT values.

At end of STEP -1, print a re-run summary:
```
📋 RE-RUN PLAN

FILE                                           CLASSIFICATION    RESULT
.claude/references/architecture-principles.md  engineer-edited   PROPOSED (4 hunks: 3 applied, 1 skipped)
.claude/references/conventions.md              stock             OVERWRITTEN (stock)
CLAUDE.md                                      protected         SKIP (protected)
.claude/rules/security.md                      protected         SKIP (protected)
```

RESULT values and their meanings are defined in the contract's §5; `SKIP (protected)` applies per the contract's protected-scope rule (`manifest.protected` minus this audit's own declared outputs — which is why `architecture-principles.md` is PROPOSED above while `CLAUDE.md` is SKIP).

If any file has `NEEDS REVIEW` hunks, print: "Re-run left <N> file(s) with hunks needing review. Resolve before the next `--audit` run."

After re-run merge, update `.claude/.mtk-cache/v${CURRENT_VERSION}/` per the contract's §4 cache rule (fresh stock template, fully-resolved files only). Then proceed to the report step (do not re-run STEP 0-4; the merge already produced the new content).

## Stamp

Prepend a stamp block to each generated doc (after the first `>` blockquote, before the body):

```
<!-- mtk-stamp
audited-against: $(git rev-parse HEAD)
audited-at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
mtk-version: <from .claude/manifest.json>
previous-stamp: <previous audited-against sha, or "none">
sections-changed: <comma-separated H2 titles, or "none">
claims-delta: +<added> ~<modified> -<removed>
-->
```

The last three fields (`previous-stamp`, `sections-changed`, `claims-delta`) are **re-run-only** — a fresh first run (no prior stamped doc) omits them entirely. Compute them by diffing the regenerated doc against its previous on-disk version **before writing**: `previous-stamp` is the prior `audited-against` value (or `"none"` if there was no prior stamp); `sections-changed` lists the `##` headings whose content differs (or `"none"`); `claims-delta` counts tagged claim lines added/modified/removed between the two versions. This is the audit trail for what a re-run actually changed.

For `CLAUDE.md` (written by `setup-bootstrap`), the stamp lives in a **footer** comment block — human edits collect above it.
