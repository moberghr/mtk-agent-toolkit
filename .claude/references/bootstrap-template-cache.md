---
name: bootstrap-template-cache
description: STEP 4.8 template-cache snapshot spec for setup-bootstrap — files to snapshot, cache layout, copy implementation, and retention. Read on-demand by setup-bootstrap STEP 4.8.
globs: [".claude/skills/setup-bootstrap/**"]
alwaysApply: false
---

# Setup Bootstrap — Seed Template Cache (STEP 4.8)

Read this companion from `setup-bootstrap` STEP 4.8 ("Seed Template Cache").

After every generated file is written to disk, also write an **unmodified copy of the template output** to `.claude/.mtk-cache/v<MANIFEST_VERSION>/`. This cache is what `--audit` re-runs diff against for 3-way merges. The cache is gitignored.

Files to snapshot (skip any the engineer declined in `--preview`):
- `CLAUDE.md`
- `AGENTS.md`
- `.claude/rules/*.md`
- `.claude/references/pre-commit-review-list.md`
- `.claude/references/architecture-principles.md` (when this bootstrap generated it)
- `.claude/references/conventions.md` (when this bootstrap generated it)
- `.claude/references/product.md` (when this bootstrap generated it — STEP 3.8)
- `.claude/references/decisions.md` (when this bootstrap generated it — STEP 3.8)
- `.claude/detected-tools.json`

Layout:
```
.claude/.mtk-cache/
  v7.0.0/
    CLAUDE.md
    AGENTS.md
    rules/
      security.md
      ...
    references/
      pre-commit-review-list.md
```

Implementation:
```bash
PM="${CLAUDE_PLUGIN_ROOT:-.}/.claude/manifest.json"
VERSION=$(python3 -c "import json; print(json.load(open('$PM'))['version'])")
CACHE_DIR=".claude/.mtk-cache/v${VERSION}"
mkdir -p "$CACHE_DIR/rules" "$CACHE_DIR/references"
# For each generated file, copy the pre-write version (not the on-disk edited one):
cp /tmp/mtk-staging/CLAUDE.md "$CACHE_DIR/CLAUDE.md"
# ...etc for each file
```

Retention: keep at most the 2 most recent versions. Older versions are pruned at this step.
